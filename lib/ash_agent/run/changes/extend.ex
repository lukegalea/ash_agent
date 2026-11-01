# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Run.Changes.Extend do
  @moduledoc """
  The `extend` action's work, after its `optimistic_lock(:budget_lock)`: raises
  `budget_limit` by `tokens`.

  A run waiting on its budget is queued again and its next `:step` job enqueued in the
  same transaction; the update is then filtered on the run still waiting on its budget,
  so a run cancelled meanwhile is not queued. Any other unfinished run only has its
  limit raised. A finished run, or one with no budget, is refused.
  """

  use Ash.Resource.Change

  require Ash.Expr

  @unfinished [:queued, :running, :waiting]

  @impl true
  def change(changeset, _opts, _context) do
    data = changeset.data

    cond do
      data.status not in @unfinished ->
        Ash.Changeset.add_error(changeset,
          field: :status,
          message: "the run is %{status}; only an unfinished run's budget can be extended",
          vars: [status: data.status]
        )

      is_nil(data.budget_limit) ->
        Ash.Changeset.add_error(changeset,
          field: :budget_limit,
          message: "the run has no token budget to extend"
        )

      true ->
        changeset
        |> Ash.Changeset.force_change_attribute(
          :budget_limit,
          data.budget_limit + Ash.Changeset.get_argument(changeset, :tokens)
        )
        |> resume(data)
    end
  end

  defp resume(changeset, %{status: :waiting, blocked_on: :budget}) do
    changeset
    |> Ash.Changeset.filter(Ash.Expr.expr(status == :waiting and blocked_on == :budget))
    |> AshStateMachine.transition_state(:queued)
    |> Ash.Changeset.force_change_attributes(%{blocked_on: nil, error_code: nil})
    |> Ash.Changeset.after_action(&AshAgent.Run.Enqueue.step/2)
  end

  defp resume(changeset, _not_waiting_on_budget), do: changeset
end
