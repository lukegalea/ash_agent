# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.Verifiers.VerifyHost do
  @moduledoc """
  Checks that a resource including `AshAgent.Invocation` supplies what the fragment needs:
  both host options of the `invocation` section, and, when it uses `AshOban`, triggers
  named `:execute` and `:reconcile` that run the actions of the same names.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl) do
    module = Verifier.get_persisted(dsl, :module)

    [
      option(dsl, :execution_identity, AshAgent.ExecutionIdentity),
      option(dsl, :digest_key, AshAgent.DigestKey),
      trigger(dsl, :execute, "request enqueues it for every ready row"),
      trigger(dsl, :reconcile, "it settles rows whose lease expired or whose outcome is unknown")
    ]
    |> List.flatten()
    |> Enum.map(fn {path, message} ->
      DslError.exception(module: module, path: path, message: message)
    end)
    |> case do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp option(dsl, name, behaviour) do
    if Verifier.get_option(dsl, [:invocation], name) do
      []
    else
      {[:invocation, name],
       "an invocation resource must name its #{inspect(behaviour)} implementation: " <>
         "`invocation do #{name} MyApp.Module end`"}
    end
  end

  defp trigger(dsl, name, why) do
    if AshOban in Spark.extensions(dsl) do
      case Enum.find(AshOban.Info.oban_triggers(dsl), &(&1.name == name)) do
        %{action: ^name} ->
          []

        nil ->
          {[:oban, :triggers],
           "an invocation resource using AshOban must declare a trigger named #{inspect(name)} " <>
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
