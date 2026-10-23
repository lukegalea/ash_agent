# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent do
  @moduledoc """
  Governed invocations and durable agent runs for Ash Framework hosts.

  An agent, a process engine or a person asks the application to do something
  with side effects: send a message, change a record, call an outside service.
  This package is for the record of that request. Each one becomes an invocation
  row with its arguments, the principal it runs as, any approval it waited for,
  and its result, so it can be retried without doing the work twice. A durable
  agent run is the same idea applied to a model's tool loop: the run and its
  steps are rows, so a run survives a restart and every step can be read back.

  The package ships declarations, not finished resources:

    * Spark fragments carrying attributes, actions, changes, validations,
      calculations and a state machine, which the host includes on its own
      resources.
    * An extension for declaring the effects an action has.
    * Behaviours the host implements: who an invocation executes as, how an
      approval is opened and read, and where the execution history comes from.

  The host supplies everything that depends on the application: the base
  resource and data layer, tenancy, ownership, policies, ash_oban triggers and
  their workers, audit and encryption at rest. See "What the host supplies" in
  the documentation.

  ## Status

  This is the bootstrap release. No fragment, extension or behaviour is built
  yet; `usage-rules.md` lists what is planned and marks each part as not yet
  built.
  """
end
