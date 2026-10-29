# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.Info do
  @moduledoc "Reads what a host supplied in its `invocation` section."

  @doc "The host's `AshAgent.ExecutionIdentity` implementation for `resource`."
  @spec execution_identity(Ash.Resource.t() | Spark.Dsl.t()) :: module() | nil
  def execution_identity(resource),
    do: Spark.Dsl.Extension.get_opt(resource, [:invocation], :execution_identity)

  @doc "The host's `AshAgent.DigestKey` implementation for `resource`."
  @spec digest_key(Ash.Resource.t() | Spark.Dsl.t()) :: module() | nil
  def digest_key(resource), do: Spark.Dsl.Extension.get_opt(resource, [:invocation], :digest_key)

  @doc "Whether `resource` declares the ash_oban trigger named `:execute`."
  @spec execute_trigger?(Ash.Resource.t()) :: boolean()
  def execute_trigger?(resource) do
    AshOban in Spark.extensions(resource) and
      Enum.any?(AshOban.Info.oban_triggers(resource), &(&1.name == :execute))
  end
end
