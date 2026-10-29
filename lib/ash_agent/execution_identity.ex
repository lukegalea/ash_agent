# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.ExecutionIdentity do
  @moduledoc """
  Who an invocation runs as. The host implements it; the package calls it and never
  reads the host's actors, grants or tenants itself.

  Two moments need an answer:

    * **When an invocation is requested**, `principal_for/2` names the principal the work
      will execute as, from the actor asking for it. The answer is stored on the row as
      `executing_principal` and is part of what makes two requests with one key the same
      request.
    * **When an invocation is claimed**, `actor_for/1` builds the actor to run the target
      as, from the stored principal. It is called at every claim, so authority comes from
      the host's grants as they are then, never from what the requester could do when
      they asked. A principal that no longer has authority is an `{:error, reason}`, and
      the invocation fails as denied without running its target.

  ## Principals

  A principal is a map with a `:type` and an `:id`, stored as given:

    * `%{type: :person, id: person_id}`: a person, running as themselves.
    * `%{type: :automation, id: name, on_behalf_of: person_id, agent: agent_key}`: a named
      automation principal holding grants of its own. `on_behalf_of` is the person whose
      request it serves (nil for work no person asked for), and `agent` the agent it runs
      for, when there is one.

  Every field is part of the principal's identity: the same automation acting for two
  people is two principals, so one person's key never returns another's row.

  An automation principal acting for a person must not be able to do more than either
  could alone: the host's actor for it holds only what both the automation's grants and
  the person's allow. The package stores and compares these principals like any other;
  whether a host issues them, how it intersects the two authorities, and who may start
  an agent, are the host's decisions.

  The package never builds an actor itself and never falls back to a more privileged one.

  ## Delegation

  `delegation/1` states a principal as RFC 8693's nested `act` claim, and `request`
  stores it in the row's `delegation` column: the person is the subject, the automation
  the actor, and the agent its `client_id`. It is informational; the principal is what is
  compared and run.
  """

  @typedoc "Who an invocation executes as."
  @type principal ::
          %{type: :person, id: String.t()}
          | %{
              required(:type) => :automation,
              required(:id) => String.t(),
              optional(:on_behalf_of) => String.t() | nil,
              optional(:agent) => String.t() | nil
            }

  @doc """
  The principal that work requested by `actor` executes as. `context` is the action
  context of the request. An actor the host cannot name a principal for gets an
  `{:error, reason}`, and the request is refused.
  """
  @callback principal_for(actor :: term(), context :: map()) ::
              {:ok, principal()} | {:error, term()}

  @doc """
  The actor to run `invocation`'s target as, built afresh from its `executing_principal`.
  """
  @callback actor_for(invocation :: Ash.Resource.record()) :: {:ok, term()} | {:error, term()}

  @doc """
  The principal as RFC 8693 delegation (section 4.1, the `act` claim), or `nil` for a
  person acting as themselves.

      iex> AshAgent.ExecutionIdentity.delegation(%{type: :automation, id: "intake", on_behalf_of: "p1", agent: "triage"})
      %{"sub" => "person:p1", "act" => %{"sub" => "automation:intake", "client_id" => "triage"}}

      iex> AshAgent.ExecutionIdentity.delegation(%{type: :automation, id: "intake"})
      %{"sub" => "automation:intake"}

      iex> AshAgent.ExecutionIdentity.delegation(%{type: :person, id: "p1"})
      nil
  """
  @spec delegation(map() | nil) :: map() | nil
  def delegation(principal) when is_map(principal) do
    case identity(principal) do
      {"automation", name, nil, agent} ->
        with_client(%{"sub" => "automation:" <> name}, agent)

      {"automation", name, person, agent} ->
        %{
          "sub" => "person:" <> person,
          "act" => with_client(%{"sub" => "automation:" <> name}, agent)
        }

      _person ->
        nil
    end
  end

  def delegation(_principal), do: nil

  @doc """
  The fields that identify a principal, as strings whatever their spelling when stored:
  two principals are the same principal exactly when these are equal.
  """
  @spec identity(map()) ::
          {String.t() | nil, String.t() | nil, String.t() | nil, String.t() | nil}
  def identity(principal) when is_map(principal) do
    {field(principal, :type), field(principal, :id), field(principal, :on_behalf_of),
     field(principal, :agent)}
  end

  defp with_client(claim, nil), do: claim
  defp with_client(claim, agent), do: Map.put(claim, "client_id", agent)

  defp field(principal, name) do
    case Map.get(principal, name, Map.get(principal, Atom.to_string(name))) do
      nil -> nil
      value -> to_string(value)
    end
  end
end
