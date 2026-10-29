# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.BusinessError do
  @moduledoc """
  A refusal the business rules of a target make, with a code a process can route on.

  Return it from an action an invocation runs when the request was well formed and the
  principal was allowed, but the domain says no: the clinician's licence has lapsed,
  the slot is already taken.

      {:error, AshAgent.BusinessError.exception(code: "licence_lapsed")}

  The invocation fails with `failure_class: :business` and `error_code` set to `code`,
  and does not retry. A process that ran the invocation maps it to a business error
  event with the same code (`AshAgent.Invocation.Failure.bpmn/1`), so a diagram can
  route on it instead of stopping in an incident.

  `code` is a short, stable identifier, not a sentence: it is stored and routed on.
  `details` are for the person reading the error and are not stored.
  """

  use Splode.Error, fields: [:code, :details], class: :invalid

  @impl true
  def message(%{code: code}), do: "refused by a business rule: #{code}"
end
