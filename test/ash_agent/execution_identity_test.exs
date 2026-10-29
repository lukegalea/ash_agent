# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.ExecutionIdentityTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias AshAgent.ExecutionIdentity

  doctest AshAgent.ExecutionIdentity

  test "a principal's identity does not care how its fields were spelled when stored" do
    assert ExecutionIdentity.identity(%{type: :automation, id: "intake", on_behalf_of: "p1"}) ==
             ExecutionIdentity.identity(%{
               "type" => "automation",
               "id" => "intake",
               "on_behalf_of" => "p1",
               "agent" => nil
             })

    refute ExecutionIdentity.identity(%{type: :automation, id: "intake", on_behalf_of: "p1"}) ==
             ExecutionIdentity.identity(%{type: :automation, id: "intake", on_behalf_of: "p2"})
  end
end
