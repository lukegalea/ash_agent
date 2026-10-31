# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Run.Toolset do
  @moduledoc """
  The tools a step offers the model: its pinned version's toolset, as ash_ai builds them
  (`AshAi.Tools.build/2` over each target's action, the schema the target's digest was
  taken over).

  Each tool is one of two kinds, decided by its action, never by a hint:

    * **in-loop**: an Ash `:read` action whose effects declaration does not reach outside
      (`open_world?: false`). It runs inside the tool loop as the executing actor, under
      that actor's policies. It is offered only when the actor may run it (`Ash.can?`).
    * **governed**: anything else. The loop is never allowed to run it: the approval
      rule answers `:ask`, the loop stops, and the call becomes an invocation.

  A call naming a tool the step did not offer is refused in the loop.

  A tool's name is its resource's last module segment and its action, in snake case:
  `CredentialCheck.record` is `credential_check_record`.
  """

  alias AshAgent.Invocation.Target

  defstruct tools: [], extra_tools: [], by_name: %{}

  @type tool :: %{
          name: String.t(),
          target: String.t(),
          resolved: map(),
          in_loop?: boolean(),
          callback: (map(), map() -> term())
        }

  @type t :: %__MODULE__{
          tools: [ReqLLM.Tool.t()],
          extra_tools: list(),
          by_name: %{String.t() => tool()}
        }

  @doc "The tools `version` offers `actor` in `tenant`."
  @spec build(map(), term(), term()) :: t()
  def build(version, actor, tenant) do
    tools =
      for entry <- version.toolset || [],
          name = entry["target"] || entry[:target],
          {:ok, target} <- [Target.resolve(name)],
          tool = tool(name, target),
          offered?(tool, actor, tenant),
          do: tool

    %__MODULE__{
      tools: Enum.map(tools, & &1.req_llm),
      extra_tools: Enum.map(tools, &{&1.req_llm, loop_callback(&1)}),
      by_name: Map.new(tools, &{&1.name, Map.delete(&1, :req_llm)})
    }
  end

  @doc "The tool's name for the target `resource.action`."
  @spec tool_name(Ash.Resource.t(), atom()) :: String.t()
  def tool_name(resource, action) do
    short = resource |> Module.split() |> List.last() |> Macro.underscore()
    "#{short}_#{action}"
  end

  @doc "The tool named `name`, or nil."
  @spec lookup(t(), String.t()) :: tool() | nil
  def lookup(%__MODULE__{by_name: by_name}, name), do: Map.get(by_name, name)

  @doc """
  The approval rule the loop asks for every call: `:ok` for an in-loop read, `:ask` for a
  governed tool, a denial for a tool the step did not offer.
  """
  @spec approver(t()) :: (map(), map() -> :ok | :ask | {:deny, String.t()})
  def approver(toolset) do
    fn call, _context ->
      case lookup(toolset, call.name) do
        %{in_loop?: true} -> :ok
        %{in_loop?: false} -> :ask
        nil -> {:deny, "this tool is not offered"}
      end
    end
  end

  @doc """
  The arguments to request a governed call with: the action's inputs (ash_ai sends them
  under `"input"`) and, for an update or destroy, the record's primary key beside them.
  """
  @spec args(tool(), map() | String.t()) :: map()
  def args(tool, arguments) do
    arguments = decode(arguments)
    input = arguments["input"] || %{}

    if tool.resolved.action.type in [:update, :destroy] do
      keys = tool.resolved.resource |> Ash.Resource.Info.primary_key() |> Enum.map(&to_string/1)
      Map.merge(input, Map.take(arguments, keys))
    else
      input
    end
  end

  @doc "Runs an in-loop read for `call` as `actor`, returning the result's text."
  @spec run_read(tool(), map(), term(), term()) :: String.t()
  def run_read(%{in_loop?: true} = tool, call, actor, tenant) do
    case tool.callback.(decode(call.arguments), %{actor: actor, tenant: tenant, context: %{}}) do
      {:ok, content, _raw} -> content
      {:error, content} -> content
    end
  end

  defp tool(name, target) do
    action = target.action
    in_loop? = action.type == :read and not target.effect.open_world?

    {req_llm, callback} =
      AshAi.Tools.build(%AshAi.Tool{
        name: tool_name(target.resource, action.name),
        resource: target.resource,
        action: action,
        domain: Ash.Resource.Info.domain(target.resource),
        arguments: [],
        load: []
      })

    %{
      name: req_llm.name,
      target: name,
      resolved: target,
      in_loop?: in_loop?,
      callback: callback,
      req_llm: req_llm
    }
  end

  defp offered?(%{in_loop?: false}, _actor, _tenant), do: true

  defp offered?(%{in_loop?: true, resolved: target}, actor, tenant),
    do: Ash.can?({target.resource, target.action.name}, actor, tenant: tenant, maybe_is: true)

  # The loop takes `{:ok, content}` from a tool it is handed; ash_ai's own callback also
  # returns the raw result. A governed tool must never run in the loop: the approval rule
  # keeps the loop from calling it, and this is the second wall.
  defp loop_callback(%{in_loop?: true, callback: callback}) do
    fn arguments, context ->
      case callback.(arguments, context) do
        {:ok, content, _raw} -> {:ok, content}
        other -> other
      end
    end
  end

  defp loop_callback(%{in_loop?: false, name: name}) do
    fn _arguments, _context -> raise "#{name} is governed and cannot run inside the tool loop" end
  end

  defp decode(arguments) when is_map(arguments), do: arguments

  defp decode(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _other -> %{}
    end
  end

  defp decode(_arguments), do: %{}
end
