# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Run.Budget do
  @moduledoc """
  A run's token budget: what its model calls may spend, held before each call and
  settled after it.

  The budget is four columns on the run: `budget_limit` (tokens the run may spend),
  `budget_spent` (tokens its settled calls used), `budget_reserved` (tokens held for
  calls that have not settled) and `budget_holds`, each unsettled hold by holder. A
  holder is one lease of one run, keyed `"<run id>:<lease epoch>"`.

    * **Reserve** (`reserve/2`), before a model call: the step holds what is left of
      the budget. The `reserve` action writes under `optimistic_lock(:budget_lock)` and
      a filter that `budget_spent + budget_reserved` stays within `budget_limit`, so of
      two reservations made from one reading at most one is written, and holds never
      add up past the limit. A reservation that meets a concurrent write reads the run
      again and tries again, a bounded number of times.
    * **Settle** (`settle/3`), after the call: the hold is released and the tokens the
      call used (its usage, in tokens) are added to `budget_spent`. A call is settled
      whatever became of it: answered, failed, or overtaken by another lease.
    * **A lost hold.** A worker that died between the two never settles. Its hold
      belongs to a lease that has expired, and the next lease of the same run releases
      it when it reserves. A worker that outlived its lease and still settles adds what
      it used to `budget_spent`; nothing it spent goes unrecorded.

  When nothing is left, the run waits on its budget (`waiting`, `blocked_on: :budget`,
  `error_code: "token_budget"`) until the host extends it (`extend`). Usage is known
  only after a call, so a call can use more than it held: that is recorded as spent,
  and the run waits on its budget at its next claim.

  A run with no `budget_limit` has no budget: nothing is held or settled.
  """

  require Logger

  @attempts 5

  @doc "The key of the hold one lease of a run takes: `\"<run id>:<lease epoch>\"`."
  @spec hold_key(Ash.UUID.t(), integer()) :: String.t()
  def hold_key(run_id, epoch), do: "#{run_id}:#{epoch}"

  @doc """
  `holds` without those of the run `run_id`'s leases before `epoch`: a later lease
  holds the run, so theirs are released.
  """
  @spec release_earlier(map(), Ash.UUID.t(), integer()) :: map()
  def release_earlier(holds, run_id, epoch) do
    prefix = "#{run_id}:"

    Map.reject(holds, fn {key, _tokens} ->
      case String.split_at(key, byte_size(prefix)) do
        {^prefix, held_epoch} -> String.to_integer(held_epoch) < epoch
        _other -> false
      end
    end)
  end

  @doc """
  Tokens a lease of `run` at `epoch` could hold now: the limit, less what was spent and
  what other holds keep. `nil` when the run has no budget.
  """
  @spec available(Ash.Resource.record(), integer()) :: integer() | nil
  def available(%{budget_limit: nil}, _epoch), do: nil

  def available(run, epoch) do
    held = run.budget_holds |> release_earlier(run.id, epoch) |> Map.values() |> Enum.sum()
    run.budget_limit - run.budget_spent - held
  end

  @doc """
  Holds what is left of `run`'s budget for one model call of its current lease.

    * `{:ok, run}`: held, or the run has no budget;
    * `{:error, :exhausted}`: nothing is left;
    * `{:error, :superseded}`: another lease holds the run;
    * `{:error, :contended}`: concurrent budget writes kept winning.
  """
  @spec reserve(Ash.Resource.record(), keyword()) ::
          {:ok, Ash.Resource.record()}
          | {:error, :exhausted | :superseded | :contended | term()}
  def reserve(run, opts), do: reserve(run, run.lease_epoch, opts, @attempts)

  defp reserve(%{budget_limit: nil} = run, _epoch, _opts, _attempts), do: {:ok, run}

  defp reserve(run, epoch, opts, attempts) do
    cond do
      run.lease_epoch != epoch or run.status != :running ->
        {:error, :superseded}

      available(run, epoch) <= 0 ->
        {:error, :exhausted}

      true ->
        input = %{run_id: run.id, epoch: epoch, tokens: available(run, epoch)}

        run
        |> Ash.Changeset.for_update(:reserve, input, opts)
        |> Ash.update()
        |> case do
          {:ok, reserved} -> {:ok, reserved}
          {:error, error} -> retry(error, run, epoch, opts, attempts, &reserve/4)
        end
    end
  end

  @doc """
  Releases the hold of `run`'s current lease and adds `tokens`, what its call used, to
  `budget_spent`. Returns the run as written; when concurrent budget writes keep
  winning, logs that the call went unsettled and returns `run` as given.
  """
  @spec settle(Ash.Resource.record(), non_neg_integer(), keyword()) :: Ash.Resource.record()
  def settle(run, tokens, opts) do
    case settle(run, run.lease_epoch, tokens, opts, @attempts) do
      {:ok, settled} ->
        settled

      {:error, reason} ->
        Logger.error(
          "agent run #{run.id}: #{tokens} tokens of epoch #{run.lease_epoch} left unsettled: " <>
            inspect(reason)
        )

        run
    end
  end

  defp settle(%{budget_limit: nil} = run, _epoch, _tokens, _opts, _attempts), do: {:ok, run}

  defp settle(run, epoch, tokens, opts, attempts) do
    run
    |> Ash.Changeset.for_update(:settle, %{run_id: run.id, epoch: epoch, tokens: tokens}, opts)
    |> Ash.update()
    |> case do
      {:ok, settled} -> {:ok, settled}
      {:error, error} -> retry(error, run, epoch, opts, attempts, &settle(&1, &2, tokens, &3, &4))
    end
  end

  # A budget write that matched no row lost to a concurrent one: read the run again and
  # try again, while attempts remain.
  defp retry(error, run, epoch, opts, attempts, again) do
    cond do
      exhausted?(error) ->
        {:error, :exhausted}

      not stale?(error) ->
        {:error, error}

      attempts <= 1 ->
        {:error, :contended}

      true ->
        case Ash.get(run.__struct__, run.id, opts) do
          {:ok, fresh} -> again.(fresh, epoch, opts, attempts - 1)
          {:error, error} -> {:error, error}
        end
    end
  end

  defp exhausted?(%AshAgent.Run.BudgetExhausted{}), do: true
  defp exhausted?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &exhausted?/1)
  defp exhausted?(_error), do: false

  defp stale?(%Ash.Error.Changes.StaleRecord{}), do: true
  defp stale?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &stale?/1)
  defp stale?(_error), do: false
end
