# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.Enqueue do
  @moduledoc """
  Enqueues the `:execute` job for a row an action made ready, inside that action's
  transaction (an `after_action` hook), so the row and its job commit or roll back
  together. On a resource with no `:execute` trigger it does nothing, and the host runs
  ready rows itself.

  The job carries the row's id only. No actor is passed: the trigger's own default actor
  runs it, and the executing actor is rebuilt at claim.
  """

  alias AshAgent.Invocation.Info

  @doc "An `after_action` hook: enqueues `:execute` when `record` is ready."
  @spec when_ready(Ash.Changeset.t(), Ash.Resource.record()) :: {:ok, Ash.Resource.record()}
  def when_ready(_changeset, %{status: :ready} = record) do
    if Info.execute_trigger?(record.__struct__), do: AshOban.run_trigger(record, :execute)
    {:ok, record}
  end

  def when_ready(_changeset, record), do: {:ok, record}
end
