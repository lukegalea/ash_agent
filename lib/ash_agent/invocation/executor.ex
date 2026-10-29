# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.Executor do
  @moduledoc """
  Runs a ready invocation: claim, commit, run, record under the fence.

    1. **Claim** (`claim/3`, its own transaction): takes the next lease epoch. Of two
       workers holding the same row, one claims and the other ends with `:skipped`.
    2. **Identity** (`c:AshAgent.ExecutionIdentity.actor_for/1`): the actor to run as is
       built afresh from the row's principal. A principal with no authority now fails the
       row as `:denied`; the target does not run.
    3. **Run and record** (`run_claimed/2`):
       * a target that writes only to this application (`open_world: false`) runs in one
         transaction with `succeed`. `succeed` is filtered on the claimed epoch, so a
         worker whose lease was taken over in the meantime matches no row, and its
         transaction rolls back with the target's effect in it: exactly one committed
         effect, whichever worker wins;
       * a target that reaches outside runs with no transaction open, and `succeed` is
         recorded under the fence afterwards. Its effect is at least once; reconciling a
         lost acknowledgement is not built in this version.
    4. A target that fails is recorded with `fail` under the same fence and a failure
       class: `:denied` for a forbidden error, `:rejected` for an invalid one,
       `:permanent` otherwise.

  Every function returns `{:ok, outcome}` with `outcome` one of `:succeeded`, `:failed`,
  `:skipped` (not claimable) and `:superseded` (the lease was lost before completing).
  `opts` carry the actor and tenant the invocation row is read and written with: the
  machinery's, not the target's.
  """

  require Ash.Query

  alias AshAgent.Invocation.{Changes.Claim, Info, LeaseLost, Target}

  @type outcome :: :succeeded | :failed | :skipped | :superseded

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
          {:error, error} -> {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Claims `row`. `claim_opts` may set `:lease_for` in milliseconds.

  `{:error, :not_claimable}` when the row is not ready and holds no expired lease, or
  when another claim took it first.
  """
  @spec claim(Ash.Resource.record(), keyword(), keyword()) ::
          {:ok, Ash.Resource.record()} | {:error, :not_claimable | term()}
  def claim(row, opts, claim_opts \\ []) do
    if Claim.claimable?(row, DateTime.utc_now()) do
      row
      |> Ash.Changeset.for_update(:claim, Map.new(Keyword.take(claim_opts, [:lease_for])), opts)
      |> Ash.update()
      |> case do
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
          {:error, _reason} -> record_failure(claimed, :denied, "no_authority", opts)
        end

      {:error, _message} ->
        record_failure(claimed, :permanent, "target_unavailable", opts)
    end
  end

  defp run_as(claimed, target, actor, opts) do
    args = args(claimed, opts)

    target_opts = [
      actor: actor,
      tenant: opts[:tenant],
      context: %{
        ash_agent: %{
          invocation_id: claimed.id,
          invocation_key: claimed.invocation_key,
          lease_epoch: claimed.lease_epoch
        }
      }
    ]

    if open_world?(claimed) do
      case Target.run(target, args, target_opts) do
        {:ok, summary} -> complete(claimed, :succeed, %{result: summary}, opts)
        {:error, error} -> record_failure(claimed, failure_class(error), error_code(error), opts)
      end
    else
      case run_with_completion(claimed, target, args, target_opts, opts) do
        {:ok, _done} ->
          {:ok, :succeeded}

        {:error, error} ->
          if lease_lost?(error),
            do: {:ok, :superseded},
            else: record_failure(claimed, failure_class(error), error_code(error), opts)
      end
    end
  end

  # The target's effect and `succeed` in one transaction. An exception in the target
  # rolls it back like an error does; it is recorded rather than left for the lease to
  # expire.
  defp run_with_completion(claimed, target, args, target_opts, opts) do
    [claimed.__struct__, target.resource]
    |> Enum.uniq()
    |> Ash.transact(fn ->
      with {:ok, summary} <- Target.run(target, args, target_opts) do
        complete_held(claimed, :succeed, %{result: summary}, opts)
      end
    end)
  rescue
    error -> {:error, Ash.Error.to_ash_error(error, __STACKTRACE__)}
  end

  defp record_failure(claimed, class, code, opts) do
    case complete(claimed, :fail, %{failure_class: class, error_code: code}, opts) do
      {:ok, :succeeded} -> {:ok, :failed}
      other -> other
    end
  end

  # Completes in a transaction of its own.
  defp complete(claimed, action, input, opts) do
    claimed.__struct__
    |> Ash.transact(fn -> complete_held(claimed, action, input, opts) end)
    |> case do
      {:ok, _done} -> {:ok, :succeeded}
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

  defp args(claimed, opts) do
    resource = claimed.__struct__

    # A host that seals `args` turns the attribute into a calculation that opens it.
    if Ash.Resource.Info.attribute(resource, :args),
      do: claimed.args || %{},
      else: Ash.load!(claimed, [:args], opts).args || %{}
  end

  # Undeclared or unknown counts as open-world: MCP's default, and the safe reading.
  defp open_world?(%{effects: %{"open_world" => false}}), do: false
  defp open_world?(%{effects: %{open_world: false}}), do: false
  defp open_world?(_claimed), do: true

  defp failure_class(%Ash.Error.Forbidden{}), do: :denied
  defp failure_class(%Ash.Error.Invalid{}), do: :rejected
  defp failure_class(_error), do: :permanent

  defp error_code(%Ash.Error.Forbidden{}), do: "forbidden"
  defp error_code(%Ash.Error.Invalid{}), do: "invalid"
  defp error_code(_error), do: "error"

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
