# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshAgent.Test.Repo do
  @moduledoc """
  The test host's repo. Test-env only; a consuming application brings its own.
  """

  use AshPostgres.Repo,
    otp_app: :ash_agent,
    warn_on_missing_ash_functions?: false

  @impl true
  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}

  @impl true
  def installed_extensions, do: ["ash-functions"]

  @impl true
  def prefer_transaction?, do: false
end
