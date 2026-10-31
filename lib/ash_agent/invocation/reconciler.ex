# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.Reconciler do
  @moduledoc """
  Settles the rows a worker could not: the `:reconcile` trigger's work.

  A row needs reconciling when:

    * it is `executing` and its lease expired: the worker died, or is stuck. If running
      its target again cannot repeat its effect (it writes only to this application, so
      its effect rolled back, or it is idempotent), the row is made `ready` again
      (`requeue`), while it has attempts left. Otherwise its effect may have happened
      outside, and it becomes `outcome_unknown` (`error_code` `"lease_expired"`, or
      `"attempts_exhausted"` for an idempotent one out of attempts). It is never run
      again blindly. A target that writes only here and is out of attempts fails as
      `:transient` with `"attempts_exhausted"`, which `retry` may re-ready;
    * it is `dispatched` and its deadline passed. Outside work that is not idempotent
      becomes `outcome_unknown` with `failure_class: :timeout`; anything else fails as
      `:timeout`;
    * its outcome is unknown and no one has been asked to settle it yet.

  An unknown outcome is settled, in order, by:

    1. the target's declared `reconcile_with` lookup (`AshAgent.Invocation.Target.lookup/4`),
       run as the executing principal rebuilt now. Found: the row `succeeded`, with the
       effect's reference. Not found: it `failed` with `:transient` and
       `error_code: "not_found_on_reconcile"`, so `retry` may run it again on purpose;
    2. a person: when there is no lookup, the lookup cannot tell, or it fails, the row
       asks for a resolution (`request_resolution`). The host opens a task for it, and
       applies the person's `:succeeded`, `:failed` or `:retry` with `apply_resolution`.

  A callback from outside settles a `dispatched` or `outcome_unknown` row at any time,
  through `complete_external`.

  `reconcile/3` returns `{:ok, outcome}`, `outcome` one of `outcomes/0`. Every write is
  filtered on the status and epoch it read, so two reconcilers of one row cannot both
  settle it: the loser ends with `:superseded`.
  """

  alias AshAgent.Invocation.{Executor, Failure, Info, Target}

  @outcomes [:requeued, :succeeded, :failed, :resolution_requested, :skipped, :superseded]

  @type outcome ::
          :requeued | :succeeded | :failed | :resolution_requested | :skipped | :superseded

  @doc "Every outcome `reconcile/3` can return."
  @spec outcomes() :: [outcome()]
  def outcomes, do: @outcomes

  @doc "Reconciles the row with id `id`. The `:reconcile` action's whole job."
  @spec reconcile(Ash.Resource.t(), Ash.UUID.t(), keyword()) ::
          {:ok, outcome()} | {:error, term()}
  def reconcile(resource, id, opts) do
    case Ash.get(resource, id, Keyword.put(opts, :not_found_error?, false)) do
      {:ok, nil} -> {:ok, :skipped}
      {:ok, row} -> reconcile_row(row, DateTime.utc_now(), opts)
      {:error, error} -> {:error, error}
    end
  end

  defp reconcile_row(%{status: :executing} = row, now, opts) do
    cond do
      not passed?(row.lease_expires_at, now) ->
        {:ok, :skipped}

      Failure.repeatable?(row.effects) and row.attempt_count < Info.max_attempts(row.__struct__) ->
        write(row, :requeue, %{epoch: row.lease_epoch}, opts, :requeued)

      Failure.outside?(row.effects) ->
        code =
          if Failure.repeatable?(row.effects), do: "attempts_exhausted", else: "lease_expired"

        row
        |> write_and_return(
          :mark_outcome_unknown,
          %{epoch: row.lease_epoch, error_code: code},
          opts
        )
        |> settle(opts)

      true ->
        write(
          row,
          :fail,
          %{epoch: row.lease_epoch, failure_class: :transient, error_code: "attempts_exhausted"},
          opts,
          :failed
        )
    end
  end

  defp reconcile_row(%{status: :dispatched} = row, now, opts) do
    cond do
      not passed?(row.deadline_at, now) ->
        {:ok, :skipped}

      Failure.repeatable?(row.effects) ->
        write(
          row,
          :complete_external,
          %{
            outcome: :failed,
            via: "deadline",
            failure_class: :timeout,
            error_code: "deadline_passed"
          },
          opts,
          :failed
        )

      true ->
        row
        |> write_and_return(
          :mark_outcome_unknown,
          %{epoch: row.lease_epoch, failure_class: :timeout, error_code: "deadline_passed"},
          opts
        )
        |> settle(opts)
    end
  end

  defp reconcile_row(%{status: :outcome_unknown, resolution_requested_at: nil} = row, _now, opts),
    do: settle({:ok, row}, opts)

  defp reconcile_row(_row, _now, _opts), do: {:ok, :skipped}

  # --- settling an unknown outcome ---------------------------------------------------

  defp settle({:ok, row}, opts) do
    case lookup(row, opts) do
      {:ok, %{outcome: :succeeded} = found} ->
        write(
          row,
          :complete_external,
          %{
            outcome: :succeeded,
            via: "reconcile_with",
            effect_ref: found.effect_ref,
            effect_system: found.effect_system
          },
          opts,
          :succeeded
        )

      {:ok, %{outcome: :not_found}} ->
        write(
          row,
          :complete_external,
          %{
            outcome: :failed,
            via: "reconcile_with",
            failure_class: :transient,
            error_code: "not_found_on_reconcile"
          },
          opts,
          :failed
        )

      _unknown_or_unavailable ->
        write(row, :request_resolution, %{}, opts, :resolution_requested)
    end
  end

  defp settle(:superseded, _opts), do: {:ok, :superseded}
  defp settle({:error, error}, _opts), do: {:error, error}

  defp lookup(row, opts) do
    with {:ok, target} <- Target.resolve(row.target),
         true <- not is_nil(target.effect.reconcile_with) || {:error, :no_reconcile_with},
         {:ok, actor} <- Info.execution_identity(row.__struct__).actor_for(row) do
      Target.lookup(target, row.invocation_key, Executor.stored_args(row, opts),
        actor: actor,
        tenant: opts[:tenant],
        context: %{ash_agent: Executor.context(row)}
      )
    end
  rescue
    error -> {:error, error}
  end

  # --- writing -----------------------------------------------------------------------

  defp write(row, action, input, opts, outcome) do
    case write_and_return(row, action, input, opts) do
      {:ok, _row} -> {:ok, outcome}
      :superseded -> {:ok, :superseded}
      {:error, error} -> {:error, error}
    end
  end

  defp write_and_return(row, action, input, opts) do
    row
    |> Ash.Changeset.for_update(action, input, opts)
    |> Ash.update()
    |> case do
      {:ok, written} -> {:ok, written}
      {:error, error} -> if moved_on?(error), do: :superseded, else: {:error, error}
    end
  end

  defp passed?(%DateTime{} = at, now), do: DateTime.compare(at, now) != :gt
  defp passed?(_none, _now), do: false

  defp moved_on?(%Ash.Error.Changes.StaleRecord{}), do: true
  defp moved_on?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &moved_on?/1)
  defp moved_on?(_error), do: false
end
