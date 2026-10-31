# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Step do
  @moduledoc """
  A Spark fragment for an agent run's journal: one row for each message added to a
  run's conversation, numbered in order, never changed.

      defmodule MyClinic.Execution.Step do
        use Ash.Resource,
          domain: MyClinic.Execution,
          data_layer: AshPostgres.DataLayer,
          fragments: [AshAgent.Step]

        postgres do
          table "agent_steps"
          repo MyClinic.Repo
        end
      end

  ## What a step holds

  `run_id` and `seq` (unique together); `role`: `:assistant` for a model turn, `:tool`
  for a tool's result, `:user` for a message the run itself added (a request to repair
  an answer); `parts`, the message as ash_ai's `AshAi.Transcript.to_parts/2` stores it
  (a `:user` step's parts are `[%{"type" => "text", "text" => text}]`); `tool_calls`,
  the calls a model turn made (`%{"id", "name"}`); and `prompt_fingerprint`, the
  `AshAi.Transcript.fingerprint/2` of the instructions and tools the turn was made
  with.

  A tool result is in the journal whether it came from an in-loop read or from an
  invocation; the invocation row stays the source of truth for the effect.

  ## Actions

    * `append` (create): adds a step. Only the run's `record_step` calls it, inside its
      fenced transaction (`AshAgent.Run`); a host reserves it for the job runner.

  There is no update and no destroy: the journal is append-only.

  ## What the fragment does not declare

  Tenancy, ownership, policies, encryption, the relationship to the run and the
  `postgres` block. `parts` is marked `sensitive?`; a host that encrypts content at rest
  seals it.
  """

  use Spark.Dsl.Fragment, of: Ash.Resource

  actions do
    defaults [:read]

    create :append do
      description "Add a message to a run's journal. Called only by the run's `record_step`."
      accept [:run_id, :seq, :role, :parts, :tool_calls, :prompt_fingerprint]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :run_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :seq, :integer do
      allow_nil? false
      public? true
      constraints min: 1
      description "The message's place in the run's conversation, from 1."
    end

    attribute :role, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:user, :assistant, :tool]
    end

    attribute :parts, {:array, :map} do
      allow_nil? false
      public? true
      sensitive? true
      default []
      description "The message, as `AshAi.Transcript.to_parts/2` stores it."
    end

    attribute :tool_calls, {:array, :map} do
      allow_nil? false
      public? true
      default []
      description ~s(The calls a model turn made: `%{"id" => id, "name" => tool}`.)
    end

    attribute :prompt_fingerprint, :string do
      public? true
      description "`AshAi.Transcript.fingerprint/2` of the instructions and tools offered."
    end
  end

  identities do
    identity :unique_seq, [:run_id, :seq]
  end
end
