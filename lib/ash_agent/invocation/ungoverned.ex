# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.Ungoverned do
  @moduledoc """
  A governed action was run other than by its invocation (`AshAgent.Validations.Governed`).

  `reason` says which check failed:

    * `:no_invocation`: the action's context names no invocation;
    * `:unknown_invocation`: the invocation it names does not exist in this tenant;
    * `:not_executing`: the invocation is not executing, or is executing under another
      lease epoch;
    * `:not_executor`: the caller does not hold the secret of the claim that holds the
      lease, so it is not the executor that claimed it;
    * `:other_target`: the invocation is for another action;
    * `:other_arguments`: the inputs are not the ones the invocation was requested with;
    * `:other_principal`: the actor is not the one the invocation executes as.
  """

  use Splode.Error, fields: [:target, :reason], class: :invalid

  @reasons %{
    no_invocation: "no invocation is named",
    unknown_invocation: "the invocation named does not exist",
    not_executing: "the invocation named is not executing under this lease",
    not_executor: "the caller is not the executor that claimed the invocation",
    other_target: "the invocation named is for another action",
    other_arguments: "the inputs are not the ones the invocation was requested with",
    other_principal: "the actor is not the one the invocation executes as"
  }

  @impl true
  def message(%{target: target, reason: reason}),
    do: "#{target} runs only through its invocation: #{Map.get(@reasons, reason, reason)}"
end
