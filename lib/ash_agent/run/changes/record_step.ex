# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Run.Changes.RecordStep do
  @moduledoc """
  The `record_step` action's work, after its filter on the claimed epoch.

  The update is also filtered on the `step_seq` the caller read, so an append from a
  stale copy of the run matches no row and is refused with `StaleRecord`, as is any
  append from a worker whose lease was taken over or whose run was cancelled. Nothing
  below then happens: the run, its new steps and its new invocations commit together or
  not at all.

  In the same transaction, after the run's row is written:

    * each of `steps` is appended to the host's step resource (`append`), numbered from
      the run's `step_seq`;
    * each of `invocations` is requested through the host's invocation resource
      (`invoke`), keyed `run:<run id>:<step seq>:<tool call id>` with the run as its
      parent, as the actor `c:AshAgent.ExecutionIdentity.requester_for/1` builds. Each
      row must execute as the run does: an invocation whose `executing_principal` is
      not the run's is refused, and the record with it;
    * a run left `queued` or `waiting` has its next `:step` job enqueued; a run that
      `failed` has its tool calls that have not started cancelled.

  `outcome` moves the run: `:running` (it carries on: only messages are appended),
  `:queued`, `:waiting` (on `blocked_on`), `:completed` (with `output`) or `:failed`
  (with `failure_class` and `error_code`). The counters add up what the step did.
  """

  use Ash.Resource.Change

  require Ash.Expr

  alias AshAgent.ExecutionIdentity
  alias AshAgent.Run.{Enqueue, Info, Stepper}

  @impl true
  def change(changeset, _opts, context) do
    data = changeset.data
    steps = Ash.Changeset.get_argument(changeset, :steps) || []
    outcome = Ash.Changeset.get_argument(changeset, :outcome)
    arg = &Ash.Changeset.get_argument(changeset, &1)

    changeset
    |> Ash.Changeset.filter(Ash.Expr.expr(step_seq == ^data.step_seq))
    |> AshStateMachine.transition_state(outcome)
    |> Ash.Changeset.force_change_attributes(
      %{
        step_seq: data.step_seq + length(steps),
        step_count: data.step_count + arg.(:model_calls),
        tool_call_count: data.tool_call_count + arg.(:tool_calls),
        budget_spent: data.budget_spent + arg.(:tokens),
        repair_count: data.repair_count + arg.(:repairs),
        prompt_fingerprint: arg.(:prompt_fingerprint) || data.prompt_fingerprint
      }
      |> Map.merge(state_attributes(outcome, changeset))
    )
    |> Ash.Changeset.after_action(fn changeset, run ->
      with :ok <- append(changeset, context, run, data.step_seq, steps),
           :ok <- invoke(changeset, context, run, arg.(:invocations) || []) do
        after_outcome(changeset, run)
      end
    end)
  end

  defp state_attributes(:running, _changeset), do: %{}

  defp state_attributes(:waiting, changeset),
    do: %{
      blocked_on: Ash.Changeset.get_argument(changeset, :blocked_on) || :tools,
      lease_expires_at: nil
    }

  defp state_attributes(:failed, changeset),
    do: %{
      failure_class: Ash.Changeset.get_argument(changeset, :failure_class) || :permanent,
      error_code: Ash.Changeset.get_argument(changeset, :error_code),
      lease_expires_at: nil
    }

  defp state_attributes(_queued_or_completed, _changeset),
    do: %{blocked_on: nil, lease_expires_at: nil}

  defp append(changeset, context, run, after_seq, steps) do
    steps
    |> Enum.with_index(after_seq + 1)
    |> Enum.reduce_while(:ok, fn {step, seq}, :ok ->
      input =
        step
        |> Map.new(fn {key, value} -> {String.to_existing_atom(to_string(key)), value} end)
        |> Map.take([:role, :parts, :tool_calls, :prompt_fingerprint])
        |> Map.merge(%{run_id: run.id, seq: seq})

      changeset.resource
      |> Info.step()
      |> Ash.Changeset.for_create(
        :append,
        input,
        context
        |> Ash.Context.to_opts(tenant: changeset.tenant)
        |> Keyword.put(:context, %{ash_agent: %{run: run}})
      )
      |> Ash.create()
      |> case do
        {:ok, _step} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp invoke(_changeset, _context, _run, []), do: :ok

  defp invoke(changeset, context, run, calls) do
    identity = Info.execution_identity(changeset.resource)

    case identity.requester_for(run) do
      {:ok, requester} ->
        Enum.reduce_while(calls, :ok, fn call, :ok ->
          case invoke_one(changeset, context, run, requester, call) do
            :ok -> {:cont, :ok}
            {:error, error} -> {:halt, {:error, error}}
          end
        end)

      {:error, reason} ->
        {:error, AshAgent.Invocation.NoPrincipal.exception(reason: reason)}
    end
  end

  defp invoke_one(changeset, context, run, requester, call) do
    call = Map.new(call, fn {key, value} -> {to_string(key), value} end)

    changeset.resource
    |> Info.invocation()
    |> Ash.ActionInput.for_action(
      :invoke,
      %{
        target: call["target"],
        args: call["args"] || %{},
        key: Stepper.invocation_key(run, call["step_seq"], call["tool_call_id"]),
        parent: %{
          run_id: run.id,
          step_seq: call["step_seq"],
          tool_call_id: call["tool_call_id"]
        }
      },
      actor: requester,
      tenant: changeset.tenant,
      authorize?: context.authorize?
    )
    |> Ash.run_action()
    |> case do
      {:ok, row} ->
        if ExecutionIdentity.identity(row.executing_principal) ==
             ExecutionIdentity.identity(run.executing_principal),
           do: :ok,
           else:
             {:error,
              Ash.Error.Changes.InvalidChanges.exception(
                message: "a tool call would run as someone other than its run"
              )}

      {:error, error} ->
        {:error, error}
    end
  end

  defp after_outcome(changeset, %{status: :failed} = run) do
    case AshAgent.Run.Changes.CancelInvocations.cascade(changeset, run) do
      :ok -> {:ok, run}
      {:error, error} -> {:error, error}
    end
  end

  defp after_outcome(changeset, run), do: Enqueue.step(changeset, run)
end
