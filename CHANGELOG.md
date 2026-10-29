<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

<!-- changelog -->

## [Unreleased]

Nothing has been released yet.

### Features:

- `AshAgent.Effects`, a resource extension declaring per action what it does to the world: MCP's four tool-annotation
  hints with MCP's defaults, an explicit ACP tool kind, approval (`:none`, `:confirm`, `:four_eyes`) with approver role
  and expiry, intent, a reconciliation action and preconditions. Verifiers reject `read_only?: true` on anything but an
  Ash `:read` action, declarations for missing actions, four-eyes approval without a role, and reconciliation or
  precondition names that do not exist. `AshAgent.Effects.Info` reads declarations.
- `AshAgent.Effects.Domain`, a domain extension that checks every action the domain exposes as an ash_ai tool is
  declared: an error when the resource uses `AshAgent.Effects`, a warning otherwise.
- The repository: a mix project for the `:ash_agent` application with `AshAgent` as its root module, depending on
  `ash`, `spark`, `ash_ai`, `ash_state_machine` and `ash_oban`. No fragment, extension or behaviour is built yet.
- A test host: plain `Ash.Resource` modules on Postgres in `test/support`, standing in for an application that
  consumes the package.
- The boundary check, `scripts/check-boundary.sh`, and its self-test. CI fails on a reference to a `Phoenix*`,
  `AshEnterprise*` or `AshBpmn*` module and on a Phoenix package reaching the dependency tree by any path other than
  `ash_ai -> ash_json_api -> phoenix`.
