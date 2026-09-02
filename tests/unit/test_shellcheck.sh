#!/usr/bin/env bash
# Runs shellcheck over every shell script in the repo, if shellcheck is
# installed. Soft-skips (exit 0, no failures) when it isn't -- shellcheck
# isn't a hard dependency of this repo, see README "Testing".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/assert.sh"

if ! command -v shellcheck >/dev/null 2>&1; then
    echo "  SKIP shellcheck not installed -- see README \"Testing\" to install it locally."
    exit 0
fi

SCRIPTS=(
    "$REPO_ROOT/install.sh"
    "$REPO_ROOT/uninstall.sh"
    "$REPO_ROOT/entrypoint.sh"
    "$REPO_ROOT/proxy-auth-entrypoint.sh"
    "$REPO_ROOT/falco-notify.sh"
    "$REPO_ROOT/bin/cc-container"
    "$REPO_ROOT/bin/update-deps.sh"
)

test_all_scripts_pass_shellcheck() {
    local script
    for script in "${SCRIPTS[@]}"; do
        CURRENT_TEST="shellcheck $(basename "$script")"
        assert_success shellcheck "$script"
    done
}

run_test test_all_scripts_pass_shellcheck

print_summary
