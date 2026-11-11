# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.Referral do
  @moduledoc """
  A test host resource with a state machine: a clinic's referral of a clinician to the
  licensing board.

  A referral is drafted, then submitted, then completed. `complete` is a transition only
  a `submitted` referral may make, so a request to complete a `draft` one is refused at
  request time, before anyone is asked to approve it; `withdraw` is a destroy only a
  `draft` referral may take. `submit` carries an after-action hook with a visible side
  effect (`hooks/0`), which nothing before its execution may trigger.

  Any clinic staff may read a referral, and draft one. Submitting is a person's alone,
  on a referral left open or held by them: `restricted_to` names the one person who may
  submit a held referral, and an automation holds no grant to submit at all, so a
  request by anyone else is refused without learning whether the referral is there.
  """

  use Ash.Resource,
    domain: AshAgent.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine, AshAgent.Effects]

  @table __MODULE__
  @hooks :hooks

  postgres do
    table "referrals"
    repo AshAgent.Test.Repo
  end

  effects do
    action :draft,
      kind: :edit,
      destructive?: false,
      open_world?: false,
      intent: :execute

    action :submit,
      kind: :edit,
      destructive?: false,
      open_world?: false,
      intent: :execute

    action :complete,
      kind: :edit,
      destructive?: false,
      open_world?: false,
      intent: :execute

    action :withdraw,
      kind: :delete,
      destructive?: true,
      open_world?: false,
      intent: :execute
  end

  state_machine do
    state_attribute :state
    initial_states [:draft]
    default_initial_state :draft

    transitions do
      transition :submit, from: [:draft], to: :submitted
      transition :complete, from: [:submitted], to: :completed
    end
  end

  actions do
    defaults [:read]

    create :draft do
      primary? true
      accept [:note, :restricted_to]
    end

    update :submit do
      accept []
      require_atomic? false

      change transition_state(:submitted)

      # The visible side effect: counted once the referral is submitted, and only then.
      change after_action(fn _changeset, referral, _context ->
               count()
               {:ok, referral}
             end)
    end

    update :complete do
      accept []
      require_atomic? false
      change transition_state(:completed)
    end

    destroy :withdraw do
      accept []
      require_atomic? false

      validate fn changeset, _context ->
        if changeset.data.state == :draft,
          do: :ok,
          else: {:error, AshAgent.BusinessError.exception(code: "not_draft")}
      end
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action_type(:create) do
      authorize_if always()
    end

    policy action(:submit) do
      description """
      A referral is submitted by a person: anyone when it is open, the one person it
      is restricted to when it is held. An automation holds no grant to submit.
      """

      authorize_if expr(is_nil(restricted_to) and is_nil(^actor(:automation)))
      authorize_if expr(restricted_to == ^actor(:id) and is_nil(^actor(:automation)))
    end

    policy action(:complete) do
      authorize_if always()
    end

    policy action(:withdraw) do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :note, :string do
      public? true
    end

    attribute :restricted_to, :string do
      public? true

      description """
      The one person (their id) who may submit this referral; nil when any person may.
      """
    end
  end

  @doc """
  How many times `submit`'s after-action hook has run: the visible side effect a
  request-time pre-check must never trigger.
  """
  def hooks do
    if :ets.whereis(@table) == :undefined,
      do: 0,
      else: :ets.lookup_element(@table, @hooks, 2, 0)
  end

  defp count do
    if :ets.whereis(@table) == :undefined,
      do: :ets.new(@table, [:named_table, :public, :set])

    :ets.update_counter(@table, @hooks, 1, {@hooks, 0})
  end
end
