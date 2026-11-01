# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Run.Changes.Settle do
  @moduledoc """
  The `settle` action's work, after its `optimistic_lock(:budget_lock)`
  (`AshAgent.Run.Budget`).

  Releases the hold of the lease `epoch` of the run `run_id`, when it still has one, and
  adds `tokens` (what the call used) to `budget_spent`. A call is settled whatever
  became of its lease: a hold already released by a later lease releases nothing, and
  what the call used is still recorded.
  """

  use Ash.Resource.Change

  alias AshAgent.Run.Budget

  @impl true
  def change(changeset, _opts, _context) do
    data = changeset.data

    key =
      Budget.hold_key(
        Ash.Changeset.get_argument(changeset, :run_id),
        Ash.Changeset.get_argument(changeset, :epoch)
      )

    {held, holds} = Map.pop(data.budget_holds, key, 0)

    Ash.Changeset.force_change_attributes(changeset, %{
      budget_holds: holds,
      budget_reserved: data.budget_reserved - held,
      budget_spent: data.budget_spent + Ash.Changeset.get_argument(changeset, :tokens)
    })
  end
end
