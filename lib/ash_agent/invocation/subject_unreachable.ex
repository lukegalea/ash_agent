# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.SubjectUnreachable do
  @moduledoc """
  The record an update or destroy target acts on still exists, but the actor the
  invocation runs as can no longer read it: their authority changed between the request
  and the run. The executor records it as `:denied`, like any refusal of the actor.

  A record that no longer exists at all is an `Ash.Error.Query.NotFound` instead,
  recorded as `:rejected`.
  """

  use Splode.Error, fields: [:resource], class: :forbidden

  @impl true
  def message(%{resource: resource}),
    do: "the executing actor cannot reach the #{inspect(resource)} record to act on"
end
