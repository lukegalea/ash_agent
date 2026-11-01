# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Run.Changes.Reserve do
  @moduledoc """
  The `reserve` action's work, after its `optimistic_lock(:budget_lock)`
  (`AshAgent.Run.Budget`).

  The lease `epoch` of the run `run_id` holds `tokens` more. Holds of that run's earlier
  leases are released first: a later lease holds the run. When the holds and what was
  spent would pass `budget_limit`, the reservation is refused with
  `AshAgent.Run.BudgetExhausted` and nothing is written; otherwise the update is also
  filtered on the same sum, so the database refuses what the reading allowed if the row
  moved under it.

  A run reserving for its own step must still hold that lease: the update is filtered
  on `lease_epoch` and `status == :running`, so a worker whose lease was taken over
  holds nothing.
  """

  use Ash.Resource.Change

  require Ash.Expr

  alias AshAgent.Run.{Budget, BudgetExhausted}

  @impl true
  def change(changeset, _opts, _context) do
    data = changeset.data
    run_id = Ash.Changeset.get_argument(changeset, :run_id)
    epoch = Ash.Changeset.get_argument(changeset, :epoch)
    tokens = Ash.Changeset.get_argument(changeset, :tokens)

    holds =
      data.budget_holds
      |> Budget.release_earlier(run_id, epoch)
      |> Map.update(Budget.hold_key(run_id, epoch), tokens, &(&1 + tokens))

    reserved = holds |> Map.values() |> Enum.sum()

    cond do
      is_nil(data.budget_limit) ->
        Ash.Changeset.add_error(changeset,
          field: :budget_limit,
          message: "the run has no token budget to reserve from"
        )

      data.budget_spent + reserved > data.budget_limit ->
        Ash.Changeset.add_error(
          changeset,
          BudgetExhausted.exception(
            run_id: data.id,
            tokens: tokens,
            available: Budget.available(data, epoch)
          )
        )

      true ->
        changeset
        |> own_lease(data, run_id, epoch)
        |> Ash.Changeset.filter(Ash.Expr.expr(budget_spent + ^reserved <= budget_limit))
        |> Ash.Changeset.force_change_attributes(%{
          budget_holds: holds,
          budget_reserved: reserved
        })
    end
  end

  defp own_lease(changeset, %{id: run_id}, run_id, epoch),
    do:
      Ash.Changeset.filter(changeset, Ash.Expr.expr(status == :running and lease_epoch == ^epoch))

  defp own_lease(changeset, _root, _run_id, _epoch), do: changeset
end
