# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.Failure do
  @moduledoc """
  Typed failure: what an error from a target means for its invocation, what happens
  next, and what a process that ran it sees.

  | Error | Class | Next | A process sees |
  |---|---|---|---|
  | `Ash.Error.Forbidden` | `:denied` | `failed`, final | an incident |
  | `Ash.Error.Invalid` | `:rejected` | `failed`, final | an incident |
  | the subject of an update or destroy is gone (`NotFound`, invalid) | `:rejected` | `failed`, final | an incident |
  | the subject is there but the executing actor cannot reach it (`AshAgent.Invocation.SubjectUnreachable`, forbidden) | `:denied` | `failed`, final | an incident |
  | `AshAgent.BusinessError{code}` | `:business` | `failed`, final | a business error `code` |
  | transient (`AshAgent.FailureClass`) | `:transient` | `ready` again after a backoff, until `max_attempts`; then `failed`, which `retry` may re-ready | waits; then an incident |
  | indeterminate, on a target that writes only here, or an idempotent one | `:transient` | as transient: running it again is safe | waits |
  | indeterminate, on an outside target that is not idempotent | — | `outcome_unknown`, never retried blindly | waits |
  | a deadline on outside work that is not idempotent | `:timeout` | `outcome_unknown` | waits |
  | a deadline on other work | `:timeout` | `failed`, final | an incident |
  | a refused budget (`AshAgent.FailureClass`) | `:budget` | `failed`, final for the invocation | an incident |
  | anything else | `:permanent` | `failed`, final | an incident |

  An error is classified from the inside out: the first error in the tree that is an
  `AshAgent.BusinessError` or that an `AshAgent.FailureClass` implementation classifies
  decides; otherwise the outermost Ash error class does.
  """

  alias AshAgent.BusinessError

  @classes [:rejected, :denied, :business, :transient, :permanent, :timeout, :budget]

  @typedoc "A failure class, recorded in `failure_class`."
  @type class :: :rejected | :denied | :business | :transient | :permanent | :timeout | :budget

  @typedoc "A classified error: a class, or `:indeterminate` when the effect may have happened."
  @type classified :: {class() | :indeterminate, String.t()}

  @typedoc "What happens to the row next."
  @type next :: :fail | {:retry, non_neg_integer()} | :unknown

  @doc "Classifies `error`, as the table above says."
  @spec classify(term()) :: classified()
  def classify(error) do
    case inner(error) do
      nil -> outer(error)
      classified -> classified
    end
  end

  @doc """
  What happens next to a row whose attempt `attempt` (counted from 1) failed with
  `classified`: `:fail`, `{:retry, delay_ms}` or `:unknown`. `effects` is the row's
  effects snapshot.
  """
  @spec next(classified(), map(), pos_integer(), pos_integer()) :: next()
  def next({:indeterminate, code}, effects, attempt, max_attempts) do
    if repeatable?(effects),
      do: next({:transient, code}, effects, attempt, max_attempts),
      else: :unknown
  end

  def next({:transient, _code}, _effects, attempt, max_attempts) when attempt < max_attempts,
    do: {:retry, backoff(attempt)}

  def next(_classified, _effects, _attempt, _max_attempts), do: :fail

  @doc "The class recorded for `classified` when the row fails."
  @spec recorded_class(classified()) :: class()
  def recorded_class({:indeterminate, _code}), do: :transient
  def recorded_class({class, _code}), do: class

  @doc """
  Whether running the target again cannot repeat its effect: it writes only to this
  application (its effect commits with `succeed` or not at all), or it is idempotent.
  Undeclared counts as neither, which is MCP's default and the safe reading.
  """
  @spec repeatable?(map()) :: boolean()
  def repeatable?(effects) when is_map(effects) do
    Map.get(effects, "open_world", Map.get(effects, :open_world)) == false or
      Map.get(effects, "idempotent", Map.get(effects, :idempotent)) == true
  end

  def repeatable?(_effects), do: false

  @doc "The wait before attempt `attempt + 1`: 30 seconds, quadrupling, at most an hour."
  @spec backoff(pos_integer()) :: non_neg_integer()
  def backoff(attempt) when attempt >= 1,
    do: min(30_000 * Integer.pow(4, attempt - 1), 3_600_000)

  @doc """
  What a process that ran the invocation sees: `:completed`, `{:error, {:bpmn_error,
  code, %{}}}` for a business failure (a diagram's error boundary routes on `code`),
  `{:error, {:incident, class, code}}` for any other final failure, and `:waiting` while
  the outcome is not final.
  """
  @spec bpmn(map()) ::
          :completed
          | :waiting
          | {:error, {:bpmn_error, String.t(), map()}}
          | {:error, {:incident, atom(), String.t() | nil}}
  def bpmn(%{status: :succeeded}), do: :completed

  def bpmn(%{status: :failed, failure_class: :business, error_code: code}),
    do: {:error, {:bpmn_error, code, %{}}}

  def bpmn(%{status: status, failure_class: class, error_code: code})
      when status in [:failed, :rejected, :stale, :cancelled],
      do: {:error, {:incident, class || status, code}}

  def bpmn(_invocation), do: :waiting

  # --- classifying -------------------------------------------------------------------

  defp inner(%BusinessError{code: code}), do: {:business, to_string(code)}

  # In a project with no implementation of the protocol but `Any`'s, Dialyzer sees that
  # `classify/1` only ever returns `:unclassified`; a host's implementations are what
  # make the first clause match.
  @dialyzer {:no_match, inner: 1}

  defp inner(error) do
    case AshAgent.FailureClass.classify(error) do
      {class, code} when class in @classes or class == :indeterminate ->
        {class, to_string(code)}

      _unclassified ->
        error |> children() |> Enum.find_value(&inner/1)
    end
  end

  defp children(%{errors: errors}) when is_list(errors), do: errors
  defp children(%{error: error}) when not is_nil(error), do: [error]
  defp children(_error), do: []

  defp outer(%Ash.Error.Forbidden{}), do: {:denied, "forbidden"}
  defp outer(%Ash.Error.Invalid{}), do: {:rejected, "invalid"}
  defp outer(_error), do: {:permanent, "error"}
end
