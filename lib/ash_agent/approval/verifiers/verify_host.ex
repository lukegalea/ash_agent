# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Approval.Verifiers.VerifyHost do
  @moduledoc """
  Checks that a resource including `AshAgent.Approval.PostureFragment` supplies both
  host options of its `approval_posture` section.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl) do
    module = Verifier.get_persisted(dsl, :module)

    [
      option(dsl, :authority, AshAgent.Approval.Authority),
      option(dsl, :execution_identity, AshAgent.ExecutionIdentity)
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
    if Verifier.get_option(dsl, [:approval_posture], name) do
      []
    else
      {[:approval_posture, name],
       "a resource including AshAgent.Approval.PostureFragment must name its #{inspect(behaviour)} " <>
         "implementation: `approval_posture do #{name} MyApp.Module end`"}
    end
  end
end
