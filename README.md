<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# AshAgent

Governed invocations and durable agent runs for [Ash Framework](https://ash-hq.org) hosts.

> **Status: early.** The effects declaration (`AshAgent.Effects`) and the invocation fragment (`AshAgent.Invocation`)
> with its two host behaviours are built. Durable agent runs are not built yet. [`usage-rules.md`](usage-rules.md) says
> which parts have landed.

## What it is for

When an agent, a process engine or a person asks an application to do something with side effects, such as sending a
message, changing a record or calling an outside service, the application needs a record of that request: what was
asked, with which arguments, on whose authority, whether someone approved it, and what came back. With that record, a
request can be retried without doing the work twice, and someone can read afterwards what an agent did.

This package will provide the reusable parts of that record for Ash applications:

- **Invocations.** One row per request for an effect, with its arguments, the principal it executes as, the approval it
  waited for and its result.
- **Durable agent runs.** A model's tool loop recorded as a run and its steps, so a run survives a restart and every
  step can be read back. The tool loop itself is [ash_ai](https://github.com/ash-project/ash_ai)'s.
- **An effects declaration.** An extension for stating what an action does to the world, so callers can decide what
  needs approval.

## What the host supplies

The package ships declarations, not finished resources. A host application includes the package's Spark fragments on
its own resources and supplies everything that depends on the application:

- the base resource and data layer, including the `postgres` block, table and repo;
- tenancy and ownership columns;
- policies;
- ash_oban triggers, and therefore the workers, queues and schedules;
- audit and encryption at rest;
- implementations of the package's behaviours: who an invocation executes as and the key its argument digest is
  taken under; later, how an approval is opened and read, and where execution history comes from.

See [What the host supplies](documentation/topics/what-the-host-supplies.md).

## Installation

The Hex package named `ash_agent` belongs to an unrelated project. This package is not published to Hex; use it as a
git dependency:

```elixir
def deps do
  [
    {:ash_agent, github: "lukegalea/ash_agent"}
  ]
end
```

Because both use the name `ash_agent`, an application cannot depend on this package and the Hex package at the same
time.

## Dependencies and boundary

The package depends on `ash`, `spark`, `ash_ai`, `ash_state_machine` and `ash_oban`. It never references Phoenix, and
CI fails if any code in `lib/` does, or if a Phoenix package reaches the dependency tree by a path other than the one
`ash_ai` brings in. See [The boundary](documentation/topics/the-boundary.md).

The package defines no mix tasks.

## Development

The toolchain and the test database come from [devenv](https://devenv.sh):

```bash
devenv up -d                   # start the test host's Postgres
devenv shell -- mix test       # run the suite
devenv shell -- scripts/check-boundary.sh
```

The test suite runs against a test host: plain `Ash.Resource` modules on Postgres in `test/support`, standing in for an
application that consumes the package. Its migrations are generated with `MIX_ENV=test mix ash.codegen <name>`.

CI runs `mix format --check-formatted`, `mix credo --strict`, `mix compile --warnings-as-errors`, `mix test` against
Postgres 16, `mix ash.codegen --check`, `mix dialyzer`, `mix docs`, the boundary check and its self-test, the
dependency audits and a REUSE check.

## License

MIT. See [LICENSE](LICENSE).
