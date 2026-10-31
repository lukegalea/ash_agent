# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Run.Enqueue do
  @moduledoc """
  Enqueues a run's next `:step` job inside the transaction of the action that gave it
  work (an `after_action` hook), so the run and its job commit or roll back together.

  The job carries the run's id only; no actor. Whether the run really has a step to take
  is decided when the job runs (`needs_step`), so enqueueing too often costs a job that
  ends at once, never a second model call. On a resource with no `:step` trigger it does
  nothing, and the host steps runs itself.
  """

  @waiting [:queued, :waiting]

  @doc "An `after_action` hook: enqueues `:step` when `run` is queued or waiting."
  @spec step(Ash.Changeset.t(), Ash.Resource.record()) :: {:ok, Ash.Resource.record()}
  def step(_changeset, %{status: status} = run) when status in @waiting do
    if trigger?(run.__struct__), do: AshOban.run_trigger(run, :step)
    {:ok, run}
  end

  def step(_changeset, run), do: {:ok, run}

  @doc "Enqueues `:step` for the run with id `run_id` of `resource`, in `tenant`."
  @spec wake(Ash.Resource.t(), Ash.UUID.t(), term()) :: :ok
  def wake(resource, run_id, tenant) do
    if trigger?(resource),
      do: AshOban.run_trigger(struct(resource, id: run_id), :step, tenant: tenant)

    :ok
  end

  defp trigger?(resource), do: AshAgent.Invocation.Info.trigger?(resource, :step)
end
