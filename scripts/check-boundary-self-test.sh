#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT
#
# Shows that the boundary check fails when it should.
#
# 1. The dependency check, against a synthetic tree with a forbidden path.
# 2. The reference check, against the real build: a fixture module that calls
#    Phoenix is copied into lib/, the check must fail and name it, and the
#    fixture is removed again however the script exits.
set -euo pipefail
cd "$(dirname "$0")/.."

fixture=test/boundary_fixtures/phoenix_reference.ex.txt
target=lib/boundary_fixture_phoenix_reference.ex

mix run --no-start scripts/check_boundary.exs --self-test

trap 'rm -f "$target"; mix compile >/dev/null 2>&1 || true' EXIT
cp "$fixture" "$target"

set +e
output="$(mix run --no-start scripts/check_boundary.exs 2>&1)"
status=$?
set -e

printf '%s\n' "$output"

if [ "$status" -eq 0 ]; then
  echo "self-test: FAILED, the boundary check passed with a Phoenix reference in lib/" >&2
  exit 1
fi

if ! grep -q 'reference: AshAgent.BoundaryFixture.PhoenixReference refers to Phoenix' <<<"$output"; then
  echo "self-test: FAILED, the boundary check failed without naming the fixture's Phoenix reference" >&2
  exit 1
fi

echo "self-test: ok (the reference check fails on a deliberate Phoenix reference)"
