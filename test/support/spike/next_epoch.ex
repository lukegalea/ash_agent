# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.Spike.NextEpoch do
  @moduledoc """
  Takes the next lease epoch: the loaded row's epoch plus one.

  Deliberately not atomic. A host that audits writes through a wrapper which
  refuses atomic updates runs it as an ordinary change, and fences the write
  with a filter or an optimistic lock instead of an atomic increment.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.force_change_attribute(
      changeset,
      :lease_epoch,
      changeset.data.lease_epoch + 1
    )
  end
end
