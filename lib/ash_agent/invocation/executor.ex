# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.Executor do
  @moduledoc """
  Runs a ready invocation: claim, commit, run, record under the fence.

    1. **Claim** (`claim/3`, its own transaction): takes the next lease epoch. Of two
       workers holding the same row, one claims and the other ends with `:skipped`. A
       row whose target is declared differently now from when it was requested becomes
       `stale` at the claim, and ends with `:stale`; its target never runs.
    2. **Identity** (`c:AshAgent.ExecutionIdentity.actor_for/1`): the actor to run as is
       built afresh from the row's principal. A principal with no authority now fails the
       row as `:denied`, with `error_code` `"no_authority"` (followed by the host's reason
       when that is an atom, as in `"no_authority: inactive"`); the target does not run.
    3. **Run and record** (`run_claimed/2`), on the path the target's current
       declaration names, which the claim checked is the one requested:
       * a target that writes only to this application (`open_world: false`) runs in one
         transaction with its completion. The completion is filtered on the claimed
         epoch, so a worker whose lease was taken over in the meantime matches no row,
         and its transaction rolls back with the target's effect in it: exactly one
         committed effect, whichever worker wins. An expired lease means the effect did
         not happen, so the row is made ready again;
       * a target that reaches outside runs with no transaction open, and its outcome is
         recorded under the fence afterwards. An idempotent one is given the invocation
         key (`context.ash_agent.invocation_key`) to send as the outside service's
         idempotency key, so a second call after an expired lease is deduplicated there.
         One that is not idempotent is never called twice for one claim: an error that
         leaves its effect in doubt, or a lease that expires with no outcome recorded,
         makes the row `outcome_unknown` for reconciliation (`AshAgent.Invocation.Reconciler`);
       * a target that hands its work on returns an `AshAgent.Invocation.Dispatch`: the
         row becomes `dispatched` and waits, with no lease, until its deadline.
    4. A target that fails is classified (`AshAgent.Invocation.Failure`): a transient
       failure makes the row `ready` again after a backoff (`defer`) until the host's
       `max_attempts`; one whose effect is in doubt on an outside target that is not
       idempotent makes it `outcome_unknown`; anything else fails it with its class.
       A subject the executing actor can no longer reach is `:denied`; one that is gone
       is `:rejected`.

  Every function returns `{:ok, outcome}` with `outcome` one of `outcomes/0`: `:succeeded`,
  `:failed`, `:deferred` (ready again after a backoff), `:dispatched`,
  `:outcome_unknown`, `:skipped` (not claimable), `:superseded` (the lease was lost
  before completing) and `:stale` (the target changed since the request).
  `opts` carry the actor and tenant the invocation row is read and written with: the
  machinery's, not the target's.
  """

  require Ash.Query

  alias AshAgent.Invocation.{Changes.Claim, Dispatch, Failure, Info, LeaseLost, Target}

  @outcomes [
    :succeeded,
    :failed,
    :deferred,
    :dispatched,
    :outcome_unknown,
    :skipped,
    :superseded,
    :stale
  ]

  @type outcome ::
          :succeeded
          | :failed
          | :deferred
          | :dispatched
          | :outcome_unknown
          | :skipped
          | :superseded
          | :stale

  @doc "Every outcome `execute/3` can return."
  @spec outcomes() :: [outcome()]
  def outcomes, do: @outcomes

  @doc "Claims the row with id `id` and runs it. The `:execute` action's whole job."
  @spec execute(Ash.Resource.t(), Ash.UUID.t(), keyword()) :: {:ok, outcome()} | {:error, term()}
  def execute(resource, id, opts) do
    case Ash.get(resource, id, Keyword.put(opts, :not_found_error?, false)) do
      {:ok, nil} ->
        {:ok, :skipped}

      {:ok, row} ->
        case claim(row, opts) do
          {:ok, claimed} -> run_claimed(claimed, opts)
          {:error, :not_claimable} -> {:ok, :skipped}
          {:error, :stale} -> {:ok, :stale}
          {:error, error} -> {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Claims `row`. `claim_opts` may set `:lease_for` in milliseconds.

  `{:error, :not_claimable}` when the row is not ready and holds no expired lease, or
  when another claim took it first. `{:error, :stale}` when its target is declared
  differently now from when it was requested: the claim has made the row `stale`, and it
  must not run.
  """
  @spec claim(Ash.Resource.record(), keyword(), keyword()) ::
          {:ok, Ash.Resource.record()} | {:error, :not_claimable | :stale | term()}
  def claim(row, opts, claim_opts \\ []) do
    if Claim.claimable?(row, DateTime.utc_now()) do
      row
      |> Ash.Changeset.for_update(:claim, Map.new(Keyword.take(claim_opts, [:lease_for])), opts)
      |> Ash.update()
      |> case do
        {:ok, %{status: :stale}} ->
          {:error, :stale}

        {:ok, claimed} ->
          {:ok, claimed}

        {:error, error} ->
          if lost_claim?(error), do: {:error, :not_claimable}, else: {:error, error}
      end
    else
      {:error, :not_claimable}
    end
  end

  @doc "Runs a row this worker claimed, and records the outcome under its epoch."
  @spec run_claimed(Ash.Resource.record(), keyword()) :: {:ok, outcome()} | {:error, term()}
  def run_claimed(claimed, opts) do
    resource = claimed.__struct__

    case Target.resolve(claimed.target) do
      {:ok, target} ->
        case Info.execution_identity(resource).actor_for(claimed) do
          {:ok, actor} -> run_as(claimed, target, actor, opts)
          {:error, reason} -> record_failure(claimed, {:denied, no_authority(reason)}, opts)
        end

      {:error, _message} ->
        record_failure(claimed, {:permanent, "target_unavailable"}, opts)
    end
  end

  defp run_as(claimed, target, actor, opts) do
    args = stored_args(claimed, opts)

    target_opts = [
      actor: actor,
      tenant: opts[:tenant],
      context: %{ash_agent: context(claimed)}
    ]

    if target.effect.open_world? do
      case Target.run(target, args, target_opts) do
        {:ok, value} -> complete(claimed, completion(value), opts)
        {:error, error} -> record_failure(claimed, Failure.classify(error), opts)
      end
    else
      case run_with_completion(claimed, target, args, target_opts, opts) do
        {:ok, outcome} ->
          {:ok, outcome}

        {:error, error} ->
          if lease_lost?(error),
            do: {:ok, :superseded},
            else: record_failure(claimed, Failure.classify(error), opts)
      end
    end
  end

  @doc false
  # What a target and its lookup see of the invocation, under `context.ash_agent`.
  @spec context(Ash.Resource.record()) :: map()
  def context(invocation) do
    %{
      invocation_id: invocation.id,
      invocation_key: invocation.invocation_key,
      lease_epoch: invocation.lease_epoch
    }
  end

  # The target's effect and its completion in one transaction. An exception in the
  # target rolls it back like an error does; it is recorded rather than left for the
  # lease to expire.
  defp run_with_completion(claimed, target, args, target_opts, opts) do
    [claimed.__struct__, target.resource]
    |> Enum.uniq()
    |> Ash.transact(fn ->
      with {:ok, value} <- Target.run(target, args, target_opts),
           {action, input, outcome} = completion(value),
           {:ok, _done} <- complete_held(claimed, action, input, opts) do
        outcome
      end
    end)
  rescue
    error -> {:error, Ash.Error.to_ash_error(error, __STACKTRACE__)}
  end

  defp completion(%Dispatch{} = dispatch) do
    {:dispatch,
     %{
       effect_ref: dispatch.effect_ref,
       effect_system: dispatch.effect_system,
       deadline_at: dispatch.deadline_at
     }, :dispatched}
  end

  defp completion(summary), do: {:succeed, %{result: summary}, :succeeded}

  defp record_failure(claimed, {_class, code} = classified, opts) do
    max_attempts = Info.max_attempts(claimed.__struct__)

    case Failure.next(classified, claimed.effects, claimed.attempt_count, max_attempts) do
      {:retry, delay} ->
        retry_at = DateTime.add(DateTime.utc_now(), delay, :millisecond)
        complete(claimed, {:defer, %{retry_at: retry_at, error_code: code}, :deferred}, opts)

      :unknown ->
        complete(
          claimed,
          {:mark_outcome_unknown, %{error_code: code}, :outcome_unknown},
          opts
        )

      :fail ->
        complete(
          claimed,
          {:fail, %{failure_class: Failure.recorded_class(classified), error_code: code},
           :failed},
          opts
        )
    end
  end

  # Completes in a transaction of its own.
  defp complete(claimed, {action, input, outcome}, opts) do
    claimed.__struct__
    |> Ash.transact(fn -> complete_held(claimed, action, input, opts) end)
    |> case do
      {:ok, _done} -> {:ok, outcome}
      {:error, error} -> if lease_lost?(error), do: {:ok, :superseded}, else: {:error, error}
    end
  end

  # Inside a transaction: reads the row again under a row lock, so the write below
  # starts from what is committed now, then writes filtered on the claimed epoch.
  defp complete_held(claimed, action, input, opts) do
    resource = claimed.__struct__
    lost = LeaseLost.exception(id: claimed.id, epoch: claimed.lease_epoch)

    resource
    |> Ash.Query.filter(id == ^claimed.id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(opts)
    |> case do
      {:ok, %{status: :executing, lease_epoch: epoch} = current}
      when epoch == claimed.lease_epoch ->
        current
        |> Ash.Changeset.for_update(action, Map.put(input, :epoch, epoch), opts)
        |> Ash.update()
        |> case do
          {:ok, done} -> {:ok, done}
          {:error, error} -> if lost_claim?(error), do: {:error, lost}, else: {:error, error}
        end

      {:ok, _moved_on} ->
        {:error, lost}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc false
  # The arguments the row was requested with. A host that seals `args` turns the
  # attribute into a calculation that opens it.
  @spec stored_args(Ash.Resource.record(), keyword()) :: map()
  def stored_args(invocation, opts) do
    if Ash.Resource.Info.attribute(invocation.__struct__, :args),
      do: invocation.args || %{},
      else: Ash.load!(invocation, [:args], opts).args || %{}
  end

  # The host's reason, when it is a plain name, says why the principal has no authority
  # now: an inactive account, a revoked grant. Anything else stays out of the row.
  defp no_authority(reason)
       when is_atom(reason) and not is_nil(reason) and not is_boolean(reason),
       do: String.slice("no_authority: #{reason}", 0, 256)

  defp no_authority(_reason), do: "no_authority"

  defp lease_lost?(%LeaseLost{}), do: true
  defp lease_lost?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &lease_lost?/1)
  defp lease_lost?(_error), do: false

  # A write that matched no row (the epoch or the version moved on), or a claim of a row
  # that is no longer claimable.
  defp lost_claim?(%Ash.Error.Changes.StaleRecord{}), do: true
  defp lost_claim?(%Ash.Error.Changes.InvalidAttribute{field: :status}), do: true
  defp lost_claim?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &lost_claim?/1)
  defp lost_claim?(_error), do: false
end
