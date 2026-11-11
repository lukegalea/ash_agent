# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Approval.Changes.ClearPostureEndsAt do
  @moduledoc """
  The `set_approval_posture` action's clearing of the end date: an
  `:implementation` posture keeps it, every other posture clears it. Runs before
  the action's validation, which sees the cleared value.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :approval_posture) == :implementation do
      changeset
    else
      Ash.Changeset.change_attribute(changeset, :approval_posture_ends_at, nil)
    end
  end
end
