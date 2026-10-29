# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.NoPrincipal do
  @moduledoc """
  The host named no principal for the actor asking (`c:AshAgent.ExecutionIdentity.principal_for/2`
  returned an error), so the request cannot be recorded: there is no one it would run as.
  """

  use Splode.Error, fields: [:reason], class: :forbidden

  @impl true
  def message(%{reason: reason}), do: "no principal can run this request: #{inspect(reason)}"
end
