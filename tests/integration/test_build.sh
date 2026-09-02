#!/usr/bin/env bash
# Builds the images (slow: apt/npm/pip installs). Doesn't start any
# containers (see test_runtime.sh for that), so no cleanup is needed here --
# the resulting images are tagged claude-code:latest /
# claude-code-proxy-auth:latest, shared across all workspaces by design
# (see AGENTS.md "Multi-instance invariants"), not scoped to this test run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/assert.sh"

COMPOSE=(docker compose -f "$REPO_ROOT/docker-compose.yml")

test_claude_code_image_builds() {
    assert_success "${COMPOSE[@]}" build claude-code
}

test_proxy_auth_image_builds() {
    assert_success "${COMPOSE[@]}" --profile enterprise-proxy build proxy-auth
}

run_test test_claude_code_image_builds
run_test test_proxy_auth_image_builds

print_summary
