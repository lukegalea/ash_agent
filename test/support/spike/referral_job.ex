# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.Spike.ReferralJob do
  @moduledoc """
  A test host resource that includes the spike fragment: a clinic's job to
  send a referral letter. Plain `Ash.Resource` on Postgres, so the package's
  own suite shows the fragment works without any particular host.
  """

  use Ash.Resource,
    domain: AshAgent.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    fragments: [AshAgent.Test.Spike.FencedLifecycle]

  postgres do
    table "spike_referral_jobs"
    repo AshAgent.Test.Repo
  end
end
