# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Run.Dsl do
  @section %Spark.Dsl.Section{
    name: :run,
    describe: """
    What the host supplies to the `AshAgent.Run` fragment: the resources a run's version, steps
    and tool calls live in, and how a step reaches a model.
    """,
    examples: [
      """
      run do
        agent_version MyClinic.Execution.AgentVersion
        step MyClinic.Execution.Step
        invocation MyClinic.Execution.Invocation
        runtime MyClinic.AgentRuntime
      end
      """
    ],
    schema: [
      agent_version: [
        type: :atom,
        doc: "The host's resource that includes `AshAgent.AgentVersion`: what a run pins."
      ],
      step: [
        type: :atom,
        doc: "The host's resource that includes `AshAgent.Step`: the run's journal."
      ],
      invocation: [
        type: :atom,
        doc: """
        The host's resource that includes `AshAgent.Invocation`: every tool call that is not an
        in-loop read is one of its rows. Its `execution_identity` is the run's too.
        """
      ],
      runtime: [
        type: {:behaviour, AshAgent.Runtime},
        doc: "The module implementing `AshAgent.Runtime`: how a step reaches a model."
      ]
    ]
  }

  @moduledoc """
  The `run` section a host fills on a resource that includes the `AshAgent.Run`
  fragment. The fragment brings this extension with it.

  Every option is required, and checked when the resource compiles. A resource that also
  uses `AshOban` must declare a trigger named `:step` running the `:step` action and one
  named `:recover` running the `:recover` action; see `usage-rules/triggers.md`.

  #{Spark.Dsl.Extension.doc_index([@section])}

  #{Spark.Dsl.Extension.doc([@section])}
  """

  use Spark.Dsl.Extension,
    sections: [@section],
    transformers: [AshAgent.Run.Transformers.AddNeedsStep],
    verifiers: [AshAgent.Run.Verifiers.VerifyHost]
end
