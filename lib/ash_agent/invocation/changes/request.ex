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
       (`c:AshAgent.ExecutionIdentity.principal_for/2`);
    4. the arguments are checked against the target without running it, and the row is
       routed: `rejected` if they do not fit, `awaiting_approval` if the declaration
       asks for an approval, `ready` otherwise. The subject's `version_number` is kept
       as a precondition. The resolved target and the subject (the record an update or
       destroy acts on, else nil) are put in the changeset context under `:ash_agent`,
       for the host's own changes on `request`, which run after this one;
    5. just before the insert, once every change of the action (the host's included)
       has run, the arguments are digested under the host's key (`AshAgent.DigestKey`);
    6. after the insert, inside its transaction, a ready row's `:execute` job is
       enqueued, so a committed ready row always has a job and a rolled-back one never
       does.

  A target that does not resolve, an actor with no principal and a parent that does not
  parse are errors, not rows: there is nothing well-formed to record.
  """

  use Ash.Resource.Change

  alias AshAgent.Effects.Effect
  alias AshAgent.Invocation.{Enqueue, Info, Lineage, Target}

  @impl true
  def change(changeset, _opts, context) do
    args = args(changeset)

    with {:ok, lineage} <- lineage(changeset),
         {:ok, target} <- target(changeset),
         {:ok, principal} <- principal(changeset.resource, context) do
      changeset
      |> Ash.Changeset.force_change_attributes(
        Map.merge(lineage, %{
          kind: Lineage.kind(lineage),
          mode: :live,
          executing_principal: principal,
          effects: Effect.to_map(target.effect),
          target_digest: Target.digest(target),
          approval_mode: target.effect.approval
        })
      )
      |> route(target, args)
      |> Ash.Changeset.before_action(&digest_args(&1, args))
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

  defp route(changeset, target, args) do
    case Target.prepare(target, args, tenant: changeset.tenant) do
      {:ok, %{subject: subject}} ->
        changeset
        |> Ash.Changeset.force_change_attribute(
          :preconditions,
          Target.preconditions(target, subject)
        )
        |> Ash.Changeset.set_context(%{ash_agent: %{target: target, subject: subject}})
        |> AshStateMachine.transition_state(first_state(target.effect))

      {:error, messages} ->
        changeset
        |> AshStateMachine.transition_state(:rejected)
        |> Ash.Changeset.force_change_attributes(%{
          failure_class: :rejected,
          error_code: String.slice("invalid_arguments: " <> Enum.join(messages, "; "), 0, 256)
        })
    end
  end

  defp first_state(%Effect{approval: :none}), do: :ready
  defp first_state(%Effect{}), do: :awaiting_approval

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
