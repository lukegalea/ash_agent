# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.Run do
  @moduledoc """
  The test host's agent run resource: the `AshAgent.Run` fragment on a plain
  `Ash.Resource` over Postgres, with no tenancy, policies, audit or triggers. Tests take
  steps themselves, with `AshAgent.Run.Stepper.step/3`.
  """

  use Ash.Resource,
    domain: AshAgent.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    fragments: [AshAgent.Run]

  postgres do
    table "agent_runs"
    repo AshAgent.Test.Repo
  end

  run do
    agent_version(AshAgent.Test.AgentVersion)
    step(AshAgent.Test.Step)
    invocation(AshAgent.Test.Invocation)
    runtime(AshAgent.Test.Runtime)
  end
end
