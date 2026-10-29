# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.Changes.EnqueueExecute do
  @moduledoc "Enqueues `:execute` for the row when the action leaves it ready (`AshAgent.Invocation.Enqueue`)."

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context),
    do: Ash.Changeset.after_action(changeset, &AshAgent.Invocation.Enqueue.when_ready/2)
end
