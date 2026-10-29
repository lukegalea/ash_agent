# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.Verifiers.VerifyHost do
  @moduledoc """
  Checks that a resource including `AshAgent.Invocation` supplies what the fragment needs:
  both options of the `invocation` section, and, when it uses `AshOban`, a trigger named
  `:execute` that runs the `:execute` action.
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
      execute_trigger(dsl)
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

  defp execute_trigger(dsl) do
    if AshOban in Spark.extensions(dsl) do
      case Enum.find(AshOban.Info.oban_triggers(dsl), &(&1.name == :execute)) do
        %{action: :execute} ->
          []

        nil ->
          {[:oban, :triggers],
           "an invocation resource using AshOban must declare a trigger named :execute " <>
             "running the :execute action; request enqueues it for every ready row"}

        %{action: action} ->
          {[:oban, :triggers, :execute],
           "the :execute trigger must run the :execute action, not #{inspect(action)}"}
      end
    else
      []
    end
  end
end
