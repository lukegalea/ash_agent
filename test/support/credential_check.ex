# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.CredentialCheck do
  @moduledoc """
  A test host resource that invocations run: a clinic's check of a clinician's licence.

    * `:record` writes only here and needs no approval: the internal path.
    * `:record_reviewed` is the same write, confirmed by a person first.
    * `:mark_verified` updates a check, so its subject is captured as a precondition.
    * `:notify_board` reaches outside (it only pretends to): the open-world path.
    * `:archive` is declared nowhere, so it cannot be invoked.

  A check is visible to everyone unless it is `restricted_to` one person, such as a
  check still under review: then only that person reads it.
  """

  use Ash.Resource,
    domain: AshAgent.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAgent.Effects]

  postgres do
    table "credential_checks"
    repo AshAgent.Test.Repo
  end

  effects do
    action :record,
      kind: :edit,
      destructive?: false,
      open_world?: false,
      intent: :execute

    action :record_reviewed,
      kind: :edit,
      destructive?: false,
      open_world?: false,
      approval: :confirm,
      intent: :execute

    action :mark_verified,
      kind: :edit,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :execute

    action :notify_board, kind: :fetch, destructive?: false, intent: :execute
  end

  actions do
    defaults [:read]

    create :record do
      accept [:licence_number, :clinician_name]
    end

    create :record_reviewed do
      accept [:licence_number, :clinician_name]
    end

    update :mark_verified do
      accept []
      change set_attribute(:verified?, true)
    end

    update :archive do
      accept []
    end

    action :notify_board, :boolean do
      argument :licence_number, :string, allow_nil?: false
      run fn _input, _context -> {:ok, true} end
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(is_nil(restricted_to) or restricted_to == ^actor(:id))
    end

    policy action_type([:create, :update, :destroy, :action]) do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :licence_number, :string do
      allow_nil? false
      public? true
    end

    attribute :clinician_name, :string, public?: true
    attribute :restricted_to, :string, public?: true
    attribute :verified?, :boolean, public?: true, allow_nil?: false, default: false
    attribute :version_number, :integer, public?: true, allow_nil?: false, default: 1
  end

  identities do
    identity :unique_licence_number, [:licence_number]
  end
end
