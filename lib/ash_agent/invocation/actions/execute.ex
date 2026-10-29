# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.Actions.Execute do
  @moduledoc """
  The `execute` action, run by the host's `:execute` trigger with the row's primary key.
  It holds no transaction of its own; see `AshAgent.Invocation.Executor`.
  """

  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context) do
    primary_key = input.arguments.primary_key
    id = Map.get(primary_key, "id") || Map.get(primary_key, :id)

    AshAgent.Invocation.Executor.execute(input.resource, id, Ash.Context.to_opts(context))
  end
end
