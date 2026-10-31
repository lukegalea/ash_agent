# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Run.Changes.EnqueueStep do
  @moduledoc "Enqueues the run's `:step` job when the action leaves it queued or waiting."

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context),
    do: Ash.Changeset.after_action(changeset, &AshAgent.Run.Enqueue.step/2)
end
