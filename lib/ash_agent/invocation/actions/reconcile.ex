# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.Actions.Reconcile do
  @moduledoc """
  The `reconcile` action, run by the host's `:reconcile` trigger with the row's primary
  key. It holds no transaction of its own: a `reconcile_with` lookup may call out. See
  `AshAgent.Invocation.Reconciler`.
  """

  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context) do
    primary_key = input.arguments.primary_key
    id = Map.get(primary_key, "id") || Map.get(primary_key, :id)

    AshAgent.Invocation.Reconciler.reconcile(input.resource, id, Ash.Context.to_opts(context))
  end
end
