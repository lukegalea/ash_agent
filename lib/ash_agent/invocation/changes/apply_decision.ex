# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.Changes.ApplyDecision do
  @moduledoc """
  Applies an approval's outcome to a row awaiting one.

  The outcome is read just before the write (a `before_action` hook), after every change
  of the action has run, so a host may attach a change of its own to `apply_decision`
  that reads its approval mechanism and sets the `outcome` and `decided_by_id`
  arguments, or adds an error when the decision must not apply. The package does not
  know how approvals are made.

    * `:approved`: if the approval still holds (`AshAgent.Invocation.Approval.stale_reason/2`:
      not expired, and the digest recomputed from the row, the target as declared now and
      the preconditions' records as they stand now equals `approval_digest`), the row
      becomes `ready`, records who approved it, and its `:execute` job is enqueued in the
      same transaction. Otherwise it becomes `stale`, with the reason as `error_code`;
    * `:rejected`: the row becomes `rejected`, with `failure_class: :rejected`;
    * `:stale`: the row becomes `stale`: what was approved is no longer what would run.

  With no outcome the update is refused, so it writes nothing.
  """

  use Ash.Resource.Change

  alias AshAgent.Invocation.{Approval, Enqueue}

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&apply_outcome/1)
    |> Ash.Changeset.after_action(&Enqueue.when_ready/2)
  end

  defp apply_outcome(changeset) do
    case Ash.Changeset.get_argument(changeset, :outcome) do
      :approved ->
        case Approval.stale_reason(changeset.data, tenant: changeset.tenant) do
          nil ->
            changeset
            |> AshStateMachine.transition_state(:ready)
            |> Ash.Changeset.force_change_attributes(%{
              approved_by_id: Ash.Changeset.get_argument(changeset, :decided_by_id),
              next_attempt_at: nil
            })

          reason ->
            changeset
            |> AshStateMachine.transition_state(:stale)
            |> Ash.Changeset.force_change_attribute(:error_code, reason)
        end

      :rejected ->
        changeset
        |> AshStateMachine.transition_state(:rejected)
        |> Ash.Changeset.force_change_attributes(%{
          failure_class: :rejected,
          error_code: "approval_rejected"
        })

      :stale ->
        AshStateMachine.transition_state(changeset, :stale)

      nil ->
        Ash.Changeset.add_error(changeset, field: :outcome, message: "no decision to apply")
    end
  end
end
