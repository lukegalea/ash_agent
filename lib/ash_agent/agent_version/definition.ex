# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.AgentVersion.Definition do
  @moduledoc """
  What an agent version is, as data: its toolset's digests, its content hash, what
  stops it being published, and whether a run pinned to it may carry on.

  Each function takes a version record (or, for `toolset/1` and `content_hash/1`, its
  attributes), so a host can ask about a version it read in any tenant.
  """

  alias AshAgent.AgentVersion.{DefinitionDrift, NotPublished}
  alias AshAgent.Invocation.Target

  @limits ~w(max_steps max_tool_calls deadline token_budget max_repairs)

  @doc """
  `entries` with each target's current digest: `%{"target" => name, "target_digest" =>
  digest}`, the digest `nil` when the target does not resolve (it names no loaded
  resource or action, or the action declares no effects). A digest supplied with an
  entry is ignored: it is always the target's own.
  """
  @spec toolset([map()]) :: [map()]
  def toolset(entries) do
    Enum.map(entries, fn entry ->
      name = target_name(entry)
      %{"target" => name, "target_digest" => current_digest(name)}
    end)
  end

  @doc """
  SHA-256 over the canonical JSON (RFC 8785) of a version's content: `instructions`,
  `model_profile`, `toolset` (names and digests, in order), `limits` and `output_type`.
  The key, the number and the publish-time choices are not content.
  """
  @spec content_hash(map()) :: String.t()
  def content_hash(%{__struct__: _} = version), do: version |> Map.from_struct() |> content_hash()

  def content_hash(content) do
    content
    |> Map.new(fn {field, value} -> {to_string(field), value} end)
    |> Map.take(~w(instructions model_profile toolset limits output_type))
    |> AshAgent.Digest.sha256_hex()
  end

  @doc """
  Why `version` cannot be published, as messages; `[]` when it can.

    * Every toolset target resolves to an action with an effects declaration: the
      target is resolved through `AshAgent.Invocation.Target.resolve/1`, which reads
      the declaration with `AshAgent.Effects.Info`. A target with no declaration
      cannot be governed, so an agent may not be offered it.
    * Every toolset target's digest is still the one the version was written with. A
      target that changed since needs the draft revised, so the version records what
      it now offers.
    * Every limit is set.
    * `output_type` names an Ash type (`AshAgent.Run.Output.type/1`), so a run can cast
      its answer.
    * No two toolset targets share a tool name (`AshAgent.Run.Toolset.tool_name/2`),
      so the model can tell them apart.
  """
  @spec publish_problems(map()) :: [String.t()]
  def publish_problems(version) do
    Enum.flat_map(version.toolset || [], &target_problems/1) ++
      limit_problems(version.limits) ++
      output_problems(version) ++ name_problems(version.toolset || [])
  end

  @doc """
  The toolset targets of `version` that are not what they were when it was written:
  `[%{"target" => name, "pinned" => digest, "current" => digest_or_nil}]`.
  """
  @spec drift(map()) :: [map()]
  def drift(version) do
    Enum.flat_map(version.toolset || [], fn entry ->
      entry = stringify_entry(entry)
      current = current_digest(entry["target"])

      if is_nil(current) or current != entry["target_digest"],
        do: [
          %{"target" => entry["target"], "pinned" => entry["target_digest"], "current" => current}
        ],
        else: []
    end)
  end

  @doc """
  Whether a run pinned to `version` may take its next step: the version is published or
  retired, and no toolset target has drifted (`drift/1`). A drifted target is
  `AshAgent.AgentVersion.DefinitionDrift`, whose `reason` is `:definition_drift`; a
  draft is `AshAgent.AgentVersion.NotPublished`.
  """
  @spec check_pinned(map()) :: {:ok, map()} | {:error, Exception.t()}
  def check_pinned(%{status: status} = version) when status in [:published, :retired] do
    case drift(version) do
      [] ->
        {:ok, version}

      drifted ->
        {:error,
         DefinitionDrift.exception(key: version.key, version: version.version, drifted: drifted)}
    end
  end

  def check_pinned(version),
    do:
      {:error,
       NotPublished.exception(key: version.key, version: version.version, status: version.status)}

  defp target_problems(entry) do
    entry = stringify_entry(entry)
    name = entry["target"]

    case Target.resolve(name) do
      {:error, message} ->
        ["toolset: #{message}"]

      {:ok, target} ->
        if Target.digest(target) == entry["target_digest"],
          do: [],
          else: [
            "toolset: #{name} has changed since this version was written " <>
              "(definition_drift); revise the draft"
          ]
    end
  end

  defp limit_problems(limits) do
    limits = stringify_entry(limits || %{})

    for limit <- @limits, is_nil(limits[limit]), do: "limits: #{limit} is not set"
  end

  defp output_problems(version) do
    case AshAgent.Run.Output.type(version.output_type) do
      {:ok, _type} -> []
      {:error, message} -> [message]
    end
  end

  defp name_problems(toolset) do
    toolset
    |> Enum.flat_map(fn entry ->
      case Target.resolve(target_name(entry)) do
        {:ok, target} ->
          [
            {AshAgent.Run.Toolset.tool_name(target.resource, target.action.name),
             target_name(entry)}
          ]

        {:error, _unresolvable} ->
          []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.filter(fn {_name, targets} -> length(targets) > 1 end)
    |> Enum.map(fn {name, targets} ->
      "toolset: #{Enum.join(targets, " and ")} would both be offered as #{name}"
    end)
  end

  defp current_digest(name) when is_binary(name) do
    case Target.resolve(name) do
      {:ok, target} -> Target.digest(target)
      {:error, _unresolvable} -> nil
    end
  end

  defp current_digest(_name), do: nil

  defp target_name(entry), do: stringify_entry(entry)["target"]

  defp stringify_entry(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
