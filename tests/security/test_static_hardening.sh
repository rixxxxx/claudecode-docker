#!/usr/bin/env bash
# Static hardening checks -- no containers started, just `docker compose
# config` resolution (needs the docker CLI, not a running daemon) and
# grepping the Dockerfiles. Fast.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/assert.sh"

COMPOSE=(docker compose -f "$REPO_ROOT/docker-compose.yml" --profile enterprise-proxy)
RESOLVED_CONFIG="$("${COMPOSE[@]}" config)"

test_no_service_is_privileged() {
    assert_not_contains "$RESOLVED_CONFIG" "privileged: true"
}

test_no_service_adds_capabilities() {
    # No service should need extra Linux capabilities beyond Docker's
    # default drop set (see AGENTS.md: claude-code runs non-root; the same
    # minimal-privilege intent applies to egress-proxy/proxy-auth).
    assert_not_contains "$RESOLVED_CONFIG" "cap_add:"
}

test_no_service_mounts_docker_socket() {
    # Even a read-only docker.sock mount is effectively root-equivalent
    # host access (the Docker API itself has no granular read/write
    # distinction) -- must never be mounted into any service here.
    assert_not_contains "$RESOLVED_CONFIG" "docker.sock"
}

test_dockerfiles_dont_copy_full_build_context() {
    # A "COPY . ." (or "ADD . .") would pull the entire build context into
    # an image layer regardless of intent -- this repo relies on targeted
    # COPYs instead, so .dockerignore's exclusions (secrets, .git, etc.)
    # can't be silently bypassed by a future broad COPY.
    local f
    for f in "$REPO_ROOT/Dockerfile" "$REPO_ROOT/Dockerfile.proxy-auth"; do
        CURRENT_TEST="no full-context COPY in $(basename "$f")"
        assert_not_contains "$(cat "$f")" "COPY . ."
        CURRENT_TEST="no full-context ADD in $(basename "$f")"
        assert_not_contains "$(cat "$f")" "ADD . ."
    done
}

run_test test_no_service_is_privileged
run_test test_no_service_adds_capabilities
run_test test_no_service_mounts_docker_socket
run_test test_dockerfiles_dont_copy_full_build_context

print_summary
