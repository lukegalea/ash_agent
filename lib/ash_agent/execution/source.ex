# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Execution.Source do
  @moduledoc """
  Where an execution's history comes from: one behaviour for each kind of record a host
  reads to show what happened, in what order, and how it ended.

  The history of one piece of work is spread over many records: the invocation and its
  attempts, an agent run and its steps, the approval it waited for, the model calls it
  made, the decisions and judgments it rested on. A host shows them together by reading
  each kind of record through a source and mapping its rows to **entries**, which share
  one shape and one status vocabulary. The host owns the registry of sources and the
  view that combines them; the package owns the shape.

  ## A source

    * `read/2` reads the rows that belong to a trace, **as the viewer**: through the
      source's own read action, with the actor and tenant it is given, so a row the
      viewer may not read is never read. It reads at most `:limit` rows after `:after`
      (a cursor it returned earlier), and returns the cursor of the next page, or `nil`
      when there is none.
    * `to_entries/1` maps the rows it read to entries. A row may give several (an
      invocation's logical operation and its effect) or none.

  `read/2` is told what to read by a scope: the correlation id the work was recorded
  under, and the references of records already in the trace (`"run:<id>"`,
  `"invocation:<id>"`). A source reads the rows that carry the correlation id or point at
  one of the references; a source with nothing to match reads nothing.

  ## An entry

    * `at`: when it happened.
    * `kind`: one of `kinds/0`.
    * `status`: one of the six in `statuses/0` (`AshAgent.Execution.Status`).
    * `blocked_on`: for a waiting entry, what it waits for (`:approval`, `:requester`,
      `:queue`, `:tools`, `:human`, `:budget`, ...), else `nil`.
    * `source_ref`: the record it comes from, as `"<type>:<id>"`.
    * `parent_ref`: the record it belongs under (a run's step under the run, an attempt
      under its invocation), or `nil`.
    * `definition_ref`: what it ran, as `"key@version"`, or `nil`.
    * `actor_label`: who it ran as, or `nil`.
    * `cost`: what it spent (`%{tokens: n, duration_ms: n}`, either key optional), or
      `nil`.
    * `recorded?`: `false` when the record exists but what it held was not recorded or
      can no longer be read (its content was erased, its telemetry never arrived). A
      reader shows "not recorded", never an empty value.
    * `summary`: a short, structural description. Never the sealed content of a record:
      arguments, results, messages and judged text stay where they are, readable through
      the record's own read.

  `entry/1` builds one and keeps it inside the vocabulary.
  """

  @typedoc "A record's reference: `\"<type>:<id>\"`."
  @type ref :: String.t()

  @typedoc "What a trace reads."
  @type scope :: %{correlation_id: String.t() | nil, refs: MapSet.t(ref())}

  @typedoc "An opaque position in a source's rows."
  @type cursor :: String.t()

  @type kind ::
          :logical_operation
          | :attempt
          | :observation
          | :decision
          | :proposal
          | :approval
          | :effect
          | :model_call
          | :process_event

  @type entry :: %{
          at: DateTime.t(),
          kind: kind(),
          status: AshAgent.Execution.Status.t(),
          blocked_on: atom() | nil,
          source_ref: ref(),
          parent_ref: ref() | nil,
          definition_ref: String.t() | nil,
          actor_label: String.t() | nil,
          cost: map() | nil,
          recorded?: boolean(),
          summary: String.t() | nil
        }

  @doc """
  The rows of `scope` that the viewer may read. `opts` carries `:actor`, `:tenant`,
  `:limit` and `:after` (a cursor from an earlier read, or `nil`). An error is reported
  as the source's, never read as "nothing happened".
  """
  @callback read(scope(), opts :: keyword()) ::
              {:ok, [Ash.Resource.record()], cursor() | nil} | {:error, term()}

  @doc "The entries `rows` give."
  @callback to_entries(rows :: [Ash.Resource.record()]) :: [entry()]

  @kinds [
    :logical_operation,
    :attempt,
    :observation,
    :decision,
    :proposal,
    :approval,
    :effect,
    :model_call,
    :process_event
  ]

  @fields [
    :at,
    :kind,
    :status,
    :blocked_on,
    :source_ref,
    :parent_ref,
    :definition_ref,
    :actor_label,
    :cost,
    :recorded?,
    :summary
  ]

  @doc "The kinds of entry."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  An entry from `fields`. `at`, `kind` and `source_ref` are required, and `kind` must be
  one of `kinds/0`. A status outside the six reads as `:uncertain`
  (`AshAgent.Execution.Status.coerce/1`), never as a success; `recorded?` defaults to
  `true` and the other fields to `nil`.

      iex> entry = AshAgent.Execution.Source.entry(%{at: ~U[2026-01-01 00:00:00Z], kind: :effect, source_ref: "invocation:1", status: :done})
      iex> {entry.status, entry.recorded?, entry.parent_ref}
      {:uncertain, true, nil}
  """
  @spec entry(map() | keyword()) :: entry()
  def entry(fields) do
    fields = Map.new(fields)

    case Map.keys(fields) -- @fields do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown entry fields: #{inspect(unknown)}"
    end

    at = Map.get(fields, :at)
    kind = Map.get(fields, :kind)
    source_ref = Map.get(fields, :source_ref)

    unless match?(%DateTime{}, at), do: raise(ArgumentError, "an entry needs `at`, a DateTime")
    unless kind in @kinds, do: raise(ArgumentError, "unknown entry kind: #{inspect(kind)}")

    unless is_binary(source_ref) and source_ref != "",
      do: raise(ArgumentError, "an entry needs a `source_ref`")

    @fields
    |> Map.new(&{&1, nil})
    |> Map.merge(fields)
    |> Map.update!(:status, &AshAgent.Execution.Status.coerce/1)
    |> Map.update!(:recorded?, &(&1 != false))
  end

  @doc """
  The reference of a record of `type`: `\"<type>:<id>\"`.

      iex> AshAgent.Execution.Source.ref(:run, "5f0c")
      "run:5f0c"
  """
  @spec ref(atom() | String.t(), term()) :: ref()
  def ref(type, id), do: "#{type}:#{id}"

  @doc """
  The ids of `scope`'s references of `type`.

      iex> scope = %{correlation_id: nil, refs: MapSet.new(["run:a", "invocation:b", "run:c"])}
      iex> AshAgent.Execution.Source.ids(scope, :run) |> Enum.sort()
      ["a", "c"]
  """
  @spec ids(scope(), atom() | String.t()) :: [String.t()]
  def ids(%{refs: refs}, type) do
    prefix = "#{type}:"
    for ref <- refs, String.starts_with?(ref, prefix), do: String.replace_prefix(ref, prefix, "")
  end
end
