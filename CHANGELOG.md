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

- The release decides which version of an agent runs live. `AshAgent.ReleaseManifest` takes an optional `agent_version/2`
  (the id of the version the active release pins for an agent key, or nil). A live run's `start` pins it instead of the
  latest published version, so publishing a candidate does not make it live; with no release pinning the agent, or a
  host that does not implement the callback, the latest published version runs as before. Runs that are not live are
  unchanged.
- Releases. The `invocation` section takes an optional `release_manifest`, a module implementing the new
  `AshAgent.ReleaseManifest` (`active/2`: the release live in a tenant that covers a target, with its id and digest). `request` records the
  active release as `release_manifest_id`, an approval binds its digest as `manifest_digest` in its
  `authorization_details`, and `apply_decision` and every `claim` find the row `stale` with `error_code`
  `"manifest_changed"` once a different release is active. A host that declares none binds nothing.
- Taint. `AshAgent.Run` gains `tainted?` (default `false`): set once a call that reaches outside the application
  (`open_world?`, or an effects snapshot that says nothing) has succeeded and answered the run, and never cleared. It
  is recorded, not enforced, so a host can report or admit on it. `record_step` takes a `tainted` argument for it.
  Hosts generate a migration for the column.
- Runs that cause no effects. `AshAgent.Run` gains `mode` (`:live`, `:shadow`, `:eval`; default `:live`) and
  `fixtures` (`%{"Resource.Module.action" => result}`), both accepted by `start`, and `run_principal/3` is given the
  mode as `:mode` in its context. The `invocation` section takes an optional `run` (the host's run resource): a run's
  tool call then takes the run's mode, read from the run row. A row that is not live is routed `ready` even when its
  declaration asks for an approval (`approval_mode` still records it), is never claimed unless its target is a read
  that stays inside (`AshAgent.Invocation.Changes.Claim.runs?/1`), and is answered by the new machinery action
  `simulate` from the run's fixture: `succeeded` with `simulated: true` (new attribute) and the fixture as `result`,
  or `failed` (`:permanent`, `"no_fixture"`). Hosts generate a migration for the three columns.
- `record_step` enqueues the next `:step` job only when it leaves the run queued. A run it leaves waiting is woken by
  what it waits on (`AshAgent.Run.Changes.Wake`, `extend`) or found by the sweep; with `:executing` out of the unique
  states, enqueueing it too left a job that could only end as `:skipped`.
- usage-rules/triggers.md: the `:step` trigger is unique while a job waits, not while one runs
  (`worker_opts unique: [period: :infinity, states: [:available, :scheduled, :retryable]]`). With ash_oban's default
  the executing job counts, so a step that took its tools in its loop and left the run queued had its next job
  dropped, and the run waited for the sweep.
- A run's token budget is held before each model call and settled after it. New `AshAgent.Run` attributes
  `budget_reserved`, `budget_holds` (each unsettled hold, keyed `"<run id>:<lease epoch>"`) and `budget_lock`, and
  actions `reserve` and `settle` (both under `optimistic_lock(:budget_lock)`; `reserve` also filtered on the sum
  staying within `budget_limit`, and refused with `AshAgent.Run.BudgetExhausted` when it would not) and `extend`
  (raises `budget_limit`; a run waiting on its budget is queued again). The step reserves what is left before its call
  and settles the tokens the call used, however the call ended; a refused reservation makes the run wait on its
  budget, with no call. A hold whose worker died is released by the run's next lease. `AshAgent.Run.Budget` holds
  the retry loop. `record_step` no longer takes `tokens`: `settle` alone writes `budget_spent`.
- A run can name the record it is about: `AshAgent.Run`'s `start` accepts `subject_type` (a resource's module name)
  and `subject_id`, both or neither. The starter must be able to read the record (one they cannot is refused like one
  that does not exist), and it is left in the changeset context as `ash_agent.subject` for the host's changes on
  `start`, as an invocation's `request` leaves its subject, so a host can seal the run's content under the subject's
  erasure key.
- `complete_external` accepts `result`: what handed-on work came back with (a person's answer, a callback's payload),
  recorded on a row that succeeds and read by a run's next step as the tool call's result. A failed outcome and a late
  callback on a final row record none.
- A run offers a toolset target its domain (or its resource) exposes as an ash_ai `tool` under that tool's name,
  description, `action_parameters`, `load` and `select`, so a read can hide ash_ai's filter and sort controls from a
  model. An in-loop read run again on resume has the run in its action context, as it has in the loop.
