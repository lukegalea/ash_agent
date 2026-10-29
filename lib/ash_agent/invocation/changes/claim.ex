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

  The claim moves the row to `executing`, starts a lease of `lease_for` milliseconds,
  and counts the attempt. The epoch is taken by the action's `optimistic_lock`, so two
  claims from one reading cannot both win.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    data = changeset.data
    now = DateTime.utc_now()

    if claimable?(data, now) do
      changeset
      |> AshStateMachine.transition_state(:executing)
      |> Ash.Changeset.force_change_attributes(%{
        lease_expires_at:
          DateTime.add(now, Ash.Changeset.get_argument(changeset, :lease_for), :millisecond),
        attempt_count: data.attempt_count + 1,
        next_attempt_at: nil
      })
    else
      Ash.Changeset.add_error(changeset,
        field: :status,
        message: "is %{status}; only a ready row, or one whose lease expired, can be claimed",
        vars: [status: data.status]
      )
    end
  end

  @doc "Whether `invocation` may be claimed at `now`."
  @spec claimable?(Ash.Resource.record(), DateTime.t()) :: boolean()
  def claimable?(%{status: :ready}, _now), do: true

  def claimable?(%{status: :executing, lease_expires_at: %DateTime{} = expires} = row, now),
    do: DateTime.compare(expires, now) != :gt and not open_world?(row)

  def claimable?(_row, _now), do: false

  # Undeclared or unknown counts as open-world: MCP's default, and the safe reading.
  defp open_world?(%{effects: %{"open_world" => false}}), do: false
  defp open_world?(%{effects: %{open_world: false}}), do: false
  defp open_world?(_row), do: true
end
