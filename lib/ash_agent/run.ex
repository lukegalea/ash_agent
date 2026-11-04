# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Run do
  @moduledoc """
  A Spark fragment for a durable agent run: one row per run of an agent version, which
  is its own checkpoint. A run is rows and a trigger, not a process: each step is one
  job that claims the run, makes one model call with no transaction open, and records
  what came back under the lease it claimed. A worker that dies loses at most the call
  it was making; the next job carries on from the journal.

      defmodule MyClinic.Execution.Run do
        use Ash.Resource,
          domain: MyClinic.Execution,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshOban],
          fragments: [AshAgent.Run]

        postgres do
          table "agent_runs"
          repo MyClinic.Repo
        end

        run do
          agent_version MyClinic.Execution.AgentVersion
          step MyClinic.Execution.Step
          invocation MyClinic.Execution.Invocation
          runtime MyClinic.AgentRuntime
        end

        oban do
          triggers do
            trigger :step do
              action :step
              # ... see usage-rules/triggers.md
            end
          end
        end
      end

  ## Lifecycle

  `queued → running → (waiting) → … → completed | failed | cancelled`. `completed`,
  `failed` and `cancelled` are final. A `waiting` run says what it waits for in
  `blocked_on`: `:tools` (its tool calls' invocations), `:budget` (its token budget is
  spent) or `:limit` (its step or tool-call limit is reached). A run waiting on its
  budget stays until its host extends it (`extend`); one waiting on a limit stays until
  its host lifts it.

  ## One step

  The `:step` trigger's action, `step` (`AshAgent.Run.Stepper`):

    1. **Claim** (`claim_step`, its own transaction): takes the next lease epoch under
       `optimistic_lock(:lease_epoch)`, so of two jobs for one run one claims and the
       other ends before any model call. The claim checks the run's deadline, its
       limits and budget, and that the pinned version has not drifted
       (`AshAgent.AgentVersion.Definition.check_pinned/1`): a drifted version fails the
       run with `error_code: "definition_drift"`.
    2. **Rebuild**: the executing actor afresh (`c:AshAgent.ExecutionIdentity.actor_for/1`
       with the run row), the conversation from the journal, the tools the version
       offers that the actor may use, and their fingerprint.
    3. **Tool results**: a model turn whose calls have no result yet gets them, from
       each call's invocation when it has finished; an in-loop read is run again. While
       any invocation has not finished, the run waits for it, and no model call is made.
    4. **Model call**, outside any transaction: the step first holds what is left of
       the token budget (`reserve`, `AshAgent.Run.Budget`), and waits on its budget when
       nothing is; then ash_ai's tool loop, once, with the host's model
       (`AshAgent.Runtime`). After the call, `settle` releases the hold and adds the
       tokens it used to `budget_spent`. In-loop reads (Ash `:read` actions that do not
       reach outside) run in the loop as the executing actor; every other call stops the
       loop. Each message the loop adds is recorded as it arrives, under the fence.
    5. **Record** (`record_step`, fenced on the epoch): the calls the loop stopped for
       become invocations (`invoke`, keyed `run:<run id>:<step seq>:<tool call id>`, as
       the person who started the run), and the run waits for them; a loop that ran
       reads and was stopped by its iteration limit is queued for the next step; a
       final answer is cast to the version's `output_type` and completes the run. An
       answer that does not cast gets a repair turn, up to the version's `max_repairs`,
       after which the run fails as `:rejected`.

  A tool call that is not an in-loop read never runs in the loop: its effect runs once,
  as an invocation, and a step repeated after a worker died reads the invocation's
  recorded result rather than calling anything again.

  ## Actions

    * `start` (create): pins the agent's latest published version, asks the host who
      the run executes as (`c:AshAgent.ExecutionIdentity.run_principal/3`, which also
      decides whether the actor may start that agent), sets the deadline and token
      budget from the version's limits, and enqueues the first step. A run may name the
      record it is about (`subject_type`, `subject_id`): the actor must be able to read
      it, and the record is left in the changeset context (`ash_agent.subject`) for the
      host's own changes, as an invocation's subject is (see
      `AshAgent.Run.Changes.Start`).
    * `claim_step`, `record_step`: the step's own writes, above.
    * `step` (generic, no transaction): the `:step` trigger's action.
    * `reserve`, `settle` (update): the budget's writes, under
      `optimistic_lock(:budget_lock)` (`AshAgent.Run.Budget`).
    * `extend` (update): raises the token budget; a run waiting on it is queued again.
      Who may extend a run is the host's policy.
    * `recover` (update): queues again a `running` run whose lease expired: its worker
      died, or its model call failed.
    * `request_cancel` (update): cancels a run that has not finished. Its tool calls'
      invocations that have not started are cancelled with it; one that is executing
      keeps running and records the request. Nothing done is undone.

  ## Runs that cause no effects

  A run is `tainted?` once a call that reaches outside (`open_world?`) has answered it: the
  answer is content its host did not write. In-loop reads and writes inside the
  application never taint. Taint is recorded and never enforced here.

  A run started with `mode: :eval` (a suite case) or `:shadow` (a candidate beside live
  work) takes its steps and model calls like any run, and its in-loop reads run as its
  executing actor, but nothing it asks for has an effect. Each tool call is still an
  invocation, recorded with the run's mode, and the host's invocation resource answers
  it from the run's `fixtures` instead of running its target (`AshAgent.Invocation`,
  "Invocations of a run that is not live"). The host is told the mode when it names who
  the run executes as (`c:AshAgent.ExecutionIdentity.run_principal/3`).

  `needs_step` is a calculation, not a counter: a run is `queued`, or `waiting` on
  `:tools` with none of its invocations still open. Every invocation that finishes can
  wake the run (`AshAgent.Run.Changes.Wake`, which the host attaches to its invocation
  resource), and the `:step` sweep picks up any run whose wake-up was lost.

  Fencing and the budget use a filter on the update and `optimistic_lock`, never an
  atomic update, so they work on hosts whose audit wrapper refuses atomics.

  ## What the fragment does not declare

  Tenancy, ownership, policies, triggers, relationships to host resources, encryption
  and the `postgres` block. `input` and `output` are marked `sensitive?`; a host that
  encrypts content at rest seals them.
  """

  use Spark.Dsl.Fragment,
    of: Ash.Resource,
    extensions: [AshStateMachine, AshAgent.Run.Dsl]

  @failure_classes AshAgent.Invocation.failure_classes()

  state_machine do
    state_attribute :status
    initial_states [:queued]
    default_initial_state :queued

    transitions do
      transition :claim_step, from: [:queued, :waiting], to: [:running, :waiting, :failed]

      transition :record_step,
        from: :running,
        to: [:running, :queued, :waiting, :completed, :failed]

      transition :recover, from: :running, to: :queued
      transition :extend, from: :waiting, to: :queued
      transition :request_cancel, from: [:queued, :running, :waiting], to: :cancelled
    end
  end

  actions do
    defaults [:read]

    create :start do
      description "Start a run of an agent's latest published version."
      accept [:input, :run_key, :origin, :subject_type, :subject_id, :mode, :fixtures]

      argument :agent, :string do
        description "The agent's key."
        allow_nil? false
        constraints max_length: 255
      end

      change AshAgent.Run.Changes.Start
    end

    update :claim_step do
      description "Take the lease for one step of a run that has work to do."
      accept []
      require_atomic? false

      argument :lease_for, :integer do
        description "How long the lease lasts, in milliseconds."
        allow_nil? false
        default 300_000
        constraints min: 0
      end

      change filter(expr(status in [:queued, :waiting]))
      change optimistic_lock(:lease_epoch)
      change AshAgent.Run.Changes.ClaimStep
    end

    update :record_step do
      description """
      Append messages to the run's journal, request the tool calls that need governing, and
      move the run on. Refused unless `epoch` still holds the lease.
      """

      accept [:output]
      require_atomic? false

      argument :epoch, :integer, allow_nil?: false

      argument :steps, {:array, :map} do
        description "The messages to append, in order: `%{role, parts, tool_calls}`."
        allow_nil? false
        default []
        sensitive? true
      end

      argument :invocations, {:array, :map} do
        description """
        The tool calls to request: `%{tool_call_id, step_seq, target, args}`, each
        through the host's invocation resource, as the run's requester.
        """

        allow_nil? false
        default []
        sensitive? true
      end

      argument :outcome, :atom do
        allow_nil? false
        constraints one_of: [:running, :queued, :waiting, :completed, :failed]
      end

      argument :blocked_on, :atom, constraints: [one_of: [:tools, :human, :budget, :limit]]
      argument :failure_class, :atom, constraints: [one_of: @failure_classes]
      argument :error_code, :string, constraints: [max_length: 256]
      argument :model_calls, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
      argument :tool_calls, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
      argument :repairs, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
      argument :prompt_fingerprint, :string

      argument :tainted, :boolean do
        description "Whether the step took in a result from outside (`tainted?`)."
        allow_nil? false
        default false
      end

      change filter(expr(status == :running and lease_epoch == ^arg(:epoch)))
      change AshAgent.Run.Changes.RecordStep
    end

    update :recover do
      description "Queue again a running run whose lease expired."
      accept []
      require_atomic? false

      change filter(expr(status == :running and lease_expires_at <= now()))
      change transition_state(:queued)
      change set_attribute(:lease_expires_at, nil)
      change AshAgent.Run.Changes.EnqueueStep
    end

    update :reserve do
      description """
      Hold tokens of the run's budget for one model call, before the call is made
      (`AshAgent.Run.Budget`). Refused with `AshAgent.Run.BudgetExhausted` when fewer are left.
      """

      accept []
      require_atomic? false

      argument :run_id, :uuid do
        description "The run whose step makes the call."
        allow_nil? false
      end

      argument :epoch, :integer do
        description "The lease of that run the call is made under."
        allow_nil? false
      end

      argument :tokens, :integer, allow_nil?: false, constraints: [min: 1]

      change optimistic_lock(:budget_lock)
      change AshAgent.Run.Changes.Reserve
    end

    update :settle do
      description """
      Release a call's hold and add the tokens it used to `budget_spent`, after the call
      (`AshAgent.Run.Budget`).
      """

      accept []
      require_atomic? false

      argument :run_id, :uuid, allow_nil?: false
      argument :epoch, :integer, allow_nil?: false
      argument :tokens, :integer, allow_nil?: false, constraints: [min: 0]

      change optimistic_lock(:budget_lock)
      change AshAgent.Run.Changes.Settle
    end

    update :extend do
      description """
      Raise the run's token budget by `tokens`. A run waiting on its budget is queued again.
      """

      accept []
      require_atomic? false

      argument :tokens, :integer, allow_nil?: false, constraints: [min: 1]

      change optimistic_lock(:budget_lock)
      change AshAgent.Run.Changes.Extend
    end

    update :request_cancel do
      description "Cancel a run that has not finished, and its tool calls that have not started."
      accept []
      require_atomic? false

      change filter(expr(status in [:queued, :running, :waiting]))
      change transition_state(:cancelled)
      change set_attribute(:cancel_requested_at, &DateTime.utc_now/0)
      change set_attribute(:lease_expires_at, nil)
      change set_attribute(:blocked_on, nil)
      change AshAgent.Run.Changes.CancelInvocations
    end

    action :step, :atom do
      description "Claim a run that has work to do, make one model call, and record it."

      constraints one_of: AshAgent.Run.Stepper.outcomes()
      transaction? false

      argument :primary_key, :map, allow_nil?: false

      run AshAgent.Run.Actions.Step
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :run_key, :string do
      allow_nil? false
      public? true
      constraints max_length: 512
      description "The run's stable key, unique per tenant."
    end

    attribute :origin, :atom do
      allow_nil? false
      public? true
      default :direct
      constraints one_of: [:direct, :assistant, :bpmn, :acp, :eval, :schedule]
      description "What started the run."
    end

    attribute :mode, :atom do
      allow_nil? false
      public? true
      default :live
      constraints one_of: [:live, :shadow, :eval]

      description """
      Whether the run's tool calls really run (`:live`), or are answered from `fixtures`
      (`:shadow`, `:eval`).
      """
    end

    attribute :fixtures, :map do
      allow_nil? false
      public? true
      default %{}

      description """
      What a run that is not live answers its tool calls with, by target:
      `%{"Resource.Module.action" => result}`.
      """
    end

    attribute :subject_type, :string do
      public? true
      constraints max_length: 255

      description "The resource of the record the run is about, as its module name, when it is about one."
    end

    attribute :subject_id, :string do
      public? true
      constraints max_length: 255
      description "The primary key of the record the run is about."
    end

    attribute :agent_key, :string do
      allow_nil? false
      public? true
      constraints max_length: 255
    end

    attribute :agent_version_id, :uuid do
      allow_nil? false
      public? true
      description "The agent version the run is pinned to."
    end

    attribute :input, :string do
      public? true
      sensitive? true
      description "What the run was asked: the conversation's first message."
    end

    attribute :executing_principal, :map do
      public? true

      constraints fields: [
                    type: [
                      type: :atom,
                      allow_nil?: false,
                      constraints: [one_of: [:person, :automation]]
                    ],
                    id: [type: :string, allow_nil?: false],
                    on_behalf_of: [type: :string, allow_nil?: true],
                    agent: [type: :string, allow_nil?: true]
                  ]

      description "Who the run's steps and tool calls run as (`AshAgent.ExecutionIdentity`)."
    end

    attribute :tainted?, :boolean do
      allow_nil? false
      public? true
      default false

      description """
      Whether the run has taken in a result from outside: the answer to a call of a target
      that reaches outside the application (`open_world?`). Set once, never cleared. It is
      recorded, not enforced: a host reports it, or admits on it.
      """
    end

    attribute :blocked_on, :atom do
      public? true
      constraints one_of: [:tools, :human, :budget, :limit]
      description "What a waiting run waits for."
    end

    attribute :step_seq, :integer do
      allow_nil? false
      public? true
      default 0
      description "The `seq` of the last message in the run's journal."
    end

    attribute :step_count, :integer do
      allow_nil? false
      public? true
      default 0
      description "Model calls the run has made."
    end

    attribute :tool_call_count, :integer do
      allow_nil? false
      public? true
      default 0
    end

    attribute :repair_count, :integer do
      allow_nil? false
      public? true
      default 0
      description "Turns the run has been given to repair an answer that did not cast."
    end

    attribute :budget_limit, :integer do
      public? true
      description "Tokens the run may spend: the version's `token_budget` when it started."
    end

    attribute :budget_spent, :integer do
      allow_nil? false
      public? true
      default 0
      description "Tokens the run's settled model calls used."
    end

    attribute :budget_reserved, :integer do
      allow_nil? false
      public? true
      default 0
      description "Tokens held for model calls that have not settled: the sum of `budget_holds`."
    end

    attribute :budget_holds, :map do
      allow_nil? false
      public? true
      default %{}

      description """
      Each hold not yet settled, by the lease that took it: `%{"<run id>:<lease epoch>" => tokens}`.
      """
    end

    attribute :budget_lock, :integer do
      allow_nil? false
      public? true
      default 0

      description "Incremented by every budget write; `reserve`, `settle` and `extend` lock on it."
    end

    attribute :deadline_at, :utc_datetime_usec, public?: true

    attribute :lease_epoch, :integer do
      allow_nil? false
      public? true
      default 0
      description "Incremented by every claim. A record must name the epoch it claimed with."
    end

    attribute :lease_expires_at, :utc_datetime_usec, public?: true
    attribute :cancel_requested_at, :utc_datetime_usec, public?: true

    attribute :output, :map do
      public? true
      sensitive? true
      description "The answer, cast to the version's `output_type`: `%{\"value\" => value}`."
    end

    attribute :failure_class, :atom do
      public? true
      constraints one_of: @failure_classes
    end

    attribute :error_code, :string do
      public? true
      constraints max_length: 256
    end

    attribute :prompt_fingerprint, :string do
      public? true

      description "The fingerprint of the instructions and tools the last model call was made with."
    end

    attribute :correlation_id, :string, public?: true
    attribute :traceparent, :string, public?: true
  end

  identities do
    identity :unique_key, [:run_key]
  end
end
