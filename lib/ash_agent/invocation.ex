# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation do
  @moduledoc """
  A Spark fragment for the invocation record: one row for each request to run an action
  that has effects, with a stable key, a keyed digest of its arguments, a lease that
  fences stale workers, and a typed outcome.

  The host includes it on a resource built from its own base and supplies the rest
  (`usage-rules/fragments.md`):

      defmodule MyClinic.Execution.Invocation do
        use Ash.Resource,
          domain: MyClinic.Execution,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshOban],
          fragments: [AshAgent.Invocation]

        postgres do
          table "invocations"
          repo MyClinic.Repo
        end

        invocation do
          execution_identity MyClinic.ExecutionIdentity
          digest_key MyClinic.InvocationDigestKey
        end

        oban do
          triggers do
            trigger :execute do
              action :execute
              # ... see usage-rules/triggers.md
            end
          end
        end
      end

  ## Lifecycle

  `requested → awaiting_approval → ready → executing → (dispatched) → succeeded | failed |
  outcome_unknown`, plus `rejected`, `stale` and `cancelled`. `request` creates a row
  directly in `awaiting_approval`, `ready` or `rejected`. `succeeded`, `failed`,
  `rejected`, `stale` and `cancelled` are terminal: no action changes a row in one of
  them. `dispatched` and `outcome_unknown` belong to external work and are reached by
  actions a later version adds.

  ## Actions

    * `invoke` (generic): the entry point. Reads by key; the same key with the same
      target, arguments, principal and parent returns the existing row, and the same key
      with anything different is an `AshAgent.Invocation.IdempotencyConflict`. Otherwise
      it calls `request`. Concurrent callers that both miss the read collide on the key's
      identity; the loser reads again and applies the same comparison. It never upserts.
    * `request` (create): resolves and checks the target (`AshAgent.Invocation.Target`),
      derives the principal (`c:AshAgent.ExecutionIdentity.principal_for/2`) and lineage,
      snapshots the effects declaration, digests the target and the arguments, captures
      the subject's `version_number`, and routes the row: `rejected` when the arguments
      do not fit the target or name a record the caller cannot read, `awaiting_approval` when the declaration asks for an
      approval, `ready` otherwise. A ready row's `:execute` job is enqueued in the same
      transaction.
    * `claim` (update): `ready → executing`, or takes over an `executing` row whose lease
      has expired when its target writes only to this application. Takes the next lease
      epoch under `optimistic_lock(:lease_epoch)`, so of two claims from one reading one
      wins. A row whose target is declared differently now from when it was requested
      (its `target_digest` no longer matches) becomes `stale` instead, and nothing runs.
    * `succeed` and `fail` (updates): complete a claimed row, filtered on the epoch the
      worker claimed with. A worker whose lease was taken over matches no row, gets
      `Ash.Error.Changes.StaleRecord`, and its transaction rolls back.
    * `apply_decision` (update): applies an approval's outcome to an `awaiting_approval`
      row: `ready`, `rejected` or `stale`. The outcome arrives as an argument, set by the
      caller or by a change the host attaches to the action.
    * `request_cancel` (update): cancels a row that has not started; on a row that is
      executing it only records the request.
    * `execute` (generic, no transaction): the `:execute` trigger's action. Claims, builds
      the executing actor afresh, runs the target and completes under the fence; see
      `AshAgent.Invocation.Executor`.

  Fencing uses a filter on the update and `optimistic_lock`, never an atomic update, so
  it works on hosts whose audit wrapper refuses atomics.

  ## What the fragment does not declare

  Tenancy, ownership, policies, triggers, relationships to host resources, encryption
  and the `postgres` block. `args` and `result` are marked `sensitive?`; a host that
  encrypts content at rest seals them.
  """

  use Spark.Dsl.Fragment,
    of: Ash.Resource,
    extensions: [AshStateMachine, AshAgent.Invocation.Dsl]

  @failure_classes [:rejected, :denied, :business, :transient, :permanent, :timeout, :budget]

  @doc false
  def failure_classes, do: @failure_classes

  state_machine do
    state_attribute :status
    initial_states [:requested, :awaiting_approval, :ready, :rejected]
    default_initial_state :requested
    # Reached by the external-work actions of a later version.
    extra_states [:dispatched, :outcome_unknown]

    transitions do
      transition :apply_decision, from: :awaiting_approval, to: [:ready, :rejected, :stale]
      transition :claim, from: [:ready, :executing], to: [:executing, :stale]
      transition :succeed, from: :executing, to: :succeeded
      transition :fail, from: :executing, to: :failed

      transition :request_cancel,
        from: [:requested, :awaiting_approval, :ready],
        to: :cancelled
    end
  end

  actions do
    defaults [:read]

    action :invoke, :struct do
      description """
      Request an action through its governed invocation, or get back the one already
      requested with this key.
      """

      argument :target, :string, allow_nil?: false
      argument :args, :map, allow_nil?: false, default: %{}, sensitive?: true

      argument :key, :string do
        description "The request's stable key. Omitted, a fresh one is used."
        constraints max_length: 512
      end

      argument :parent, :map do
        description """
        The work this request belongs to: `invocation_id`, `run_id` (with `step_seq` and
        `tool_call_id`), or `process_instance_id` (with `process_node_id`).
        """
      end

      run AshAgent.Invocation.Actions.Invoke
    end

    create :request do
      description "Record a request to run a target, checked and routed but not run."
      accept [:target, :args, :invocation_key]

      argument :parent, :map

      change AshAgent.Invocation.Changes.Request
    end

    update :claim do
      description "Take the lease on a ready row, or on one whose lease has expired."
      accept []
      require_atomic? false

      argument :lease_for, :integer do
        description "How long the lease lasts, in milliseconds."
        allow_nil? false
        default 300_000
        constraints min: 0
      end

      change filter(expr(status in [:ready, :executing]))
      change optimistic_lock(:lease_epoch)
      change AshAgent.Invocation.Changes.Claim
    end

    update :succeed do
      description "Record that the claimed work happened. Refused unless `epoch` still holds the lease."
      accept [:result]
      require_atomic? false

      argument :epoch, :integer, allow_nil?: false

      change filter(expr(status == :executing and lease_epoch == ^arg(:epoch)))
      change transition_state(:succeeded)
      change set_attribute(:lease_expires_at, nil)
    end

    update :fail do
      description "Record that the claimed work failed. Refused unless `epoch` still holds the lease."
      accept [:failure_class, :error_code]
      require_atomic? false

      argument :epoch, :integer, allow_nil?: false

      validate present(:failure_class)
      change filter(expr(status == :executing and lease_epoch == ^arg(:epoch)))
      change transition_state(:failed)
      change set_attribute(:lease_expires_at, nil)
    end

    update :apply_decision do
      description "Apply an approval's outcome to a row awaiting one."
      accept []
      require_atomic? false

      argument :outcome, :atom do
        description """
        `:approved`, `:rejected` or `:stale`. Supplied by the caller, or set by a change
        the host attaches to this action. With no outcome the update is refused.
        """

        constraints one_of: [:approved, :rejected, :stale]
      end

      argument :decided_by_id, :uuid

      change filter(expr(status == :awaiting_approval))
      change AshAgent.Invocation.Changes.ApplyDecision
    end

    update :request_cancel do
      description "Cancel a row that has not started; mark one that is executing."
      accept []
      require_atomic? false

      change AshAgent.Invocation.Changes.RequestCancel
    end

    action :execute, :atom do
      description "Claim a ready row, run its target as its principal, and record the outcome."
      constraints one_of: [:succeeded, :failed, :skipped, :superseded, :stale]
      transaction? false

      argument :primary_key, :map, allow_nil?: false

      run AshAgent.Invocation.Actions.Execute
    end
  end

  attributes do
    uuid_primary_key :id

    # --- identity ---

    attribute :invocation_key, :string do
      allow_nil? false
      public? true
      constraints max_length: 512
      description "The request's stable logical key, unique per tenant."
    end

    attribute :kind, :atom do
      allow_nil? false
      public? true
      default :direct
      constraints one_of: [:tool_call, :process_task, :integration, :external_worker, :direct]
      description "What kind of caller asked."
    end

    attribute :mode, :atom do
      allow_nil? false
      public? true
      default :live
      constraints one_of: [:live, :shadow, :eval]
      description "Whether the target really runs (`:live`) or only fixtures do."
    end

    # --- target ---

    attribute :target, :string do
      allow_nil? false
      public? true
      constraints max_length: 512
      description "The action requested, as `\"Resource.Module.action\"`."
    end

    attribute :target_digest, :string do
      public? true
      description "SHA-256 of the target's input schema and effects declaration when requested."
    end

    attribute :effects, :map do
      public? true

      description "The target's effects declaration when requested (`AshAgent.Effects.Effect.to_map/1`)."
    end

    # --- payload ---

    attribute :args, :map do
      public? true
      sensitive? true
      description "The arguments requested. Never changed after the request."
    end

    attribute :args_digest, :string do
      public? true
      description "HMAC-SHA256 of the arguments' canonical JSON under the host's digest key."
    end

    attribute :preconditions, {:array, :map} do
      allow_nil? false
      public? true
      default []
      description "Records the request depends on, with the `version_number` each had."
    end

    # --- who ---

    attribute :executing_principal, :map do
      public? true

      constraints fields: [
                    type: [
                      type: :atom,
                      allow_nil?: false,
                      constraints: [one_of: [:person, :automation]]
                    ],
                    id: [type: :string, allow_nil?: false]
                  ]

      description "Who the target runs as: a person or a named automation principal."
    end

    attribute :delegation, :map do
      public? true
      description "The delegation chain, in RFC 8693's nested `act` shape. Informational."
    end

    # --- lineage ---

    attribute :run_id, :uuid, public?: true
    attribute :step_seq, :integer, public?: true
    attribute :tool_call_id, :string, public?: true
    attribute :process_instance_id, :uuid, public?: true
    attribute :process_node_id, :string, public?: true
    attribute :parent_invocation_id, :uuid, public?: true
    attribute :rerun_of_id, :uuid, public?: true
    attribute :release_manifest_id, :uuid, public?: true
    attribute :correlation_id, :string, public?: true
    attribute :traceparent, :string, public?: true

    # --- approval ---

    attribute :approval_mode, :atom do
      allow_nil? false
      public? true
      default :none
      constraints one_of: [:none, :confirm, :four_eyes]
    end

    attribute :approval_task_id, :uuid, public?: true

    attribute :approval_digest, :string do
      public? true
      description "SHA-256 of the canonical JSON of what was granted (`authorization_details`)."
    end

    attribute :authorization_details, {:array, :map} do
      public? true
      description "What an approval grants, in RFC 9396's `authorization_details` shape."
    end

    attribute :approved_by_id, :uuid, public?: true
    attribute :approval_expires_at, :utc_datetime_usec, public?: true

    # --- lease ---

    attribute :lease_epoch, :integer do
      allow_nil? false
      public? true
      default 0
      description "Incremented by every claim. A completion must name the epoch it claimed with."
    end

    attribute :lease_expires_at, :utc_datetime_usec, public?: true

    attribute :attempt_count, :integer do
      allow_nil? false
      public? true
      default 0
    end

    attribute :next_attempt_at, :utc_datetime_usec, public?: true
    attribute :deadline_at, :utc_datetime_usec, public?: true
    attribute :cancel_requested_at, :utc_datetime_usec, public?: true

    # --- outcome ---

    attribute :failure_class, :atom do
      public? true
      constraints one_of: @failure_classes
    end

    attribute :error_code, :string do
      public? true
      constraints max_length: 256
    end

    attribute :result, :map do
      public? true
      sensitive? true

      description "What the target returned: the record it touched, or the value of a generic action."
    end

    attribute :effect_system, :string, public?: true
    attribute :effect_ref, :string, public?: true
    attribute :effect_observed_at, :utc_datetime_usec, public?: true
    attribute :reconciled_via, :string, public?: true
  end

  identities do
    identity :unique_key, [:invocation_key]
    identity :unique_effect, [:effect_system, :effect_ref]
  end
end
