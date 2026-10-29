# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.LeaseLost do
  @moduledoc """
  A worker tried to complete an invocation whose lease it no longer holds: another claim
  took a newer epoch, or the row was completed. The worker's transaction rolls back,
  including any effect its target made in it.
  """

  use Splode.Error, fields: [:id, :epoch], class: :invalid

  @impl true
  def message(%{id: id, epoch: epoch}),
    do: "invocation #{id} is no longer held at lease epoch #{epoch}"
end
