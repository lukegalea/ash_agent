# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.Changes.Requeue do
  @moduledoc """
  The `requeue` action's work, after its filter on the epoch: an `executing` row whose
  lease has expired becomes `ready` again and its `:execute` job is enqueued in the same
  transaction.

  Refused unless the lease has expired and running the target again cannot repeat its
  effect (`AshAgent.Invocation.Failure.repeatable?/1`). For a target that writes only to
  this application, an expired lease with no `succeed` means its effect rolled back with
  its transaction; for an idempotent one, the outside service deduplicates a second call
  by the invocation key. Any other row's effect may have happened, and only
  `mark_outcome_unknown` and reconciliation may settle it.

  Refused, too, once the row has used its attempts (`attempt_count` at the host's
  `max_attempts`): a worker that dies every time is not run forever.
  """

  use Ash.Resource.Change

  alias AshAgent.Invocation.{Enqueue, Failure, Info}

  @impl true
  def change(changeset, _opts, _context) do
    data = changeset.data

    cond do
      not expired?(data.lease_expires_at) ->
        Ash.Changeset.add_error(changeset,
          field: :lease_expires_at,
          message: "the lease has not expired"
        )

      not Failure.repeatable?(data.effects) ->
        Ash.Changeset.add_error(changeset,
          field: :effects,
          message:
            "running this target again could repeat an outside effect; reconcile it instead"
        )

      data.attempt_count >= Info.max_attempts(changeset.resource) ->
        Ash.Changeset.add_error(changeset,
          field: :attempt_count,
          message: "the row has used its attempts; reconcile it instead"
        )

      true ->
        changeset
        |> AshStateMachine.transition_state(:ready)
        |> Ash.Changeset.force_change_attributes(%{lease_expires_at: nil, next_attempt_at: nil})
        |> Ash.Changeset.after_action(&Enqueue.when_ready/2)
    end
  end

  defp expired?(%DateTime{} = at), do: DateTime.compare(at, DateTime.utc_now()) != :gt
  defp expired?(_none), do: false
end
