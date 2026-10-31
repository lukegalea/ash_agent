# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Run.Changes.CancelInvocations do
  @moduledoc """
  A run that ends without finishing (cancelled, or failed) cancels its tool calls that
  have not started: each of its invocations that is `requested`, `awaiting_approval` or
  `ready` gets `request_cancel`, in the same transaction. One that is executing,
  dispatched or of unknown outcome records the request and ends as its own rules say;
  one that finished is left as it is. Nothing done is undone: reversing an effect is a
  separate request, never a side effect of cancelling.

  The invocations are found and cancelled without authorization: the decision to stop
  the run was authorized on the run, and this is that decision's bookkeeping.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshAgent.Run.Info

  @open [:requested, :awaiting_approval, :ready, :executing, :dispatched, :outcome_unknown]

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, run ->
      case cascade(changeset, run) do
        :ok -> {:ok, run}
        {:error, error} -> {:error, error}
      end
    end)
  end

  @doc "Requests the cancellation of every open invocation of `run`."
  @spec cascade(Ash.Changeset.t(), Ash.Resource.record()) :: :ok | {:error, term()}
  def cascade(changeset, run) do
    opts = [tenant: changeset.tenant, authorize?: false]
    invocation = Info.invocation(changeset.resource)

    invocation
    |> Ash.Query.filter(run_id == ^run.id and status in ^@open and is_nil(cancel_requested_at))
    |> Ash.read(opts)
    |> case do
      {:ok, rows} -> Enum.reduce_while(rows, :ok, &cancel(&1, &2, invocation, opts))
      {:error, error} -> {:error, error}
    end
  end

  # A row a worker claimed in the meantime is read again and asked once more: the claim
  # either landed first (it is executing, and records the request) or not at all.
  defp cancel(row, :ok, invocation, opts, retried? \\ false) do
    case row |> Ash.Changeset.for_update(:request_cancel, %{}, opts) |> Ash.update() do
      {:ok, _row} ->
        {:cont, :ok}

      {:error, error} ->
        if retried? or not stale?(error) do
          {:halt, {:error, error}}
        else
          case Ash.get(invocation, row.id, opts) do
            {:ok, %{status: status} = fresh} when status in @open ->
              cancel(fresh, :ok, invocation, opts, true)

            {:ok, _finished} ->
              {:cont, :ok}

            {:error, error} ->
              {:halt, {:error, error}}
          end
        end
    end
  end

  defp stale?(%Ash.Error.Changes.StaleRecord{}), do: true
  defp stale?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &stale?/1)
  defp stale?(_error), do: false
end
