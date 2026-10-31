# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Run.Changes.ClaimStep do
  @moduledoc """
  The `claim_step` action's work, after its filter and `optimistic_lock(:lease_epoch)`.

  A run waiting on its budget or a limit is not claimable: only its host lifts those.
  Otherwise the claim reads the pinned version and decides, in this order:

    * the deadline has passed: `failed` with `:timeout`, `"deadline_passed"`;
    * the pinned version has drifted (`AshAgent.AgentVersion.Definition.check_pinned/1`):
      `failed` with `:permanent`, `"definition_drift"`; the run never offers a tool that
      is not the one that was approved;
    * the run has made `max_steps` model calls, or `max_tool_calls` tool calls:
      `waiting` on `:limit`;
    * the run has spent its token budget: `waiting` on `:budget`;
    * otherwise `running`, with a lease of `lease_for` milliseconds.

  The epoch is taken by the action's `optimistic_lock`, so two claims from one reading
  cannot both win. The version read is put in the claimed run's metadata
  (`:agent_version`) for the step.
  """

  use Ash.Resource.Change

  alias AshAgent.AgentVersion.Definition
  alias AshAgent.Run.Info

  @impl true
  def change(changeset, _opts, _context) do
    if changeset.data.status == :waiting and changeset.data.blocked_on in [:budget, :limit] do
      Ash.Changeset.add_error(changeset,
        field: :blocked_on,
        message: "the run waits on its %{blocked_on}; only its host lifts that",
        vars: [blocked_on: changeset.data.blocked_on]
      )
    else
      Ash.Changeset.before_action(changeset, &decide/1)
    end
  end

  defp decide(changeset) do
    run = changeset.data

    case Ash.get(Info.agent_version(changeset.resource), run.agent_version_id,
           tenant: changeset.tenant,
           authorize?: false
         ) do
      {:ok, version} ->
        changeset
        |> decide(run, version)
        |> Ash.Changeset.after_action(fn _changeset, claimed ->
          {:ok, Ash.Resource.put_metadata(claimed, :agent_version, version)}
        end)

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  defp decide(changeset, run, version) do
    limits = Map.new(version.limits || %{}, fn {key, value} -> {to_string(key), value} end)
    now = DateTime.utc_now()

    cond do
      run.deadline_at && DateTime.compare(run.deadline_at, now) != :gt ->
        finish(changeset, :failed, failure_class: :timeout, error_code: "deadline_passed")

      match?({:error, _}, Definition.check_pinned(version)) ->
        finish(changeset, :failed, failure_class: :permanent, error_code: "definition_drift")

      reached?(run.step_count, limits["max_steps"]) ->
        finish(changeset, :waiting, blocked_on: :limit, error_code: "max_steps")

      reached?(run.tool_call_count, limits["max_tool_calls"]) ->
        finish(changeset, :waiting, blocked_on: :limit, error_code: "max_tool_calls")

      reached?(run.budget_spent, run.budget_limit) ->
        finish(changeset, :waiting, blocked_on: :budget, error_code: "token_budget")

      true ->
        changeset
        |> AshStateMachine.transition_state(:running)
        |> Ash.Changeset.force_change_attributes(%{
          blocked_on: nil,
          error_code: nil,
          lease_expires_at:
            DateTime.add(now, Ash.Changeset.get_argument(changeset, :lease_for), :millisecond)
        })
    end
  end

  defp finish(changeset, state, attributes) do
    changeset
    |> AshStateMachine.transition_state(state)
    |> Ash.Changeset.force_change_attributes(
      attributes
      |> Map.new()
      |> Map.put(:lease_expires_at, nil)
    )
  end

  defp reached?(count, limit) when is_integer(limit), do: count >= limit
  defp reached?(_count, _no_limit), do: false
end
