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

- `AshAgent.Invocation`, a fragment for the invocation record: attributes, the lifecycle as a state machine, and the
  actions `invoke` (get by key or request; the same key with a different request is an
  `AshAgent.Invocation.IdempotencyConflict`, never an upsert), `request` (resolves the target, checks its arguments
  without running it, snapshots its effects declaration, digests target and arguments, routes to `ready`,
  `awaiting_approval` or `rejected`, and enqueues `:execute` for a ready row in the same transaction), `claim` (next
  lease epoch under `optimistic_lock`), `succeed` and `fail` (filtered on the claimed epoch), `apply_decision`,
  `request_cancel` and `execute` (a generic action with no transaction; `AshAgent.Invocation.Executor`).
- `AshAgent.ExecutionIdentity` and `AshAgent.DigestKey`, the behaviours the fragment calls, named in the resource's
  `invocation` section and checked when it compiles.
- `AshAgent.Digest`: RFC 8785 canonical JSON, SHA-256 and HMAC-SHA256 digests of it.
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
