# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.AgentVersion do
  @moduledoc """
  A Spark fragment for an agent version: one immutable, numbered definition of an agent
  that a run pins, so what an agent was when it ran is a row, not whatever the code
  says now.

      defmodule MyClinic.Execution.AgentVersion do
        use Ash.Resource,
          domain: MyClinic.Execution,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshAgent.Effects],
          fragments: [AshAgent.AgentVersion]

        postgres do
          table "agent_versions"
          repo MyClinic.Repo
        end
      end

  ## What a version holds

  `key` and `version` (unique together), `instructions` (plain text),
  `model_profile`, `toolset` (each target the agent may ask for, with the target's
  digest when the version was written), `limits`, `output_type`, `source` (`:code` or
  `:authored`), `baseline_id` (the version this one was copied from, when it was) and
  `content_hash`, SHA-256 over the canonical JSON of the instructions, model profile,
  toolset, limits and output type (`AshAgent.AgentVersion.Definition.content_hash/1`).
  Who a run acts as (`authority`) and whether a run may start with no person asking
  (`requesterless`) are chosen when the version is published, not before.

  ## Lifecycle

  `draft → published → retired`, one way. A draft may be revised; a published version
  never changes again; a retired one starts no new run.

  ## Actions

    * `register_from_code` (generic): the code sync. Takes an agent module
      (`AshAgent.Agent`) and returns the key's latest version when its content hash is
      the declaration's, or a new draft numbered one past it when it is not. Running it
      again with the same code writes nothing.
    * `create_draft` (create): a draft written by a person (`source: :authored`),
      numbered one past the key's latest version.
    * `revise_draft` (update): changes a draft's content. Refused on any other status.
    * `apply_publish` (update): `draft → published`, with the publish-time choices
      `authority` and `requesterless`. Refused when the version cannot be published
      (`AshAgent.AgentVersion.Definition.publish_problems/1`): a toolset target that
      declares no effects (`AshAgent.Effects.Info`) or whose declaration changed since
      the draft was written, or a limit that is missing. Who may publish, and the
      approval it waits for, are the host's: it declares `apply_publish` as a governed
      target (`AshAgent.Validations.Governed`) with an effects declaration that asks for
      approval, and asks for it through its invocation resource.
    * `retire` (update): `published → retired`.
    * `latest_published` (read, one row): the key's highest published version.

  ## Pinning and drift

  A run records the version's id and reads it again at each step through
  `AshAgent.AgentVersion.Definition.check_pinned/1`: the version must be published or
  retired, and each toolset target must still resolve to the digest it had when the
  version was written. A target whose input schema or effects declaration has changed
  since is `AshAgent.AgentVersion.DefinitionDrift`, and the run fails closed rather than
  offer the model a tool that is not the one that was approved. Publishing a later
  version changes nothing about an earlier one, so a run pinned to version 1 carries on
  after version 2 is published.

  ## What the fragment does not declare

  Tenancy, ownership, policies, approvals, the effects declarations of its own actions,
  relationships to host resources and the `postgres` block.
  """

  use Spark.Dsl.Fragment,
    of: Ash.Resource,
    extensions: [AshStateMachine]

  @content [:instructions, :model_profile, :toolset, :limits, :output_type]

  @doc false
  def content_attributes, do: @content

  state_machine do
    state_attribute :status
    initial_states [:draft]
    default_initial_state :draft

    transitions do
      transition :apply_publish, from: :draft, to: :published
      transition :retire, from: :published, to: :retired
    end
  end

  actions do
    defaults [:read]

    read :latest_published do
      description "The highest published version of `key`."
      get? true

      argument :key, :string, allow_nil?: false

      filter expr(key == ^arg(:key) and status == :published)
      prepare build(sort: [version: :desc], limit: 1)
    end

    action :register_from_code, :struct do
      description """
      Register an agent declared in code: the key's latest version when nothing changed,
      otherwise a new draft numbered one past it.
      """

      argument :agent, :atom do
        description "The agent module (`use AshAgent.Agent`)."
        allow_nil? false
      end

      run AshAgent.AgentVersion.Actions.RegisterFromCode
    end

    create :create_draft do
      description "Write a draft, numbered one past the key's latest version."
      accept [:key | @content]

      change AshAgent.AgentVersion.Changes.Content
    end

    update :revise_draft do
      description "Change a draft's content. Refused on a version that is not a draft."
      accept @content
      require_atomic? false

      change filter(expr(status == :draft))
      change AshAgent.AgentVersion.Changes.Content
    end

    update :apply_publish do
      description """
      Publish a draft with who its runs act as. Refused when the draft cannot be
      published.
      """

      accept []
      require_atomic? false

      argument :authority, :map do
        description """
        Who a run of this version acts as: `%{"type" => "requester"}` (the default, the
        person who asked), or `%{"type" => "automation", "name" => principal}`.
        """

        allow_nil? false
        default %{"type" => "requester"}
      end

      argument :requesterless, :boolean do
        description """
        Whether a run may start with no person asking (a schedule, a process start).
        Only with an automation authority.
        """

        allow_nil? false
        default false
      end

      change filter(expr(status == :draft))
      change AshAgent.AgentVersion.Changes.Publish
      change transition_state(:published)
      change set_attribute(:published_at, &DateTime.utc_now/0)
    end

    update :retire do
      description "Stop new runs starting on a published version. Runs pinned to it carry on."
      accept []
      require_atomic? false

      change filter(expr(status == :published))
      change transition_state(:retired)
      change set_attribute(:retired_at, &DateTime.utc_now/0)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :key, :string do
      allow_nil? false
      public? true
      constraints max_length: 255
      description "The agent's stable name. Versions are numbered per key."
    end

    attribute :version, :integer do
      allow_nil? false
      public? true
      constraints min: 1
      description "This version's number within its key, from 1."
    end

    attribute :source, :atom do
      allow_nil? false
      public? true
      default :authored
      constraints one_of: [:code, :authored]

      description "Whether the version was registered from an agent module or written by a person."
    end

    attribute :instructions, :string do
      allow_nil? false
      public? true
      constraints allow_empty?: false, trim?: false
      description "The system prompt, as plain text."
    end

    attribute :model_profile, :string do
      allow_nil? false
      public? true
      constraints max_length: 255
      description "The host's model profile the agent runs on."
    end

    attribute :toolset, {:array, :map} do
      allow_nil? false
      public? true
      default []

      description """
      Each target the agent may ask for, `%{"target" => name, "target_digest" => digest}`.
      The digest is the target's when the version was written (`AshAgent.Invocation.Target.digest/1`),
      `nil` when the target did not resolve.
      """
    end

    attribute :limits, :map do
      allow_nil? false
      public? true

      constraints fields: [
                    max_steps: [type: :integer, allow_nil?: true, constraints: [min: 1]],
                    max_tool_calls: [type: :integer, allow_nil?: true, constraints: [min: 1]],
                    deadline: [type: :integer, allow_nil?: true, constraints: [min: 1]],
                    token_budget: [type: :integer, allow_nil?: true, constraints: [min: 1]],
                    max_repairs: [type: :integer, allow_nil?: true, constraints: [min: 0]]
                  ]

      description """
      A run's bounds: `max_steps` (model calls), `max_tool_calls`, `deadline` (seconds),
      `token_budget` (tokens) and `max_repairs` (turns to repair an output). All are
      required to publish.
      """
    end

    attribute :output_type, :string do
      allow_nil? false
      public? true
      default "string"
      constraints max_length: 255
      description "The Ash type a run's output is cast to, by name."
    end

    attribute :content_hash, :string do
      allow_nil? false
      public? true

      description "SHA-256 of the version's canonical content (`AshAgent.AgentVersion.Definition.content_hash/1`)."
    end

    attribute :baseline_id, :uuid do
      public? true

      description "The version this one was copied from, such as a shared baseline a tenant adopted."
    end

    attribute :authority, :map do
      public? true

      constraints fields: [
                    type: [
                      type: :atom,
                      allow_nil?: false,
                      constraints: [one_of: [:requester, :automation]]
                    ],
                    name: [type: :string, allow_nil?: true]
                  ]

      description """
      Who a run acts as, chosen when the version was published: the requester, or a named
      automation principal acting for them. `nil` on a draft.
      """
    end

    attribute :requesterless, :boolean do
      allow_nil? false
      public? true
      default false

      description "Whether a run may start with no person asking. Chosen when the version was published."
    end

    attribute :published_at, :utc_datetime_usec, public?: true
    attribute :retired_at, :utc_datetime_usec, public?: true
  end

  identities do
    identity :unique_version, [:key, :version]
  end
end
