# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.Domain do
  @moduledoc """
  The test host's domain.

  The test host plays the part of an application that consumes this package. It
  uses plain `Ash.Resource` with no base resource of its own, so the suite shows
  that nothing in the package depends on any particular host.
  """

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshAgent.Test.Clinician do
      define :register_clinician, action: :create
      define :list_clinicians, action: :read
    end

    resource AshAgent.Test.CredentialCheck do
      define :list_checks, action: :read
    end

    resource AshAgent.Test.Invocation do
      define :invoke, action: :invoke, args: [:target, :args]
      define :request_invocation, action: :request
      define :get_invocation, action: :read, get_by: [:id]
      define :claim_invocation, action: :claim
      define :apply_decision, action: :apply_decision
      define :request_cancel, action: :request_cancel
      define :execute_invocation, action: :execute, args: [:primary_key]
      define :reconcile_invocation, action: :reconcile, args: [:primary_key]
      define :complete_external, action: :complete_external
      define :apply_resolution, action: :apply_resolution
      define :retry_invocation, action: :retry
    end

    resource AshAgent.Test.AgentVersion do
      define :register_agent, action: :register_from_code, args: [:agent]
      define :create_agent_draft, action: :create_draft
      define :revise_agent_draft, action: :revise_draft
      define :publish_agent_version, action: :apply_publish
      define :retire_agent_version, action: :retire
      define :get_agent_version, action: :read, get_by: [:id]
      define :latest_published_agent_version, action: :latest_published, args: [:key]
      define :list_agent_versions, action: :read
    end

    resource AshAgent.Test.Run do
      define :start_run, action: :start, args: [:agent, :input]
      define :get_run, action: :read, get_by: [:id]
      define :claim_step, action: :claim_step
      define :record_step, action: :record_step
      define :recover_run, action: :recover
      define :request_run_cancel, action: :request_cancel
      define :step_run, action: :step, args: [:primary_key]
    end

    resource AshAgent.Test.Step do
      define :list_steps, action: :read
    end

    resource AshAgent.Test.Spike.ReferralJob do
      define :enqueue_referral, action: :enqueue, args: [:label]
      define :claim_referral, action: :claim
      define :complete_referral, action: :complete, args: [:epoch]
    end
  end
end
