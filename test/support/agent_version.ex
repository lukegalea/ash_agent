# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.AgentVersion do
  @moduledoc """
  The test host's agent version resource: the `AshAgent.AgentVersion` fragment on a
  plain `Ash.Resource` over Postgres, with no tenancy, policies, audit or approval. The
  host's governed publish path is the host's; here `apply_publish` is called directly.
  """

  use Ash.Resource,
    domain: AshAgent.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    fragments: [AshAgent.AgentVersion]

  postgres do
    table "agent_versions"
    repo AshAgent.Test.Repo
  end
end
