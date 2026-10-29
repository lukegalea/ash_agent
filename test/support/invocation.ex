# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.Invocation do
  @moduledoc """
  The test host's invocation resource: the `AshAgent.Invocation` fragment on a plain
  `Ash.Resource` over Postgres, with no tenancy, policies, audit or triggers. It shows the
  fragment needs nothing a particular host supplies beyond the `invocation` section.
  """

  use Ash.Resource,
    domain: AshAgent.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    fragments: [AshAgent.Invocation]

  postgres do
    table "invocations"
    repo AshAgent.Test.Repo
  end

  invocation do
    execution_identity(AshAgent.Test.ExecutionIdentity)
    digest_key(AshAgent.Test.DigestKey)
  end
end
