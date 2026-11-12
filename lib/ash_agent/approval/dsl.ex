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
      ],
      invocation: [
        type: :atom,
        doc: """
        The host's resource that includes `AshAgent.Invocation`. Optional: name it, and
        declare `set_approval_posture` a four-eyes target with `posture_floor?: true`, to
        let a posture be lowered through an approved invocation. Without it a change
        approved that way is not recognized, and only the sole administrator or an
        operator may lower the posture.
        """
      ],
      tenant_attribute: [
        type: :atom,
        doc: """
        The attribute of the row whose value is the tenant the `authority` is
        asked about when this row's posture changes. Optional: it defaults to
        the resource's primary key, when that is a single attribute; a resource
        without one must name an attribute here, and the check at compile time
        refuses a name that is not an attribute.
        """
      ]
    ]
  }

  @moduledoc """
  The `approval_posture` section a host fills on a resource that includes the
  `AshAgent.Approval.PostureFragment` fragment. The fragment brings this extension
  with it.

  `authority` and `execution_identity` are required, and checked when the resource
  compiles; `invocation` and `tenant_attribute` are optional.

  #{Spark.Dsl.Extension.doc_index([@section])}

  #{Spark.Dsl.Extension.doc([@section])}
  """

  use Spark.Dsl.Extension,
    sections: [@section],
    verifiers: [AshAgent.Approval.Verifiers.VerifyHost]
end
