# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Run.Changes.Start do
  @moduledoc """
  The `start` action's work.

  A run pins the agent's latest published version in the run's tenant (`latest_published`
  on the host's agent version resource), and refuses when there is none or when it has
  drifted (`AshAgent.AgentVersion.Definition.check_pinned/1`): a run never starts on a
  version whose tools are not the ones that were approved.

  The host then names who the run executes as, from the actor and the version's
  publish-time authority (`c:AshAgent.ExecutionIdentity.run_principal/3`). That is also
  where it decides whether the actor may start this agent at all: a refusal is an
  `AshAgent.Invocation.NoPrincipal` (forbidden), and no run is written.

  The run's deadline is the version's `deadline` (in seconds) from now, and its token
  budget the version's `token_budget`. A run with no key gets a fresh one. Its first
  step is enqueued in the same transaction.

  The version is read without authorization: it is the action's own bookkeeping, and
  whether the actor may start the agent is the host's answer above.
  """

  use Ash.Resource.Change

  alias AshAgent.AgentVersion.Definition
  alias AshAgent.Invocation.NoPrincipal
  alias AshAgent.Run.{Enqueue, Info}

  @impl true
  def change(changeset, _opts, context) do
    changeset
    |> default_key()
    |> Ash.Changeset.before_action(&pin(&1, context))
    |> Ash.Changeset.after_action(&Enqueue.step/2)
  end

  defp default_key(changeset) do
    case Ash.Changeset.get_attribute(changeset, :run_key) do
      nil ->
        Ash.Changeset.force_change_attribute(changeset, :run_key, "run:" <> Ash.UUID.generate())

      _key ->
        changeset
    end
  end

  defp pin(changeset, context) do
    key = Ash.Changeset.get_argument(changeset, :agent)

    with {:ok, version} <- latest_published(changeset, key),
         {:ok, version} <- Definition.check_pinned(version),
         {:ok, principal} <- principal(changeset, version, context) do
      limits = stringify(version.limits || %{})

      Ash.Changeset.force_change_attributes(changeset, %{
        agent_key: version.key,
        agent_version_id: version.id,
        executing_principal: principal,
        budget_limit: limits["token_budget"],
        deadline_at: deadline(limits["deadline"])
      })
    else
      {:error, error} -> Ash.Changeset.add_error(changeset, error)
    end
  end

  defp latest_published(changeset, key) do
    changeset.resource
    |> Info.agent_version()
    |> Ash.Query.for_read(:latest_published, %{key: key},
      tenant: changeset.tenant,
      authorize?: false
    )
    |> Ash.read_one()
    |> case do
      {:ok, nil} ->
        {:error,
         Ash.Error.Changes.InvalidArgument.exception(
           field: :agent,
           message: "no published version of #{key}"
         )}

      other ->
        other
    end
  end

  defp principal(changeset, version, context) do
    identity = Info.execution_identity(changeset.resource)

    if function_exported?(identity, :run_principal, 3) do
      case identity.run_principal(context.actor, version, Map.from_struct(context)) do
        {:ok, principal} -> {:ok, principal}
        {:error, reason} -> {:error, NoPrincipal.exception(reason: reason)}
      end
    else
      {:error,
       NoPrincipal.exception(
         reason: "#{inspect(identity)} does not implement run_principal/3, so no run can start"
       )}
    end
  end

  defp deadline(seconds) when is_integer(seconds),
    do: DateTime.add(DateTime.utc_now(), seconds, :second)

  defp deadline(_none), do: nil

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
