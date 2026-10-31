# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Run.Changes.Wake do
  @moduledoc """
  Wakes a run when one of its tool calls' invocations finishes: the host attaches it to
  its invocation resource's updates and names its run resource.

      changes do
        change {AshAgent.Run.Changes.Wake, run: MyClinic.Execution.Run}, on: [:update]
      end

  When an update moves an invocation that belongs to a run (`run_id`) into a final state
  (`succeeded`, `failed`, `rejected`, `stale` or `cancelled`), the run's `:step` job is
  enqueued in the same transaction. The job decides whether the run has a step to take
  (`needs_step`): two invocations finishing at once enqueue two jobs and the run steps
  once; a callback replayed on a finished invocation changes no state and wakes nothing.
  The `:step` sweep picks up a run whose wake-up was lost.
  """

  use Ash.Resource.Change

  @final [:succeeded, :failed, :rejected, :stale, :cancelled]

  @impl true
  def init(opts) do
    if is_atom(opts[:run]) and not is_nil(opts[:run]),
      do: {:ok, opts},
      else: {:error, "Wake needs the host's run resource: `run: MyApp.Run`"}
  end

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, invocation ->
      if is_binary(invocation.run_id) and invocation.status in @final and
           changeset.data.status not in @final do
        AshAgent.Run.Enqueue.wake(opts[:run], invocation.run_id, changeset.tenant)
      end

      {:ok, invocation}
    end)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
