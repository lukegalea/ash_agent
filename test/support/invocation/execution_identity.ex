# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.ExecutionIdentity do
  @moduledoc """
  The test host's `AshAgent.ExecutionIdentity`.

  A person is a map with an `:id`, and runs as themselves. An automation is a map with
  an `:automation` name, the person it acts `:for` (a person map, or nil) and an
  `:agent`; it runs as an actor carrying both names. A name in `revoke/1`'s list has
  lost its authority, so `actor_for/1` refuses it, the way a host refuses a principal
  whose grant was revoked. An automation is refused when either it or the person it acts
  for has lost theirs, since what both allow is then nothing.
  """

  @behaviour AshAgent.ExecutionIdentity

  @key {__MODULE__, :revoked}

  @impl true
  def principal_for(%{automation: name} = actor, _context) when is_binary(name) do
    on_behalf_of =
      case actor[:for] do
        %{id: id} -> id
        nil -> nil
      end

    {:ok, %{type: :automation, id: name, on_behalf_of: on_behalf_of, agent: actor[:agent]}}
  end

  def principal_for(%{id: id}, _context) when is_binary(id), do: {:ok, %{type: :person, id: id}}
  def principal_for(_actor, _context), do: {:error, :not_a_person}

  @impl true
  def actor_for(%{executing_principal: principal}) do
    case AshAgent.ExecutionIdentity.identity(principal) do
      {"automation", name, person, _agent} ->
        if Enum.any?([name, person], &revoked?/1),
          do: {:error, :revoked},
          else: {:ok, %{id: person, automation: name}}

      {_person, id, _on_behalf_of, _agent} ->
        if revoked?(id), do: {:error, :revoked}, else: {:ok, %{id: id}}
    end
  end

  @doc "Marks `name` as having lost its authority, until `restore/0`."
  def revoke(name), do: :persistent_term.put(@key, [name | :persistent_term.get(@key, [])])

  @doc "Restores every revoked principal."
  def restore, do: :persistent_term.erase(@key)

  defp revoked?(nil), do: false
  defp revoked?(name), do: name in :persistent_term.get(@key, [])
end
