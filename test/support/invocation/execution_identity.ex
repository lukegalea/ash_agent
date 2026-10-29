# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.ExecutionIdentity do
  @moduledoc """
  The test host's `AshAgent.ExecutionIdentity`: an actor is a map with an `:id`, and it
  runs as itself. A person whose id is in `revoke/1`'s list has lost their authority, so
  `actor_for/1` refuses them, the way a host refuses a person whose grant was revoked.
  """

  @behaviour AshAgent.ExecutionIdentity

  @key {__MODULE__, :revoked}

  @impl true
  def principal_for(%{id: id}, _context) when is_binary(id), do: {:ok, %{type: :person, id: id}}
  def principal_for(_actor, _context), do: {:error, :not_a_person}

  @impl true
  def actor_for(%{executing_principal: principal}) do
    id = Map.get(principal, :id) || Map.get(principal, "id")

    if id in :persistent_term.get(@key, []),
      do: {:error, :revoked},
      else: {:ok, %{id: id}}
  end

  @doc "Marks `id` as having lost its authority, until `restore/0`."
  def revoke(id), do: :persistent_term.put(@key, [id | :persistent_term.get(@key, [])])

  @doc "Restores every revoked person."
  def restore, do: :persistent_term.erase(@key)
end
