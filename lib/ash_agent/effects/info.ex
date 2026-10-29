# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Effects.Info do
  @moduledoc """
  Reads `AshAgent.Effects` declarations.

  An action with no declaration answers `nil`. What an undeclared action means is
  the caller's decision; the safe reading is MCP's defaults, which treat it as
  writing, destructive, not idempotent and open-world.
  """

  alias AshAgent.Effects.Effect

  @doc "Every effects declaration on `resource`, in declaration order."
  @spec effects(Ash.Resource.t() | Spark.Dsl.t()) :: [Effect.t()]
  def effects(resource_or_dsl) do
    if uses_effects?(resource_or_dsl),
      do: Spark.Dsl.Extension.get_entities(resource_or_dsl, [:effects]),
      else: []
  end

  @doc "The declaration for `action` (a name or an action struct) on `resource`, or `nil`."
  @spec effect(Ash.Resource.t() | Spark.Dsl.t(), atom() | struct()) :: Effect.t() | nil
  def effect(resource_or_dsl, %{name: name}), do: effect(resource_or_dsl, name)

  def effect(resource_or_dsl, name) when is_atom(name),
    do: Enum.find(effects(resource_or_dsl), &(&1.name == name))

  @doc "Whether `action` on `resource` has an effects declaration."
  @spec declared?(Ash.Resource.t() | Spark.Dsl.t(), atom() | struct()) :: boolean()
  def declared?(resource_or_dsl, action), do: not is_nil(effect(resource_or_dsl, action))

  @doc "Whether `resource` uses the `AshAgent.Effects` extension at all."
  @spec uses_effects?(Ash.Resource.t() | Spark.Dsl.t()) :: boolean()
  def uses_effects?(resource_or_dsl) when is_map(resource_or_dsl),
    do: AshAgent.Effects in Spark.extensions(resource_or_dsl)

  def uses_effects?(resource) when is_atom(resource),
    do: Spark.Dsl.is?(resource, Ash.Resource) and AshAgent.Effects in Spark.extensions(resource)
end
