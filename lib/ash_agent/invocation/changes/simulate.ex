# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.Changes.Simulate do
  @moduledoc """
  The `simulate` action's work: a ready row of a run that is not live gets the run's
  fixture for its target as its outcome, and its target never runs.

  A fixture (the `result` given) makes the row `succeeded`, with the fixture as its
  `result` and `simulated: true`. None makes it `failed`, `:permanent`, with
  `error_code: "no_fixture"`: the run asked for something its fixtures do not answer,
  and nothing stands in for it.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    common = %{simulated: true, next_attempt_at: nil, lease_expires_at: nil}

    # A host that encrypts `result` at rest turns the accepted attribute into an argument.
    case Ash.Changeset.fetch_argument_or_change(changeset, :result) do
      {:ok, result} when is_map(result) ->
        changeset
        |> AshStateMachine.transition_state(:succeeded)
        |> Ash.Changeset.force_change_attributes(common)

      _none ->
        changeset
        |> Ash.Changeset.clear_change(:result)
        |> Ash.Changeset.force_delete_argument(:result)
        |> AshStateMachine.transition_state(:failed)
        |> Ash.Changeset.force_change_attributes(
          Map.merge(common, %{failure_class: :permanent, error_code: "no_fixture"})
        )
    end
  end
end
