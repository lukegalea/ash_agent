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

  @doc """
  The host's resource that includes `AshAgent.Invocation`, through which a posture
  change approved under four eyes arrives, or `nil` when the host names none.
  """
  @spec invocation(Ash.Resource.t() | Spark.Dsl.t()) :: module() | nil
  def invocation(resource),
    do: Spark.Dsl.Extension.get_opt(resource, [:approval_posture], :invocation)

  @doc """
  The attribute of the row whose value is the tenant the `authority` is asked
  about for a posture change: the `tenant_attribute` the host named, or the
  resource's primary key when that is a single attribute. `nil` when the host
  named none and the primary key is not one attribute.
  """
  @spec tenant_attribute(Ash.Resource.t() | Spark.Dsl.t()) :: atom() | nil
  def tenant_attribute(resource) do
    case Spark.Dsl.Extension.get_opt(resource, [:approval_posture], :tenant_attribute) do
      nil ->
        case Ash.Resource.Info.primary_key(resource) do
          [single] -> single
          _not_one -> nil
        end

      attribute ->
        attribute
    end
  end
end
