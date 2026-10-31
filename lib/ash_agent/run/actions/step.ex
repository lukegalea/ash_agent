# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Run.Actions.Step do
  @moduledoc """
  The `step` action, run by the host's `:step` trigger with the run's primary key. It
  holds no transaction of its own; see `AshAgent.Run.Stepper`.
  """

  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context) do
    primary_key = input.arguments.primary_key
    id = Map.get(primary_key, "id") || Map.get(primary_key, :id)

    AshAgent.Run.Stepper.step(input.resource, id, Ash.Context.to_opts(context))
  end
end
