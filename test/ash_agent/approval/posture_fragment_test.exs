# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Approval.PostureFragmentTest do
  @moduledoc false
  use AshAgent.DataCase, async: false

  alias AshAgent.Test.{Authority, Domain}

  setup do
    on_exit(&Authority.restore/0)

    admin = %{id: Ash.UUID.generate()}
    other = %{id: Ash.UUID.generate()}
    operator = %{id: Ash.UUID.generate()}
    Authority.set_holders(Authority.administrator_role(), [admin.id, other.id])

    tenant = Domain.create_tenant!(%{})
    %{tenant: tenant, admin: admin, other: other, operator: operator}
  end

  defp days(n), do: DateTime.add(DateTime.utc_now(), n, :day)

  defp set!(tenant, params, opts),
    do: Domain.set_approval_posture!(tenant, params, opts)

  defp set(tenant, params, opts),
    do: Domain.set_approval_posture(tenant, params, opts)

  describe "lowering" do
    test "is refused for one of two administrators", %{tenant: tenant, admin: admin} do
      assert {:error, %Ash.Error.Invalid{}} =
               set(tenant, %{approval_posture: :small_team}, actor: admin)

      assert Domain.get_tenant!(tenant.id).approval_posture == :standard
    end

    test "is allowed for the sole administrator", %{tenant: tenant, admin: admin, other: other} do
      Authority.set_holders(Authority.administrator_role(), [admin.id])

      assert set!(tenant, %{approval_posture: :small_team}, actor: admin).approval_posture ==
               :small_team

      # A second administrator ever since, and nobody lowers it alone again.
      Authority.set_holders(Authority.administrator_role(), [admin.id, other.id])

      assert {:error, %Ash.Error.Invalid{}} =
               set(
                 tenant,
                 %{approval_posture: :implementation, approval_posture_ends_at: days(7)},
                 actor: admin
               )
    end

    test "is allowed for an operator", %{tenant: tenant, operator: operator} do
      Authority.set_operators([operator])

      assert set!(tenant, %{approval_posture: :implementation, approval_posture_ends_at: days(7)},
               actor: operator
             ).approval_posture == :implementation
    end

    test "is allowed through an approved four-eyes change (the seam)", %{
      tenant: tenant,
      admin: admin
    } do
      assert set!(tenant, %{approval_posture: :small_team},
               actor: admin,
               context: %{ash_agent: %{invocation_id: Ash.UUID.generate()}}
             ).approval_posture == :small_team
    end

    test "is refused for a person who is not an administrator", %{
      tenant: tenant,
      operator: operator
    } do
      Authority.set_operators([operator])
      set!(tenant, %{approval_posture: :small_team}, actor: operator)

      nurse = %{id: Ash.UUID.generate()}

      assert {:error, %Ash.Error.Invalid{}} =
               set(tenant, %{approval_posture: :implementation}, actor: nurse)

      assert Domain.get_tenant!(tenant.id).approval_posture == :small_team
    end
  end

  describe "raising" do
    test "is the work of one administrator", %{tenant: tenant, admin: admin, operator: operator} do
      Authority.set_operators([operator])
      set!(tenant, %{approval_posture: :small_team}, actor: operator)

      assert set!(tenant, %{approval_posture: :standard}, actor: admin).approval_posture ==
               :standard
    end

    test "is refused for a person who is not an administrator", %{
      tenant: tenant,
      operator: operator
    } do
      Authority.set_operators([operator])
      lowered = set!(tenant, %{approval_posture: :small_team}, actor: operator)

      nurse = %{id: Ash.UUID.generate()}

      assert {:error, %Ash.Error.Invalid{}} =
               set(lowered, %{approval_posture: :standard}, actor: nurse)

      assert Domain.get_tenant!(tenant.id).approval_posture == :small_team
    end
  end

  describe "the implementation end date" do
    test "is required, in the future, and within the 120 days", %{
      tenant: tenant,
      admin: admin
    } do
      Authority.set_holders(Authority.administrator_role(), [admin.id])

      assert {:error, %Ash.Error.Invalid{}} =
               set(tenant, %{approval_posture: :implementation}, actor: admin)

      assert {:error, %Ash.Error.Invalid{}} =
               set(
                 tenant,
                 %{approval_posture: :implementation, approval_posture_ends_at: days(-1)},
                 actor: admin
               )

      assert {:error, %Ash.Error.Invalid{}} =
               set(
                 tenant,
                 %{approval_posture: :implementation, approval_posture_ends_at: days(121)},
                 actor: admin
               )

      assert {:ok, %{approval_posture: :implementation}} =
               set(
                 tenant,
                 %{approval_posture: :implementation, approval_posture_ends_at: days(120)},
                 actor: admin
               )
    end

    test "the other postures clear it", %{tenant: tenant, operator: operator} do
      Authority.set_operators([operator])

      set!(tenant, %{approval_posture: :implementation, approval_posture_ends_at: days(7)},
        actor: operator
      )

      lowered =
        set!(tenant, %{approval_posture: :small_team, approval_posture_ends_at: days(30)},
          actor: operator
        )

      assert {lowered.approval_posture, lowered.approval_posture_ends_at} == {:small_team, nil}
    end
  end
end
