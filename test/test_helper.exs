# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

# Create the test host's database if it is missing, start the repo, and run the
# generated migrations in priv/repo/migrations.
AshAgent.Test.Repo.__adapter__().storage_up(AshAgent.Test.Repo.config())

{:ok, _} = AshAgent.Test.Repo.start_link()

Ecto.Migrator.run(AshAgent.Test.Repo, Path.expand("priv/repo/migrations"), :up, all: true)

Ecto.Adapters.SQL.Sandbox.mode(AshAgent.Test.Repo, :manual)

ExUnit.start()
