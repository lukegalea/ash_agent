# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

import Config

# The test host. Connection details come from the environment so both devenv
# (port read back from the cluster's postgresql.conf) and CI (a service
# container on 5432) work without editing this file.
config :ash_agent, ecto_repos: [AshAgent.Test.Repo]
config :ash_agent, ash_domains: [AshAgent.Test.Domain]

config :ash_agent, AshAgent.Test.Repo,
  hostname: System.get_env("DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  username: System.get_env("DB_USER", "postgres"),
  password: System.get_env("DB_PASSWORD", "postgres"),
  database: "ash_agent_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online()

config :ash, disable_async?: true

config :logger, level: :warning
