# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Effects.Verifiers.VerifyToolsDeclared do
  @moduledoc """
  Checks that every ash_ai tool a domain exposes, declared on the domain or on one
  of its resources, names an action with an `AshAgent.Effects` declaration. See
  `AshAgent.Effects.Domain` for when that is an error and when a warning.
  """

  use Spark.Dsl.Verifier

  alias AshAgent.Effects.Info
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl) do
    module = Verifier.get_persisted(dsl, :module)

    {errors, warnings} =
      dsl
      |> tools()
      |> Enum.reject(&Info.declared?(&1.resource, &1.action))
      |> Enum.split_with(&Info.uses_effects?(&1.resource))

    case {errors, warnings} do
      {[], []} ->
        :ok

      {[], warnings} ->
        {:warn, Enum.map(warnings, &{message(&1), Spark.Dsl.Entity.anno(&1)})}

      {errors, _warnings} ->
        {:error, Enum.map(errors, &error(module, &1))}
    end
  end

  defp tools(dsl) do
    resource_tools =
      for resource <- Ash.Domain.Info.resources(dsl),
          AshAi in Spark.extensions(resource),
          tool <- AshAi.Info.tools(resource),
          do: tool

    AshAi.Info.tools(dsl) ++ resource_tools
  end

  defp error(module, tool) do
    DslError.exception(
      module: module,
      path: [:tools, tool.name],
      message:
        message(tool) <>
          ". #{inspect(tool.resource)} declares effects, so every action it exposes must be declared.",
      location: Spark.Dsl.Entity.anno(tool)
    )
  end

  defp message(tool) do
    "tool #{inspect(tool.name)} exposes #{inspect(tool.resource)}.#{tool.action}, " <>
      "which has no effects declaration"
  end
end
