# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Effects.Verifiers.VerifyDeclarations do
  @moduledoc """
  Checks each `effects` declaration against the resource's actions. See
  `AshAgent.Effects` for the rules.
  """

  use Spark.Dsl.Verifier

  alias AshAgent.Effects.Effect
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl) do
    module = Verifier.get_persisted(dsl, :module)

    dsl
    |> AshAgent.Effects.Info.effects()
    |> Enum.flat_map(fn effect ->
      effect
      |> problems(Ash.Resource.Info.action(dsl, effect.name), dsl)
      |> Enum.map(&error(module, effect, &1))
    end)
    |> case do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp problems(effect, nil, _dsl),
    do: ["declares effects for #{inspect(effect.name)}, which is not an action of this resource"]

  defp problems(effect, action, dsl) do
    [
      read_only(effect, action),
      approval(effect),
      reconcile_with(effect, dsl),
      preconditions(effect, action)
    ]
    |> List.flatten()
  end

  defp read_only(%Effect{read_only?: true} = effect, %{type: type}) when type != :read do
    "declares #{inspect(effect.name)} read_only?: true, but it is a #{inspect(type)} action. " <>
      "Only an Ash :read action is read-only."
  end

  defp read_only(_effect, _action), do: []

  defp approval(%Effect{approval: :four_eyes, approver_role: nil} = effect),
    do: "declares #{inspect(effect.name)} approval: :four_eyes without an approver_role"

  defp approval(%Effect{approval: :none} = effect) do
    for {option, value} <- [
          approver_role: effect.approver_role,
          approval_expires_in: effect.approval_expires_in
        ],
        not is_nil(value),
        do: "declares #{inspect(effect.name)} #{option} with approval: :none"
  end

  defp approval(_effect), do: []

  defp reconcile_with(%Effect{reconcile_with: nil}, _dsl), do: []

  defp reconcile_with(%Effect{reconcile_with: name} = effect, dsl) do
    case Ash.Resource.Info.action(dsl, name) do
      %{type: type} when type in [:read, :action] ->
        []

      nil ->
        "declares #{inspect(effect.name)} reconcile_with: #{inspect(name)}, which is not an action of this resource"

      %{type: type} ->
        "declares #{inspect(effect.name)} reconcile_with: #{inspect(name)}, a #{inspect(type)} action. " <>
          "Reconciliation reads, so it must be a :read or generic action."
    end
  end

  defp preconditions(effect, action) do
    inputs = Enum.map(action.arguments, & &1.name) ++ Map.get(action, :accept, [])

    for name <- effect.preconditions, name not in inputs do
      "declares #{inspect(effect.name)} precondition #{inspect(name)}, which is not an input of the action"
    end
  end

  defp error(module, effect, message) do
    DslError.exception(
      module: module,
      path: [:effects, :action, effect.name],
      message: message,
      location: Spark.Dsl.Entity.anno(effect)
    )
  end
end
