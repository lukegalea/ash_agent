# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.Authority do
  @moduledoc """
  The test host's answers about its people (`AshAgent.Approval.Authority`): the
  approval posture in force, the holders of its roles, and its platform
  operators, kept in persistent terms the way the test host's
  `AshAgent.Test.ExecutionIdentity` keeps what it is asked. A test sets them and
  `restore/0` clears them.

  Holders are keyed by the tenant they hold the role in (`set_holders/3`), as
  the posture-change rules ask; `:any` is every tenant at once, what the
  approval rules are content with.
  """

  @behaviour AshAgent.Approval.Authority

  @posture {__MODULE__, :posture}
  @roles {__MODULE__, :roles}
  @operators {__MODULE__, :operators}

  @administrator_role :clinic_administrator

  @impl true
  def posture(_tenant), do: :persistent_term.get(@posture, {:standard, nil})

  @impl true
  def holders(tenant, role) do
    roles = :persistent_term.get(@roles, %{})

    Map.get(roles, {tenant, role}, Map.get(roles, {:any, role}, []))
  end

  @impl true
  def administrator_role, do: @administrator_role

  @impl true
  def operator?(actor), do: actor in :persistent_term.get(@operators, [])

  @doc "Puts `posture` in force with its `ends_at`, until `restore/0`."
  def set_posture(posture, ends_at \\ nil),
    do: :persistent_term.put(@posture, {posture, ends_at})

  @doc """
  Makes `ids` everyone who has ever held `role` in `tenant`, until `restore/0`.
  `tenant` defaults to `:any`, every tenant at once.
  """
  def set_holders(role, ids, tenant \\ :any),
    do:
      :persistent_term.put(
        @roles,
        Map.put(:persistent_term.get(@roles, %{}), {tenant, role}, ids)
      )

  @doc "Makes each of `actors` a platform operator, until `restore/0`."
  def set_operators(actors), do: :persistent_term.put(@operators, actors)

  @doc "Restores the answers to their defaults: `:standard`, no holders, no operators."
  def restore do
    :persistent_term.erase(@posture)
    :persistent_term.erase(@roles)
    :persistent_term.erase(@operators)
  end
end
