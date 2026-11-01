# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Run.JournalTest do
  use ExUnit.Case, async: true

  alias AshAgent.Run.Journal

  # What a host that seals a run's content reads once its key is gone.
  defmodule Erased do
    defstruct [:scope]
  end

  @turn [%{"type" => "text", "text" => "Noted."}]

  defp step(role, parts), do: %{role: role, parts: parts, tool_calls: [], seq: 1}

  test "the input and each step, in order, as messages" do
    assert {:ok, [first, user, turn]} =
             Journal.messages("Note the renewal", [
               step(:user, [%{"type" => "text", "text" => "Answer as JSON"}]),
               step(:assistant, @turn)
             ])

    assert {first.role, user.role, turn.role} == {:user, :user, :assistant}
  end

  test "no input is no first message" do
    assert {:ok, [%{role: :assistant}]} = Journal.messages(nil, [step(:assistant, @turn)])
  end

  test "a step whose parts can no longer be read makes the conversation unreadable" do
    for role <- [:assistant, :tool, :user] do
      assert Journal.messages("Note the renewal", [step(role, %Erased{scope: "s"})]) ==
               :unreadable
    end
  end

  test "an input that can no longer be read makes the conversation unreadable" do
    assert Journal.messages(%Erased{scope: "s"}, [step(:assistant, @turn)]) == :unreadable
    assert Journal.messages(%Erased{scope: "s"}, []) == :unreadable
  end
end
