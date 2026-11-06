# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Run.Calculations.NeedsStep do
  @moduledoc """
  Whether a run has a step to take now: it is `queued`, or it is `waiting` on its tool
  calls and none of its invocations is still open (`AshAgent.Invocation.open_statuses/0`).

  Derived, never counted: nothing has to remember to decrement it on every way an
  invocation can end, so a missed wake-up costs a sweep's delay and never parks a run
  for good. It is an expression over the host's invocation resource (the `run`
  section's `invocation`, passed as the `invocation` option by
  `AshAgent.Run.Transformers.AddNeedsStep`), so a trigger's `where` and a read can
  filter on it.
  """

  use Ash.Resource.Calculation

  require Ash.Expr

  @open AshAgent.Invocation.open_statuses()

  @impl true
  def expression(opts, _context) do
    open = %Ash.Query.Exists{
      path: [],
      resource: opts[:invocation],
      expr: Ash.Expr.expr(run_id == parent(id) and status in ^@open),
      at_path: [],
      related?: false
    }

    Ash.Expr.expr(
      status == :queued or
        (status == :waiting and blocked_on in [:tools, :human] and not (^open))
    )
  end
end
