# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.Step do
  @moduledoc """
  The test host's step resource: the `AshAgent.Step` fragment on a plain `Ash.Resource`
  over Postgres.
  """

  use Ash.Resource,
    domain: AshAgent.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    fragments: [AshAgent.Step]

  postgres do
    table "agent_steps"
    repo AshAgent.Test.Repo
  end
end
