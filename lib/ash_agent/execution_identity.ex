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

  A principal is a map with a `:type` and an `:id`, both stored as given:

    * `%{type: :person, id: person_id}`: a person, running as themselves.
    * `%{type: :automation, id: name}`: a named automation principal holding grants of its
      own. The package stores and compares these like any other principal; whether a host
      issues them, and with what authority, is the host's decision.

  The package never builds an actor itself and never falls back to a more privileged one.
  """

  @typedoc "Who an invocation executes as."
  @type principal :: %{type: :person | :automation, id: String.t()}

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
end
