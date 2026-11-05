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
  def active(target, _tenant) do
    with %{covers: covers} = active <- :persistent_term.get(@key, nil),
         true <- covers == :all or target in covers do
      {:ok, Map.take(active, [:id, :digest])}
    else
      _none_or_not_covering -> {:ok, nil}
    end
  end

  @doc """
  Makes `digest` the digest of the active release, with a fresh id. It covers every
  target, or only those named by `covers`.
  """
  @spec activate(String.t(), :all | [String.t()]) :: %{id: Ash.UUID.t(), digest: String.t()}
  def activate(digest, covers \\ :all) do
    active = %{id: Ash.UUID.generate(), digest: digest}
    :persistent_term.put(@key, Map.put(active, :covers, covers))
    active
  end

  @doc "No release is active."
  @spec clear() :: :ok
  def clear do
    :persistent_term.erase(@key)
    :ok
  end
end
