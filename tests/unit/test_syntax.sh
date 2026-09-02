#!/usr/bin/env bash
# `bash -n` (parse-only, no execution) over every shell script in the repo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/assert.sh"

SCRIPTS=(
    "$REPO_ROOT/install.sh"
    "$REPO_ROOT/uninstall.sh"
    "$REPO_ROOT/entrypoint.sh"
    "$REPO_ROOT/proxy-auth-entrypoint.sh"
    "$REPO_ROOT/bin/cc-container"
    "$REPO_ROOT/bin/update-deps.sh"
    "$REPO_ROOT/tests/run-tests.sh"
    "$REPO_ROOT/tests/lib/assert.sh"
)
for f in "$REPO_ROOT"/tests/unit/test_*.sh "$REPO_ROOT"/tests/integration/test_*.sh; do
    [ -e "$f" ] || continue
    SCRIPTS+=("$f")
done

test_all_scripts_parse() {
    local script
    for script in "${SCRIPTS[@]}"; do
        CURRENT_TEST="bash -n $(basename "$script")"
        assert_success bash -n "$script"
    done
}

run_test test_all_scripts_parse

print_summary
