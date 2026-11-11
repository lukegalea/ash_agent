# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.GovernedTenant do
  @moduledoc """
  The test host's tenant resource with the four-eyes seam open: it names the
  invocation resource in its `approval_posture` section and declares
  `set_approval_posture` a four-eyes target at the floor, so a posture may be
  lowered through an approved invocation as well as by the sole administrator or
  an operator directly. It attaches no `AshAgent.Validations.Governed`, which
  would refuse those direct changes.
  """

  use Ash.Resource,
    domain: AshAgent.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAgent.Effects],
    fragments: [AshAgent.Approval.PostureFragment]

  postgres do
    table "governed_tenants"
    repo AshAgent.Test.Repo
  end

  attributes do
    uuid_primary_key :id
  end

  actions do
    defaults [:read, :create]
  end

  effects do
    action :set_approval_posture,
      kind: :edit,
      destructive?: false,
      open_world?: false,
      intent: :execute,
      approval: :four_eyes,
      approver_role: :clinic_administrator,
      posture_floor?: true
  end

  approval_posture do
    authority(AshAgent.Test.Authority)
    execution_identity(AshAgent.Test.ExecutionIdentity)
    invocation(AshAgent.Test.Invocation)
  end
end
