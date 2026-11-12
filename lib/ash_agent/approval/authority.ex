# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Approval.Authority do
  @moduledoc """
  What a host answers about its people for approval postures
  (`AshAgent.Approval.Posture`): the posture in force, who holds its roles, and
  who its platform operators are.

  The package calls this and never reads the host's people, roles or tenants
  itself. Name the implementation in the `invocation` section of the resource
  that includes `AshAgent.Invocation`:

      invocation do
        authority MyClinic.ApprovalAuthority
        execution_identity MyClinic.ExecutionIdentity
        digest_key MyClinic.InvocationDigestKey
      end
  The same module is named in the `approval_posture` section of a resource that
  includes `AshAgent.Approval.PostureFragment`, together with the host's
  `AshAgent.ExecutionIdentity` module, whose `principal_of/1` maps an actor to
  a person for the posture-change rules.

  ## What each answer is for

    * `posture/1` is asked where an approval is decided and re-checked: at
      `apply_decision`, and at every `claim` of a row that was approved
      (`AshAgent.Invocation.Approval.stale_reason/2` re-asks it, so a
      self-approval the posture no longer allows makes the row `stale`).
    * `holders/2` is everyone who holds **or has ever held** the role: the set
      the governance rules need, not the host's current grants. The rule for
      lowering a tenant's posture asks whether one person is the only
      administrator there ever was; the approval rule asks only whether the
      approver role has holders at all. Whether an approver holds a role *now*
      stays with the host's policies, as it is today.
    * `administrator_role/0` names the role whose holders may approve when the
      approver role has none, and the role the posture-change rules are about.
    * `operator?/1` names a platform-level operator: one who may set any
      tenant's posture, because the platform, not the tenant, vouches for them.

  Each is called with the tenant in question and no actor: for an approval, the
  tenant the invocation carries; for a posture change, the value of the row's
  `tenant_attribute`. These are facts about people, not authority checks. Who
  may call the actions that use them is the host's policies.
  """

  @typedoc "A person, as the host identifies them: the id of a person principal."
  @type person_id :: String.t()

  @doc """
  The approval posture in force for `tenant`, with its end date (`nil` unless
  the posture is `:implementation`, which requires one). A posture and end date
  a host no longer stands behind are answered as `:standard` by
  `AshAgent.Approval.Posture.effective/3`.
  """
  @callback posture(tenant :: term()) :: {AshAgent.Approval.Posture.posture(), DateTime.t() | nil}

  @doc """
  Everyone who holds or has ever held `role` in `tenant`, as person ids. The
  host's current grants are its own; this is the historical set the governance
  rules ask for.
  """
  @callback holders(tenant :: term(), role :: atom()) :: [person_id()]

  @doc "The role the posture rules treat as the tenant's administrators."
  @callback administrator_role() :: atom()

  @doc """
  Whether `actor` is a platform-level operator who may set a tenant's posture:
  raising it, and lowering it, alone.
  """
  @callback operator?(actor :: term()) :: boolean()
end
