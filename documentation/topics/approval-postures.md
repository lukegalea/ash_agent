<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# Approval postures

Who may decide an approval is the package's rule (`AshAgent.Approval.Posture`), not each host's: a small
organization, or one being set up, does not need a second person for every act, and no posture weakens the
guarantees. The host supplies only facts about its people (`AshAgent.Approval.Authority`).

There are three postures, a closed set:

| Posture | A `:four_eyes` target | Ends |
|---|---|---|
| `:standard` (the default) | Another holder of the approver role approves; the requester is excluded | Never |
| `:small_team` | The requester may approve their own request if they hold the approver role. If nobody holds that role, any holder of the administrator role may approve, the requester included | Never; a person turns it off |
| `:implementation` | The requester confirms it themselves; no approver role is needed | A required end date, at most 120 days after it is set |

`:none` and `:confirm` targets behave as declared under every posture. An end date that has passed makes the
posture `:standard`.

## The invariants, under every posture

1. A posture changes *which person* decides, never *whether* a person decides. A non-person principal — an
   agent, an engine, an automation — is never a candidate; an `:implementation` whose requester is not a
   person falls back to `:standard` behaviour.
2. A posture never widens what anyone may do. The host's grants still apply when the target runs.
3. The approval binding is unchanged. A stale subject, target or clock still stops the act.
4. Every approval records what it rested on: `approval_basis` on the invocation row, one of `:confirm`,
   `:four_eyes`, `:small_team`, `:implementation`. `apply_decision` computes it from the posture in force and
   the approver (`AshAgent.Invocation.Approval.basis/3`), so the row records what the rule says, whoever
   reports the decision.

## What the host supplies

`AshAgent.Approval.Authority`, named as `authority` in the `invocation` section (required):

```elixir
@callback posture(tenant) :: {posture, ends_at | nil}
@callback holders(tenant, role) :: [person_id]     # everyone who holds or has ever held the role
@callback administrator_role() :: atom
@callback operator?(actor) :: boolean              # a platform-level operator who may set a tenant's posture
```

The posture is asked where an approval is decided and re-checked: at `apply_decision`, and at every `claim` of
an approved row. `holders/2` is the *historical* set the governance rules need — whether an approver holds a
role *now* stays with the host's policies, as it is today.

## Staleness

`AshAgent.Invocation.Approval.stale_reason/2` re-asks the posture wherever it is asked: the decision and every
claim. A self-approval the posture in force no longer allows — raised to `:standard`, or an `:implementation`
that ended — makes the row `stale` with `error_code: "approved_by_requester"`, and nothing runs. Another
person's approval survives a change of posture: the binding, not the regime, is what it rests on.

## The floor

An effect declared `approval: :four_eyes, posture_floor?: true` keeps `:standard` behaviour under every
posture: another holder of the approver role approves, the requester excluded, always. The verifier accepts
the option only with `approval: :four_eyes`, and the option is part of the row's effects snapshot, so the
approval binds it.

## Changing a tenant's posture

`AshAgent.Approval.PostureFragment` goes on the host's tenant resource: the posture and its end date, and one
action, `set_approval_posture`, whose validation answers who may change them:

* an `:implementation` needs an end date in the future and within 120 days; every other posture clears it;
* raising the posture (towards `:standard`) is the work of one administrator;
* lowering it needs the sole administrator (the only person who has ever held the administrator role), an
  operator, or a change approved under four eyes. For the last, the host names its invocation resource in the
  `approval_posture` section (`invocation`) and declares `set_approval_posture` a four-eyes target with
  `posture_floor?: true`. The validation then verifies the invocation the context names exactly as
  `AshAgent.Validations.Governed` does: executing under its executor's lease, for this action, these inputs and
  this actor. A context that only names an invocation counts for nothing. Do not attach `Governed` itself to
  `set_approval_posture`: it would refuse the sole administrator's and an operator's direct changes.
* a refusal is `AshAgent.Approval.PostureChangeRefused`. A request to lower the posture through `invoke` is not
  refused for it at request time, before its approval exists; the claim checks it again, approval in hand.

Policies stay with the host: the validation is the rule about the change itself, asked of the actor the host's
policies already let through.
