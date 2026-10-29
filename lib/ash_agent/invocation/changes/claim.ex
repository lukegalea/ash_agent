# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.Changes.Claim do
  @moduledoc """
  The `claim` action's work, after its filter and `optimistic_lock(:lease_epoch)`.

  A row is claimable when it is `ready`, or when it is `executing` with an expired lease
  and its target writes only to this application (`open_world: false` in its effects
  snapshot). Such a target's effect commits in one transaction with `succeed`, so a lease
  that expired without a `succeed` means the effect did not happen, and running it again
  is safe. An open-world target's expired lease is not claimable: its effect may have
  happened outside, and only reconciliation may decide.

  A claimable row's `target_digest` is then compared with the digest of the target as
  it is declared now. A row whose target changed since it was requested (its input
  schema or its effects declaration) becomes `stale`, with `error_code:
  "target_changed"`, and nothing runs: what was requested, and perhaps approved, is not
  what would run, and the snapshot the takeover rule above reads no longer describes the
  code. A target that no longer resolves is claimed as before, and the executor fails it.

  Otherwise the claim moves the row to `executing`, starts a lease of `lease_for`
  milliseconds, and counts the attempt. The epoch is taken by the action's
  `optimistic_lock`, so two claims from one reading cannot both win.
  """

  use Ash.Resource.Change

  alias AshAgent.Invocation.Target

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
        changeset
        |> AshStateMachine.transition_state(:stale)
        |> Ash.Changeset.force_change_attributes(%{
          error_code: "target_changed",
          lease_expires_at: nil,
          next_attempt_at: nil
        })

      true ->
        changeset
        |> AshStateMachine.transition_state(:executing)
        |> Ash.Changeset.force_change_attributes(%{
          lease_expires_at:
            DateTime.add(now, Ash.Changeset.get_argument(changeset, :lease_for), :millisecond),
          attempt_count: data.attempt_count + 1,
          next_attempt_at: nil
        })
    end
  end

  @doc "Whether `invocation` may be claimed at `now`."
  @spec claimable?(Ash.Resource.record(), DateTime.t()) :: boolean()
  def claimable?(%{status: :ready}, _now), do: true

  def claimable?(%{status: :executing, lease_expires_at: %DateTime{} = expires} = row, now),
    do: DateTime.compare(expires, now) != :gt and not open_world?(row)

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

  # Undeclared or unknown counts as open-world: MCP's default, and the safe reading.
  defp open_world?(%{effects: %{"open_world" => false}}), do: false
  defp open_world?(%{effects: %{open_world: false}}), do: false
  defp open_world?(_row), do: true
end
