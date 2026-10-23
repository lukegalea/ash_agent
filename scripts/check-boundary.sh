#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT
#
# Fails if the package boundary is broken: a Phoenix or application-specific
# package in the dependency tree, or a reference to a Phoenix*, AshEnterprise*
# or AshBpmn* module in compiled code. See scripts/check_boundary.exs.
set -euo pipefail
cd "$(dirname "$0")/.."
exec mix run --no-start scripts/check_boundary.exs "$@"
