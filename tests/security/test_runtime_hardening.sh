#!/usr/bin/env bash
# Runtime hardening checks: brings up the real stack under a dedicated test
# project and probes specific bypass attempts an adversarial workload
# inside claude-code might try. Needs Docker; can be slow on first run
# (image build). Cleans up via trap.
#
# No -e: a failing assertion must not abort the script before later
# assertions/cleanup run -- see tests/integration/test_runtime.sh for the
# same rationale (assert_success/assert_failure are already set -e safe).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/assert.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/docker_lib.sh"

PROJECT="$(docker_test_project_name)"
COMPOSE=(docker compose -f "$REPO_ROOT/docker-compose.yml" -p "$PROJECT")

cleanup() { docker_test_cleanup "$PROJECT"; }
trap cleanup EXIT

echo "  (using COMPOSE_PROJECT_NAME=$PROJECT -- can take a while on first run)"

if ! "${COMPOSE[@]}" up -d --wait 2>&1 | sed 's/^/  /'; then
    CURRENT_TEST="stack startup"
    _fail "docker compose up -d --wait failed -- see output above"
    print_summary
    exit 1
fi

test_direct_network_bypass_fails() {
    # Even with HTTP_PROXY/HTTPS_PROXY explicitly unset and --noproxy '*'
    # (i.e. actively trying to bypass egress-proxy), claude-code must have
    # no route to the outside world at all -- the "internal" Docker network
    # has no default gateway (docker-compose.yml: internal: true). This
    # checks the network-level guarantee underneath the domain allowlist,
    # independent of whether any given tool honors HTTP_PROXY.
    assert_failure "${COMPOSE[@]}" exec -T claude-code \
        env -u HTTP_PROXY -u HTTPS_PROXY \
        curl -sS --noproxy '*' --max-time 5 -o /dev/null https://1.1.1.1
}

test_workspace_squid_override_is_readonly() {
    # See AGENTS.md "Per-workspace .squid-claudecode-docker overrides": this
    # path is intentionally mounted read-only inside claude-code so a
    # session can see its own effective network policy but never widen it
    # from inside the sandbox.
    assert_failure "${COMPOSE[@]}" exec -T claude-code \
        touch /workspace/.squid-claudecode-docker/security-test-write-attempt
}

test_squid_denies_nonstandard_port_even_for_allowed_domain() {
    # Safe_ports/SSL_ports ACLs in squid.conf (ports 80/443 only) must
    # reject CONNECT to any other port outright, independent of the domain
    # allowlist -- api.anthropic.com is allowed, but not on an arbitrary
    # port.
    assert_failure "${COMPOSE[@]}" exec -T claude-code \
        curl -sS --max-time 5 -o /dev/null https://api.anthropic.com:8443
}

run_test test_direct_network_bypass_fails
run_test test_workspace_squid_override_is_readonly
run_test test_squid_denies_nonstandard_port_even_for_allowed_domain

print_summary
