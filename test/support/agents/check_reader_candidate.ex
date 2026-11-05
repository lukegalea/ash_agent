# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.Agents.CheckReaderCandidate do
  @moduledoc """
  The same agent as `AshAgent.Test.Agents.CheckReader`, key and tools, with new
  instructions: a candidate for a release.
  """

  use AshAgent.Agent,
    key: "clinic.check_reader",
    instructions: "Read the clinic's credential checks and record what is missing. Be brief.",
    model_profile: "in_zone",
    tools: [
      {AshAgent.Test.CredentialCheck, :read},
      {AshAgent.Test.CredentialCheck, :record}
    ],
    limits: [
      max_steps: 6,
      max_tool_calls: 8,
      deadline: [hours: 1],
      token_budget: 10_000,
      max_repairs: 1
    ],
    output_type: :map
end
