# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.InvocationPathsTest do
  @moduledoc """
  What happens to an invocation after its target runs, or fails to: the paths by effect,
  typed failure, reconciliation of a lost acknowledgement, dispatch and its deadline,
  and a person's resolution of an unknown outcome.
  """
  use AshAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias AshAgent.Invocation.{Executor, Failure}
  alias AshAgent.Test.{Board, CredentialCheck, Domain}

  @record "AshAgent.Test.CredentialCheck.record"
  @post "AshAgent.Test.CredentialCheck.post_notice"
  @post_keyed "AshAgent.Test.CredentialCheck.post_notice_keyed"
  @notify "AshAgent.Test.CredentialCheck.notify_board"
  @refer "AshAgent.Test.CredentialCheck.refer"
  @refer_keyed "AshAgent.Test.CredentialCheck.refer_keyed"
  @standing "AshAgent.Test.CredentialCheck.confirm_standing"

  setup do
    Board.start!()
    %{nurse: %{id: Ash.UUID.generate()}, lead: %{id: Ash.UUID.generate()}}
  end

  defp machinery, do: [actor: %{id: "machinery"}]
  defp key, do: "test:#{System.unique_integer([:positive])}"
  defp notice(n \\ 1), do: %{"licence_number" => "RN-#{n}"}

  defp invoke!(actor, target, args),
    do: Domain.invoke!(target, args, %{key: key()}, actor: actor)

  defp execute(row), do: Domain.execute_invocation!(%{"id" => row.id}, machinery())
  defp reconcile(row), do: Domain.reconcile_invocation!(%{"id" => row.id}, machinery())
  defp get(row), do: Domain.get_invocation!(row.id)

  defp checks(licence),
    do: Domain.list_checks!(query: [filter: [licence_number: licence]], authorize?: false)

  # A worker claims the row and calls the board, and dies before recording anything: its
  # lease is already over, as if it had run out while the worker was gone.
  defp claimed_and_abandoned(row) do
    {:ok, claimed} = Executor.claim(row, machinery(), lease_for: 0)
    {:ok, _} = Board.post(row.args["licence_number"], row.invocation_key)
    claimed
  end

  # The row as if it had been requested under an earlier declaration of its target.
  defp requested_under_earlier_definition!(row) do
    earlier = AshAgent.Digest.sha256_hex(%{"effects" => row.effects, "release" => "earlier"})

    {1, _} =
      Repo.update_all(
        from(i in "invocations", where: i.id == type(^row.id, Ecto.UUID)),
        set: [target_digest: earlier]
      )

    get(row)
  end

  # Moves a timestamp of the row into the past, past the actions: time passing.
  defp elapse!(row, field) do
    past = DateTime.add(DateTime.utc_now(), -60, :second)

    {1, _} =
      Repo.update_all(
        from(i in "invocations", where: i.id == type(^row.id, Ecto.UUID)),
        set: [{field, past}]
      )

    get(row)
  end

  describe "an outside target that is not idempotent" do
    test "a lost acknowledgement is unknown, never retried; the lookup settles it", %{
      nurse: nurse
    } do
      Board.mode(:accept_then_lose)
      row = invoke!(nurse, @post, notice())

      assert :outcome_unknown = execute(row)
      unknown = get(row)
      assert {unknown.status, unknown.error_code} == {:outcome_unknown, "timeout"}
      assert Board.calls() == 1

      # Another delivery of the job finds nothing to run.
      assert :skipped = execute(row)

      assert :succeeded = reconcile(row)
      done = get(row)

      assert {done.status, done.reconciled_via, done.effect_system, done.effect_ref} ==
               {:succeeded, "reconcile_with", "board", row.invocation_key}

      assert Board.calls() == 1
    end

    test "a worker that dies after the call leaves it unknown, then reconciled once", %{
      nurse: nurse
    } do
      row = invoke!(nurse, @post, notice())
      claimed_and_abandoned(row)

      # Its expired lease is not taken over: that would call the board again.
      assert {:error, :not_claimable} = Executor.claim(get(row), machinery())

      assert :succeeded = reconcile(row)
      assert %{status: :succeeded, reconciled_via: "reconcile_with"} = get(row)
      assert {Board.calls(), Board.notices()} == {1, 1}
    end

    test "a lookup that finds nothing fails it as transient, and retry is deliberate", %{
      nurse: nurse
    } do
      row = invoke!(nurse, @post, notice())
      {:ok, _claimed} = Executor.claim(row, machinery(), lease_for: 0)

      assert :failed = reconcile(row)

      assert %{status: :failed, failure_class: :transient, error_code: "not_found_on_reconcile"} =
               get(row)

      assert %{status: :ready} = Domain.retry_invocation!(get(row))
      assert :succeeded = execute(row)
      assert Board.notices() == 1
    end

    test "with no lookup, a person is asked, and their resolution applies", %{nurse: nurse} do
      for {outcome, n, status} <-
            [succeeded: 1, failed: 2, retry: 3]
            |> Enum.map(fn {o, n} ->
              {o, n, %{succeeded: :succeeded, failed: :failed, retry: :ready}[o]}
            end) do
        row = invoke!(nurse, @notify, notice(n))
        {:ok, _claimed} = Executor.claim(row, machinery(), lease_for: 0)

        assert :resolution_requested = reconcile(row)
        asked = get(row)

        assert {asked.status, is_struct(asked.resolution_requested_at, DateTime)} ==
                 {:outcome_unknown, true}

        # A second sweep asks no one again.
        assert :skipped = reconcile(row)

        resolved = Domain.apply_resolution!(asked, %{outcome: outcome, decided_by_id: nurse.id})
        assert {resolved.status, resolved.resolved_by_id} == {status, nurse.id}
        assert resolved.reconciled_via == "operator"
      end
    end

    test "a resolution needs an outcome and an open request" do
      row = invoke!(%{id: Ash.UUID.generate()}, @notify, notice())
      {:ok, _claimed} = Executor.claim(row, machinery(), lease_for: 0)
      assert :resolution_requested = reconcile(row)

      assert {:error, %Ash.Error.Invalid{}} = Domain.apply_resolution(get(row), %{})
      assert get(row).status == :outcome_unknown

      done = Domain.apply_resolution!(get(row), %{outcome: :succeeded})
      assert {:error, _} = Domain.apply_resolution(done, %{outcome: :retry})
    end
  end

  describe "a target whose rerun cannot repeat its effect" do
    test "an internal target's expired lease is re-readied, not unknown", %{nurse: nurse} do
      row = invoke!(nurse, @record, %{"licence_number" => "RN-1"})
      {:ok, _claimed} = Executor.claim(row, machinery(), lease_for: 0)

      assert :requeued = reconcile(row)
      assert %{status: :ready, lease_expires_at: nil} = get(row)

      assert :succeeded = execute(row)
      assert length(checks("RN-1")) == 1
    end

    test "an idempotent outside target is called again with its key and deduplicated", %{
      nurse: nurse
    } do
      row = invoke!(nurse, @post_keyed, notice())
      claimed_and_abandoned(row)

      assert :requeued = reconcile(row)
      assert :succeeded = execute(row)
      assert {Board.calls(), Board.notices()} == {2, 1}
    end

    test "a lease that has not expired is left alone", %{nurse: nurse} do
      row = invoke!(nurse, @record, %{"licence_number" => "RN-1"})
      {:ok, _claimed} = Executor.claim(row, machinery())

      assert :skipped = reconcile(row)
      assert get(row).status == :executing
    end

    test "requeue refuses a target whose rerun could repeat an outside effect", %{nurse: nurse} do
      row = invoke!(nurse, @post, notice())
      {:ok, claimed} = Executor.claim(row, machinery(), lease_for: 0)

      assert {:error, %Ash.Error.Invalid{}} =
               claimed
               |> Ash.Changeset.for_update(:requeue, %{epoch: claimed.lease_epoch}, machinery())
               |> Ash.update()

      assert get(row).status == :executing
    end
  end

  describe "typed failure" do
    test "a transient failure backs off and is retried, then is final at max_attempts", %{
      nurse: nurse
    } do
      Board.mode(:busy)
      row = invoke!(nurse, @post, notice())

      assert :deferred = execute(row)
      deferred = get(row)

      assert {deferred.status, deferred.failure_class, deferred.error_code} ==
               {:ready, :transient, "rate_limited"}

      assert DateTime.compare(deferred.next_attempt_at, DateTime.utc_now()) == :gt
      # Not before its time.
      assert :skipped = execute(row)

      assert :deferred = row |> elapse!(:next_attempt_at) |> execute()
      assert :failed = row |> elapse!(:next_attempt_at) |> execute()

      failed = get(row)

      assert {failed.status, failed.failure_class, failed.attempt_count} ==
               {:failed, :transient, 3}

      assert Board.calls() == 3

      # `retry` makes it ready again on purpose, and it succeeds.
      Board.mode(:accept)
      assert %{status: :ready, failure_class: nil} = Domain.retry_invocation!(failed)
      assert :succeeded = execute(row)
    end

    test "only a transient failure can be retried", %{nurse: nurse} do
      Board.mode(:refuse)
      row = invoke!(nurse, @post, notice())
      assert :failed = execute(row)
      assert %{failure_class: :permanent, error_code: "refused"} = get(row)
      assert {:error, _} = Domain.retry_invocation(get(row))
    end

    test "a business error is final, and a process sees its code", %{nurse: nurse} do
      check = Ash.create!(CredentialCheck, %{licence_number: "LAPSED-1"}, action: :record)
      row = invoke!(nurse, @standing, %{"id" => check.id})

      assert :failed = execute(row)
      failed = get(row)
      assert {failed.failure_class, failed.error_code} == {:business, "licence_lapsed"}
      assert Failure.bpmn(failed) == {:error, {:bpmn_error, "licence_lapsed", %{}}}
    end

    test "a refused budget is its own class", %{nurse: nurse} do
      Board.mode(:over_budget)
      row = invoke!(nurse, @post, notice())
      assert :failed = execute(row)
      assert %{status: :failed, failure_class: :budget} = get(row)
    end
  end

  describe "an attempt that may have reached outside" do
    test "an error after the call is not a definite failure: an idempotent target runs again",
         %{nurse: nurse} do
      # The board takes the notice, then the target's own write loses a race.
      Board.mode(:accept_then_stale)
      row = invoke!(nurse, @post_keyed, notice())

      assert :deferred = execute(row)
      assert %{status: :ready, failure_class: :transient, error_code: "invalid"} = get(row)

      Board.mode(:accept)
      assert :succeeded = row |> elapse!(:next_attempt_at) |> execute()
      assert {Board.calls(), Board.notices()} == {2, 1}
    end

    test "an error after the call on a target that is not idempotent is unknown, then looked up",
         %{nurse: nurse} do
      Board.mode(:accept_then_stale)
      row = invoke!(nurse, @post, notice())

      assert :outcome_unknown = execute(row)
      assert :succeeded = reconcile(row)
      assert %{status: :succeeded, reconciled_via: "reconcile_with"} = get(row)
      assert {Board.calls(), Board.notices()} == {1, 1}
    end

    @tag :capture_log
    test "a target that raises after the call is recorded, never left to its lease", %{
      nurse: nurse
    } do
      Board.mode(:accept_then_raise)
      row = invoke!(nurse, @post, notice())

      assert :outcome_unknown = execute(row)
      assert %{status: :outcome_unknown, error_code: "raised"} = get(row)

      keyed = invoke!(nurse, @post_keyed, notice(2))
      assert :deferred = execute(keyed)
      assert %{status: :ready, failure_class: :transient, error_code: "raised"} = get(keyed)
    end

    @tag :capture_log
    test "an idempotent outside target that keeps failing ends unknown at max_attempts, not failed",
         %{nurse: nurse} do
      Board.mode(:accept_then_raise)
      row = invoke!(nurse, @post_keyed, notice())

      assert :deferred = execute(row)
      assert :deferred = row |> elapse!(:next_attempt_at) |> execute()
      assert :outcome_unknown = row |> elapse!(:next_attempt_at) |> execute()

      # The board holds the notice: the lookup settles it, and nothing is sent again.
      assert :succeeded = reconcile(row)
      assert {get(row).attempt_count, Board.calls(), Board.notices()} == {3, 3, 1}
    end

    test "a worker that keeps dying is not re-run past max_attempts", %{nurse: nurse} do
      row = invoke!(nurse, @post_keyed, notice())

      for _attempt <- 1..3 do
        claimed_and_abandoned(get(row))
        assert reconcile(row) in [:requeued, :succeeded]
      end

      # Three attempts, each of which reached the board: the third lease is not handed out
      # again; the lookup settles the row instead.
      done = get(row)

      assert {done.status, done.attempt_count, done.reconciled_via} ==
               {:succeeded, 3, "reconcile_with"}

      assert {:error, :not_claimable} = Executor.claim(done, machinery())
    end

    test "an expired lease at max_attempts is not taken over at claim either", %{nurse: nurse} do
      row = invoke!(nurse, @record, %{"licence_number" => "RN-1"})

      for _attempt <- 1..3 do
        {:ok, _claimed} = Executor.claim(get(row), machinery(), lease_for: 0)
      end

      assert {:error, :not_claimable} = Executor.claim(get(row), machinery())
      assert :failed = reconcile(row)

      assert %{status: :failed, failure_class: :transient, error_code: "attempts_exhausted"} =
               get(row)

      assert checks("RN-1") == []
    end

    test "a row a deploy changed after an attempt reached outside is reconciled, not stale",
         %{nurse: nurse} do
      row = invoke!(nurse, @post_keyed, notice())
      claimed_and_abandoned(row)
      assert :requeued = reconcile(row)

      changed = requested_under_earlier_definition!(get(row))
      assert :outcome_unknown = execute(changed)
      assert %{status: :outcome_unknown, error_code: "target_changed"} = get(row)

      assert :succeeded = reconcile(row)
      assert {get(row).status, Board.notices()} == {:succeeded, 1}
    end

    test "cancelling a ready row an attempt reached outside reconciles it", %{nurse: nurse} do
      row = invoke!(nurse, @post_keyed, notice())
      claimed_and_abandoned(row)
      assert :requeued = reconcile(row)

      asked = Domain.request_cancel!(get(row))

      assert {asked.status, is_struct(asked.cancel_requested_at, DateTime)} ==
               {:outcome_unknown, true}

      assert :succeeded = reconcile(row)
      assert get(row).status == :succeeded

      # One that never ran is simply cancelled.
      assert %{status: :cancelled} =
               Domain.request_cancel!(invoke!(nurse, @post_keyed, notice(2)))
    end

    test "a row an attempt reached outside whose principal lost authority is reconciled", %{
      nurse: nurse
    } do
      row = invoke!(nurse, @post_keyed, notice())
      claimed_and_abandoned(row)
      assert :requeued = reconcile(row)

      AshAgent.Test.ExecutionIdentity.revoke(nurse.id)
      on_exit(&AshAgent.Test.ExecutionIdentity.restore/0)

      assert :outcome_unknown = execute(row)
      assert %{status: :outcome_unknown, error_code: "no_authority: revoked"} = get(row)
    end
  end

  describe "dispatch" do
    test "handed-on work waits without a lease; its callback settles it once", %{nurse: nurse} do
      row = invoke!(nurse, @refer, notice())

      assert :dispatched = execute(row)
      waiting = get(row)

      assert {waiting.status, waiting.lease_expires_at, waiting.effect_ref} ==
               {:dispatched, nil, row.invocation_key}

      assert %DateTime{} = waiting.deadline_at
      assert :skipped = reconcile(row)

      done =
        Domain.complete_external!(waiting, %{outcome: :succeeded, via: "callback"})

      assert {done.status, done.reconciled_via} == {:succeeded, "callback"}

      # A late callback that disagrees is kept as evidence and changes nothing else.
      late = Domain.complete_external!(done, %{outcome: :failed, via: "callback"})
      assert late.status == :succeeded
      assert [%{"outcome" => "failed", "via" => "callback"}] = late.evidence
    end

    test "a passed deadline on outside work that is not idempotent is unknown", %{
      nurse: nurse
    } do
      row = invoke!(nurse, @refer, notice())
      :dispatched = execute(row)

      assert :succeeded = row |> elapse!(:deadline_at) |> reconcile()
      # The lookup found the referral the board took; nothing was sent again.
      assert %{status: :succeeded, reconciled_via: "reconcile_with"} = get(row)
      assert Board.calls() == 1
    end

    test "a passed deadline on idempotent outside work fails as a timeout", %{nurse: nurse} do
      row = invoke!(nurse, @refer_keyed, notice())
      :dispatched = execute(row)

      assert :failed = row |> elapse!(:deadline_at) |> reconcile()

      assert %{status: :failed, failure_class: :timeout, reconciled_via: "deadline"} = get(row)
    end

    test "a callback for a row that has not been handed on is refused", %{nurse: nurse} do
      row = invoke!(nurse, @refer, notice())

      assert {:error, %Ash.Error.Invalid{}} =
               Domain.complete_external(row, %{outcome: :succeeded, via: "callback"})
    end
  end
end
