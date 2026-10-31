# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Run.Transformers.AddNeedsStep do
  @moduledoc """
  Adds the `needs_step` calculation (`AshAgent.Run.Calculations.NeedsStep`) over the
  invocation resource the host names in its `run` section. The fragment cannot name it
  itself: the resource is the host's.
  """

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def before?(Ash.Resource.Transformers.DefaultAccept), do: true
  def before?(_transformer), do: false

  @impl true
  def transform(dsl) do
    case Transformer.get_option(dsl, [:run], :invocation) do
      nil ->
        {:ok, dsl}

      invocation ->
        Ash.Resource.Builder.add_new_calculation(
          dsl,
          :needs_step,
          :boolean,
          {AshAgent.Run.Calculations.NeedsStep, invocation: invocation},
          public?: true,
          description: "Whether the run has a step to take now."
        )
    end
  end
end
