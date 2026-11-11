# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.Tenant do
  @moduledoc """
  The test host's tenant resource: the `AshAgent.Approval.PostureFragment` on a
  plain `Ash.Resource` over Postgres, with no tenancy or policies. It shows the
  fragment needs nothing a particular host supplies beyond its section.
  """

  use Ash.Resource,
    domain: AshAgent.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    fragments: [AshAgent.Approval.PostureFragment]

  postgres do
    table "tenants"
    repo AshAgent.Test.Repo
  end

  # A host supplies its own primary key and timestamps.
  attributes do
    uuid_primary_key :id
    create_timestamp :inserted_at, public?: true
  end

  actions do
    defaults [:read, :create]
  end

  approval_posture do
    authority(AshAgent.Test.Authority)
    execution_identity(AshAgent.Test.ExecutionIdentity)
  end
end
