# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.Spike.FencedLifecycle do
  @moduledoc """
  A spike fragment, not part of the package: the smallest fragment shaped like
  the ones this package will ship, so a host can check that one composes onto
  its own base resource before the real fragments are written.

  It carries what the real fragments carry and nothing a host supplies:
  attributes, a state machine, and actions with a change and a filtered update.
  `:claim` moves a queued row to running and takes a new lease epoch;
  `:complete` finishes the row only for the holder of the current epoch, by
  filtering the update on it. A writer holding an older epoch matches no row
  and gets `Ash.Error.Changes.StaleRecord`.

  No tenancy, ownership, policies, triggers, audit or `postgres` block: those
  belong to the host. It lives in `test/support` so the package never ships it;
  a host that wants to try it compiles this file and
  `AshAgent.Test.Spike.NextEpoch` from the dependency's source.
  """

  use Spark.Dsl.Fragment, of: Ash.Resource, extensions: [AshStateMachine]

  state_machine do
    initial_states [:queued]
    default_initial_state :queued

    transitions do
      transition :claim, from: :queued, to: :running
      transition :complete, from: :running, to: :completed
    end
  end

  actions do
    defaults [:read]

    create :enqueue do
      accept [:label]
    end

    update :claim do
      accept []
      require_atomic? false
      change transition_state(:running)
      change AshAgent.Test.Spike.NextEpoch
    end

    update :complete do
      accept [:result]
      require_atomic? false

      argument :epoch, :integer do
        allow_nil? false
      end

      change filter(expr(lease_epoch == ^arg(:epoch)))
      change transition_state(:completed)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :label, :string do
      allow_nil? false
      public? true
    end

    attribute :lease_epoch, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :result, :string do
      public? true
    end
  end
end
