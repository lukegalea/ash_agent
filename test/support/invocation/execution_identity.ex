# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.ExecutionIdentity do
  @moduledoc """
  The test host's `AshAgent.ExecutionIdentity`.

  A person is a map with an `:id`, and runs as themselves. An automation is a map with
  an `:automation` name, the person it acts `:for` (a person map, or nil) and an
  `:agent`; it runs as an actor carrying both names and the agent, which
  `principal_of/1` reads back. A name in `revoke/1`'s list has lost its authority, so
  `actor_for/1` refuses it, the way a host refuses a principal whose grant was revoked.
  An automation is refused when either it or the person it acts for has lost theirs,
  since what both allow is then nothing.
  """

  @behaviour AshAgent.ExecutionIdentity

  @key {__MODULE__, :revoked}
  @starts {__MODULE__, :starts}

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
      {"automation", name, person, agent} ->
        if Enum.any?([name, person], &revoked?/1),
          do: {:error, :revoked},
          else: {:ok, %{id: person, automation: name, agent: agent}}

      {_person, id, _on_behalf_of, _agent} ->
        if revoked?(id), do: {:error, :revoked}, else: {:ok, %{id: id}}
    end
  end

  @impl true
  def principal_of(%{automation: name, id: person} = actor) when is_binary(name),
    do: {:ok, %{type: :automation, id: name, on_behalf_of: person, agent: actor[:agent]}}

  def principal_of(%{id: id}) when is_binary(id), do: {:ok, %{type: :person, id: id}}
  def principal_of(_actor), do: :error

  @doc """
  A run of `agent_version` started by a person runs as them, or as the automation its
  authority names acting for them, when the person holds the agent's start grant
  (`grant_start/2`).
  """
  @impl true
  def run_principal(%{id: id}, version, _context) when is_binary(id) do
    if {id, version.key} in :persistent_term.get(@starts, []) do
      case version.authority do
        %{type: :automation, name: name} ->
          {:ok, %{type: :automation, id: name, on_behalf_of: id, agent: version.key}}

        _requester ->
          {:ok, %{type: :person, id: id}}
      end
    else
      {:error, :no_start_grant}
    end
  end

  def run_principal(_actor, _version, _context), do: {:error, :not_a_person}

  @doc "The person who started `run`, as `principal_for/2` maps to the run's principal."
  @impl true
  def requester_for(%{executing_principal: principal}) do
    case AshAgent.ExecutionIdentity.identity(principal) do
      {"automation", name, person, agent} when is_binary(person) ->
        {:ok, %{automation: name, for: %{id: person}, agent: agent}}

      {"person", id, _on_behalf_of, _agent} ->
        if revoked?(id), do: {:error, :revoked}, else: {:ok, %{id: id}}

      _other ->
        {:error, :no_requester}
    end
  end

  @doc "Lets the person `person_id` start the agent `key`, until `restore/0`."
  def grant_start(person_id, key),
    do: :persistent_term.put(@starts, [{person_id, key} | :persistent_term.get(@starts, [])])

  @doc "Marks `name` as having lost its authority, until `restore/0`."
  def revoke(name), do: :persistent_term.put(@key, [name | :persistent_term.get(@key, [])])

  @doc "Restores every revoked principal."
  def restore do
    :persistent_term.erase(@key)
    :persistent_term.erase(@starts)
  end

  defp revoked?(nil), do: false
  defp revoked?(name), do: name in :persistent_term.get(@key, [])
end
