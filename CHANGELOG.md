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

- The repository: a mix project for the `:ash_agent` application with `AshAgent` as its root module, depending on
  `ash`, `spark`, `ash_ai`, `ash_state_machine` and `ash_oban`. No fragment, extension or behaviour is built yet.
- A test host: plain `Ash.Resource` modules on Postgres in `test/support`, standing in for an application that
  consumes the package.
- The boundary check, `scripts/check-boundary.sh`, and its self-test. CI fails on a reference to a `Phoenix*`,
  `AshEnterprise*` or `AshBpmn*` module and on a Phoenix package reaching the dependency tree by any path other than
  `ash_ai -> ash_json_api -> phoenix`.
