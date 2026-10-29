# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.Changes.RequestCancel do
  @moduledoc """
  Cancellation is cooperative.

    * A row that has not started (`requested`, `awaiting_approval`, `ready`) becomes
      `cancelled`. A `ready` row's job still runs, finds the row not claimable and ends.
    * A row that is `executing`, `dispatched` or `outcome_unknown` keeps its state and records
      `cancel_requested_at`: its work may already have happened, and what follows is for
      whoever completes or reconciles it to decide.
    * A finished row cannot be changed, so cancelling one is refused.

  The update is filtered on the status and lease epoch it read, so a cancellation that
  races a claim either lands before it (and the claim finds a cancelled row) or is
  refused with `StaleRecord`.
  """

  use Ash.Resource.Change

  require Ash.Expr

  @not_started [:requested, :awaiting_approval, :ready]
  @in_flight [:executing, :dispatched, :outcome_unknown]

  @impl true
  def change(changeset, _opts, _context) do
    %{status: status, lease_epoch: epoch} = changeset.data

    changeset =
      Ash.Changeset.filter(changeset, Ash.Expr.expr(status == ^status and lease_epoch == ^epoch))

    cond do
      status in @not_started ->
        AshStateMachine.transition_state(changeset, :cancelled)

      status in @in_flight ->
        Ash.Changeset.force_change_attribute(changeset, :cancel_requested_at, DateTime.utc_now())

      true ->
        Ash.Changeset.add_error(changeset,
          field: :status,
          message: "is %{status}; a finished invocation cannot be cancelled",
          vars: [status: status]
        )
    end
  end
end
