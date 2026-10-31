# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Runtime do
  @moduledoc """
  How an agent run's step reaches a model. The host implements it and names it in the
  `run` section of its run resource (`AshAgent.Run`); the package never picks a model,
  a provider or a transport itself.

  A step makes one call to ash_ai's tool loop (`AshAi.ToolLoop.stream/2`). The loop's
  model and transport come from `loop_options/3`; the step adds the rest itself: the
  version's instructions as the system prompt, its toolset, the approval rule, the
  actor and tenant, and `max_iterations: 1`.
  """

  @doc """
  The tool loop options that choose the model and how it is called, for a step of
  `run` on `agent_version` (its `model_profile` names the host's profile):

    * `:model`: a model spec ReqLLM accepts;
    * `:req_llm`: the module the loop calls instead of `ReqLLM`, typically one that
      guards and records each call;
    * `:req_llm_opts`: options for it.

  `caller` names the call for the host's records: `"run:<run id>:<step seq>"`, the
  sequence number the step's first new message will take. A step repeated after its
  worker died uses the same name, so the host's record shows the repeated call.

  `{:error, reason}` when the profile cannot be used now (not configured, or not one an
  agent may run on): the step makes no call and is tried again when its lease expires.
  """
  @callback loop_options(
              agent_version :: Ash.Resource.record(),
              run :: Ash.Resource.record(),
              caller :: String.t()
            ) :: {:ok, keyword()} | {:error, term()}

  @doc """
  Runs `fun`, a whole step, in what the host keeps per request: a correlation id the
  run's audited writes share, a trace context. Optional; without it the step runs as it
  is.
  """
  @callback around_step(run :: Ash.Resource.record(), fun :: (-> result)) :: result
            when result: term()

  @optional_callbacks around_step: 2
end
