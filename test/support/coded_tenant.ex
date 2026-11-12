# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.CodedTenant do
  @moduledoc """
  The test host's tenant resource whose tenants the Authority knows by an
  attribute other than the primary key: it names `tenant_attribute :code`, so a
  posture change on a row asks the Authority about that row's `code`.
  """

  use Ash.Resource,
    domain: AshAgent.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    fragments: [AshAgent.Approval.PostureFragment]

  postgres do
    table "coded_tenants"
    repo AshAgent.Test.Repo
  end

  attributes do
    uuid_primary_key :id
    attribute :code, :string, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read]

    create :create do
      accept [:code]
    end
  end

  approval_posture do
    authority(AshAgent.Test.Authority)
    execution_identity(AshAgent.Test.ExecutionIdentity)
    tenant_attribute(:code)
  end
end
