#!/usr/bin/env bash
# Shared helpers for Docker-based tests (tests/integration/, tests/security/).
# Sourced by each test file -- not a test file itself (no test_ prefix, so
# tests/run-tests.sh's glob skips it).

DOCKER_LIB_REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"

# docker_test_project_name -- a COMPOSE_PROJECT_NAME dedicated to the
# calling test file's own process, so it never collides with or tears down
# a real cc-container instance (see AGENTS.md "Multi-instance invariants").
docker_test_project_name() {
    echo "cc-selftest-$$"
}

# docker_test_cleanup <project_name> -- tears down everything a test run
# under this project name may have started (including the enterprise-proxy
# profile's proxy-auth). Safe to call even if nothing was ever started.
docker_test_cleanup() {
    local project="$1"
    docker compose -f "$DOCKER_LIB_REPO_ROOT/docker-compose.yml" -p "$project" \
        --profile enterprise-proxy down -v --remove-orphans >/dev/null 2>&1 || true
}
