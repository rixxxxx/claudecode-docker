#!/usr/bin/env bash
# Brings up the real stack under a dedicated test project and verifies the
# security-critical invariants from AGENTS.md (non-root, domain allowlist,
# proxy-auth network isolation) plus a Squid config parse check. Needs
# Docker; can be slow on first run (image build). Cleans up via trap.
#
# No -e: a failing assertion must not abort the script before later
# assertions/cleanup run -- see assert_success/assert_failure in
# tests/lib/assert.sh, which are already safe under set -e themselves, but
# other commands in this file (e.g. capturing `docker compose exec` output)
# are not wrapped that way and are allowed to fail without aborting.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/assert.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_lib.sh"

PROJECT="$(integration_project_name)"
COMPOSE=(docker compose -f "$REPO_ROOT/docker-compose.yml" -p "$PROJECT")

cleanup() { integration_cleanup "$PROJECT"; }
trap cleanup EXIT

echo "  (using COMPOSE_PROJECT_NAME=$PROJECT -- can take a while on first run)"

if ! "${COMPOSE[@]}" up -d --wait 2>&1 | sed 's/^/  /'; then
    CURRENT_TEST="stack startup"
    _fail "docker compose up -d --wait failed -- see output above"
    print_summary
    exit 1
fi

test_claude_code_runs_as_nonroot() {
    local uid
    uid="$("${COMPOSE[@]}" exec -T claude-code id -u | tr -d '\r\n')"
    assert_equal "1000" "$uid"
}

test_squid_config_parses() {
    assert_success "${COMPOSE[@]}" exec -T egress-proxy squid -k parse
}

test_allowed_domain_is_reachable() {
    # No -f: a non-2xx from Anthropic itself would still mean the CONNECT
    # tunnel through egress-proxy succeeded, which is what this checks --
    # curl only exits non-zero here if the proxy/network layer failed.
    assert_success "${COMPOSE[@]}" exec -T claude-code \
        curl -sS --max-time 10 -o /dev/null https://api.anthropic.com
}

test_non_allowlisted_domain_is_blocked() {
    # example.com isn't in .squid-claudecode-docker/00-defaults.conf, so
    # Squid must refuse the CONNECT -- curl never gets a tunnel at all,
    # regardless of -f.
    assert_failure "${COMPOSE[@]}" exec -T claude-code \
        curl -sS --max-time 10 -o /dev/null https://example.com
}

test_claude_code_is_not_on_proxy_chain_network() {
    # Security-critical (see AGENTS.md): claude-code must never join
    # proxy-chain -- checked directly via the container's actual network
    # attachments rather than trying to reach proxy-auth by name, since
    # proxy-auth isn't even started outside the enterprise-proxy profile.
    local cid networks
    cid="$("${COMPOSE[@]}" ps -q claude-code)"
    networks="$(docker inspect "$cid" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null)"
    assert_not_contains "$networks" "proxy-chain"
    assert_not_contains "$networks" "external"
}

run_test test_claude_code_runs_as_nonroot
run_test test_squid_config_parses
run_test test_allowed_domain_is_reachable
run_test test_non_allowlisted_domain_is_blocked
run_test test_claude_code_is_not_on_proxy_chain_network

print_summary
