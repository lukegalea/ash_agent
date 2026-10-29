# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.IdempotencyConflict do
  @moduledoc """
  An invocation key was used again for a different request: another target, other
  arguments, another principal or another parent.

  The existing row is not returned and not changed. A key names one request; a caller
  that means a new request uses a new key.
  """

  use Splode.Error, fields: [:key], class: :invalid

  @impl true
  def message(%{key: key}),
    do: "the invocation key #{inspect(key)} was already used for a different request"
end
