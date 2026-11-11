# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Approval.PostureFragment do
  @moduledoc """
  A Spark fragment for the host's tenant resource: the approval posture in force
  for that tenant (`AshAgent.Approval.Posture`) and its end date, with the one
  action that changes them.

  The host includes it on its tenant resource, built from its own base:

      defmodule MyClinic.Tenant do
        use Ash.Resource,
          domain: MyClinic,
          data_layer: AshPostgres.DataLayer,
          fragments: [AshAgent.Approval.PostureFragment]

        postgres do
          table "tenants"
          repo MyClinic.Repo
        end

        approval_posture do
          authority MyClinic.ApprovalAuthority
          execution_identity MyClinic.ExecutionIdentity
        end
      end

  ## The action

  `set_approval_posture` (update) accepts both attributes and enforces, in its
  change and validation (`AshAgent.Approval.Changes.ClearPostureEndsAt`,
  `AshAgent.Approval.Validations.PostureChange`):

    * an `:implementation` posture needs an end date in the future and at most
      `AshAgent.Approval.Posture.max_implementation_days/0` days out; every
      other posture clears the end date;
    * raising the posture (towards `:standard`) is the work of one
      administrator; lowering it needs the sole administrator, an operator, or a
      change approved under four eyes.

  The four-eyes path is a seam: declare this action as a governed target of its
  own — an effects declaration with `approval: :four_eyes, approver_role: <the
  administrators>, posture_floor?: true`, reached through `invoke`, and
  `validate {AshAgent.Validations.Governed, invocation: MyClinic.Invocation}` on
  the action — and the validation accepts the change, because the approval
  behind it was four eyes under every posture. A host that reaches the action
  another way relies on its policies alone.

  ## What the fragment does not declare

  Tenancy, policies, encryption and the `postgres` block; the host supplies
  them, as it does for the other fragments. The posture is read through
  `c:AshAgent.Approval.Authority.posture/1`, which the host implements over this
  row or over wherever else it keeps it.
  """

  use Spark.Dsl.Fragment,
    of: Ash.Resource,
    extensions: [AshAgent.Approval.Dsl]

  actions do
    update :set_approval_posture do
      description "Set the tenant's approval posture and its end date."
      accept [:approval_posture, :approval_posture_ends_at]
      require_atomic? false

      change AshAgent.Approval.Changes.ClearPostureEndsAt
      validate AshAgent.Approval.Validations.PostureChange
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :approval_posture, :atom do
      allow_nil? false
      public? true
      default :standard
      constraints one_of: AshAgent.Approval.Posture.postures()

      description """
      The tenant's approval posture (`AshAgent.Approval.Posture`): which person
      decides an approval. `:standard` unless a person changes it.
      """
    end

    attribute :approval_posture_ends_at, :utc_datetime_usec do
      public? true

      description """
      When the `:implementation` posture ends, after which it reads as
      `:standard` (`AshAgent.Approval.Posture.effective/3`). Kept by no other
      posture.
      """
    end
  end
end
