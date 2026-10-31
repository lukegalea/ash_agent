# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.Runtime do
  @moduledoc """
  The test host's `AshAgent.Runtime`: every step calls `AshAgent.Test.ScriptedModel`
  instead of a provider. A profile named `"offline"` has no model, as a profile the host
  cannot use.
  """

  @behaviour AshAgent.Runtime

  @impl true
  def loop_options(%{model_profile: "offline"}, _run, _caller), do: {:error, :offline}

  def loop_options(_version, _run, caller) do
    {:ok,
     model: "openai:gpt-4o-mini",
     req_llm: AshAgent.Test.ScriptedModel,
     req_llm_opts: [caller: caller]}
  end
end
