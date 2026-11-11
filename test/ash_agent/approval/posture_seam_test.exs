# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Approval.PostureSeamTest do
  @moduledoc false
  use AshAgent.DataCase, async: false

  alias AshAgent.Approval.PostureChangeRefused
  alias AshAgent.Invocation.Executor
  alias AshAgent.Test.{Authority, Domain, ExecutionIdentity}

  @set "AshAgent.Test.GovernedTenant.set_approval_posture"

  setup do
    on_exit(fn ->
      Authority.restore()
      ExecutionIdentity.restore()
    end)

    admin = %{id: Ash.UUID.generate()}
    other = %{id: Ash.UUID.generate()}
    Authority.set_holders(Authority.administrator_role(), [admin.id, other.id])

    %{tenant: Domain.create_governed_tenant!(%{}), admin: admin, other: other}
  end

  defp machinery, do: [actor: %{id: "machinery"}]
  defp key, do: "seam:#{System.unique_integer([:positive])}"

  defp lower!(tenant, actor),
    do:
      Domain.invoke!(@set, %{"id" => tenant.id, "approval_posture" => "small_team"}, %{key: key()},
        actor: actor
      )

  defp posture(tenant), do: Domain.get_governed_tenant!(tenant.id).approval_posture

  test "one of two administrators asks, the other approves, and the posture is lowered", %{
    tenant: tenant,
    admin: admin,
    other: other
  } do
    # Refused if done alone, but asked for: the request waits for its approval.
    assert {:error, %Ash.Error.Invalid{errors: [%PostureChangeRefused{reason: :lowering}]}} =
             Domain.set_governed_posture(tenant, %{approval_posture: :small_team}, actor: admin)

    row = lower!(tenant, admin)
    assert row.status == :awaiting_approval

    approved = Domain.apply_decision!(row, %{outcome: :approved, decided_by_id: other.id})
    assert {approved.status, approved.approval_basis} == {:ready, :four_eyes}

    assert {:ok, claimed} = Executor.claim(approved, machinery())
    assert {:ok, :succeeded} = Executor.run_claimed(claimed, machinery())
    assert posture(tenant) == :small_team
  end

  test "the requester cannot approve their own lowering, whatever the posture", %{
    tenant: tenant,
    admin: admin
  } do
    Authority.set_posture(:small_team)
    Authority.set_holders(:clinic_administrator, [admin.id])

    row = lower!(tenant, admin)
    stale = Domain.apply_decision!(row, %{outcome: :approved, decided_by_id: admin.id})

    assert {stale.status, stale.error_code} == {:stale, "approved_by_requester"}
    assert posture(tenant) == :standard
  end

  test "a context that names the invocation but is not its executor counts for nothing", %{
    tenant: tenant,
    admin: admin,
    other: other
  } do
    row = lower!(tenant, admin)
    approved = Domain.apply_decision!(row, %{outcome: :approved, decided_by_id: other.id})
    assert {:ok, claimed} = Executor.claim(approved, machinery())

    # Everything but the executor's lease token.
    forged = Map.delete(Executor.context(claimed), :lease_token)

    assert {:error, %Ash.Error.Invalid{errors: [%PostureChangeRefused{reason: :lowering}]}} =
             Domain.set_governed_posture(tenant, %{approval_posture: :small_team},
               actor: admin,
               context: %{ash_agent: forged}
             )

    assert posture(tenant) == :standard
  end
end