- Durable agent runs: `AshAgent.Run`, a fragment for a run of a pinned agent version, and `AshAgent.Step`, its
  append-only journal (one row per message). One `:step` job is one model call: `claim_step` takes the lease under
  `optimistic_lock(:lease_epoch)` (and checks the deadline, drift, the step and tool-call limits and the token
  budget), the model is called through ash_ai's tool loop with no transaction open, and each message the loop emits is
  recorded under the fence (`record_step`, filtered on the epoch and the journal's `step_seq`). Only Ash `:read`
  actions that do not reach outside run in the loop; every other tool call becomes an invocation keyed
  `run:<run id>:<step seq>:<tool call id>`, and a step repeated after a worker died reads its recorded result. An
  answer is cast to the version's `output_type`, with up to `max_repairs` repair turns, then `failed(:rejected)`.
  `request_cancel` cancels a run and its unstarted invocations. `needs_step` is a derived calculation over the host's
  invocation resource; `AshAgent.Run.Changes.Wake` wakes a run when one of its invocations finishes. New host
  behaviour `AshAgent.Runtime` (the model and transport a step uses) and optional `AshAgent.ExecutionIdentity`
  callbacks `run_principal/3` (who may start which agent, and as whom it runs) and `requester_for/1` (who requests a
  run's tool calls). `req_llm` is now a dependency.
- `AshAgent.AgentVersion.Definition.publish_problems/1` also refuses an `output_type` that names no Ash type, and two
  toolset targets that would be offered under the same tool name.
- `AshAgent.AgentVersion`, a fragment for immutable, numbered agent versions that a run pins (`draft → published →
  retired`), and `AshAgent.Agent`, the declaration of an agent in code. `register_from_code` syncs a declaration and
  writes a new draft only when its content hash changed; a changed tool changes the hash. `apply_publish` refuses a
  toolset target without an effects declaration, one that changed since the draft was written, or a missing limit, and
  records who runs act as (the requester by default, or a named automation principal; `requesterless` only with one).
  `AshAgent.AgentVersion.Definition.check_pinned/1` fails a pinned version whose tools drifted with
  `AshAgent.AgentVersion.DefinitionDrift` (`:definition_drift`).
- An attempt that may have reached outside is never ended as though nothing ran. A row an earlier attempt of which
  may have reached an outside target becomes `outcome_unknown`, for reconciliation, where it would have gone `stale`
  at claim (including through a host's change calling `AshAgent.Invocation.Changes.Claim.stale/2`), been cancelled
  from `ready`, or failed before its target ran (no authority, a target that no longer resolves, a subject out of
  reach). An outside target that had started and returns an error the host did not classify, or raises, is
  `:indeterminate`, not `:rejected` or `:permanent` (`AshAgent.Invocation.Failure.classify_started/1`); a forbidden
  error stays `:denied`. An idempotent outside target out of attempts is `outcome_unknown`, not failed. An expired
  lease is taken over at claim, or re-readied by `requeue`, only while `attempt_count` is below `max_attempts`;
  past that, `reconcile` makes it `outcome_unknown` (outside) or fails it as `:transient`, `"attempts_exhausted"`
  (internal).
- The executor checks an approved row's subject once more on the record its target is about to write, inside the
  target's transaction for an internal one: a `version_number` other than the one approved makes the row `stale`
  through the new `mark_stale` action, and nothing runs. `AshAgent.Invocation.Target.run/3` takes `:preconditions`
  and returns `{:not_run, reason}` for anything refused before the action started.
- `AshAgent.Validations.Governed` requires the claim's secret. `AshAgent.Invocation.Executor.claim/3` makes one for
  each claim, stores only its digest (`lease_token_digest`, a new attribute; `claim` takes it as an argument) and
  hands it to the target in `context.ash_agent.lease_token`; a caller without it is refused with reason
  `:not_executor`. The requester knows the row's id, key, epoch and arguments, so they could otherwise run a governed
  action themselves while the row is executing.

- `AshAgent.Validations.Governed`: a validation that refuses a governed action unless its own invocation is running
  it. It reads the invocation named in `context.ash_agent` and requires it `executing` under the named lease epoch,
  for this action, with an `args_digest` matching the inputs given (plus the acted-on record's primary key), and the
  actor to be the invocation's principal. It has `atomic/3` and is temporal safe; a refusal is
  `AshAgent.Invocation.Ungoverned` with a `reason`. `AshAgent.ExecutionIdentity` gains a required callback,
  `principal_of/1`, the inverse of `actor_for/1`, which the validation calls.

- Approvals bind the request they approve. `request` records, for a row awaiting approval, its RFC 9396
  `authorization_details`, their `approval_digest` (SHA-256 of the RFC 8785 canonical JSON) and `approval_expires_at`
  from the declaration's `approval_expires_in` (`AshAgent.Invocation.Approval`). `apply_decision` makes an approved row
  ready only while the digest recomputed from the row, the target as declared now and the preconditions' records as
  they stand now still matches and the approval has not expired; `claim` checks the same before every attempt.
  Otherwise the row is `stale`, with `error_code` naming why. `AshAgent.Invocation.Target.current_preconditions/2`
  reads the preconditions' records as they stand now.
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
- An update or destroy target whose record the executing actor can no longer read fails as `:denied`
  (`AshAgent.Invocation.SubjectUnreachable`, forbidden), and one whose record is gone as `:rejected`; both were
  recorded as `:permanent`.
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
