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

- Execution paths, typed failure and reconciliation for `AshAgent.Invocation`. A transient failure makes a row ready
  again after a backoff, up to the `invocation` section's `max_attempts`, then fails it as `:transient`; `retry` makes
  it ready again. An outside target that is not idempotent is never called twice for one claim: an error that leaves
  its effect in doubt, or a lease that expires with no outcome, makes the row `outcome_unknown`. The new `reconcile`
  action (the host's required `:reconcile` trigger) re-readies an expired lease when a rerun cannot repeat the effect,
  settles an unknown outcome through the target's `reconcile_with` lookup, and otherwise asks a person
  (`request_resolution`, `apply_resolution` with `:succeeded`, `:failed` or `:retry`). A target can hand its work on by
  returning an `AshAgent.Invocation.Dispatch`: the row is `dispatched`, holds no lease, and is settled by
  `complete_external` or by its deadline. A late callback on a final row is kept in `evidence` and changes nothing
  else. New actions: `defer`, `dispatch`, `mark_outcome_unknown`, `requeue`, `complete_external`, `request_resolution`,
  `apply_resolution`, `retry`, `reconcile`.
- `AshAgent.BusinessError{code}` and the `AshAgent.FailureClass` protocol, with which a host classifies its own error
  types. `AshAgent.Invocation.Failure` holds the table: class, what happens next, and what a process sees
  (`bpmn/1`: a business error code, an incident, or waiting).

- `AshAgent.Invocation`, a fragment for the invocation record: attributes, the lifecycle as a state machine, and the
  actions `invoke` (get by key or request; the same key with a different request is an
  `AshAgent.Invocation.IdempotencyConflict`, never an upsert), `request` (resolves the target, checks its arguments
  without running it, snapshots its effects declaration, digests target and arguments, routes to `ready`,
  `awaiting_approval` or `rejected`, and enqueues `:execute` for a ready row in the same transaction), `claim` (next
  lease epoch under `optimistic_lock`), `succeed` and `fail` (filtered on the claimed epoch), `apply_decision`,
  `request_cancel` and `execute` (a generic action with no transaction; `AshAgent.Invocation.Executor`).
- `AshAgent.ExecutionIdentity` and `AshAgent.DigestKey`, the behaviours the fragment calls, named in the resource's
  `invocation` section and checked when it compiles.
- Automation principals carry the person they act for (`on_behalf_of`) and their `agent`, both part of the principal's
  identity, so `invoke` never returns one person's row to another under the same automation.
  `AshAgent.ExecutionIdentity.delegation/1` states a principal as RFC 8693's `act` claim, and `request` stores it in
  `delegation`. A host's `actor_for/1` refusal reason, when an atom, is recorded as `"no_authority: <reason>"`.
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
