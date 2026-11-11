# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Approval.PostureChangeRefused do
  @moduledoc """
  A tenant's approval posture was set by someone the posture rules do not let set it
  (`AshAgent.Approval.Validations.PostureChange`).

  `reason` is one of:

    * `:lowering`: lowering needs the sole administrator, an operator, or a change
      approved under four eyes;
    * `:raising`: raising needs an administrator or an operator.

  It is its own error so that a request to change the posture through an invocation
  is not refused at request time for want of the approval it is asking for
  (`AshAgent.Invocation.Target.precheck/3`): the claim checks it again, with the
  approval in hand.
  """

  use Splode.Error, fields: [:reason, field: :approval_posture], class: :invalid

  @impl true
  def message(%{reason: :lowering}),
    do:
      "a lower approval posture needs the sole administrator, an operator, " <>
        "or a change approved under four eyes"

  def message(%{reason: :raising}), do: "a higher approval posture needs an administrator"
  def message(%{reason: reason}), do: "the approval posture cannot be set: #{inspect(reason)}"
end
