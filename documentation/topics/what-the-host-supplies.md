<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# What the host supplies

This package ships declarations that a host application turns into resources. The split below is the design; of the
package's side, only the effects declaration is built yet.

| Concern | The package declares | The host supplies |
|---|---|---|
| Base resource and data layer | Nothing. Fragments assume an Ash resource whose data layer supports filtered updates | Its base resource, the `postgres` block, table and repo |
| Attributes, calculations, lifecycle | Attributes, calculations and a state machine on each fragment, and identities on columns that are not tenant columns | Tenant and ownership columns, and the encryption of attributes the fragments mark `sensitive?` |
| Actions | The actions of each fragment, with their changes and validations | Which actors may call which action, and the code interfaces on its own domain |
| Executing principal | A behaviour asking who an invocation executes as | An implementation built from the host's own grants |
| Approvals | A behaviour for opening an approval and reading its decision, and the state that waits for it | An implementation over the host's approval mechanism |
| Tenancy | None. Actions never read a tenant themselves | A `multitenancy` block, usually through its base resource |
| Policies | None | All of them |
| Triggers and workers | The trigger names the actions expect, and a template in `usage-rules.md` | The `oban` blocks: worker and scheduler modules, queues, schedules, the default actor |
| Audit | Nothing | Whatever audit trail it keeps |
| Effects | The `effects` declaration (`AshAgent.Effects`), its verifiers, and a domain check that exposed tools are declared | A declaration on each action it exposes or governs |

## Example: a clinic

A clinic's application checks clinicians' credentials. An agent drafts a request to a licensing board for a clinician
whose licence is about to expire. The clinic's application includes the invocation fragment on its own resource, on its
own base resource and in its own tenant, writes the policy that only credentialing staff may approve such a request,
and declares the trigger that sends the request once it is approved. The package records the request, waits for the
approval and runs the request at most once.
