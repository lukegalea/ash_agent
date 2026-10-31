# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Run.Info do
  @moduledoc "Reads what a host supplied in its `run` section."

  @doc "The host's agent version resource."
  @spec agent_version(Ash.Resource.t() | Spark.Dsl.t()) :: Ash.Resource.t() | nil
  def agent_version(resource), do: Spark.Dsl.Extension.get_opt(resource, [:run], :agent_version)

  @doc "The host's step resource."
  @spec step(Ash.Resource.t() | Spark.Dsl.t()) :: Ash.Resource.t() | nil
  def step(resource), do: Spark.Dsl.Extension.get_opt(resource, [:run], :step)

  @doc "The host's invocation resource."
  @spec invocation(Ash.Resource.t() | Spark.Dsl.t()) :: Ash.Resource.t() | nil
  def invocation(resource), do: Spark.Dsl.Extension.get_opt(resource, [:run], :invocation)

  @doc "The host's `AshAgent.Runtime` implementation."
  @spec runtime(Ash.Resource.t() | Spark.Dsl.t()) :: module() | nil
  def runtime(resource), do: Spark.Dsl.Extension.get_opt(resource, [:run], :runtime)

  @doc "The host's `AshAgent.ExecutionIdentity`: its invocation resource's."
  @spec execution_identity(Ash.Resource.t()) :: module()
  def execution_identity(resource),
    do: AshAgent.Invocation.Info.execution_identity(invocation(resource))
end
