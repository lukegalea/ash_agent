# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.Run.SeesSubject do
  @moduledoc """
  A host change on the test host's `start`, after the fragment's: it tells the test
  process which subject the fragment left in the changeset context, as a host's sealing
  change would read it.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case get_in(changeset.context, [:ash_agent, :subject]) do
      nil -> changeset
      subject -> tap(changeset, fn _changeset -> send(self(), {:start_subject, subject}) end)
    end
  end
end
