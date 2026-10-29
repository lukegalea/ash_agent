# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.Credential do
  @moduledoc """
  A test host resource with effects declarations: a clinician's credential, which
  credentialing staff activate after a second person approves.

  It belongs to no domain: the effects tests read its
  declarations and expose its actions as tools on domains they define.
  """
  use Ash.Resource, domain: nil, extensions: [AshAgent.Effects]

  effects do
    action :read, kind: :read, read_only?: true, open_world?: false, intent: :inspect

    action :activate,
      kind: :edit,
      destructive?: false,
      idempotent?: true,
      approval: :four_eyes,
      approver_role: :credentialing_committee,
      approval_expires_in: [days: 3],
      intent: :execute,
      reconcile_with: :lookup_activation,
      preconditions: [:clinician_id]
  end

  actions do
    defaults [:read]

    update :activate do
      argument :clinician_id, :uuid
    end

    update :suspend

    action :lookup_activation, :boolean do
      run fn _input, _context -> {:ok, false} end
    end
  end

  attributes do
    uuid_primary_key :id
  end
end
