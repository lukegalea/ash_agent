# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Run.Stepper do
  @moduledoc """
  One step of a run: claim, commit, call the model once, record under the fence.

    1. **Claim** (`claim/3`, its own transaction): only a run that has a step to take
       (`needs_step`) is claimed, and of two jobs for one run one claims; the other ends
       with `:skipped` before any model call. The claim may instead end the run
       (deadline, drift) or park it (limits, budget); see
       `AshAgent.Run.Changes.ClaimStep`.
    2. **Rebuild**: the executing actor afresh
       (`c:AshAgent.ExecutionIdentity.actor_for/1` with the run), the toolset
       (`AshAgent.Run.Toolset`) and the conversation (`AshAgent.Run.Journal`). A
       principal with no authority now fails the run as `:denied`, with `error_code`
       `"no_authority"` (followed by the host's reason when it is an atom).
    3. **Tool results**: a model turn whose calls have no result yet gets them before
       any model call. A governed call's invocation is read by its key: a finished one
       gives its recorded result (its effect is never run again); an open one makes the
       run wait; a missing one (the worker died before it was requested) is requested
       now, and the run waits. An in-loop read is run again. Results are recorded as
       steps under the fence.
    4. **Model call**, with no transaction open: `AshAi.ToolLoop.stream/2` once
       (`max_iterations: 1`), with the host's model (`AshAgent.Runtime`), the version's
       instructions as the system prompt, and `AshAgent.Run.Toolset.approver/1` as the
       approval rule. Each message the loop emits is recorded as a step under the fence
       as it arrives, so a worker that dies mid-call loses only what was not yet emitted.
       When the instructions or tools changed since the last call (the
       `prompt_fingerprint` differs), the replayed turns' reasoning is left out, as
       `AshAi.Transcript` says it must be.
    5. **Record** (`record_step`, fenced): the loop stopped for governed calls: they are
       requested and the run waits on them. The loop ran reads and hit its iteration
       limit: the run is queued for its next step. The model answered: the answer is
       cast to the version's `output_type` (`AshAgent.Run.Output`) and completes the run,
       or, when it does not cast, the run gets a repair turn (up to `max_repairs`) and is
       queued, and past that fails as `:rejected` with `"output_uncastable"`.

  A model call that fails, or a profile the host cannot use now, records nothing more:
  the run stays `running` until its lease expires and `recover` queues it again. A
  record refused because the lease moved on ends the step as `:superseded`, having
  changed nothing.

  Every function returns `{:ok, outcome}` with `outcome` one of `outcomes/0`.
  `opts` carry the actor and tenant the run's rows are read and written with: the
  machinery's.
  """

  require Ash.Query
  require Logger

  alias AshAgent.Invocation.Failure
  alias AshAgent.Run.{Info, Journal, Output, Toolset}

  @outcomes [
    :completed,
    :waiting,
    :queued,
    :failed,
    :cancelled,
    :skipped,
    :superseded,
    :interrupted
  ]

  @final_invocation [:succeeded, :failed, :rejected, :stale, :cancelled]

  @type outcome ::
          :completed
          | :waiting
          | :queued
          | :failed
          | :cancelled
          | :skipped
          | :superseded
          | :interrupted

  @doc "Every outcome `step/3` can return."
  @spec outcomes() :: [outcome()]
  def outcomes, do: @outcomes

  @doc "The key of the invocation for a tool call: `run:<run id>:<step seq>:<tool call id>`."
  @spec invocation_key(Ash.Resource.record(), integer(), String.t()) :: String.t()
  def invocation_key(run, step_seq, tool_call_id), do: "run:#{run.id}:#{step_seq}:#{tool_call_id}"

  @doc "Takes one step of the run with id `id`, if it has one to take. The `step` action's job."
  @spec step(Ash.Resource.t(), Ash.UUID.t(), keyword()) :: {:ok, outcome()} | {:error, term()}
  def step(resource, id, opts) do
    case due(resource, id, opts) do
      {:ok, nil} ->
        {:ok, :skipped}

      {:ok, run} ->
        case claim(run, opts) do
          {:ok, %{status: :running} = claimed} ->
            around(claimed, fn -> run_claimed(claimed, opts) end)

          {:ok, %{status: status}} ->
            {:ok, status}

          {:error, :not_claimable} ->
            {:ok, :skipped}

          {:error, error} ->
            {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  @doc "The run with id `id` when it has a step to take now (`needs_step`), else nil."
  @spec due(Ash.Resource.t(), Ash.UUID.t(), keyword()) ::
          {:ok, Ash.Resource.record() | nil} | {:error, term()}
  def due(resource, id, opts) do
    resource
    |> Ash.Query.filter(id == ^id and needs_step == true)
    |> Ash.read_one(opts)
  end

  @doc """
  Claims `run` for one step. `claim_opts` may set `:lease_for` in milliseconds.
  `{:error, :not_claimable}` when another claim took it first, or it waits on what only
  its host can lift.
  """
  @spec claim(Ash.Resource.record(), keyword(), keyword()) ::
          {:ok, Ash.Resource.record()} | {:error, :not_claimable | term()}
  def claim(run, opts, claim_opts \\ []) do
    run
    |> Ash.Changeset.for_update(
      :claim_step,
      Map.new(Keyword.take(claim_opts, [:lease_for])),
      opts
    )
    |> Ash.update()
    |> case do
      {:ok, claimed} -> {:ok, claimed}
      {:error, error} -> if lost?(error), do: {:error, :not_claimable}, else: {:error, error}
    end
  end

  @doc "Takes the step of a run this worker claimed."
  @spec run_claimed(Ash.Resource.record(), keyword()) :: {:ok, outcome()} | {:error, term()}
  def run_claimed(run, opts) do
    version = run.__metadata__[:agent_version] || version!(run, opts)

    case Info.execution_identity(run.__struct__).actor_for(run) do
      {:ok, actor} ->
        toolset = Toolset.build(version, actor, opts[:tenant])

        with {:ok, steps} <- Journal.steps(run, opts) do
          messages = Journal.messages(Journal.value(run, :input, opts), steps)
          results(run, version, toolset, actor, messages, steps, opts)
        end

      {:error, reason} ->
        fail(run, :denied, no_authority(reason), opts)
    end
  end

  # --- tool results --------------------------------------------------------

  defp results(run, version, toolset, actor, messages, steps, opts) do
    seqs = Journal.call_seqs(steps)

    settled =
      messages
      |> AshAi.ToolLoop.pending_tool_calls()
      |> Enum.reduce(%{results: [], invoke: [], open?: false}, fn call, acc ->
        settle(call, acc, run, toolset, actor, seqs, opts)
      end)

    result_steps = Enum.map(settled.results, &Journal.step(&1, nil))

    cond do
      settled.invoke != [] or settled.open? ->
        record(
          run,
          %{
            steps: result_steps,
            invocations: settled.invoke,
            outcome: :waiting,
            blocked_on: :tools
          },
          opts
        )

      settled.results == [] ->
        call_model(run, version, toolset, actor, messages, opts)

      true ->
        case record_step(run, %{steps: result_steps, outcome: :running}, opts) do
          {:ok, run} ->
            call_model(run, version, toolset, actor, messages ++ settled.results, opts)

          {:stop, result} ->
            result
        end
    end
  end

  defp settle(call, acc, run, toolset, actor, seqs, opts) do
    case Toolset.lookup(toolset, call.name) do
      %{in_loop?: true} = tool ->
        add_result(acc, call.id, Toolset.run_read(tool, call, actor, opts[:tenant]))

      %{in_loop?: false} = tool ->
        seq = Map.get(seqs, call.id)

        case invocation(run, invocation_key(run, seq, call.id), opts) do
          nil ->
            %{
              acc
              | invoke: acc.invoke ++ [request(tool, call, seq)]
            }

          %{status: status} = row when status in @final_invocation ->
            add_result(acc, call.id, content(row, opts))

          _open ->
            %{acc | open?: true}
        end

      nil ->
        add_result(acc, call.id, Jason.encode!(%{error: "this tool is not offered"}))
    end
  end

  defp add_result(acc, call_id, content),
    do: %{acc | results: acc.results ++ [Journal.tool_result(call_id, content)]}

  defp request(tool, call, seq) do
    %{
      tool_call_id: call.id,
      step_seq: seq,
      target: tool.target,
      args: Toolset.args(tool, call.arguments)
    }
  end

  defp invocation(run, key, opts) do
    run.__struct__
    |> Info.invocation()
    |> Ash.Query.filter(invocation_key == ^key)
    |> Ash.read_one!(tenant: opts[:tenant], authorize?: false)
  end

  # What a finished invocation tells the model: the record it touched or the value it
  # returned, or that it did not run and why.
  defp content(%{status: :succeeded} = row, opts),
    do: Jason.encode!(Journal.value(row, :result, opts) || %{})

  defp content(row, _opts) do
    reason = Enum.join(Enum.reject([row.status, row.error_code], &is_nil/1), ": ")
    Jason.encode!(%{error: "not run: #{reason}"})
  end

  # --- model call ----------------------------------------------------------

  defp call_model(run, version, toolset, actor, messages, opts) do
    runtime = Info.runtime(run.__struct__)
    caller = "run:#{run.id}:#{run.step_seq + 1}"

    case runtime.loop_options(version, run, caller) do
      {:ok, loop_opts} ->
        fingerprint = AshAi.Transcript.fingerprint(version.instructions, toolset.tools)

        messages =
          if run.prompt_fingerprint in [nil, fingerprint],
            do: messages,
            else: AshAi.Transcript.strip_reasoning(messages)

        loop_opts =
          Keyword.merge(loop_opts,
            tools: false,
            extra_tools: toolset.extra_tools,
            system_prompt: fn _opts -> version.instructions end,
            approve_tool_call: Toolset.approver(toolset),
            max_iterations: 1,
            actor: actor,
            tenant: opts[:tenant],
            context: %{ash_agent: %{run_id: run.id}}
          )

        stream(run, version, toolset, messages, loop_opts, fingerprint, opts)

      {:error, reason} ->
        Logger.warning("agent run #{run.id}: no model to call: #{inspect(reason)}")
        {:ok, :interrupted}
    end
  end

  defp stream(run, version, toolset, messages, loop_opts, fingerprint, opts) do
    acc = %{run: run, error: nil, limit?: false, turn_seq: nil}

    messages
    |> AshAi.ToolLoop.stream(loop_opts)
    |> Enum.reduce_while(acc, fn
      {:message, message}, acc ->
        case record_step(
               acc.run,
               %{steps: [Journal.step(message, fingerprint)], outcome: :running},
               opts
             ) do
          {:ok, run} ->
            seq = if message.role == :assistant, do: run.step_seq, else: acc.turn_seq
            {:cont, %{acc | run: run, turn_seq: seq}}

          {:stop, result} ->
            {:halt, {:stopped, result}}
        end

      {:error, :max_iterations_reached}, acc ->
        {:cont, %{acc | limit?: true}}

      {:error, reason}, acc ->
        {:cont, %{acc | error: reason}}

      {:done, result}, acc ->
        {:halt, {:done, result, acc}}

      _event, acc ->
        {:cont, acc}
    end)
    |> case do
      {:done, result, acc} -> finish(acc, result, version, toolset, fingerprint, opts)
      {:stopped, result} -> result
      %{} -> {:ok, :interrupted}
    end
  rescue
    error ->
      Logger.error(
        "agent run #{run.id}: model call raised: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      {:ok, :interrupted}
  end

  defp finish(%{error: error}, _result, _version, _toolset, _fingerprint, _opts)
       when not is_nil(error) do
    {:ok, :interrupted}
  end

  defp finish(acc, result, version, toolset, fingerprint, opts) do
    counts = %{
      model_calls: 1,
      tool_calls: length(result.tool_calls_made || []),
      tokens: tokens(result.usage),
      prompt_fingerprint: fingerprint
    }

    cond do
      result.status == :awaiting_approval ->
        calls =
          Enum.map(result.pending_approvals, fn call ->
            request(Toolset.lookup(toolset, call.name), call, acc.turn_seq)
          end)

        record(
          acc.run,
          Map.merge(counts, %{invocations: calls, outcome: :waiting, blocked_on: :tools}),
          opts
        )

      acc.limit? ->
        record(acc.run, Map.put(counts, :outcome, :queued), opts)

      result.status == :complete ->
        answer(acc.run, version, result.final_text, counts, opts)

      true ->
        {:ok, :interrupted}
    end
  end

  defp answer(run, version, text, counts, opts) do
    case Output.cast(text, version.output_type) do
      {:ok, output} ->
        record(run, Map.merge(counts, %{outcome: :completed, output: output}), opts)

      {:error, reason} ->
        if run.repair_count < max_repairs(version) do
          repair = Journal.user_step(Output.repair_prompt(reason, version.output_type))
          record(run, Map.merge(counts, %{steps: [repair], outcome: :queued, repairs: 1}), opts)
        else
          record(
            run,
            Map.merge(counts, %{
              outcome: :failed,
              failure_class: :rejected,
              error_code: "output_uncastable"
            }),
            opts
          )
        end
    end
  end

  # --- records -------------------------------------------------------------

  # A record that ends the step: its outcome is the step's.
  defp record(run, input, opts) do
    case record_step(run, input, opts) do
      {:ok, recorded} -> {:ok, recorded.status}
      {:stop, result} -> result
    end
  end

  # `{:ok, run}` as recorded, or `{:stop, result}` with the step's result when the record
  # was refused: `:superseded` when the lease moved on; otherwise (a tool call that
  # cannot be requested, say) the run is failed with the error's class.
  defp record_step(run, input, opts) do
    case write(run, input, opts) do
      {:ok, recorded} ->
        {:ok, recorded}

      {:error, error} ->
        cond do
          lost?(error) -> {:stop, {:ok, :superseded}}
          input[:outcome] == :failed -> {:stop, {:error, error}}
          true -> {:stop, fail_with(run, error, opts)}
        end
    end
  end

  defp write(run, input, opts) do
    run
    |> Ash.Changeset.for_update(:record_step, Map.put(input, :epoch, run.lease_epoch), opts)
    |> Ash.update()
  end

  defp fail_with(run, error, opts) do
    {class, code} = Failure.classify(error)
    class = if class in AshAgent.Invocation.failure_classes(), do: class, else: :permanent

    fail(run, class, code, opts)
  end

  defp fail(run, class, code, opts),
    do: record(run, %{outcome: :failed, failure_class: class, error_code: code}, opts)

  # --- helpers -------------------------------------------------------------

  defp around(run, fun) do
    runtime = Info.runtime(run.__struct__)

    if function_exported?(runtime, :around_step, 2),
      do: runtime.around_step(run, fun),
      else: fun.()
  end

  defp version!(run, opts) do
    Ash.get!(Info.agent_version(run.__struct__), run.agent_version_id,
      tenant: opts[:tenant],
      authorize?: false
    )
  end

  defp max_repairs(version) do
    limits = Map.new(version.limits || %{}, fn {key, value} -> {to_string(key), value} end)
    limits["max_repairs"] || 0
  end

  defp tokens(usage) when is_map(usage) do
    Enum.reduce([:input_tokens, :output_tokens], 0, fn key, sum ->
      case Map.get(usage, key) do
        n when is_integer(n) -> sum + n
        _ -> sum
      end
    end)
  end

  defp tokens(_usage), do: 0

  defp no_authority(reason)
       when is_atom(reason) and not is_nil(reason) and not is_boolean(reason),
       do: String.slice("no_authority: #{reason}", 0, 256)

  defp no_authority(_reason), do: "no_authority"

  # A write that matched no row: the epoch or the journal moved on, the run was
  # cancelled, or another claim took it.
  defp lost?(%Ash.Error.Changes.StaleRecord{}), do: true

  defp lost?(%Ash.Error.Changes.InvalidAttribute{field: field})
       when field in [:status, :blocked_on] do
    true
  end

  defp lost?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &lost?/1)
  defp lost?(_error), do: false
end
