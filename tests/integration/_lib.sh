#!/usr/bin/env bash
# Shared helpers for integration tests (needs Docker). Sourced by each
# tests/integration/test_*.sh -- not a test file itself (no test_ prefix,
# so tests/run-tests.sh's glob skips it).

INTEGRATION_REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"

# integration_project_name -- a COMPOSE_PROJECT_NAME dedicated to the
# calling test file's own process, so it never collides with or tears down
# a real cc-container instance (see AGENTS.md "Multi-instance invariants").
integration_project_name() {
    echo "cc-selftest-$$"
}

# integration_cleanup <project_name> -- tears down everything a test run
# under this project name may have started (including the enterprise-proxy
# profile's proxy-auth). Safe to call even if nothing was ever started.
integration_cleanup() {
    local project="$1"
    docker compose -f "$INTEGRATION_REPO_ROOT/docker-compose.yml" -p "$project" \
        --profile enterprise-proxy down -v --remove-orphans >/dev/null 2>&1 || true
}
