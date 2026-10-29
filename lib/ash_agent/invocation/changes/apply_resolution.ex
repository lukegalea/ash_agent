# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.Changes.ApplyResolution do
  @moduledoc """
  Applies a person's resolution to a row whose outcome was unknown, after a resolution
  was requested (`request_resolution`).

  The outcome is read just before the write (a `before_action` hook), after every change
  of the action has run, so a host may attach a change of its own to `apply_resolution`
  that reads the decision from its task mechanism and sets the `outcome` and
  `decided_by_id` arguments, or adds an error when the decision must not apply.

    * `:succeeded`: the effect happened. The row becomes `succeeded`.
    * `:failed`: it did not, and is not to be tried again. The row becomes `failed`,
      keeping the class it was marked unknown with (`:timeout` for a passed deadline),
      else `:permanent`.
    * `:retry`: it did not; run it again. The row becomes `ready` with the same key and
      arguments, and its `:execute` job is enqueued in the same transaction.

  Each records `resolved_by_id` and `reconciled_via: "operator"`. With no outcome the
  update is refused, so it writes nothing.
  """

  use Ash.Resource.Change

  alias AshAgent.Invocation.Enqueue

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&apply_outcome/1)
    |> Ash.Changeset.after_action(&Enqueue.when_ready/2)
  end

  defp apply_outcome(changeset) do
    resolved = %{
      resolved_by_id: Ash.Changeset.get_argument(changeset, :decided_by_id),
      reconciled_via: "operator"
    }

    case Ash.Changeset.get_argument(changeset, :outcome) do
      :succeeded ->
        changeset
        |> AshStateMachine.transition_state(:succeeded)
        |> Ash.Changeset.force_change_attributes(
          Map.merge(resolved, %{
            failure_class: nil,
            error_code: nil,
            effect_observed_at: DateTime.utc_now()
          })
        )

      :failed ->
        changeset
        |> AshStateMachine.transition_state(:failed)
        |> Ash.Changeset.force_change_attributes(
          Map.put(resolved, :failure_class, changeset.data.failure_class || :permanent)
        )

      :retry ->
        changeset
        |> AshStateMachine.transition_state(:ready)
        |> Ash.Changeset.force_change_attributes(
          Map.merge(resolved, %{
            failure_class: nil,
            error_code: nil,
            next_attempt_at: nil,
            resolution_requested_at: nil
          })
        )

      nil ->
        Ash.Changeset.add_error(changeset, field: :outcome, message: "no resolution to apply")
    end
  end
end
