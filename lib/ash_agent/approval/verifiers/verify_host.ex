# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Approval.Verifiers.VerifyHost do
  @moduledoc """
  Checks that a resource including `AshAgent.Approval.PostureFragment` supplies both
  host options of its `approval_posture` section, and that its `tenant_attribute`
  names an attribute of the resource.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl) do
    module = Verifier.get_persisted(dsl, :module)

    [
      option(dsl, :authority, AshAgent.Approval.Authority),
      option(dsl, :execution_identity, AshAgent.ExecutionIdentity),
      tenant_attribute(dsl)
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

  # The tenant the Authority is asked about for a posture change is read from the
  # row: the attribute named, or the primary key when it is a single attribute.
  defp tenant_attribute(dsl) do
    named = Verifier.get_option(dsl, [:approval_posture], :tenant_attribute)

    cond do
      is_nil(named) and match?([_single], Ash.Resource.Info.primary_key(dsl)) ->
        []

      is_nil(named) ->
        {[:approval_posture, :tenant_attribute],
         "this resource has no single-attribute primary key, so none says which tenant a row " <>
           "is: name the attribute whose value is the tenant its AshAgent.Approval.Authority " <>
           "is asked about, `approval_posture do tenant_attribute :my_attribute end`"}

      Ash.Resource.Info.attribute(dsl, named) ->
        []

      true ->
        {[:approval_posture, :tenant_attribute],
         "`#{inspect(named)}` is not an attribute of this resource: `tenant_attribute` names " <>
           "the attribute whose value is the tenant its AshAgent.Approval.Authority is asked about"}
    end
  end
end
