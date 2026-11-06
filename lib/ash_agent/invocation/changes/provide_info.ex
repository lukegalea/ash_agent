# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.Changes.ProvideInfo do
  @moduledoc """
  Returns a row whose approver asked for more information (`request_info`) to its
  approver (`awaiting_approval`), once the requester has answered.

  The row is the same request: its arguments, `authorization_details` and
  `approval_digest` do not change, and `apply_decision` checks the binding again when the
  next decision is applied. Only the approval window starts again, from the declaration's
  `approval_expires_in` as it was snapshotted on the row, so the time spent waiting on
  the requester is not taken from the approver. Where and how the requester answers is
  the host's: attach a change that records it, or refuses the update while there is no
  answer.
  """

  use Ash.Resource.Change

  alias AshAgent.Invocation.Approval

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> AshStateMachine.transition_state(:awaiting_approval)
    |> Ash.Changeset.force_change_attribute(
      :approval_expires_at,
      Approval.expires_at(changeset.data.effects || %{}, DateTime.utc_now())
    )
  end
end
