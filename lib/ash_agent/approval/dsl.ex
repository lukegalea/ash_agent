# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Approval.Dsl do
  @section %Spark.Dsl.Section{
    name: :approval_posture,
    describe: """
    What the host supplies for the approval-posture rules on a resource that includes
    `AshAgent.Approval.PostureFragment`: its `AshAgent.Approval.Authority` implementation,
    and the `AshAgent.ExecutionIdentity` implementation whose `principal_of/1` maps an actor
    to a person for those rules.
    """,
    examples: [
      """
      approval_posture do
        authority MyClinic.ApprovalAuthority
        execution_identity MyClinic.ExecutionIdentity
      end
      """
    ],
    schema: [
      authority: [
        type: {:behaviour, AshAgent.Approval.Authority},
        doc: "The module implementing `AshAgent.Approval.Authority` for this resource."
      ],
      execution_identity: [
        type: {:behaviour, AshAgent.ExecutionIdentity},
        doc: """
        The module implementing `AshAgent.ExecutionIdentity` for the host, whose
        `principal_of/1` maps the actor of a posture change to the person deciding it.
        """
      ]
    ]
  }

  @moduledoc """
  The `approval_posture` section a host fills on a resource that includes the
  `AshAgent.Approval.PostureFragment` fragment. The fragment brings this extension
  with it.

  Both options are required, and checked when the resource compiles.

  #{Spark.Dsl.Extension.doc_index([@section])}

  #{Spark.Dsl.Extension.doc([@section])}
  """

  use Spark.Dsl.Extension,
    sections: [@section],
    verifiers: [AshAgent.Approval.Verifiers.VerifyHost]
end
