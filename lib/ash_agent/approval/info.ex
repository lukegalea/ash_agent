# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Approval.Info do
  @moduledoc "Reads what a host supplied in its `approval_posture` section."

  @doc "The host's `AshAgent.Approval.Authority` implementation for `resource`."
  @spec authority(Ash.Resource.t() | Spark.Dsl.t()) :: module() | nil
  def authority(resource),
    do: Spark.Dsl.Extension.get_opt(resource, [:approval_posture], :authority)

  @doc """
  The host's `AshAgent.ExecutionIdentity` implementation for `resource`, whose
  `principal_of/1` maps the actor of a posture change to the person deciding it.
  """
  @spec execution_identity(Ash.Resource.t() | Spark.Dsl.t()) :: module() | nil
  def execution_identity(resource),
    do: Spark.Dsl.Extension.get_opt(resource, [:approval_posture], :execution_identity)
end
