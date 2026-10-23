# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.Clinician do
  @moduledoc """
  A test host resource on Postgres: a clinician whose credentials a clinic
  checks.

  It includes no fragment yet, because the package ships none. Fragments are
  added to the test host's resources as they are built, the same way a consuming
  application includes them on its own.
  """

  use Ash.Resource,
    domain: AshAgent.Test.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "clinicians"
    repo AshAgent.Test.Repo
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:name, :license_number]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :license_number, :string do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  identities do
    identity :unique_license_number, [:license_number]
  end
end
