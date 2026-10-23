# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.DataCase do
  @moduledoc """
  Case template for tests that use the test host's Postgres database.

  Each test runs inside the Ecto SQL sandbox.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias AshAgent.Test.Repo
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(AshAgent.Test.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
