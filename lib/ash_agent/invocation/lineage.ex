# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.Lineage do
  @moduledoc """
  The `parent` of a request, as the lineage columns it is stored in.

  A parent says what work a request belongs to:

    * `invocation_id`: another invocation, stored as `parent_invocation_id`;
    * `run_id`, with `step_seq` and `tool_call_id`: an agent run's tool call;
    * `process_instance_id`, with `process_node_id`: a process task.

  Keys may be atoms or strings. Anything else in the map is refused, so a caller cannot
  smuggle a column through it. The host decides whether the requester may name that
  parent: the package only records it.
  """

  @fields %{
    "invocation_id" => {:parent_invocation_id, :uuid},
    "run_id" => {:run_id, :uuid},
    "step_seq" => {:step_seq, :integer},
    "tool_call_id" => {:tool_call_id, :string},
    "process_instance_id" => {:process_instance_id, :uuid},
    "process_node_id" => {:process_node_id, :string}
  }

  @doc "The lineage attributes of `parent`, every one present (nil when not given)."
  @spec from_parent(map() | nil) :: {:ok, map()} | {:error, String.t()}
  def from_parent(nil), do: from_parent(%{})

  def from_parent(parent) when is_map(parent) do
    empty = Map.new(@fields, fn {_key, {attribute, _type}} -> {attribute, nil} end)

    Enum.reduce_while(parent, {:ok, empty}, fn {key, value}, {:ok, acc} ->
      case Map.fetch(@fields, to_string(key)) do
        {:ok, {attribute, type}} ->
          case cast(type, value) do
            {:ok, value} -> {:cont, {:ok, Map.put(acc, attribute, value)}}
            :error -> {:halt, {:error, "parent #{key} is not a valid #{type}"}}
          end

        :error ->
          {:halt,
           {:error, "parent may name only #{Enum.join(Enum.sort(Map.keys(@fields)), ", ")}"}}
      end
    end)
  end

  def from_parent(_parent), do: {:error, "parent must be a map"}

  @doc "The lineage attributes, in the order they are compared."
  @spec attributes() :: [atom()]
  def attributes, do: @fields |> Map.values() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

  @doc "The kind of caller the lineage implies."
  @spec kind(map()) :: :tool_call | :process_task | :direct
  def kind(%{run_id: run_id}) when not is_nil(run_id), do: :tool_call
  def kind(%{process_instance_id: id}) when not is_nil(id), do: :process_task
  def kind(_lineage), do: :direct

  defp cast(_type, nil), do: {:ok, nil}

  defp cast(type, value) do
    case Ash.Type.cast_input(type, value, []) do
      {:ok, value} -> {:ok, value}
      _ -> :error
    end
  end
end
