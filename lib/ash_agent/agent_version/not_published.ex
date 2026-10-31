# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.AgentVersion.NotPublished do
  @moduledoc "A run asked to pin a version that was never published (a draft)."

  use Splode.Error, fields: [:key, :version, :status], class: :invalid

  @impl true
  def message(%{key: key, version: version, status: status}),
    do:
      "#{key} version #{version} is #{status}, not published; a run pins only a published version"
end
