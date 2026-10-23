<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# AGENTS.md

This is `ash_agent`, governed invocations and durable agent runs for Ash Framework hosts, packaged as a dependency.

## Agent constitution

This repository follows `AGENT_PRINCIPLES.md` v1.5, the agent constitution of the ai-sdlc platform:
<https://github.com/lukegalea/ai-sdlc/blob/master/AGENT_PRINCIPLES.md>. That file is the root policy for every agent
session here. This file adds the rules of this repository only. It does not replace or weaken the root policy. If a
rule here contradicts a security rule there, stop and ask a human. The link opens only for people with access to the
ai-sdlc repository. If you cannot open it, these rules from it still apply:

- Do not approve your own work. A human approves every merge and every release.
- Do not put a secret in a file, a commit, a log, or a prompt.
- Do not publish anything outside this repository without human approval.
- Do not say that work is verified unless a CI result shows it.

## Project guidelines

- The package ships declarations: Spark fragments, an extension and behaviours. The host application supplies the base
  resource, data layer, tenancy, ownership, policies, ash_oban triggers, audit and encryption. Never add any of those to
  a fragment.
- Nothing here may refer to Phoenix or to a particular application. `scripts/check-boundary.sh` fails CI on a
  reference to a `Phoenix*`, `AshEnterprise*` or `AshBpmn*` module, or on a new path to a Phoenix package in the
  dependency tree. See `documentation/topics/the-boundary.md`.
- No mix tasks. The `ash_agent.` task namespace belongs to another tool.
- Examples in code, tests and documentation use a generic clinic scenario.
- The test host in `test/support` is plain `Ash.Resource` on Postgres. Generate its migrations with
  `MIX_ENV=test mix ash.codegen <name>`; do not write migrations by hand.
- Run everything inside devenv: `devenv up -d` starts the test database, `devenv shell -- <command>` runs a command.

## Before you finish

CI runs `mix format --check-formatted`, `mix credo --strict`, `mix compile --force --warnings-as-errors` (test and
dev), `mix test` against Postgres 16, `mix ash.codegen --check`, `mix dialyzer`, `mix docs`,
`mix deps.unlock --check-unused`, `mix deps.audit`, `mix hex.audit`, `scripts/check-boundary.sh`,
`scripts/check-boundary-self-test.sh` and a REUSE check. Run them before you finish.

## Generated sections

This repository does not run `mix usage_rules.sync` today. If it starts to, the task adds its own section at the end
of this file, between its `usage-rules-start` and `usage-rules-end` markers. Do not edit text inside those markers.
Keep the rules of this repository above them.
