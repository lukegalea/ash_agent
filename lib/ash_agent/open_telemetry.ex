# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.OpenTelemetry do
  @moduledoc """
  The span a run's step and an invocation's execution are reported as, in the
  OpenTelemetry GenAI semantic conventions. Pure: it names spans and builds their
  attributes, and never starts one. The package depends on no OpenTelemetry library;
  a host that exports traces attaches a `:telemetry` handler to the events below and
  starts its spans from what this module returns.

  ## The pinned version

  Every name here is taken from **semantic conventions v1.41.0** (`version/0`,
  `schema_url/0`), the last release of `open-telemetry/semantic-conventions` that
  carries the GenAI conventions before they moved to their own repository:

    * agent spans: https://github.com/open-telemetry/semantic-conventions/blob/v1.41.0/docs/gen-ai/gen-ai-agent-spans.md
    * execute tool span: https://github.com/open-telemetry/semantic-conventions/blob/v1.41.0/docs/gen-ai/gen-ai-spans.md#execute-tool-span

  The GenAI conventions have Development status, so names can change between
  releases. They change here, in one module, when the pin moves.

  ## The events

  Both are `:telemetry.span/3` events (`:start`, then `:stop` or `:exception`), emitted
  in the process doing the work:

    * `[:ash_agent, :run, :step]`: a step of a run this worker claimed
      (`AshAgent.Run.Stepper`), inside the host's `c:AshAgent.Runtime.around_step/2`, so
      it runs under the trace context the host restored there. Metadata: `run` (the
      claimed row) and `agent_version` (the version it runs, or nil). `:stop` adds
      `result`, what the step returned.
    * `[:ash_agent, :invocation, :execute]`: running an invocation this worker claimed
      (`AshAgent.Invocation.Executor`). Metadata: `invocation` (the claimed row); `:stop`
      adds `result`.

  A job that claims nothing (another worker holds the row, or it has nothing to do)
  emits neither.

  ## What a span carries

    * a step: `invoke_agent {agent key}`, kind internal, with `gen_ai.operation.name`
      `invoke_agent`, `gen_ai.provider.name` (the host's, from `step/3`'s `:provider`),
      `gen_ai.agent.name` (the agent key), `gen_ai.agent.version` (the version's
      `content_hash`, the digest a release lists it under) and `gen_ai.conversation.id`
      (the run id);
    * an invocation: `execute_tool {target}`, kind internal, with `gen_ai.operation.name`
      `execute_tool`, `gen_ai.tool.name` (the target), `gen_ai.tool.type` `function` and,
      for a run's tool call, `gen_ai.tool.call.id` and `gen_ai.conversation.id`.

  Nothing the conventions mark Opt-In is ever built: no instructions, messages, tool
  arguments or results. A value this module does not have is left out, never filled
  with a placeholder.

  ## Status

  `status/2` reads a result as `:ok` only when it is one of the outcomes that finished
  the work (`ok_outcomes/1`). Any other outcome, an error, or a result it does not
  recognise is an error with an `error.type`, so nothing unknown reads as a success.
  """

  @version "1.41.0"
  @schema_url "https://opentelemetry.io/schemas/1.41.0"

  @operation "gen_ai.operation.name"
  @provider "gen_ai.provider.name"
  @agent_name "gen_ai.agent.name"
  @agent_version "gen_ai.agent.version"
  @conversation "gen_ai.conversation.id"
  @tool_name "gen_ai.tool.name"
  @tool_type "gen_ai.tool.type"
  @tool_call_id "gen_ai.tool.call.id"
  @error_type "error.type"
  @other "_OTHER"

  @step_ok [:completed, :waiting, :queued]
  @tool_ok [:succeeded, :dispatched]

  @typedoc "A span to start: its name, kind and attributes."
  @type span :: %{name: String.t(), kind: :internal, attributes: %{String.t() => term()}}

  @doc "The semantic conventions version every name here is taken from."
  @spec version() :: String.t()
  def version, do: @version

  @doc "The schema URL of `version/0`, for the tracer that starts these spans."
  @spec schema_url() :: String.t()
  def schema_url, do: @schema_url

  @doc "The telemetry event prefixes this package emits spans for."
  @spec events() :: [[atom()]]
  def events, do: [[:ash_agent, :run, :step], [:ash_agent, :invocation, :execute]]

  @doc """
  The span for a step of `run` on `agent_version` (nil when unknown). `opts`:
  `:provider`, the `gen_ai.provider.name` the host's model is under.
  """
  @spec step(Ash.Resource.record(), Ash.Resource.record() | nil, keyword()) :: span()
  def step(run, agent_version, opts \\ []) do
    key = run.agent_key

    %{
      name: name("invoke_agent", key),
      kind: :internal,
      attributes:
        compact(%{
          @operation => "invoke_agent",
          @provider => opts[:provider],
          @agent_name => key,
          @agent_version => agent_version && agent_version.content_hash,
          @conversation => run.id
        })
    }
  end

  @doc "The span for executing `invocation`."
  @spec tool(Ash.Resource.record()) :: span()
  def tool(invocation) do
    %{
      name: name("execute_tool", invocation.target),
      kind: :internal,
      attributes:
        compact(%{
          @operation => "execute_tool",
          @tool_name => invocation.target,
          @tool_type => "function",
          @tool_call_id => invocation.tool_call_id,
          @conversation => invocation.run_id
        })
    }
  end

  @doc "The outcomes of `:step` or `:tool` that read as `:ok`."
  @spec ok_outcomes(:step | :tool) :: [atom()]
  def ok_outcomes(:step), do: @step_ok
  def ok_outcomes(:tool), do: @tool_ok

  @doc """
  How a span of `kind` (`:step` or `:tool`) ends, given what the work returned:
  `:ok`, or `{:error, attributes}` carrying `error.type`. The outcome is the error type
  for an outcome that is not ok; an exception's module name for an exception or an
  error that is one; `_OTHER` for anything else.
  """
  @spec status(:step | :tool, term()) :: :ok | {:error, %{String.t() => String.t()}}
  def status(kind, {:ok, outcome}) when is_atom(outcome) and not is_nil(outcome) do
    if outcome in ok_outcomes(kind), do: :ok, else: error(Atom.to_string(outcome))
  end

  def status(_kind, {:error, %{__exception__: true} = exception}),
    do: error(inspect(exception.__struct__))

  def status(_kind, %{__exception__: true} = exception), do: error(inspect(exception.__struct__))
  def status(_kind, _other), do: error(@other)

  defp error(type), do: {:error, %{@error_type => type}}

  defp name(operation, subject) when is_binary(subject) and subject != "",
    do: operation <> " " <> subject

  defp name(operation, _subject), do: operation

  defp compact(attributes), do: Map.reject(attributes, fn {_key, value} -> is_nil(value) end)
end
