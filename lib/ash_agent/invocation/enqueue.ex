# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.Enqueue do
  @moduledoc """
  Enqueues the job that comes next for a row an action just changed, inside that
  action's transaction (an `after_action` hook), so the row and its job commit or roll
  back together:

    * `:execute` for a row an action made `ready`;
    * `:reconcile` for a row an action made `outcome_unknown`.

  On a resource with no such trigger it does nothing, and the host runs the rows itself.
  Each trigger's scheduler is the sweep that picks up a row whose job was lost, or whose
  job could not be inserted because the job that changed it is still running for the
  same row (ash_oban keeps one job per row and trigger while one is incomplete).

  A job carries the row's id only. No actor is passed: the trigger's own default actor
  runs it, and the executing actor is rebuilt at claim.
  """

  alias AshAgent.Invocation.Info

  @doc "An `after_action` hook: enqueues `:execute` when `record` is ready."
  @spec when_ready(Ash.Changeset.t(), Ash.Resource.record()) :: {:ok, Ash.Resource.record()}
  def when_ready(_changeset, %{status: :ready} = record) do
    if Info.trigger?(record.__struct__, :execute), do: AshOban.run_trigger(record, :execute)
    {:ok, record}
  end

  def when_ready(_changeset, record), do: {:ok, record}

  @doc "An `after_action` hook: enqueues `:reconcile` when `record`'s outcome is unknown."
  @spec when_unknown(Ash.Changeset.t(), Ash.Resource.record()) :: {:ok, Ash.Resource.record()}
  def when_unknown(_changeset, %{status: :outcome_unknown} = record) do
    if Info.trigger?(record.__struct__, :reconcile), do: AshOban.run_trigger(record, :reconcile)
    {:ok, record}
  end

  def when_unknown(_changeset, record), do: {:ok, record}
end
