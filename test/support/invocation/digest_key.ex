# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.DigestKey do
  @moduledoc "The test host's `AshAgent.DigestKey`: one fixed key for every row."

  @behaviour AshAgent.DigestKey

  @impl true
  def digest_key(_invocation), do: {:ok, "test host digest key"}
end
