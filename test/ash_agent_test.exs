# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgentTest do
  @moduledoc false
  use ExUnit.Case, async: true

  test "the package starts no processes of its own" do
    refute match?({_module, _args}, Application.spec(:ash_agent, :mod))
  end

  test "the package defines no mix tasks" do
    {:ok, modules} = :application.get_key(:ash_agent, :modules)
    refute Enum.any?(modules, &String.starts_with?(Atom.to_string(&1), "Elixir.Mix.Tasks."))
  end
end
