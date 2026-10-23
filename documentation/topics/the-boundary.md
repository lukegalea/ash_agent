<!--
SPDX-FileCopyrightText: 2026 Luke Galea
SPDX-License-Identifier: MIT
-->

# The boundary

This package must work in any Ash application, not only in the one it was first written for. Its dependency list is
where that is enforced, and CI checks it with `scripts/check-boundary.sh`.

## What the check enforces

**Dependencies.** No package whose name starts with `phoenix`, and no `ash_bpmn` or `ash_enterprise`, may reach the
dependency tree, with one exception: `ash_ai` depends on `ash_json_api`, which depends on `phoenix`. That single edge,
`ash_json_api -> phoenix`, is allowed, because the package uses `ash_ai` for its tool loop. Any other path to a Phoenix
package fails, including a new one through `ash_json_api`.

**References.** No module compiled from this repository may refer to a module whose name starts with `Phoenix`,
`AshEnterprise` or `AshBpmn`. The check reads each compiled module's debug info and collects every atom in its code,
so remote calls, structs, module names passed as values and module names inside literal data are all found. This
covers `lib/` and, in the test environment, the test host in `test/support`.

## What the package leaves to the host

The fragments will declare no `multitenancy` block, no `oban` triggers, no policies, no relationship to a host
resource, no identity naming a tenant column, no encryption block and no actor type. The host supplies all of these on
the resources it builds from the fragments. See [What the host supplies](what-the-host-supplies.md).

## The self-test

`scripts/check-boundary-self-test.sh` shows that the check fails when it should. It runs the dependency check against
a synthetic tree containing `ash_bpmn -> phoenix_live_view`, then copies a fixture module that calls
`Phoenix.PubSub.broadcast/3` into `lib/`, runs the real check against the real build, and requires it to fail and name
the fixture. The fixture is removed however the script exits. CI runs the self-test after the check.

## The test host

The test suite runs against plain `Ash.Resource` modules on Postgres in `test/support`, with no base resource of their
own. As fragments are built they are included there, the same way a consuming application includes them.
