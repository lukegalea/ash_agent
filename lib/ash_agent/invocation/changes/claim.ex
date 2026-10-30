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

  Otherwise the claim moves the row to `executing`, starts a lease of `lease_for`
  milliseconds, and counts the attempt. The epoch is taken by the action's
  `optimistic_lock`, so two claims from one reading cannot both win.
  """

  use Ash.Resource.Change

  alias AshAgent.Invocation.{Approval, Failure, Target}

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
          next_attempt_at: nil
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

  defp stale(changeset, reason) do
    changeset
    |> AshStateMachine.transition_state(:stale)
    |> Ash.Changeset.force_change_attributes(%{
      error_code: reason,
      lease_expires_at: nil,
      attempt_count: changeset.data.attempt_count,
      next_attempt_at: nil
    })
  end

  @doc "Whether `invocation` may be claimed at `now`."
  @spec claimable?(Ash.Resource.record(), DateTime.t()) :: boolean()
  def claimable?(%{status: :ready, next_attempt_at: %DateTime{} = at}, now),
    do: DateTime.compare(at, now) != :gt

  def claimable?(%{status: :ready}, _now), do: true

  def claimable?(%{status: :executing, lease_expires_at: %DateTime{} = expires} = row, now),
    do: DateTime.compare(expires, now) != :gt and Failure.repeatable?(row.effects)

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
