# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.Changes.EnqueueReconcile do
  @moduledoc """
  Enqueues `:reconcile` for the row when the action leaves its outcome unknown
  (`AshAgent.Invocation.Enqueue`).
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context),
    do: Ash.Changeset.after_action(changeset, &AshAgent.Invocation.Enqueue.when_unknown/2)
end
