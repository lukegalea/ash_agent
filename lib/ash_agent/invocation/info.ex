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

  @doc "How many claims a row gets before a transient failure is final."
  @spec max_attempts(Ash.Resource.t() | Spark.Dsl.t()) :: pos_integer()
  def max_attempts(resource),
    do: Spark.Dsl.Extension.get_opt(resource, [:invocation], :max_attempts, 3)

  @doc "Whether `resource` declares the ash_oban trigger named `name`."
  @spec trigger?(Ash.Resource.t(), atom()) :: boolean()
  def trigger?(resource, name) do
    AshOban in Spark.extensions(resource) and
      Enum.any?(AshOban.Info.oban_triggers(resource), &(&1.name == name))
  end
end
