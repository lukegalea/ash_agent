# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.PrecheckTest do
  @moduledoc false
  use AshAgent.DataCase, async: false

  alias AshAgent.Test.{CredentialCheck, Domain, ExecutionIdentity, Referral}

  @reviewed "AshAgent.Test.CredentialCheck.record_reviewed"
  @notify "AshAgent.Test.CredentialCheck.notify_board"
  @standing "AshAgent.Test.CredentialCheck.confirm_standing"
  @submit "AshAgent.Test.Referral.submit"
  @complete "AshAgent.Test.Referral.complete"
  @withdraw "AshAgent.Test.Referral.withdraw"

  setup do
    on_exit(&ExecutionIdentity.restore/0)
    AshAgent.Test.ScriptedModel.script!([])

    %{
      nurse: %{id: "nurse-#{System.unique_integer([:positive])}"},
      lead: %{id: "lead-#{System.unique_integer([:positive])}"}
    }
  end

  defp machinery, do: [actor: %{id: "machinery"}]

  defp key, do: "test:#{System.unique_integer([:positive])}"

  defp invoke!(actor, target, args),
    do: Domain.invoke!(target, args, %{key: key()}, actor: actor)

  defp automation(person), do: %{automation: "intake", for: person, agent: "triage"}

  # Seeded, so no action of the resource runs to make it: the row under test starts
  # from a state its own actions did not reach.
  defp referral!(attrs \\ %{}) do
    Ash.Seed.seed!(Referral, Map.merge(%{note: "SYNTHETIC: licence RN-1"}, attrs))
  end

  defp checks(licence),
    do: Domain.list_checks!(query: [filter: [licence_number: licence]], authorize?: false)

  describe "the action's own refusal moves to request time" do
    test "a create whose validation fails is rejected, and asks no one to approve it", %{
      nurse: nurse
    } do
      row = invoke!(nurse, @reviewed, %{"licence_number" => "RN-1"})

      assert {row.status, row.failure_class} == {:rejected, :rejected}
      assert row.error_code == "invalid_request"

      assert [error] = row.rejection_details["errors"]
      assert error["path"] == "clinician_name"
      assert error["message"] =~ "must be present"

      # Its declaration asks for an approval; nobody is asked to approve a refusal.
      assert row.approval_mode == :confirm
      assert row.authorization_details == nil
      assert checks("RN-1") == []
    end

    test "an update whose validation fails is rejected with the domain's own refusal", %{
      nurse: nurse
    } do
      lapsed =
        CredentialCheck
        |> Ash.Changeset.for_create(:record, %{licence_number: "LAPSED-1"})
        |> Ash.create!()

      row = invoke!(nurse, @standing, %{"id" => lapsed.id})

      assert {row.status, row.error_code} == {:rejected, "invalid_request"}

      assert [%{"message" => "refused by a business rule: licence_lapsed"}] =
               row.rejection_details["errors"]

      refute Ash.get!(CredentialCheck, lapsed.id, authorize?: false).verified?
    end

    test "a destroy whose validation fails is rejected", %{nurse: nurse} do
      submitted = referral!(%{state: :submitted})

      row = invoke!(nurse, @withdraw, %{"id" => submitted.id})

      assert {row.status, row.error_code} == {:rejected, "invalid_request"}

      assert [%{"message" => "refused by a business rule: not_draft"}] =
               row.rejection_details["errors"]

      assert Ash.get!(Referral, submitted.id, authorize?: false).state == :submitted
    end

    test "a generic target whose validation fails is rejected", %{nurse: nurse} do
      row = invoke!(nurse, @notify, %{"licence_number" => "BLOCKED-RN-1"})

      assert {row.status, row.error_code} == {:rejected, "invalid_request"}

      assert [%{"message" => "refused by a business rule: licence_blocked"}] =
               row.rejection_details["errors"]
    end

    test "a transition the subject's state machine forbids is rejected", %{nurse: nurse} do
      draft = referral!()
      row = invoke!(nurse, @complete, %{"id" => draft.id})

      assert {row.status, row.error_code} == {:rejected, "invalid_request"}

      assert [error] = row.rejection_details["errors"]
      assert error["message"] =~ "Attempted to change state from draft to completed"
      assert Ash.get!(Referral, draft.id, authorize?: false).state == :draft
    end

    test "an unknown input carries the closest name the action does take", %{nurse: nurse} do
      row =
        invoke!(nurse, @reviewed, %{
          "licence_numbr" => "RN-1",
          "clinician_name" => "Dana Reyes"
        })

      assert row.status == :rejected
      assert row.error_code =~ "licence_numbr is not an input of record_reviewed"

      assert [unknown, missing] = row.rejection_details["errors"]
      assert unknown["path"] == "licence_numbr"
      assert unknown["did_you_mean"] == "licence_number"
      assert missing["path"] == "licence_number"
      assert missing["message"] == "licence_number is required"
    end
  end

  describe "permission" do
    test "an executing principal without the grant is refused, identically for a held record and a forbidden one",
         %{nurse: nurse, lead: lead} do
      # Held: the referral names the one person who may submit it, and this is another.
      held = referral!(%{restricted_to: nurse.id})
      held_row = invoke!(lead, @submit, %{"id" => held.id})

      # Forbidden: an automation holds no grant to submit at all, whoever it acts for.
      forbidden_row = invoke!(automation(nurse), @submit, %{"id" => referral!().id})

      refusal = &Map.take(&1, [:status, :failure_class, :error_code, :rejection_details])
      assert refusal.(held_row) == refusal.(forbidden_row)

      assert {held_row.status, held_row.error_code} == {:rejected, "not_permitted"}
      assert [%{"message" => "not permitted"}] = held_row.rejection_details["errors"]

      # The person the referral is held by may still submit it.
      assert invoke!(nurse, @submit, %{"id" => held.id}).status == :ready
    end
  end

  describe "the pre-check actor" do
    test "is built from the row as it will be written, before it is stored", %{nurse: nurse} do
      row =
        invoke!(nurse, @reviewed, %{"licence_number" => "RN-3", "clinician_name" => "Dana Reyes"})

      assert_received {:precheck_request, request}
      assert request.executing_principal == row.executing_principal
      assert {request.target, request.kind, request.run_id} == {row.target, row.kind, nil}
      # Not stored yet: no primary key, and the state the request starts from.
      assert {request.id, request.status} == {nil, :requested}
    end
  end

  describe "a valid request" do
    test "still reaches awaiting_approval, with its approval bound", %{nurse: nurse} do
      row =
        invoke!(nurse, @reviewed, %{"licence_number" => "RN-2", "clinician_name" => "Dana Reyes"})

      assert row.status == :awaiting_approval
      assert row.approval_digest
      assert row.rejection_details == nil
      assert checks("RN-2") == []
    end

    test "reaches ready, and a grant revoked between request and claim still stops execution",
         %{nurse: nurse} do
      referral = referral!(%{restricted_to: nurse.id})
      row = invoke!(nurse, @submit, %{"id" => referral.id})
      assert row.status == :ready

      ExecutionIdentity.revoke(nurse.id)

      assert :failed = Domain.execute_invocation!(%{"id" => row.id}, machinery())

      failed = Domain.get_invocation!(row.id)

      assert {failed.status, failed.failure_class, failed.error_code} ==
               {:failed, :denied, "no_authority: revoked"}

      assert Ash.get!(Referral, referral.id, authorize?: false).state == :draft
    end
  end

  describe "the pre-check never runs hooks" do
    test "a refused request, a valid one and an executed one", %{nurse: nurse, lead: lead} do
      before = Referral.hooks()
      held = referral!(%{restricted_to: nurse.id})

      assert invoke!(lead, @submit, %{"id" => held.id}).status == :rejected

      row = invoke!(nurse, @submit, %{"id" => held.id})
      assert row.status == :ready
      assert Referral.hooks() == before

      assert :succeeded = Domain.execute_invocation!(%{"id" => row.id}, machinery())
      assert Referral.hooks() == before + 1
      assert Ash.get!(Referral, held.id, authorize?: false).state == :submitted
    end
  end

  describe "a run that is not live" do
    test "is not prechecked: the row is ready and answered by its fixture", %{nurse: nurse} do
      ExecutionIdentity.grant_start(nurse.id, "clinic.check_reader")

      AshAgent.Test.Agents.CheckReader
      |> Domain.register_agent!()
      |> Domain.publish_agent_version!()

      run =
        Domain.start_run!(
          "clinic.check_reader",
          "SYNTHETIC: tell the board",
          %{mode: :eval, fixtures: %{@notify => %{"notified" => true}}},
          actor: nurse
        )

      row =
        Domain.invoke!(
          @notify,
          %{"licence_number" => "BLOCKED-RN-1"},
          %{
            key: key(),
            parent: %{run_id: run.id}
          },
          actor: nurse
        )

      assert {row.status, row.mode} == {:ready, :eval}

      assert :succeeded = Domain.execute_invocation!(%{"id" => row.id}, machinery())

      answered = Domain.get_invocation!(row.id)
      assert {answered.simulated, answered.result} == {true, %{"notified" => true}}
    end
  end
end
