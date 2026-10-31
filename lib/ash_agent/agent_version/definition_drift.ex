# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.AgentVersion.DefinitionDrift do
  @moduledoc """
  A pinned agent version no longer matches the code it offers: a toolset target's input
  schema or effects declaration changed since the version was written, or the target
  is gone (`AshAgent.AgentVersion.Definition.check_pinned/1`).

  `drifted` lists each target as `%{"target", "pinned", "current"}`. A run that meets it
  fails closed with `reason` (`:definition_drift`) as its error code; it does not offer
  the model the changed tool.
  """

  use Splode.Error, fields: [:key, :version, :drifted, reason: :definition_drift], class: :invalid

  @impl true
  def message(%{key: key, version: version, drifted: drifted}) do
    targets = Enum.map_join(drifted, ", ", & &1["target"])

    "definition_drift: #{key} version #{version} was written against other definitions of " <>
      targets
  end
end
