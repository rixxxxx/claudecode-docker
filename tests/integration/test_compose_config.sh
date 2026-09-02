#!/usr/bin/env bash
# Validates docker-compose.yml syntax/interpolation, with and without the
# enterprise-proxy profile. Doesn't start any containers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/assert.sh"

COMPOSE=(docker compose -f "$REPO_ROOT/docker-compose.yml")

test_default_profile_config_is_valid() {
    assert_success "${COMPOSE[@]}" config -q
}

test_enterprise_proxy_profile_config_is_valid() {
    assert_success "${COMPOSE[@]}" --profile enterprise-proxy config -q
}

run_test test_default_profile_config_is_valid
run_test test_enterprise_proxy_profile_config_is_valid

print_summary
