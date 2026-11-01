# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Run.BudgetExhausted do
  @moduledoc """
  A reservation asked for more of a run's token budget than is left
  (`AshAgent.Run.Budget`). `reason` is `:budget`; the run waits on its budget until its
  host extends it.
  """

  use Splode.Error, fields: [:run_id, :tokens, :available, reason: :budget], class: :invalid

  @impl true
  def message(%{run_id: run_id, tokens: tokens, available: available}),
    do:
      "token_budget: run #{run_id} has #{available} tokens left, fewer than the #{tokens} asked for"
end
