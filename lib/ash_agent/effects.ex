# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Effects do
  @effect %Spark.Dsl.Entity{
    name: :action,
    describe: """
    Declares what one action of this resource does to the world.
    """,
    examples: [
      """
      action :activate_credential,
        kind: :edit,
        destructive?: false,
        idempotent?: true,
        open_world?: true,
        approval: :four_eyes,
        approver_role: :credentialing_committee,
        approval_expires_in: [days: 3],
        intent: :execute,
        reconcile_with: :lookup_activation,
        preconditions: [:clinician_id]
      """,
      "action :read, kind: :read, read_only?: true, open_world?: false, intent: :inspect"
    ],
    target: AshAgent.Effects.Effect,
    args: [:name],
    identifier: :name,
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The name of the action this declaration describes."
      ],
      kind: [
        type: {:one_of, AshAgent.Effects.Effect.kinds()},
        required: true,
        doc: """
        The ACP tool kind: `:read`, `:edit`, `:delete`, `:move`, `:search`, `:execute`, `:think`, `:fetch`,
        `:switch_mode` or `:other`. Always stated, never derived from the hints.
        """
      ],
      read_only?: [
        type: :boolean,
        default: false,
        doc: """
        MCP `readOnlyHint`: the action does not modify its environment. Accepted only on an Ash `:read` action.
        """
      ],
      destructive?: [
        type: :boolean,
        default: true,
        doc:
          "MCP `destructiveHint`: the action may destroy or overwrite something, not only add to it."
      ],
      idempotent?: [
        type: :boolean,
        default: false,
        doc: "MCP `idempotentHint`: running it again with the same input has no further effect."
      ],
      open_world?: [
        type: :boolean,
        default: true,
        doc: "MCP `openWorldHint`: the action reaches outside this application's own data."
      ],
      approval: [
        type: {:one_of, AshAgent.Effects.Effect.approvals()},
        default: :none,
        doc: """
        `:none` runs it without asking; `:confirm` asks before it runs; `:four_eyes` needs a second person, who
        is not the one asking, from `approver_role`.
        """
      ],
      approver_role: [
        type: :atom,
        doc: "The role whose holders may approve it. Required with `approval: :four_eyes`."
      ],
      approval_expires_in: [
        type: :keyword_list,
        keys: [
          days: [type: :pos_integer],
          hours: [type: :pos_integer],
          minutes: [type: :pos_integer]
        ],
        doc: "How long an approval stays valid, as a duration keyword list such as `[days: 3]`."
      ],
      intent: [
        type: {:one_of, AshAgent.Effects.Effect.intents()},
        doc: "What the action is for: `:inspect`, `:propose`, `:approve`, `:test` or `:execute`."
      ],
      reconcile_with: [
        type: :atom,
        doc: """
        An action on this resource that finds out whether an outside effect happened, used when the outcome of a
        call is unknown.
        """
      ],
      preconditions: [
        type: {:list, :atom},
        default: [],
        doc: """
        Inputs of the action that name records whose state must not change between approval and execution.
        """
      ]
    ]
  }

  @effects %Spark.Dsl.Section{
    name: :effects,
    describe: """
    What this resource's actions do to the world, in MCP's tool-annotation vocabulary plus an ACP tool kind,
    approval, intent and reconciliation. This declaration is authoritative: hints read from anywhere else, such as
    a foreign MCP server, never relax it.
    """,
    entities: [@effect]
  }

  @moduledoc """
  A Spark extension for resources: declares, per action, what the action does to the world.

  Callers read the declaration instead of classifying actions themselves: whether an action only reads, whether it
  reaches outside the application, whether it is safe to repeat, whether it needs approval and from whom, and how to
  find out what happened when a call's outcome is lost.

  ```elixir
  defmodule MyClinic.Credential do
    use Ash.Resource, extensions: [AshAgent.Effects]

    effects do
      action :read, kind: :read, read_only?: true, open_world?: false, intent: :inspect

      action :activate,
        kind: :edit,
        destructive?: false,
        idempotent?: true,
        approval: :four_eyes,
        approver_role: :credentialing_committee,
        reconcile_with: :lookup_activation
    end
  end
  ```

  ## Verification at compile time

    * every declaration names an action of the resource, at most once;
    * `read_only?: true` is accepted only on an Ash `:read` action, because "read-only" is a fact about the action's
      type, not a hint someone may get wrong;
    * `approval: :four_eyes` names an `approver_role`, and `approver_role` and `approval_expires_in` appear only
      with an approval;
    * `reconcile_with` names a `:read` or generic action of the resource;
    * `preconditions` name arguments or accepted attributes of the action.

  `AshAgent.Effects.Domain` checks, on a domain, that the actions it exposes as tools are declared.

  Read declarations with `AshAgent.Effects.Info`.

  #{Spark.Dsl.Extension.doc_index([@effects])}

  #{Spark.Dsl.Extension.doc([@effects])}
  """

  use Spark.Dsl.Extension,
    sections: [@effects],
    verifiers: [AshAgent.Effects.Verifiers.VerifyDeclarations]
end
