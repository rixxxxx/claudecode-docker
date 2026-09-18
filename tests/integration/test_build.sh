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

test_egress_proxy_image_builds() {
    assert_success "${COMPOSE[@]}" build egress-proxy
}

test_egress_proxy_ssl_bump_prereqs_available() {
    # Regression guard for the 2026-09-18 finding (see
    # Dockerfile.egress-proxy's own comments, README "TLS interception",
    # AGENTS.md "SSL Bump support"): ubuntu/squid:latest doesn't ship
    # security_file_certgen/ssl_crtd at all -- only fixed by installing
    # squid-openssl on top. Turns "did that install actually work" from
    # something you have to notice by eye in build output into a proper
    # loud test failure. --no-cache is required here, not just belt-and-
    # suspenders: a cached layer shows "CACHED" in build output, not the
    # RUN step's own echo/warning text, so a plain cached build would
    # silently miss a real regression.
    local build_output
    build_output="$("${COMPOSE[@]}" build --no-cache egress-proxy 2>&1)"
    CURRENT_TEST="egress-proxy SSL Bump prerequisites (security_file_certgen) available after build"
    assert_contains "$build_output" "SSL Bump cert-cache initialized." \
        "if this fails, see the build output above for the real error (Dockerfile.egress-proxy's cert-cache step no longer suppresses stderr) -- squid-openssl's install or security_file_certgen -c itself needs debugging"
}

run_test test_claude_code_image_builds
run_test test_proxy_auth_image_builds
run_test test_egress_proxy_image_builds
run_test test_egress_proxy_ssl_bump_prereqs_available

print_summary
