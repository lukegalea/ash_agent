# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.InvocationSource do
  @moduledoc """
  The test host's execution source over its invocations (`AshAgent.Execution.Source`):
  the rows recorded under a trace's correlation id or named by one of its references,
  read in the order they were requested, a page at a time.

  Each row gives its logical operation, and an effect once it succeeded. A host's own
  source reads its rows through their read action as the viewer; the test host has no
  policies, so the actor it is given decides nothing here.
  """

  @behaviour AshAgent.Execution.Source

  require Ash.Query
  import Ash.Expr, only: [expr: 1]

  alias AshAgent.Execution.{Source, Status}
  alias AshAgent.Test.Invocation

  @impl true
  def read(scope, opts) do
    limit = Keyword.fetch!(opts, :limit)
    ids = Source.ids(scope, :invocation)

    query =
      Invocation
      |> Ash.Query.do_filter(matching(ids, scope.correlation_id))
      |> Ash.Query.sort(inserted_at: :asc, id: :asc)
      |> after_cursor(opts[:after])
      |> Ash.Query.limit(limit + 1)

    with {:ok, rows} <- Ash.read(query, actor: opts[:actor]) do
      page(rows, limit)
    end
  end

  @impl true
  def to_entries(rows), do: Enum.flat_map(rows, &entries/1)

  defp entries(row) do
    {status, blocked_on} = Status.invocation(row)
    ref = Source.ref(:invocation, row.id)

    operation =
      Source.entry(
        at: row.inserted_at,
        kind: :logical_operation,
        status: status,
        blocked_on: blocked_on,
        source_ref: ref,
        definition_ref: row.target,
        summary: row.target
      )

    case row.status do
      :succeeded ->
        effect =
          Source.entry(
            at: row.effect_observed_at || row.inserted_at,
            kind: :effect,
            status: :succeeded,
            source_ref: ref <> "#effect",
            parent_ref: ref,
            summary: row.target
          )

        [operation, effect]

      _other ->
        [operation]
    end
  end

  defp matching(ids, nil), do: expr(id in ^ids)
  defp matching(ids, correlation_id), do: expr(id in ^ids or correlation_id == ^correlation_id)

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, cursor) do
    [at, id] = String.split(cursor, "|", parts: 2)
    {:ok, at, 0} = DateTime.from_iso8601(at)
    Ash.Query.filter(query, inserted_at > ^at or (inserted_at == ^at and id > ^id))
  end

  defp page(rows, limit) when length(rows) > limit do
    rows = Enum.take(rows, limit)
    last = List.last(rows)
    {:ok, rows, "#{DateTime.to_iso8601(last.inserted_at)}|#{last.id}"}
  end

  defp page(rows, _limit), do: {:ok, rows, nil}
end
