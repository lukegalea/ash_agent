# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.Changes.Request do
  @moduledoc """
  The `request` action's work: everything about the row is derived here, from the
  target, the arguments, the actor and the parent, so a caller cannot set it.

  In order:

    1. the parent becomes lineage columns (`AshAgent.Invocation.Lineage`);
    2. the target resolves to an action with an effects declaration
       (`AshAgent.Invocation.Target`), which is snapshotted with the target's digest;
    3. the host names the principal the work executes as
       (`c:AshAgent.ExecutionIdentity.principal_for/2`), also kept as RFC 8693
       delegation (`AshAgent.ExecutionIdentity.delegation/1`);
    4. a run's tool call takes the run's `mode`, read from the run (`run` in the host's
       `invocation` section); any other request is `:live`. A row that is not live is
       routed `ready` even when its declaration asks for an approval, because its target
       will not run (`AshAgent.Invocation`, "Invocations of a run that is not live");
    5. the arguments are checked against the target without running it, and — for a live
       request, as the principal it will execute as
       (`c:AshAgent.ExecutionIdentity.precheck_actor/1`) — so is the action itself:
       its changes and validations, and the principal's authority over exactly that
       change (`AshAgent.Invocation.Target.precheck/3`), with no hooks run. The row is
       then routed: `rejected` if the arguments do not fit, the action refuses the
       request, or the principal is not permitted (`invalid_arguments`,
       `invalid_request` or `not_permitted` as `error_code`, the per-field errors as
       `rejection_details`), `awaiting_approval` if the declaration asks for an
       approval, `ready` otherwise. The subject's `version_number` is kept
       as a precondition. The resolved target and the subject (the record an update or
       destroy acts on, else nil) are put in the changeset context under `:ash_agent`,
       for the host's own changes on `request`, which run after this one;
    6. just before the insert, once every change of the action (the host's included)
       has run, the arguments are digested under the host's key (`AshAgent.DigestKey`),
       and a row awaiting approval records what an approval of it binds: its
       `authorization_details`, their `approval_digest` and `approval_expires_at`
       (`AshAgent.Invocation.Approval`);
    7. after the insert, inside its transaction, a ready row's `:execute` job is
       enqueued, so a committed ready row always has a job and a rolled-back one never
       does.

  A target that does not resolve, an actor with no principal and a parent that does not
  parse are errors, not rows: there is nothing well-formed to record.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshAgent.Effects.Effect
  alias AshAgent.Invocation.{Approval, Enqueue, Info, Lineage, Target}

  @impl true
  def change(changeset, _opts, context) do
    args = args(changeset)

    with {:ok, lineage} <- lineage(changeset),
         {:ok, mode} <- mode(changeset, lineage),
         {:ok, target} <- target(changeset),
         {:ok, principal} <- principal(changeset.resource, context) do
      changeset
      |> Ash.Changeset.force_change_attributes(
        Map.merge(lineage, %{
          kind: Lineage.kind(lineage),
          mode: mode,
          executing_principal: principal,
          delegation: AshAgent.ExecutionIdentity.delegation(principal),
          effects: Effect.to_map(target.effect),
          target_digest: Target.digest(target),
          approval_mode: target.effect.approval
        })
      )
      |> route(target, mode, args, context)
      |> Ash.Changeset.before_action(&digest_args(&1, args))
      |> Ash.Changeset.before_action(&bind_manifest/1)
      |> Ash.Changeset.before_action(&bind_approval/1)
      |> Ash.Changeset.after_action(&Enqueue.when_ready/2)
    else
      {:error, field, message} ->
        Ash.Changeset.add_error(changeset, field: field, message: message)
    end
  end

  defp args(changeset) do
    case Ash.Changeset.fetch_argument_or_change(changeset, :args) do
      {:ok, args} when is_map(args) -> args
      _ -> %{}
    end
  end

  defp lineage(changeset) do
    case Lineage.from_parent(Ash.Changeset.get_argument(changeset, :parent)) do
      {:ok, lineage} -> {:ok, lineage}
      {:error, message} -> {:error, :parent, message}
    end
  end

  defp target(changeset) do
    case Target.resolve(Ash.Changeset.get_attribute(changeset, :target)) do
      {:ok, target} -> {:ok, target}
      {:error, message} -> {:error, :target, message}
    end
  end

  defp principal(resource, context) do
    case Info.execution_identity(resource).principal_for(context.actor, Map.from_struct(context)) do
      {:ok, principal} ->
        {:ok, principal}

      {:error, reason} ->
        {:error, :executing_principal, "no principal can run this request: #{inspect(reason)}"}
    end
  end

  # A run's tool call takes the run's mode, read from the run itself: nothing a caller
  # passes can make a request skip its effect.
  defp mode(changeset, %{run_id: run_id}) when is_binary(run_id) do
    case Info.run(changeset.resource) do
      nil ->
        {:ok, :live}

      run ->
        run
        |> Ash.Query.filter(id == ^run_id)
        |> Ash.Query.select([:mode])
        |> Ash.read_one(tenant: changeset.tenant, authorize?: false)
        |> case do
          {:ok, %{mode: mode}} -> {:ok, mode}
          {:ok, nil} -> {:ok, :live}
          {:error, error} -> {:error, :parent, "cannot read the run: #{Exception.message(error)}"}
        end
    end
  end

  defp mode(_changeset, _lineage), do: {:ok, :live}

  defp route(changeset, target, mode, args, context) do
    opts = Ash.Context.to_opts(context, tenant: changeset.tenant)

    case Target.prepare(target, args, opts) do
      {:ok, prepared} ->
        case precheck(changeset, target, mode, prepared) do
          {:ok, changeset} -> place(changeset, target, mode, prepared)
          {:error, code, errors} -> reject(changeset, code, errors)
        end

      {:error, errors} ->
        reject(changeset, :invalid_arguments, errors)
    end
  end

  defp place(changeset, target, mode, prepared) do
    changeset
    |> Ash.Changeset.force_change_attribute(
      :preconditions,
      Target.preconditions(target, prepared.subject)
    )
    |> Ash.Changeset.set_context(%{ash_agent: %{target: target, subject: prepared.subject}})
    |> AshStateMachine.transition_state(first_state(target.effect, mode))
    |> Ash.Changeset.force_change_attribute(
      :approval_expires_at,
      if(mode == :live, do: Approval.expires_at(target.effect, DateTime.utc_now()))
    )
  end

  # The pre-check: a live request is checked against the action itself, as the principal
  # it will execute as, so what the action or the principal would refuse is refused
  # before anyone is asked to approve it (`AshAgent.Invocation.Target.precheck/3`). A run
  # that is not live never runs its target, so its action is not checked; a host that
  # names no pre-check actor keeps the claim's checks as the first its requests face.
  defp precheck(changeset, _target, mode, _prepared) when mode != :live, do: {:ok, changeset}

  defp precheck(changeset, target, :live, prepared) do
    identity = Info.execution_identity(changeset.resource)

    if function_exported?(identity, :precheck_actor, 1) do
      case identity.precheck_actor(unwritten(changeset)) do
        {:ok, actor} ->
          case Target.precheck(target, prepared, actor: actor, tenant: changeset.tenant) do
            :ok -> {:ok, changeset}
            {:error, code, errors} -> {:error, code, errors}
          end

        # The host's word that the principal cannot act now; like a refused check, it
        # says no more than that.
        {:error, _reason} ->
          {:error, :not_permitted, [%{message: "not permitted"}]}
      end
    else
      {:ok, changeset}
    end
  end

  # The request as it will be written, for the host to build its actor from as
  # `actor_for/1` does from the stored row at a claim: every attribute set so far, the
  # principal and lineage included, and the tenant, which Ash writes to an attribute
  # only when the create runs. It has no primary key yet: applying the attributes here
  # would make one up that the stored row will not have.
  defp unwritten(changeset) do
    resource = changeset.resource
    {:ok, row} = Ash.Changeset.apply_attributes(changeset, force?: true)
    row = Map.merge(row, Map.new(Ash.Resource.Info.primary_key(resource), &{&1, nil}))

    if Ash.Resource.Info.multitenancy_strategy(resource) == :attribute and
         not is_nil(changeset.to_tenant),
       do: Map.put(row, Ash.Resource.Info.multitenancy_attribute(resource), changeset.to_tenant),
       else: row
  end

  defp reject(changeset, code, errors) do
    changeset
    |> AshStateMachine.transition_state(:rejected)
    |> Ash.Changeset.force_change_attributes(%{
      failure_class: :rejected,
      error_code: error_code(code, errors),
      rejection_details: %{"errors" => Enum.map(errors, &details/1)}
    })
  end

  # The code names the check that refused; the per-field errors, stored as
  # `rejection_details`, say what would fix it. Only the arguments' own messages follow
  # their code, as they always have; a validation's or a state machine's prose stays in
  # the details, and a refusal of permission says nothing else, to anyone.
  defp error_code(:invalid_arguments, errors),
    do: String.slice("invalid_arguments: #{Target.messages(errors)}", 0, 256)

  defp error_code(code, _errors) when is_atom(code), do: Atom.to_string(code)

  defp details(error), do: Map.new(error, fn {key, value} -> {to_string(key), value} end)

  # A row that will not run asks nobody to approve it; `approval_mode` still says it
  # would have.
  defp first_state(_effect, mode) when mode != :live, do: :ready
  defp first_state(%Effect{approval: :none}, _mode), do: :ready
  defp first_state(%Effect{}, _mode), do: :awaiting_approval

  # The active release, when the host declares one: kept as the row's lineage, and its
  # digest is bound by an approval.
  defp bind_manifest(changeset) do
    with module when not is_nil(module) <- Info.release_manifest(changeset.resource),
         {:ok, active} <-
           module.active(Ash.Changeset.get_attribute(changeset, :target), changeset.tenant) do
      case active do
        nil ->
          changeset

        %{id: id, digest: digest} ->
          changeset
          |> Ash.Changeset.force_change_attribute(:release_manifest_id, id)
          |> Ash.Changeset.set_context(%{ash_agent_manifest_digest: digest})
      end
    else
      nil ->
        changeset

      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :release_manifest_id,
          message: "the active release cannot be read: #{inspect(reason)}"
        )
    end
  end

  # After `digest_args/2`, so the arguments' digest is part of what is bound.
  defp bind_approval(changeset) do
    if Ash.Changeset.get_attribute(changeset, :status) == :awaiting_approval do
      details =
        Approval.details(%{
          target: Ash.Changeset.get_attribute(changeset, :target),
          target_digest: Ash.Changeset.get_attribute(changeset, :target_digest),
          args_digest: Ash.Changeset.get_attribute(changeset, :args_digest),
          preconditions: Ash.Changeset.get_attribute(changeset, :preconditions),
          identifier: identifier(changeset),
          manifest_digest: Map.get(changeset.context, :ash_agent_manifest_digest)
        })

      Ash.Changeset.force_change_attributes(changeset, %{
        authorization_details: details,
        approval_digest: Approval.digest(details)
      })
    else
      changeset
    end
  end

  defp identifier(changeset) do
    case changeset.context do
      %{ash_agent: %{subject: %{__struct__: resource} = subject}} ->
        resource
        |> Ash.Resource.Info.primary_key()
        |> Enum.map_join(",", &to_string(Map.get(subject, &1)))

      _no_subject ->
        nil
    end
  end

  defp digest_args(changeset, args) do
    with {:ok, record} <- Ash.Changeset.apply_attributes(changeset),
         {:ok, key} <- Info.digest_key(changeset.resource).digest_key(record) do
      Ash.Changeset.force_change_attribute(
        changeset,
        :args_digest,
        AshAgent.Digest.hmac_hex(key, args)
      )
    else
      {:error, %Ash.Changeset{} = changeset} ->
        changeset

      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :args,
          message: "cannot digest the arguments: %{reason}",
          vars: [reason: inspect(reason)]
        )
    end
  end
end
