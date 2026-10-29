# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Invocation.Dsl do
  @section %Spark.Dsl.Section{
    name: :invocation,
    describe: """
    What the host supplies to the `AshAgent.Invocation` fragment: who an invocation runs as, and the key its
    argument digest is taken under.
    """,
    examples: [
      """
      invocation do
        execution_identity MyClinic.ExecutionIdentity
        digest_key MyClinic.InvocationDigestKey
      end
      """
    ],
    schema: [
      execution_identity: [
        type: {:behaviour, AshAgent.ExecutionIdentity},
        doc: "The module implementing `AshAgent.ExecutionIdentity` for this resource."
      ],
      digest_key: [
        type: {:behaviour, AshAgent.DigestKey},
        doc: "The module implementing `AshAgent.DigestKey` for this resource."
      ]
    ]
  }

  @moduledoc """
  The `invocation` section a host fills on a resource that includes the
  `AshAgent.Invocation` fragment. The fragment brings this extension with it.

  Both options are required, and checked when the resource compiles. A resource that
  also uses `AshOban` must declare a trigger named `:execute` running the `:execute`
  action, because `request` and `apply_decision` enqueue it for every row they make
  ready; see `usage-rules/triggers.md`.

  #{Spark.Dsl.Extension.doc_index([@section])}

  #{Spark.Dsl.Extension.doc([@section])}
  """

  use Spark.Dsl.Extension,
    sections: [@section],
    verifiers: [AshAgent.Invocation.Verifiers.VerifyHost]
end
