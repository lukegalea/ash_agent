# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.Changes.CompleteExternal do
  @moduledoc """
  Records the outcome of work done outside this application, learned from a callback,
  a `reconcile_with` lookup or a passed deadline (the `via` argument).

    * A `dispatched` or `outcome_unknown` row becomes `succeeded` or `failed`, with
      `reconciled_via`, `effect_observed_at` and, when given, the effect's reference. A
      failed outcome is recorded with `failure_class` (default `:permanent`).
    * A row that is already final is not changed: the callback is appended to its
      `evidence`, with when it arrived and what it said. A callback that contradicts the
      recorded outcome is how an operator finds out; it never rewrites it.
    * Any other row has no outside work to complete, and is refused.

  The update is filtered on the status and lease epoch it read, so of two callbacks for
  one row one completes it and the other gets `StaleRecord`; read again, it is then late.
  """

  use Ash.Resource.Change

  require Ash.Expr

  @open [:dispatched, :outcome_unknown]
  @final [:succeeded, :failed, :rejected, :stale, :cancelled]

  @impl true
  def change(changeset, _opts, _context) do
    %{status: status, lease_epoch: epoch} = changeset.data
    arg = &Ash.Changeset.get_argument(changeset, &1)

    changeset =
      Ash.Changeset.filter(changeset, Ash.Expr.expr(status == ^status and lease_epoch == ^epoch))

    cond do
      status in @open ->
        complete(changeset, arg.(:outcome), arg)

      status in @final ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :evidence,
          changeset.data.evidence ++ [evidence(arg)]
        )

      true ->
        Ash.Changeset.add_error(changeset,
          field: :status,
          message: "is %{status}; it has no outside work to complete",
          vars: [status: status]
        )
    end
  end

  defp complete(changeset, outcome, arg) do
    observed =
      %{
        reconciled_via: arg.(:via),
        effect_observed_at: DateTime.utc_now(),
        lease_expires_at: nil,
        failure_class: if(outcome == :failed, do: arg.(:failure_class) || :permanent),
        error_code: if(outcome == :failed, do: arg.(:error_code))
      }
      |> put_present(:effect_ref, arg.(:effect_ref))
      |> put_present(:effect_system, arg.(:effect_system))

    changeset
    |> AshStateMachine.transition_state(outcome)
    |> Ash.Changeset.force_change_attributes(observed)
  end

  defp evidence(arg) do
    %{
      "at" => DateTime.to_iso8601(DateTime.utc_now()),
      "via" => arg.(:via),
      "outcome" => Atom.to_string(arg.(:outcome)),
      "effect_ref" => arg.(:effect_ref),
      "effect_system" => arg.(:effect_system),
      "error_code" => arg.(:error_code)
    }
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
