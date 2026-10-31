# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.InvocationTest do
  @moduledoc false
  use AshAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias AshAgent.Invocation.{Approval, Executor, IdempotencyConflict, NoPrincipal}
  alias AshAgent.Test.{CredentialCheck, Domain, ExecutionIdentity, Invocation}

  @record "AshAgent.Test.CredentialCheck.record"
  @reviewed "AshAgent.Test.CredentialCheck.record_reviewed"
  @notify "AshAgent.Test.CredentialCheck.notify_board"
  @verify "AshAgent.Test.CredentialCheck.mark_verified"
  @suspend "AshAgent.Test.CredentialCheck.suspend"

  setup do
    on_exit(&ExecutionIdentity.restore/0)
    %{nurse: %{id: Ash.UUID.generate()}, lead: %{id: Ash.UUID.generate()}}
  end

  defp args(n \\ 1), do: %{"licence_number" => "RN-#{n}", "clinician_name" => "Dana Reyes"}
  defp key, do: "test:#{System.unique_integer([:positive])}"

  defp checks(licence),
    do: Domain.list_checks!(query: [filter: [licence_number: licence]], authorize?: false)

  defp machinery, do: [actor: %{id: "machinery"}]

  defp outcome(row) do
    row = Domain.get_invocation!(row.id)
    {row.status, row.failure_class, row.error_code}
  end

  # What is stored, without the struct's load metadata.
  defp stored(row), do: row |> Map.from_struct() |> Map.drop([:__meta__, :__metadata__])

  defp invoke!(actor, target, args, extra \\ %{}),
    do: Domain.invoke!(target, args, Map.put_new(extra, :key, key()), actor: actor)

  # The row as it would be had it been requested under an earlier declaration of its
  # target: its snapshot reads `changes`, and its target digest is not the current one.
  # Written past the actions, because no action may rewrite what was requested.
  defp requested_under_earlier_definition(row, changes \\ %{}) do
    effects = Map.merge(row.effects, changes)
    earlier = AshAgent.Digest.sha256_hex(%{"effects" => effects, "release" => "earlier"})

    {1, _} =
      Repo.update_all(
        from(i in "invocations", where: i.id == type(^row.id, Ecto.UUID)),
        set: [effects: effects, target_digest: earlier]
      )

    Domain.get_invocation!(row.id)
  end

  describe "invoke" do
    test "records a ready request with everything derived on the server", %{nurse: nurse} do
      key = key()
      row = Domain.invoke!(@record, args(), %{key: key}, actor: nurse)

      assert row.status == :ready
      assert row.invocation_key == key
      assert row.kind == :direct
      assert row.mode == :live
      assert row.executing_principal == %{type: :person, id: nurse.id}
      assert row.effects["open_world"] == false
      assert row.approval_mode == :none
      assert row.target_digest =~ ~r/^[0-9a-f]{64}$/

      # Keyed, and independent of key order and spelling.
      assert row.args_digest ==
               AshAgent.Digest.hmac_hex("test host digest key", %{
                 clinician_name: "Dana Reyes",
                 licence_number: "RN-1"
               })

      # Nothing has run.
      assert checks("RN-1") == []
    end

    test "the same key and request returns the same row", %{nurse: nurse} do
      key = key()
      first = Domain.invoke!(@record, args(), %{key: key}, actor: nurse)

      again =
        Domain.invoke!(
          @record,
          %{licence_number: "RN-1", clinician_name: "Dana Reyes"},
          %{key: key},
          actor: nurse
        )

      assert again.id == first.id
      assert length(Ash.read!(Invocation)) == 1
    end

    test "the same key with different arguments is a conflict and changes nothing", %{
      nurse: nurse
    } do
      key = key()
      first = Domain.invoke!(@record, args(1), %{key: key}, actor: nurse)

      assert {:error, %Ash.Error.Invalid{errors: [%IdempotencyConflict{key: ^key}]}} =
               Domain.invoke(@record, args(2), %{key: key}, actor: nurse)

      assert stored(Domain.get_invocation!(first.id)) == stored(first)
    end

    test "the same key from another person, target or parent is a conflict", %{
      nurse: nurse,
      lead: lead
    } do
      key = key()
      Domain.invoke!(@record, args(), %{key: key}, actor: nurse)

      for {target, actor, parent} <- [
            {@record, lead, nil},
            {@reviewed, nurse, nil},
            {@record, nurse, %{invocation_id: Ash.UUID.generate()}}
          ] do
        assert {:error, %Ash.Error.Invalid{errors: [%IdempotencyConflict{}]}} =
                 Domain.invoke(target, args(), %{key: key, parent: parent}, actor: actor)
      end
    end

    test "records the parent as lineage, and the kind it implies", %{nurse: nurse} do
      run_id = Ash.UUID.generate()

      row =
        invoke!(nurse, @record, args(), %{
          parent: %{"run_id" => run_id, "step_seq" => 3, "tool_call_id" => "call_7"}
        })

      assert {row.kind, row.run_id, row.step_seq, row.tool_call_id} ==
               {:tool_call, run_id, 3, "call_7"}

      assert {:error, %Ash.Error.Invalid{}} =
               Domain.invoke(@record, args(), %{key: key(), parent: %{status: "succeeded"}},
                 actor: nurse
               )
    end

    test "an actor with no principal is refused" do
      assert {:error, %Ash.Error.Forbidden{errors: [%NoPrincipal{}]}} =
               Domain.invoke(@record, args(), %{key: key()}, actor: nil)
    end

    test "an unknown or undeclared target is refused, not recorded", %{nurse: nurse} do
      for target <- [
            "AshAgent.Test.CredentialCheck.archive",
            "AshAgent.Test.CredentialCheck.nothing_here",
            "AshAgent.Test.NoSuchResource.record",
            "record"
          ] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Domain.invoke(target, %{}, %{key: key()}, actor: nurse)
      end

      assert Ash.read!(Invocation) == []
    end

    test "arguments that do not fit the target are recorded as rejected", %{nurse: nurse} do
      row = invoke!(nurse, @record, %{"clinician_name" => "Dana Reyes", "shoe_size" => 9})

      assert row.status == :rejected
      assert row.failure_class == :rejected
      assert row.error_code =~ "shoe_size is not an input"
      assert row.error_code =~ "licence_number is required"
    end

    test "an update target captures its subject, and needs it to exist", %{nurse: nurse} do
      check = Ash.create!(CredentialCheck, %{licence_number: "RN-9"}, action: :record)
      row = invoke!(nurse, @verify, %{"id" => check.id})

      assert row.status == :ready
      assert [%{"id" => id, "version_number" => 1}] = row.preconditions
      assert id == check.id

      assert invoke!(nurse, @verify, %{"id" => Ash.UUID.generate()}).status == :rejected
    end

    test "a record the caller cannot read is refused exactly as a missing one is",
         %{nurse: nurse, lead: lead} do
      hidden =
        CredentialCheck
        |> Ash.Changeset.for_create(:record, %{licence_number: "RN-9"})
        |> Ash.Changeset.force_change_attribute(:restricted_to, lead.id)
        |> Ash.create!()

      hidden_row = invoke!(nurse, @verify, %{"id" => hidden.id})
      missing_row = invoke!(nurse, @verify, %{"id" => Ash.UUID.generate()})

      outcome = &Map.take(&1, [:status, :failure_class, :error_code, :preconditions])
      assert outcome.(hidden_row) == outcome.(missing_row)
      assert {hidden_row.status, hidden_row.preconditions} == {:rejected, []}

      # The person who may read it may ask to act on it.
      assert invoke!(lead, @verify, %{"id" => hidden.id}).status == :ready
    end
  end

  describe "automation principals" do
    defp automation(person, agent \\ "triage"),
      do: %{automation: "intake", for: person, agent: agent}

    test "record the person they act for and their agent, and the delegation they imply",
         %{nurse: nurse} do
      row = invoke!(automation(nurse), @record, args())

      assert row.executing_principal == %{
               type: :automation,
               id: "intake",
               on_behalf_of: nurse.id,
               agent: "triage"
             }

      assert row.delegation == %{
               "sub" => "person:#{nurse.id}",
               "act" => %{"sub" => "automation:intake", "client_id" => "triage"}
             }

      # A person acting as themselves delegates nothing.
      assert invoke!(nurse, @record, args(2)).delegation == nil
    end

    test "the same key for another person, or another agent, is a conflict, not their row",
         %{nurse: nurse, lead: lead} do
      key = key()
      first = Domain.invoke!(@record, args(), %{key: key}, actor: automation(nurse))

      for actor <- [automation(lead), automation(nurse, "billing"), automation(nil)] do
        assert {:error, %Ash.Error.Invalid{errors: [%IdempotencyConflict{}]}} =
                 Domain.invoke(@record, args(), %{key: key}, actor: actor)
      end

      assert Domain.invoke!(@record, args(), %{key: key}, actor: automation(nurse)).id ==
               first.id
    end

    test "run only while both the automation and its person have authority", %{nurse: nurse} do
      ran = invoke!(automation(nurse), @record, args(1))
      assert :succeeded = Domain.execute_invocation!(%{"id" => ran.id}, machinery())

      for {revoked, n} <- [{"intake", 2}, {nurse.id, 3}] do
        row = invoke!(automation(nurse), @record, args(n))
        ExecutionIdentity.revoke(revoked)

        assert :failed = Domain.execute_invocation!(%{"id" => row.id}, machinery())

        failed = Domain.get_invocation!(row.id)

        assert {failed.status, failed.failure_class, failed.error_code} ==
                 {:failed, :denied, "no_authority: revoked"}

        assert checks("RN-#{n}") == []
        ExecutionIdentity.restore()
      end

      assert [_ran] = checks("RN-1")
    end
  end

  describe "approval" do
    test "a target that asks for approval waits for a decision", %{nurse: nurse, lead: lead} do
      row = invoke!(nurse, @reviewed, args())
      assert {row.status, row.approval_mode} == {:awaiting_approval, :confirm}

      approved = Domain.apply_decision!(row, %{outcome: :approved, decided_by_id: lead.id})
      assert {approved.status, approved.approved_by_id} == {:ready, lead.id}
    end

    test "a rejection and a stale approval are final", %{nurse: nurse} do
      rejected = Domain.apply_decision!(invoke!(nurse, @reviewed, args(1)), %{outcome: :rejected})
      assert {rejected.status, rejected.failure_class} == {:rejected, :rejected}

      stale = Domain.apply_decision!(invoke!(nurse, @reviewed, args(2)), %{outcome: :stale})
      assert stale.status == :stale
    end

    test "with no outcome nothing is applied", %{nurse: nurse} do
      row = invoke!(nurse, @reviewed, args())
      assert {:error, %Ash.Error.Invalid{}} = Domain.apply_decision(row, %{})
      assert Domain.get_invocation!(row.id).status == :awaiting_approval
    end
  end

  describe "approval binding" do
    setup do
      check =
        CredentialCheck
        |> Ash.Changeset.for_create(:record, %{licence_number: "RN-#{System.unique_integer()}"})
        |> Ash.create!()

      %{check: check}
    end

    defp suspend!(nurse, check), do: invoke!(nurse, @suspend, %{"id" => check.id})

    # Another write to the check, made past the invocation: its version moves on.
    defp changed!(check) do
      {1, _} =
        Repo.update_all(
          from(c in "credential_checks",
            where: c.id == type(^check.id, Ecto.UUID),
            update: [inc: [version_number: 1]]
          ),
          []
        )
    end

    # Written past the actions, as the clock is.
    defp past!(row, changes) do
      {1, _} =
        Repo.update_all(from(i in "invocations", where: i.id == type(^row.id, Ecto.UUID)),
          set: changes
        )

      Domain.get_invocation!(row.id)
    end

    defp approve!(row, lead),
      do: Domain.apply_decision!(row, %{outcome: :approved, decided_by_id: lead.id})

    test "a request awaiting approval records what an approval of it binds, in RFC 9396's shape",
         %{nurse: nurse, check: check} do
      before = DateTime.utc_now()
      row = suspend!(nurse, check)
      assert {row.status, row.approval_mode} == {:awaiting_approval, :four_eyes}

      assert row.authorization_details == [
               %{
                 "type" => "urn:ash-agent:action:" <> @suspend,
                 "actions" => ["suspend"],
                 "identifier" => check.id,
                 "target_digest" => row.target_digest,
                 "args_digest" => row.args_digest,
                 "preconditions" => [
                   %{
                     "resource" => "AshAgent.Test.CredentialCheck",
                     "id" => check.id,
                     "version_number" => 1
                   }
                 ],
                 "manifest_digest" => nil
               }
             ]

      assert row.approval_digest == AshAgent.Digest.sha256_hex(row.authorization_details)

      assert row.approval_digest ==
               Approval.digest(Domain.get_invocation!(row.id).authorization_details)

      expected = DateTime.add(before, 1, :day)
      assert DateTime.diff(row.approval_expires_at, expected, :second) in 0..5

      # A request that needs no approval binds nothing.
      ready = invoke!(nurse, @record, args())

      assert {ready.authorization_details, ready.approval_digest, ready.approval_expires_at} ==
               {nil, nil, nil}
    end

    test "a subject that changed while the approval was pending makes it stale, not ready",
         %{nurse: nurse, lead: lead, check: check} do
      row = suspend!(nurse, check)
      changed!(check)

      stale = approve!(row, lead)

      assert {stale.status, stale.error_code, stale.approved_by_id} ==
               {:stale, "subject_changed", nil}
    end

    test "an approval for one version of the subject does not run on another",
         %{nurse: nurse, lead: lead, check: check} do
      ready = approve!(suspend!(nurse, check), lead)
      assert ready.status == :ready
      changed!(check)

      assert :stale = Domain.execute_invocation!(%{"id" => ready.id}, machinery())
      assert outcome(ready) == {:stale, nil, "subject_changed"}
      assert [%{verified?: false, id: id}] = checks(check.licence_number)
      assert id == check.id
      assert Domain.get_invocation!(ready.id).attempt_count == 0
    end

    test "a subject changed after the claim, before the target reads it, does not run",
         %{nurse: nurse, lead: lead, check: check} do
      {1, _} =
        Repo.update_all(
          from(c in "credential_checks", where: c.id == type(^check.id, Ecto.UUID)),
          set: [verified?: true]
        )

      ready = approve!(suspend!(nurse, check), lead)
      {:ok, claimed} = Executor.claim(ready, machinery())

      # A concurrent edit commits between the claim and the run.
      changed!(check)

      assert {:ok, :stale} = Executor.run_claimed(claimed, machinery())
      assert outcome(ready) == {:stale, nil, "subject_changed"}
      assert [%{verified?: true}] = checks(check.licence_number)
    end

    test "an approval for a target that has since changed is not applied",
         %{nurse: nurse, lead: lead, check: check} do
      row = requested_under_earlier_definition(suspend!(nurse, check))

      assert {:stale, "target_changed"} =
               then(approve!(row, lead), &{&1.status, &1.error_code})
    end

    test "an expired approval is neither applied nor run", %{
      nurse: nurse,
      lead: lead,
      check: check
    } do
      expired = DateTime.add(DateTime.utc_now(), -60, :second)

      pending = past!(suspend!(nurse, check), approval_expires_at: expired)

      assert {:stale, "approval_expired"} =
               then(approve!(pending, lead), &{&1.status, &1.error_code})

      ready = approve!(suspend!(nurse, check), lead)
      past!(ready, approval_expires_at: expired)
      assert :stale = Domain.execute_invocation!(%{"id" => ready.id}, machinery())
      assert outcome(ready) == {:stale, nil, "approval_expired"}
    end

    test "details that are not the ones digested do not hold", %{
      nurse: nurse,
      lead: lead,
      check: check
    } do
      row = suspend!(nurse, check)
      [entry] = row.authorization_details
      row = past!(row, authorization_details: [Map.put(entry, "actions", ["archive"])])

      assert {:stale, "approval_changed"} = then(approve!(row, lead), &{&1.status, &1.error_code})
    end

    test "an approval that still holds runs, and is checked again at the claim",
         %{nurse: nurse, lead: lead, check: check} do
      ready = approve!(suspend!(nurse, check), lead)
      assert Approval.stale_reason(ready) == nil

      assert :succeeded = Domain.execute_invocation!(%{"id" => ready.id}, machinery())
      assert {:succeeded, nil, nil} = outcome(ready)
    end
  end

  describe "execute" do
    test "claims, runs the target as its principal and records the result once", %{nurse: nurse} do
      row = invoke!(nurse, @record, args())

      assert :succeeded = Domain.execute_invocation!(%{"id" => row.id}, machinery())

      done = Domain.get_invocation!(row.id)
      assert {done.status, done.lease_epoch, done.attempt_count} == {:succeeded, 1, 1}
      assert [check] = checks("RN-1")
      assert done.result == %{"resource" => "AshAgent.Test.CredentialCheck", "id" => check.id}

      # A duplicate delivery finds nothing to claim.
      assert :skipped = Domain.execute_invocation!(%{"id" => row.id}, machinery())
      assert length(checks("RN-1")) == 1
    end

    test "an open-world target runs outside a transaction and is recorded", %{nurse: nurse} do
      row = invoke!(nurse, @notify, %{"licence_number" => "RN-1"})
      assert :succeeded = Domain.execute_invocation!(%{"id" => row.id}, machinery())
      assert Domain.get_invocation!(row.id).result == %{"value" => true}
    end

    test "a principal who lost their authority fails as denied; the target never runs",
         %{nurse: nurse} do
      row = invoke!(nurse, @record, args())
      ExecutionIdentity.revoke(nurse.id)

      assert :failed = Domain.execute_invocation!(%{"id" => row.id}, machinery())

      failed = Domain.get_invocation!(row.id)

      assert {failed.status, failed.failure_class, failed.error_code} ==
               {:failed, :denied, "no_authority: revoked"}

      assert checks("RN-1") == []
    end

    test "a target that fails is recorded with its class", %{nurse: nurse} do
      Ash.create!(CredentialCheck, %{licence_number: "RN-1"}, action: :record)
      row = invoke!(nurse, @record, args())

      assert :failed = Domain.execute_invocation!(%{"id" => row.id}, machinery())
      assert %{status: :failed, failure_class: :rejected} = Domain.get_invocation!(row.id)
    end

    test "a subject the principal can no longer read is a denial; one that is gone, a rejection",
         %{nurse: nurse, lead: lead} do
      kept = Ash.create!(CredentialCheck, %{licence_number: "RN-7"}, action: :record)
      gone = Ash.create!(CredentialCheck, %{licence_number: "RN-8"}, action: :record)
      out_of_reach = invoke!(nurse, @verify, %{"id" => kept.id})
      missing = invoke!(nurse, @verify, %{"id" => gone.id})

      # Between the request and the run: the first is restricted to someone else, the
      # second deleted.
      {1, _} =
        Repo.update_all(
          from(c in "credential_checks", where: c.id == type(^kept.id, Ecto.UUID)),
          set: [restricted_to: lead.id]
        )

      {1, _} =
        Repo.delete_all(from(c in "credential_checks", where: c.id == type(^gone.id, Ecto.UUID)))

      for row <- [out_of_reach, missing] do
        assert :failed = Domain.execute_invocation!(%{"id" => row.id}, machinery())
      end

      assert {:failed, :denied, "forbidden"} == outcome(out_of_reach)
      assert {:failed, :rejected, "invalid"} == outcome(missing)

      verified = Ash.get!(CredentialCheck, kept.id, authorize?: false)
      refute verified.verified?
    end
  end

  describe "lease fencing" do
    test "a worker whose expired lease was taken over cannot complete; its effect rolls back",
         %{nurse: nurse} do
      row = invoke!(nurse, @record, args())

      # Worker A claims with a lease that has already run out, then stalls.
      {:ok, a} = Executor.claim(row, machinery(), lease_for: 0)
      # Worker B takes the row over and finishes it.
      {:ok, b} = Executor.claim(Domain.get_invocation!(row.id), machinery())
      assert b.lease_epoch == a.lease_epoch + 1
      assert {:ok, :succeeded} = Executor.run_claimed(b, machinery())

      # A wakes up: its target runs and its completion is refused, in one transaction.
      assert {:ok, :superseded} = Executor.run_claimed(a, machinery())

      assert length(checks("RN-1")) == 1
      assert %{status: :succeeded, lease_epoch: epoch} = Domain.get_invocation!(row.id)
      assert epoch == b.lease_epoch
    end

    test "a lease that has not expired cannot be taken over", %{nurse: nurse} do
      row = invoke!(nurse, @record, args())
      {:ok, _a} = Executor.claim(row, machinery())

      assert {:error, :not_claimable} =
               Executor.claim(Domain.get_invocation!(row.id), machinery())
    end

    test "an open-world target's expired lease is not taken over", %{nurse: nurse} do
      row = invoke!(nurse, @notify, %{"licence_number" => "RN-1"})
      {:ok, _a} = Executor.claim(row, machinery(), lease_for: 0)

      assert {:error, :not_claimable} =
               Executor.claim(Domain.get_invocation!(row.id), machinery())
    end

    test "two claims from one reading: one wins", %{nurse: nurse} do
      row = invoke!(nurse, @record, args())
      assert {:ok, _} = Executor.claim(row, machinery(), lease_for: 0)
      assert {:error, :not_claimable} = Executor.claim(row, machinery())
    end
  end

  describe "a target whose declaration changed since the request" do
    test "is not run: the claim marks the row stale", %{nurse: nurse} do
      row = nurse |> invoke!(@record, args()) |> requested_under_earlier_definition()

      assert :stale = Domain.execute_invocation!(%{"id" => row.id}, machinery())

      stale = Domain.get_invocation!(row.id)

      assert {stale.status, stale.error_code, stale.lease_expires_at} ==
               {:stale, "target_changed", nil}

      assert checks("RN-1") == []
    end

    test "an expired lease is not taken over under the old declaration", %{nurse: nurse} do
      # Worker A claims while the target's declaration is the one requested...
      row = invoke!(nurse, @notify, %{"licence_number" => "RN-1"})
      {:ok, a} = Executor.claim(row, machinery(), lease_for: 0)

      # ...then the row turns out to have been requested when the target wrote only to
      # this application, which would let B take A's expired lease over and call out a
      # second time while A is still in its call.
      requested_under_earlier_definition(a, %{"open_world" => false})

      # B does not call out. Nor does it call the row stale, as though nothing ran: A's
      # attempt, under the declaration as it is now, may have reached outside.
      assert {:error, :outcome_unknown} =
               Executor.claim(Domain.get_invocation!(row.id), machinery())

      assert %{status: :outcome_unknown, error_code: "target_changed"} =
               Domain.get_invocation!(row.id)

      # A finishes its call, and its completion is refused.
      assert {:ok, :superseded} = Executor.run_claimed(a, machinery())
      assert Domain.get_invocation!(row.id).status == :outcome_unknown
    end
  end

  describe "cancel and finished rows" do
    test "a row that has not started is cancelled; an executing one is only marked",
         %{nurse: nurse} do
      assert Domain.request_cancel!(invoke!(nurse, @record, args(1))).status == :cancelled
      assert Domain.request_cancel!(invoke!(nurse, @reviewed, args(2))).status == :cancelled

      {:ok, claimed} = Executor.claim(invoke!(nurse, @record, args(3)), machinery())
      marked = Domain.request_cancel!(claimed)
      assert marked.status == :executing
      assert marked.cancel_requested_at

      # The worker still completes what it started.
      assert {:ok, :succeeded} = Executor.run_claimed(claimed, machinery())
    end

    test "a finished row cannot be changed by any action", %{nurse: nurse} do
      row = invoke!(nurse, @record, args())
      assert :succeeded = Domain.execute_invocation!(%{"id" => row.id}, machinery())
      done = Domain.get_invocation!(row.id)

      assert {:error, _} = Domain.request_cancel(done)
      assert {:error, _} = Domain.apply_decision(done, %{outcome: :approved})
      assert {:error, :not_claimable} = Executor.claim(done, machinery())

      for action <- [:succeed, :fail] do
        assert {:error, _} =
                 done
                 |> Ash.Changeset.for_update(action, %{
                   epoch: done.lease_epoch,
                   failure_class: :permanent
                 })
                 |> Ash.update()
      end

      assert stored(Domain.get_invocation!(row.id)) == stored(done)
    end
  end
end
