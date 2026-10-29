# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.FailureTest do
  @moduledoc """
  The typed-failure table, error by error: its class, what happens next, and what a
  process that ran the invocation sees.
  """
  use ExUnit.Case, async: true

  alias AshAgent.BusinessError
  alias AshAgent.Invocation.Failure
  alias AshAgent.Test.Board.Error, as: BoardError

  @internal %{"open_world" => false, "idempotent" => false}
  @outside %{"open_world" => true, "idempotent" => false}
  @outside_idempotent %{"open_world" => true, "idempotent" => true}

  defp forbidden, do: Ash.Error.Forbidden.exception(errors: [])
  defp invalid(errors \\ []), do: Ash.Error.Invalid.exception(errors: errors)
  defp unknown(error), do: Ash.Error.Unknown.exception(errors: [error])

  # error, effects, attempt => class, next, BPMN
  @table [
    {:forbidden, @internal, 1, {:denied, "forbidden"}, :fail, {:incident, :denied}},
    {:invalid, @internal, 1, {:rejected, "invalid"}, :fail, {:incident, :rejected}},
    {:business, @outside, 1, {:business, "licence_lapsed"}, :fail, :bpmn_error},
    {:rate_limited, @outside, 1, {:transient, "rate_limited"}, :retry, nil},
    {:rate_limited, @outside, 3, {:transient, "rate_limited"}, :fail, {:incident, :transient}},
    {:timeout, @outside, 1, {:indeterminate, "timeout"}, :unknown, nil},
    {:timeout, @outside_idempotent, 1, {:indeterminate, "timeout"}, :retry, nil},
    {:timeout, @internal, 1, {:indeterminate, "timeout"}, :retry, nil},
    {:refused, @outside, 1, {:permanent, "refused"}, :fail, {:incident, :permanent}},
    {:over_budget, @outside, 1, {:budget, "over_budget"}, :fail, {:incident, :budget}},
    {:other, @internal, 1, {:permanent, "error"}, :fail, {:incident, :permanent}}
  ]

  defp error(:forbidden), do: forbidden()
  defp error(:invalid), do: invalid()
  defp error(:business), do: invalid([BusinessError.exception(code: "licence_lapsed")])
  defp error(:other), do: unknown(RuntimeError.exception("boom"))
  defp error(reason), do: unknown(BoardError.exception(reason: reason))

  test "every error class, against what happens next and what a process sees" do
    for {kind, effects, attempt, classified, next, bpmn} <- @table do
      assert Failure.classify(error(kind)) == classified, "classify #{kind}"

      decided = Failure.next(classified, effects, attempt, 3)

      assert match?(^next, decided) or match?({^next, _delay}, decided),
             "next for #{kind} on attempt #{attempt}: #{inspect(decided)}"

      if next == :fail do
        row = %{
          status: :failed,
          failure_class: Failure.recorded_class(classified),
          error_code: elem(classified, 1)
        }

        case bpmn do
          :bpmn_error -> assert {:error, {:bpmn_error, "licence_lapsed", %{}}} = Failure.bpmn(row)
          {:incident, class} -> assert {:error, {:incident, ^class, _code}} = Failure.bpmn(row)
        end
      end
    end
  end

  test "a business error wins over the Ash class it is wrapped in" do
    error = forbidden() |> Map.put(:errors, [BusinessError.exception(code: "slot_taken")])
    assert Failure.classify(error) == {:business, "slot_taken"}
  end

  test "backoff quadruples from thirty seconds and stops at an hour" do
    assert Enum.map(1..5, &Failure.backoff/1) ==
             [30_000, 120_000, 480_000, 1_920_000, 3_600_000]
  end

  test "rows that are not final are waiting, for a process" do
    for status <- [:ready, :executing, :dispatched, :outcome_unknown, :awaiting_approval] do
      assert Failure.bpmn(%{status: status, failure_class: nil, error_code: nil}) == :waiting
    end

    assert Failure.bpmn(%{status: :succeeded}) == :completed
  end

  test "undeclared effects are neither internal nor idempotent" do
    refute Failure.repeatable?(%{})
    refute Failure.repeatable?(nil)
    assert Failure.repeatable?(%{open_world: false})
  end
end
