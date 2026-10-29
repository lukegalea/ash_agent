# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Effects.Effect do
  @moduledoc """
  One action's effects declaration: the `action` entity of the `effects` section.

  The four hints are MCP's tool annotations with MCP's defaults for whatever the
  declaration leaves out: `read_only?` false, `destructive?` true, `idempotent?`
  false, `open_world?` true. `kind` is an ACP tool kind and is always stated,
  because the hints cannot express `search`, `fetch`, `move` or `think`.

  Read one with `AshAgent.Effects.Info.effect/2`.
  """

  @kinds [:read, :edit, :delete, :move, :search, :execute, :think, :fetch, :switch_mode, :other]
  @approvals [:none, :confirm, :four_eyes]
  @intents [:inspect, :propose, :approve, :test, :execute]

  defstruct [
    :name,
    :kind,
    :approver_role,
    :approval_expires_in,
    :intent,
    :reconcile_with,
    read_only?: false,
    destructive?: true,
    idempotent?: false,
    open_world?: true,
    approval: :none,
    preconditions: [],
    __identifier__: nil,
    __spark_metadata__: nil
  ]

  @type kind ::
          :read
          | :edit
          | :delete
          | :move
          | :search
          | :execute
          | :think
          | :fetch
          | :switch_mode
          | :other

  @type t :: %__MODULE__{
          name: atom(),
          kind: kind(),
          read_only?: boolean(),
          destructive?: boolean(),
          idempotent?: boolean(),
          open_world?: boolean(),
          approval: :none | :confirm | :four_eyes,
          approver_role: atom() | nil,
          approval_expires_in: keyword() | nil,
          intent: :inspect | :propose | :approve | :test | :execute | nil,
          reconcile_with: atom() | nil,
          preconditions: [atom()],
          __identifier__: term(),
          __spark_metadata__: Spark.Dsl.Entity.spark_meta()
        }

  @doc false
  def kinds, do: @kinds
  @doc false
  def approvals, do: @approvals
  @doc false
  def intents, do: @intents

  @doc """
  The declaration as a map with string keys and string values, in a fixed shape:
  what a host stores as a snapshot of the declaration or feeds to a digest.
  Absent options are `nil`; `approval_expires_in` becomes a map of unit to count.
  """
  @spec to_map(t()) :: %{String.t() => term()}
  def to_map(%__MODULE__{} = effect) do
    %{
      "action" => Atom.to_string(effect.name),
      "kind" => Atom.to_string(effect.kind),
      "read_only" => effect.read_only?,
      "destructive" => effect.destructive?,
      "idempotent" => effect.idempotent?,
      "open_world" => effect.open_world?,
      "approval" => Atom.to_string(effect.approval),
      "approver_role" => atom_string(effect.approver_role),
      "approval_expires_in" => expires_in(effect.approval_expires_in),
      "intent" => atom_string(effect.intent),
      "reconcile_with" => atom_string(effect.reconcile_with),
      "preconditions" => Enum.map(effect.preconditions, &Atom.to_string/1)
    }
  end

  defp atom_string(nil), do: nil
  defp atom_string(atom), do: Atom.to_string(atom)

  defp expires_in(nil), do: nil
  defp expires_in(duration), do: Map.new(duration, fn {unit, n} -> {Atom.to_string(unit), n} end)
end
