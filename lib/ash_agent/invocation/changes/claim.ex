# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.Changes.Claim do
  @moduledoc """
  The `claim` action's work, after its filter and `optimistic_lock(:lease_epoch)`.

  A row is claimable when it is `ready` and its `next_attempt_at` (set by a backoff) has
  come, or when it is `executing` with an expired lease and running its target again
  cannot repeat its effect (`AshAgent.Invocation.Failure.repeatable?/1` on its effects
  snapshot): the target writes only to this application, so its effect committed with
  `succeed` or not at all, or it is idempotent, so the outside service deduplicates it by
  the invocation key. Any other target's expired lease is not claimable: its effect may
  have happened outside, and only reconciliation may decide
  (`AshAgent.Invocation.Reconciler`).

  A claimable row's `target_digest` is then compared with the digest of the target as
  it is declared now. A row whose target changed since it was requested (its input
  schema or its effects declaration) becomes `stale`, with `error_code:
  "target_changed"`, and nothing runs: what was requested, and perhaps approved, is not
  what would run, and the snapshot the takeover rule above reads no longer describes the
  code. A target that no longer resolves is claimed as before, and the executor fails it.

  A row that needed an approval is then checked again, inside the claim's transaction,
  with `AshAgent.Invocation.Approval.stale_reason/2`: an approval that has expired, or
  whose digest no longer matches the row, the target as declared now and the
  preconditions' records as they stand now (a subject changed since it was approved),
  makes the row `stale` with the reason as `error_code`, and nothing runs. An approval
  is checked at every claim, not once: it is what was approved, not an exemption.

  A row that would go `stale` after an earlier attempt that may have reached outside
  (`AshAgent.Invocation.Failure.attempted_outside?/2`: an idempotent outside target made
  ready again after a lost lease or a failed attempt) becomes `outcome_unknown` instead,
  with the same `error_code`, and its `:reconcile` job is enqueued: the outside service
  may hold the effect, and only reconciliation may say so.

  An expired lease is taken over only while the row has attempts left
  (`attempt_count` below the host's `max_attempts`); past that, reconciliation settles
  it (`AshAgent.Invocation.Reconciler`). A `ready` row is always claimable: `retry` and
  a person's resolution make one ready on purpose.

  Otherwise the claim moves the row to `executing`, starts a lease of `lease_for`
  milliseconds, records `lease_token_digest` (the digest of the secret only the claiming
  executor holds, which a governed target asks for), and counts the attempt. The epoch is
  taken by the action's `optimistic_lock`, so two claims from one reading cannot both
  win.
  """

  use Ash.Resource.Change

  alias AshAgent.Invocation.{Approval, Enqueue, Failure, Info, Target}

  @impl true
  def change(changeset, _opts, _context) do
    data = changeset.data
    now = DateTime.utc_now()

    cond do
      not claimable?(data, now) ->
        Ash.Changeset.add_error(changeset,
          field: :status,
          message: "is %{status}; only a ready row, or one whose lease expired, can be claimed",
          vars: [status: data.status]
        )

      target_changed?(data) ->
        stale(changeset, "target_changed")

      true ->
        changeset
        |> AshStateMachine.transition_state(:executing)
        |> Ash.Changeset.force_change_attributes(%{
          lease_expires_at:
            DateTime.add(now, Ash.Changeset.get_argument(changeset, :lease_for), :millisecond),
          attempt_count: data.attempt_count + 1,
          next_attempt_at: nil,
          lease_token_digest: Ash.Changeset.get_argument(changeset, :lease_token_digest)
        })
        |> Ash.Changeset.before_action(&recheck_approval/1)
    end
  end

  defp recheck_approval(changeset) do
    case Approval.stale_reason(changeset.data, tenant: changeset.tenant) do
      nil -> changeset
      reason -> stale(changeset, reason)
    end
  end

  @doc """
  Makes the row being claimed `stale` with `reason` as its `error_code`, so its target
  does not run; or, when an earlier attempt of it may have reached outside, leaves it
  `outcome_unknown` with the same `error_code` and enqueues `:reconcile`. A change a host
  attaches to `claim` to refuse the attempt (an approver who may no longer approve) calls
  this rather than making the row stale itself.
  """
  @spec stale(Ash.Changeset.t(), String.t()) :: Ash.Changeset.t()
  def stale(changeset, reason) do
    data = changeset.data

    changeset =
      Ash.Changeset.force_change_attributes(changeset, %{
        error_code: reason,
        lease_expires_at: nil,
        lease_token_digest: nil,
        attempt_count: data.attempt_count,
        next_attempt_at: nil
      })

    if Failure.attempted_outside?(data, data.attempt_count) do
      changeset
      |> AshStateMachine.transition_state(:outcome_unknown)
      |> Ash.Changeset.after_action(&Enqueue.when_unknown/2)
    else
      AshStateMachine.transition_state(changeset, :stale)
    end
  end

  @doc "Whether `invocation` may be claimed at `now`."
  @spec claimable?(Ash.Resource.record(), DateTime.t()) :: boolean()
  def claimable?(%{status: :ready, next_attempt_at: %DateTime{} = at}, now),
    do: DateTime.compare(at, now) != :gt

  def claimable?(%{status: :ready}, _now), do: true

  def claimable?(%{status: :executing, lease_expires_at: %DateTime{} = expires} = row, now) do
    DateTime.compare(expires, now) != :gt and Failure.repeatable?(row.effects) and
      row.attempt_count < Info.max_attempts(row.__struct__)
  end

  def claimable?(_row, _now), do: false

  @doc """
  Whether the target `invocation` names is declared differently now from when it was
  requested. A target that no longer resolves does not count as changed here.
  """
  @spec target_changed?(Ash.Resource.record()) :: boolean()
  def target_changed?(invocation) do
    case Target.resolve(invocation.target) do
      {:ok, target} -> Target.digest(target) != invocation.target_digest
      {:error, _unresolvable} -> false
    end
  end
end
