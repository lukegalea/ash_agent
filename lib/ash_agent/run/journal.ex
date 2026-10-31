# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Run.Journal do
  @moduledoc """
  A run's conversation, read from and written to its steps.

  The conversation is the run's `input` as the first user message, then each step in
  `seq` order: a `:user` step as a user message, any other through ash_ai's
  `AshAi.Transcript.from_parts/1`. A step is one message, so a model turn and each of
  its tool results are separate steps, appended as they happen.
  """

  require Ash.Query

  alias AshAgent.Run.Info
  alias AshAi.Transcript
  alias ReqLLM.Context

  @doc "The steps of `run`, in order, with their parts readable."
  @spec steps(Ash.Resource.record(), keyword()) ::
          {:ok, [Ash.Resource.record()]} | {:error, term()}
  def steps(run, opts) do
    step = Info.step(run.__struct__)
    read_opts = [tenant: opts[:tenant], authorize?: false]

    step
    |> Ash.Query.filter(run_id == ^run.id)
    |> Ash.Query.sort(seq: :asc)
    |> Ash.read(read_opts)
    |> case do
      {:ok, steps} -> readable(steps, step, :parts, read_opts)
      {:error, error} -> {:error, error}
    end
  end

  @doc "The conversation `input` and `steps` make, as ReqLLM messages."
  @spec messages(String.t() | nil, [map()]) :: [ReqLLM.Message.t()]
  def messages(input, steps) do
    first = if is_binary(input) and input != "", do: [Context.user(input)], else: []

    first ++
      Enum.flat_map(steps, fn
        %{role: :user, parts: parts} -> [Context.user(Transcript.text(parts))]
        %{parts: parts} -> Transcript.from_parts(parts)
      end)
  end

  @doc "The `seq` of the step that made each tool call, by call id."
  @spec call_seqs([map()]) :: %{String.t() => pos_integer()}
  def call_seqs(steps) do
    for step <- steps, call <- step.tool_calls || [], into: %{} do
      {call["id"] || call[:id], step.seq}
    end
  end

  @doc "A step for `message`, a model turn or a tool result."
  @spec step(ReqLLM.Message.t(), String.t() | nil) :: map()
  def step(%ReqLLM.Message{} = message, fingerprint) do
    %{
      role: message.role,
      parts: Transcript.to_parts([message]),
      tool_calls:
        for call <- message.tool_calls || [] do
          %{"id" => call.id, "name" => call.function[:name] || call.function["name"]}
        end,
      prompt_fingerprint: fingerprint
    }
  end

  @doc "A tool result for the call `call_id`, as a message."
  @spec tool_result(String.t(), String.t()) :: ReqLLM.Message.t()
  def tool_result(call_id, content), do: Context.tool_result(call_id, content)

  @doc "A user message the run adds itself, as a step."
  @spec user_step(String.t()) :: map()
  def user_step(text),
    do: %{role: :user, parts: [%{"type" => "text", "text" => text}], tool_calls: []}

  @doc """
  `field` of `record`, readable: a host that seals it at rest turns the attribute into
  a calculation that opens it, which is loaded here.
  """
  @spec value(Ash.Resource.record(), atom(), keyword()) :: term()
  def value(record, field, opts) do
    if Ash.Resource.Info.attribute(record.__struct__, field) do
      Map.get(record, field)
    else
      record
      |> Ash.load!([field], tenant: opts[:tenant], authorize?: false)
      |> Map.get(field)
    end
  end

  defp readable(records, resource, field, opts) do
    if Ash.Resource.Info.attribute(resource, field),
      do: {:ok, records},
      else: Ash.load(records, [field], opts)
  end
end
