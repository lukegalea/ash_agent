# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Run.Verifiers.VerifyHost do
  @moduledoc """
  Checks that a resource including `AshAgent.Run` supplies what the fragment needs: every
  option of the `run` section, and, when it uses `AshOban`, triggers named `:step` and
  `:recover` that run the actions of the same names.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @options [
    agent_version: "AshAgent.AgentVersion",
    step: "AshAgent.Step",
    invocation: "AshAgent.Invocation",
    runtime: "AshAgent.Runtime"
  ]

  @impl true
  def verify(dsl) do
    module = Verifier.get_persisted(dsl, :module)

    (Enum.map(@options, &option(dsl, &1)) ++
       [
         trigger(dsl, :step, "start and every step enqueue it for a run with work to do"),
         trigger(dsl, :recover, "it queues again a run whose worker died holding the lease")
       ])
    |> List.flatten()
    |> Enum.map(fn {path, message} ->
      DslError.exception(module: module, path: path, message: message)
    end)
    |> case do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp option(dsl, {name, what}) do
    if Verifier.get_option(dsl, [:run], name) do
      []
    else
      {[:run, name],
       "a run resource must name its #{what} module: `run do #{name} MyApp.Module end`"}
    end
  end

  defp trigger(dsl, name, why) do
    if AshOban in Spark.extensions(dsl) do
      case Enum.find(AshOban.Info.oban_triggers(dsl), &(&1.name == name)) do
        %{action: ^name} ->
          []

        nil ->
          {[:oban, :triggers],
           "a run resource using AshOban must declare a trigger named #{inspect(name)} " <>
             "running the #{inspect(name)} action; #{why}"}

        %{action: action} ->
          {[:oban, :triggers, name],
           "the #{inspect(name)} trigger must run the #{inspect(name)} action, not #{inspect(action)}"}
      end
    else
      []
    end
  end
end
