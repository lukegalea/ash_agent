# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.Board.Error do
  @moduledoc "The fake board's failure, classified for invocations by `AshAgent.FailureClass`."

  use Splode.Error, fields: [:reason], class: :unknown

  @impl true
  def message(%{reason: reason}), do: "the board answered #{reason}"
end

defimpl AshAgent.FailureClass, for: AshAgent.Test.Board.Error do
  def classify(%{reason: :rate_limited}), do: {:transient, "rate_limited"}
  def classify(%{reason: :timeout}), do: {:indeterminate, "timeout"}
  def classify(%{reason: :over_budget}), do: {:budget, "over_budget"}
  def classify(%{reason: reason}), do: {:permanent, to_string(reason)}
end
