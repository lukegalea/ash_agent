# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Approval.PostureInvocationTest do
  @moduledoc false
  use AshAgent.DataCase, async: false

  alias AshAgent.Invocation.Executor
  alias AshAgent.Test.{Authority, CredentialCheck, Domain, ExecutionIdentity}

  @suspend "AshAgent.Test.CredentialCheck.suspend"
  @reviewed "AshAgent.Test.CredentialCheck.record_reviewed"

  setup do
    on_exit(fn ->
      Authority.restore()
      ExecutionIdentity.restore()
    end)

    check =
      CredentialCheck
      |> Ash.Changeset.for_create(:record, %{licence_number: "RN-#{System.unique_integer()}"})
      |> Ash.create!()

    %{nurse: %{id: Ash.UUID.generate()}, lead: %{id: Ash.UUID.generate()}, check: check}
  end

  defp args(n \\ 1), do: %{"licence_number" => "RN-#{n}", "clinician_name" => "Dana Reyes"}
  defp key, do: "posture:#{System.unique_integer([:positive])}"
  defp machinery, do: [actor: %{id: "machinery"}]

  # `:suspend` acts on a check: the check is its subject, and its version is a
  # precondition the approval binds.
  defp suspend!(actor, check),
    do: Domain.invoke!(@suspend, %{"id" => check.id}, %{key: key()}, actor: actor)

  defp invoke!(actor, target, a),
    do: Domain.invoke!(target, a, %{key: key()}, actor: actor)

  defp approve!(row, who),
    do: Domain.apply_decision!(row, %{outcome: :approved, decided_by_id: who.id})

  defp run!(row) do
    assert {:ok, claimed} = Executor.claim(row, machinery())
    assert {:ok, :succeeded} = Executor.run_claimed(claimed, machinery())
  end

  describe "a small team" do
    test "the requester may approve their own request while they hold the approver role", %{
      nurse: nurse,
      check: check
    } do
      Authority.set_posture(:small_team)
      Authority.set_holders(:credentialing_committee, [nurse.id])

      approved = suspend!(nurse, check) |> approve!(nurse)

      assert {approved.status, approved.approval_basis, approved.approved_by_id} ==
               {:ready, :small_team, nurse.id}
    end

    test "another holder's approval rests on four eyes, and still runs", %{
      nurse: nurse,
      lead: lead,
      check: check
    } do
      Authority.set_posture(:small_team)
      Authority.set_holders(:credentialing_committee, [nurse.id, lead.id])

      approved = suspend!(nurse, check) |> approve!(lead)
      assert {approved.status, approved.approval_basis} == {:ready, :four_eyes}

      run!(approved)
    end

    test "an administrator approves when the role has no holders", %{
      nurse: nurse,
      lead: lead,
      check: check
    } do
      Authority.set_posture(:small_team)
      Authority.set_holders(:credentialing_committee, [])
      Authority.set_holders(Authority.administrator_role(), [lead.id])

      approved = suspend!(nurse, check) |> approve!(lead)
      assert {approved.status, approved.approval_basis} == {:ready, :small_team}
    end

    test "a self-approval in flight goes stale when the posture is raised before the claim",
         %{nurse: nurse, check: check} do
      Authority.set_posture(:small_team)
      Authority.set_holders(:credentialing_committee, [nurse.id])

      approved = suspend!(nurse, check) |> approve!(nurse)
      Authority.set_posture(:standard)

      assert :stale = Domain.execute_invocation!(%{"id" => approved.id}, machinery())

      stale = Domain.get_invocation!(approved.id)
      assert {stale.status, stale.error_code} == {:stale, "approved_by_requester"}
    end

    test "a self-approval the posture no longer allows is refused at the decision", %{
      nurse: nurse,
      check: check
    } do
      Authority.set_posture(:small_team)
      Authority.set_holders(:credentialing_committee, [nurse.id])
      row = suspend!(nurse, check)

      Authority.set_posture(:standard)

      stale = Domain.apply_decision!(row, %{outcome: :approved, decided_by_id: nurse.id})
      assert {stale.status, stale.error_code} == {:stale, "approved_by_requester"}
    end

    test "another person's approval survives the posture being raised", %{
      nurse: nurse,
      lead: lead,
      check: check
    } do
      Authority.set_posture(:small_team)
      Authority.set_holders(:credentialing_committee, [nurse.id, lead.id])

      approved = suspend!(nurse, check) |> approve!(lead)
      Authority.set_posture(:standard)

      run!(approved)
    end
  end

  describe "an implementation posture" do
    test "the requester confirms it themselves, with no approver role", %{
      nurse: nurse,
      check: check
    } do
      Authority.set_posture(:implementation, DateTime.add(DateTime.utc_now(), 7, :day))
      Authority.set_holders(:credentialing_committee, [])

      approved = suspend!(nurse, check) |> approve!(nurse)
      assert {approved.status, approved.approval_basis} == {:ready, :implementation}
    end

    test "one that has ended behaves as standard", %{nurse: nurse, check: check} do
      Authority.set_posture(:implementation, DateTime.add(DateTime.utc_now(), -1, :day))

      stale =
        suspend!(nurse, check)
        |> Domain.apply_decision!(%{outcome: :approved, decided_by_id: nurse.id})

      assert {stale.status, stale.error_code} == {:stale, "approved_by_requester"}
    end

    test "a self-approval in flight goes stale when the end date passes before the claim", %{
      nurse: nurse,
      check: check
    } do
      Authority.set_posture(:implementation, DateTime.add(DateTime.utc_now(), 7, :day))

      approved = suspend!(nurse, check) |> approve!(nurse)

      Authority.set_posture(:implementation, DateTime.add(DateTime.utc_now(), -1, :day))

      assert :stale = Domain.execute_invocation!(%{"id" => approved.id}, machinery())

      assert %{status: :stale, error_code: "approved_by_requester"} =
               Domain.get_invocation!(approved.id)
    end
  end

  describe "a confirm target" do
    test "rests on the declaration under every posture", %{nurse: nurse} do
      for {posture, ends_at} <- [
            {:standard, nil},
            {:small_team, nil},
            {:implementation, DateTime.add(DateTime.utc_now(), 7, :day)}
          ] do
        Authority.set_posture(posture, ends_at)

        approved = invoke!(nurse, @reviewed, args()) |> approve!(nurse)
        assert {approved.status, approved.approval_basis} == {:ready, :confirm}
      end
    end
  end

  describe "a requester that is not a person" do
    test "never approves, under any posture", %{nurse: nurse, check: check} do
      automation = %{automation: "licence-bot", for: nurse, agent: "checker"}
      Authority.set_posture(:implementation, DateTime.add(DateTime.utc_now(), 7, :day))

      row = Domain.invoke!(@suspend, %{"id" => check.id}, %{key: key()}, actor: automation)

      stale = Domain.apply_decision!(row, %{outcome: :approved, decided_by_id: nurse.id})
      assert {stale.status, stale.error_code} == {:stale, "approved_by_requester"}
    end
  end
end
