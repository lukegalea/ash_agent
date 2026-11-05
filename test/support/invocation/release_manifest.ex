# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.ReleaseManifest do
  @moduledoc """
  The test host's `AshAgent.ReleaseManifest`: the active release is whatever a test last
  `activate/1`d, and none until then.
  """

  @behaviour AshAgent.ReleaseManifest

  @key {__MODULE__, :active}

  @impl true
  def active(_tenant) do
    case :persistent_term.get(@key, nil) do
      nil -> {:ok, nil}
      active -> {:ok, active}
    end
  end

  @doc "Makes `digest` the digest of the active release, with a fresh id."
  @spec activate(String.t()) :: %{id: Ash.UUID.t(), digest: String.t()}
  def activate(digest) do
    active = %{id: Ash.UUID.generate(), digest: digest}
    :persistent_term.put(@key, active)
    active
  end

  @doc "No release is active."
  @spec clear() :: :ok
  def clear do
    :persistent_term.erase(@key)
    :ok
  end
end
