# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Approval.PostureFragmentTest do
  @moduledoc false
  use AshAgent.DataCase, async: false

  import Spark.Test

  alias AshAgent.Test.{Authority, Domain}
  alias Spark.Error.DslError

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

    test "is not allowed by a context that only names an invocation", %{
      tenant: tenant,
      admin: admin
    } do
      # A context is only what the caller says; this tenant names no invocation
      # resource, so nothing could verify it anyway.
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               set(tenant, %{approval_posture: :small_team},
                 actor: admin,
                 context: %{ash_agent: %{invocation_id: Ash.UUID.generate(), lease_epoch: 1}}
               )

      assert [%AshAgent.Approval.PostureChangeRefused{reason: :lowering}] = errors
      assert Domain.get_tenant!(tenant.id).approval_posture == :standard
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

  describe "the tenant the Authority is asked about" do
    test "is the row itself, so a lone administrator passes no tenant", %{
      tenant: tenant,
      admin: admin
    } do
      # Holders of this row's tenant only: a caller passing none is still
      # answered, because the row is what is asked about.
      Authority.set_holders(Authority.administrator_role(), [admin.id], tenant.id)

      assert set!(tenant, %{approval_posture: :small_team}, actor: admin).approval_posture ==
               :small_team
    end

    test "never the one the caller passes", %{tenant: tenant, admin: admin} do
      other_tenant = Ash.UUID.generate()
      outsider = %{id: Ash.UUID.generate()}

      # The lone administrator of another tenant, and of this one.
      Authority.set_holders(Authority.administrator_role(), [outsider.id], other_tenant)
      Authority.set_holders(Authority.administrator_role(), [admin.id], tenant.id)

      # Lowering this row while passing their own tenant.
      assert {:error,
              %Ash.Error.Invalid{
                errors: [%AshAgent.Approval.PostureChangeRefused{reason: :lowering}]
              }} =
               set(tenant, %{approval_posture: :small_team},
                 actor: outsider,
                 tenant: other_tenant
               )

      assert Domain.get_tenant!(tenant.id).approval_posture == :standard

      # And raising it, once this row's lone administrator has lowered it.
      lowered = set!(tenant, %{approval_posture: :small_team}, actor: admin)

      assert {:error,
              %Ash.Error.Invalid{
                errors: [%AshAgent.Approval.PostureChangeRefused{reason: :raising}]
              }} =
               set(lowered, %{approval_posture: :standard},
                 actor: outsider,
                 tenant: other_tenant
               )

      assert Domain.get_tenant!(tenant.id).approval_posture == :small_team
    end

    test "is a named attribute's value, not the primary key", %{admin: admin} do
      tenant = Domain.create_coded_tenant!(%{code: "clinic-north"})

      # Sole administrator of the tenant the row's code names. The setup's
      # holders are two, so the row's id would not have answered this.
      Authority.set_holders(Authority.administrator_role(), [admin.id], tenant.code)

      assert Domain.set_coded_posture!(tenant, %{approval_posture: :small_team}, actor: admin).approval_posture ==
               :small_team

      assert Domain.get_coded_tenant!(tenant.id).approval_posture == :small_team
    end
  end

  describe "the verifier" do
    test "refuses a tenant_attribute that is not an attribute" do
      error =
        assert_dsl_error %DslError{path: [:approval_posture, :tenant_attribute]} do
          defmodule Elixir.AshAgent.Approval.PostureFragmentTest.UnknownTenantAttribute do
            use Ash.Resource, domain: nil, fragments: [AshAgent.Approval.PostureFragment]

            attributes do
              uuid_primary_key :id
            end

            approval_posture do
              authority(AshAgent.Test.Authority)
              execution_identity AshAgent.Test.ExecutionIdentity
              tenant_attribute(:org_id)
            end
          end
        end

      assert error.message =~ "is not an attribute of this resource"
    end

    test "refuses no tenant_attribute and no single-attribute primary key" do
      error =
        assert_dsl_error %DslError{path: [:approval_posture, :tenant_attribute]} do
          defmodule Elixir.AshAgent.Approval.PostureFragmentTest.CompositeKey do
            use Ash.Resource, domain: nil, fragments: [AshAgent.Approval.PostureFragment]

            attributes do
              uuid_primary_key :id
              attribute :site_id, :uuid, primary_key?: true, allow_nil?: false, public?: true
            end

            approval_posture do
              authority(AshAgent.Test.Authority)
              execution_identity AshAgent.Test.ExecutionIdentity
            end
          end
        end

      assert error.message =~ "no single-attribute primary key"
    end
  end
end
