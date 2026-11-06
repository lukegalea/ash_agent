# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.ExecutionSourceTest do
  @moduledoc false
  use AshAgent.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias AshAgent.Execution.{Source, Status}
  alias AshAgent.Test.{Domain, InvocationSource}

  doctest AshAgent.Execution.Source
  doctest AshAgent.Execution.Status

  @record "AshAgent.Test.CredentialCheck.record"
  @reviewed "AshAgent.Test.CredentialCheck.record_reviewed"

  setup do
    %{nurse: %{id: Ash.UUID.generate()}}
  end

  defp invoke!(nurse, target, n),
    do:
      Domain.invoke!(
        target,
        %{"licence_number" => "RN-#{n}", "clinician_name" => "Dana Reyes"},
        %{key: "trace:#{System.unique_integer([:positive])}"},
        actor: nurse
      )

  defp scope(refs, correlation_id \\ nil),
    do: %{correlation_id: correlation_id, refs: MapSet.new(refs)}

  defp read(scope, opts \\ []),
    do: InvocationSource.read(scope, Keyword.merge([limit: 10, after: nil], opts))

  # Written past the actions: the host stamps the correlation id with a change of its own.
  defp correlate!(row, id) do
    {1, _} =
      Repo.update_all(
        from(i in "invocations", where: i.id == type(^row.id, Ecto.UUID)),
        set: [correlation_id: id]
      )
  end

  describe "a source on the test host" do
    test "reads the rows its scope names, and maps them to entries in the shared vocabulary",
         %{nurse: nurse} do
      ready = invoke!(nurse, @record, 1)
      waiting = invoke!(nurse, @reviewed, 2)
      _other = invoke!(nurse, @record, 3)

      assert {:ok, rows, nil} =
               read(scope([Source.ref(:invocation, ready.id), "invocation:" <> waiting.id]))

      assert Enum.map(rows, & &1.id) == [ready.id, waiting.id]

      assert [first, second] = InvocationSource.to_entries(rows)

      assert {first.kind, first.status, first.blocked_on} ==
               {:logical_operation, :waiting, :queue}

      assert {second.status, second.blocked_on} == {:waiting, :approval}
      assert first.source_ref == "invocation:#{ready.id}"
      assert first.recorded?

      for entry <- [first, second] do
        assert entry.kind in Source.kinds()
        assert entry.status in Status.statuses()
      end
    end

    test "reads what was recorded under the correlation id", %{nurse: nurse} do
      row = invoke!(nurse, @record, 1)
      _uncorrelated = invoke!(nurse, @record, 2)
      correlate!(row, "corr-1")

      assert {:ok, [%{id: id}], nil} = read(scope([], "corr-1"))
      assert id == row.id
    end

    test "reads nothing when its scope matches nothing", %{nurse: nurse} do
      invoke!(nurse, @record, 1)
      assert read(scope([])) == {:ok, [], nil}
      assert read(scope(["run:#{Ash.UUID.generate()}"])) == {:ok, [], nil}
    end

    test "reads at most its limit, and a cursor reads the rest", %{nurse: nurse} do
      rows = for n <- 1..5, do: invoke!(nurse, @record, n)
      refs = Enum.map(rows, &Source.ref(:invocation, &1.id))

      assert {:ok, page, cursor} = read(scope(refs), limit: 2)
      assert length(page) == 2 and is_binary(cursor)

      assert {:ok, page2, cursor2} = read(scope(refs), limit: 2, after: cursor)
      assert {:ok, page3, nil} = read(scope(refs), limit: 2, after: cursor2)

      assert Enum.map(page ++ page2 ++ page3, & &1.id) == Enum.map(rows, & &1.id)
    end
  end

  describe "the shared status" do
    test "places every invocation status, and request_info waits on the requester" do
      assert Status.invocation(:request_info) == {:waiting, :requester}
      assert Status.invocation(%{status: :request_info}) == {:waiting, :requester}

      for state <- AshStateMachine.Info.state_machine_all_states(AshAgent.Test.Invocation) do
        {status, _blocked_on} = Status.invocation(state)
        assert status in Status.statuses()
      end

      assert Status.invocation(:executing) == {:running, nil}
      assert Status.invocation(:succeeded) == {:succeeded, nil}
      assert Status.invocation(:rejected) == {:cancelled, nil}
      assert Status.invocation(:stale) == {:failed, nil}
    end

    test "places every run status" do
      for state <- AshStateMachine.Info.state_machine_all_states(AshAgent.Test.Run) do
        {status, _blocked_on} = Status.run(state)
        assert status in Status.statuses()
      end

      assert Status.run(%{status: :waiting, blocked_on: :budget}) == {:waiting, :budget}
      assert Status.run(:completed) == {:succeeded, nil}
    end

    test "an unknown, missing or misspelled status is uncertain, never a success" do
      for unknown <- [nil, :done, :ok, "succeeded", :error, %{}, %{status: nil}] do
        assert Status.invocation(unknown) == {:uncertain, nil}
        assert Status.run(unknown) == {:uncertain, nil}
        assert Status.coerce(unknown) == :uncertain
      end
    end
  end

  describe "entry/1" do
    @at ~U[2026-01-01 00:00:00Z]

    test "fills the optional fields and counts a record as recorded unless told otherwise" do
      entry = Source.entry(at: @at, kind: :attempt, source_ref: "x:1", status: :failed)

      assert entry == %{
               at: @at,
               kind: :attempt,
               status: :failed,
               blocked_on: nil,
               source_ref: "x:1",
               parent_ref: nil,
               definition_ref: nil,
               actor_label: nil,
               cost: nil,
               recorded?: true,
               summary: nil
             }

      assert Source.entry(at: @at, kind: :effect, source_ref: "x:1", recorded?: false).recorded? ==
               false
    end

    test "a status it does not know, or none, is uncertain" do
      assert Source.entry(at: @at, kind: :effect, source_ref: "x:1").status == :uncertain

      assert Source.entry(at: @at, kind: :effect, source_ref: "x:1", status: :ok).status ==
               :uncertain
    end

    test "refuses an entry outside the vocabulary or without what places it" do
      assert_raise ArgumentError, fn -> Source.entry(at: @at, kind: :guess, source_ref: "x:1") end

      assert_raise ArgumentError, fn ->
        Source.entry(at: nil, kind: :effect, source_ref: "x:1")
      end

      assert_raise ArgumentError, fn -> Source.entry(at: @at, kind: :effect, source_ref: nil) end
      assert_raise ArgumentError, fn -> Source.entry(at: @at, kind: :effect, source_ref: "") end

      assert_raise ArgumentError, fn ->
        Source.entry(at: @at, kind: :effect, source_ref: "x:1", colour: :red)
      end
    end
  end
end
