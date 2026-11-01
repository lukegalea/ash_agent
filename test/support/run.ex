# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.Run do
  @moduledoc """
  The test host's agent run resource: the `AshAgent.Run` fragment on a plain
  `Ash.Resource` over Postgres, with no tenancy, policies, audit or triggers. Tests take
  steps themselves, with `AshAgent.Run.Stepper.step/3`.

  Every update is under `optimistic_lock(:revision)`, as on a host that locks every
  write to a row: a step must carry on from the run as its last write left it.
  """

  use Ash.Resource,
    domain: AshAgent.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    fragments: [AshAgent.Run]

  postgres do
    table "agent_runs"
    repo AshAgent.Test.Repo
  end

  attributes do
    attribute :revision, :integer, allow_nil?: false, default: 0, public?: true
  end

  run do
    agent_version(AshAgent.Test.AgentVersion)
    step(AshAgent.Test.Step)
    invocation(AshAgent.Test.Invocation)
    runtime(AshAgent.Test.Runtime)
  end

  changes do
    change AshAgent.Test.Run.SeesSubject, on: [:create]
    change optimistic_lock(:revision), on: [:update]
  end
end
