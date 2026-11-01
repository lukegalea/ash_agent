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

  The host is also told the run's `mode` (as `:mode` in the context it is given): a run
  that is not live may execute as someone else, such as an evaluation principal.

  The run's deadline is the version's `deadline` (in seconds) from now, and its token
  budget the version's `token_budget`. A run with no key gets a fresh one. Its first
  step is enqueued in the same transaction.

  ## The subject

  A run that names the record it is about (`subject_type` and `subject_id`, both or
  neither) gets that record read as the actor, in the run's tenant, before anything
  else: a record the actor cannot read is refused the same way as one that does not
  exist, so a run never learns more about a record than its starter could. The record
  is put in the changeset context as `ash_agent.subject`, where an invocation's
  `request` puts its subject, for the host's own changes on `start` (which run after
  this one): sealing the run's content under the subject's erasure scope is the host's
  choice, made there. `subject_type` is stored as the resource's module name.

  The version is read without authorization: it is the action's own bookkeeping, and
  whether the actor may start the agent is the host's answer above.
  """

  use Ash.Resource.Change

  alias AshAgent.AgentVersion.Definition
  alias AshAgent.Invocation.NoPrincipal
  alias AshAgent.Run.{Enqueue, Info, Subject}

  @impl true
  def change(changeset, _opts, context) do
    changeset
    |> default_key()
    |> read_subject(context)
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

  defp read_subject(changeset, context) do
    type = Ash.Changeset.get_attribute(changeset, :subject_type)
    id = Ash.Changeset.get_attribute(changeset, :subject_id)

    case Subject.read(type, id, Ash.Context.to_opts(context, tenant: changeset.tenant)) do
      {:ok, nil} ->
        changeset

      {:ok, %{__struct__: resource} = subject} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:subject_type, inspect(resource))
        |> Ash.Changeset.set_context(%{ash_agent: %{subject: subject}})

      {:error, field, message} ->
        Ash.Changeset.add_error(changeset, field: field, message: message)
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
      context =
        context
        |> Map.from_struct()
        |> Map.put(:mode, Ash.Changeset.get_attribute(changeset, :mode))

      case identity.run_principal(context.actor, version, context) do
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
