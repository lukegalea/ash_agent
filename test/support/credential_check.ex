# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.CredentialCheck do
  @moduledoc """
  A test host resource that invocations run: a clinic's check of a clinician's licence.

    * `:record` writes only here and needs no approval: the internal path.
    * `:record_reviewed` is the same write, confirmed by a person first, and names the
      clinician it is about: one without `clinician_name` is refused at request time.
    * `:mark_verified` updates a check, so its subject is captured as a precondition.
    * `:notify_board` reaches outside (it only pretends to): the open-world path, with
      no way to find out afterwards what happened. It refuses a licence the board has
      asked the clinic never to send (one starting "BLOCKED"), which a request learns
      before anything runs.
    * `:suspend` updates a check after a second person from the credentialing committee
      approves, within a day: an approval bound to a subject.
    * `:restrict` and `:page_board` are governed (`AshAgent.Validations.Governed`): an
      update and a generic action that run only through their own invocation.
    * `:archive` is declared nowhere, so it cannot be invoked.

  `:read` is declared read-only and writes nowhere outside, so an agent run reads checks
  inside its tool loop. `:in_run` is the same read, answering only inside a run (the
  run's id in the action context), as a host's read that guards what reaches a model
  would; the domain offers it as the ash_ai tool `checks_in_run`. Set
  `config :ash_agent, :die_reading_in_run, true` and its next read exits the process
  reading, as a worker killed between the model's call and its result.

  A check is visible to everyone unless it is `restricted_to` one person, such as a
  check still under review: then only that person reads it.
  """

  use Ash.Resource,
    domain: AshAgent.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAgent.Effects]

  alias AshAgent.Test.Board

  postgres do
    table "credential_checks"
    repo AshAgent.Test.Repo
  end

  effects do
    action :read,
      kind: :read,
      read_only?: true,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect

    action :in_run,
      kind: :read,
      read_only?: true,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect

    action :record,
      kind: :edit,
      destructive?: false,
      open_world?: false,
      intent: :execute

    action :record_reviewed,
      kind: :edit,
      destructive?: false,
      open_world?: false,
      approval: :confirm,
      intent: :execute

    action :mark_verified,
      kind: :edit,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :execute

    action :notify_board, kind: :fetch, destructive?: false, intent: :execute

    action :post_notice,
      kind: :execute,
      destructive?: false,
      intent: :execute,
      reconcile_with: :find_notice

    action :post_notice_keyed,
      kind: :execute,
      destructive?: false,
      idempotent?: true,
      intent: :execute,
      reconcile_with: :find_notice

    action :refer,
      kind: :execute,
      destructive?: false,
      intent: :execute,
      reconcile_with: :find_notice

    action :refer_keyed, kind: :execute, destructive?: false, idempotent?: true, intent: :execute

    action :find_notice, kind: :fetch, destructive?: false, idempotent?: true, intent: :inspect

    action :confirm_standing,
      kind: :edit,
      destructive?: false,
      open_world?: false,
      intent: :execute

    action :restrict,
      kind: :edit,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :execute

    action :page_board, kind: :execute, destructive?: false, intent: :execute

    action :suspend,
      kind: :edit,
      destructive?: false,
      open_world?: false,
      approval: :four_eyes,
      approver_role: :credentialing_committee,
      approval_expires_in: [days: 1],
      intent: :execute
  end

  actions do
    defaults [:read]

    read :in_run do
      description "Credential checks, read only inside an agent run."

      prepare fn query, _context ->
        case query.context do
          %{ash_agent: %{run_id: run_id}} when is_binary(run_id) ->
            if Application.get_env(:ash_agent, :die_reading_in_run) do
              Application.delete_env(:ash_agent, :die_reading_in_run)
              exit(:worker_killed)
            end

            query

          _outside_a_run ->
            Ash.Query.add_error(query, "checks are read here only inside an agent run")
        end
      end
    end

    create :record do
      accept [:licence_number, :clinician_name]
    end

    create :record_reviewed do
      accept [:licence_number, :clinician_name]
      validate present(:clinician_name)
    end

    action :notify_board, :boolean do
      argument :licence_number, :string, allow_nil?: false

      validate fn input, _context ->
        if String.starts_with?(input.arguments.licence_number, "BLOCKED"),
          do: {:error, AshAgent.BusinessError.exception(code: "licence_blocked")},
          else: :ok
      end

      run fn _input, _context -> {:ok, true} end
    end

    update :mark_verified do
      accept []
      change set_attribute(:verified?, true)
    end

    update :archive do
      accept []
    end

    update :suspend do
      accept []
      change set_attribute(:verified?, false)
    end

    update :restrict do
      accept [:restricted_to]
      validate {AshAgent.Validations.Governed, invocation: AshAgent.Test.Invocation}
    end

    action :page_board, :boolean do
      argument :licence_number, :string, allow_nil?: false
      validate {AshAgent.Validations.Governed, invocation: AshAgent.Test.Invocation}
      run fn _input, _context -> {:ok, true} end
    end

    action :post_notice, :map do
      argument :licence_number, :string, allow_nil?: false
      run fn input, _context -> Board.post(input.arguments.licence_number, key(input)) end
    end

    action :post_notice_keyed, :map do
      argument :licence_number, :string, allow_nil?: false
      run fn input, _context -> Board.post(input.arguments.licence_number, key(input)) end
    end

    action :refer, :struct do
      constraints instance_of: AshAgent.Invocation.Dispatch
      argument :licence_number, :string, allow_nil?: false

      run fn input, _context ->
        referred(Board.post(input.arguments.licence_number, key(input)))
      end
    end

    action :refer_keyed, :struct do
      constraints instance_of: AshAgent.Invocation.Dispatch
      argument :licence_number, :string, allow_nil?: false

      run fn input, _context ->
        referred(Board.post(input.arguments.licence_number, key(input)))
      end
    end

    action :find_notice, :map do
      argument :invocation_key, :string, allow_nil?: false
      run fn input, _context -> Board.find(input.arguments.invocation_key) end
    end

    update :confirm_standing do
      accept []
      require_atomic? false

      validate fn changeset, _context ->
        if String.starts_with?(changeset.data.licence_number, "LAPSED"),
          do: {:error, AshAgent.BusinessError.exception(code: "licence_lapsed")},
          else: :ok
      end

      change set_attribute(:verified?, true)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(is_nil(restricted_to) or restricted_to == ^actor(:id))
    end

    policy action_type([:create, :update, :destroy, :action]) do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :licence_number, :string do
      allow_nil? false
      public? true
    end

    attribute :clinician_name, :string, public?: true
    attribute :restricted_to, :string, public?: true
    attribute :verified?, :boolean, public?: true, allow_nil?: false, default: false
    attribute :version_number, :integer, public?: true, allow_nil?: false, default: 1
  end

  identities do
    identity :unique_licence_number, [:licence_number]
  end

  # The invocation the action runs for, as the executor puts it in the context.
  defp key(input), do: input.context.ash_agent.invocation_key

  defp referred({:ok, %{"ref" => ref}}) do
    {:ok,
     AshAgent.Invocation.Dispatch.new(
       effect_system: "board",
       effect_ref: ref,
       deadline_at: DateTime.add(DateTime.utc_now(), 1, :day)
     )}
  end

  defp referred(error), do: error
end
