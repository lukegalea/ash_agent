# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.Agents.Archivist do
  @moduledoc """
  A clinic agent offered a tool that declares no effects (`CredentialCheck.archive`), so
  it registers as a draft and cannot be published.
  """

  use AshAgent.Agent,
    key: "clinic.archivist",
    instructions: "Archive checks that are no longer needed.",
    model_profile: "in_zone",
    tools: [{AshAgent.Test.CredentialCheck, :archive}],
    limits: [
      max_steps: 2,
      max_tool_calls: 2,
      deadline: [minutes: 5],
      token_budget: 1_000,
      max_repairs: 0
    ]
end
