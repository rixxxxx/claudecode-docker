#!/usr/bin/env bash
# Runs this repo's test suite. See AGENTS.md "Validating changes" and
# README.md "Testing".
#
#   ./tests/run-tests.sh                # unit tests only (fast, no Docker)
#   ./tests/run-tests.sh --integration  # integration tests only (needs Docker)
#   ./tests/run-tests.sh --security     # security tests only (needs Docker)
#   ./tests/run-tests.sh --all          # unit + integration + security
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

run_unit=false
run_integration=false
run_security=false
any_explicit=false

for arg in "$@"; do
    case "$arg" in
        --integration) run_integration=true; any_explicit=true ;;
        --security) run_security=true; any_explicit=true ;;
        --all) run_unit=true; run_integration=true; run_security=true; any_explicit=true ;;
        -h|--help)
            echo "Usage: $0 [--integration] [--security] [--all]"
            exit 0
            ;;
        *)
            echo "Usage: $0 [--integration] [--security] [--all]" >&2
            exit 1
            ;;
    esac
done

# No tier flags given at all -- default to unit tests only (fast, no Docker).
if [ "$any_explicit" = false ]; then
    run_unit=true
fi

# run_suite <dir> <label> -- runs every tests/*/test_*.sh in <dir> as its
# own subprocess (each file owns its own pass/fail counters via
# tests/lib/assert.sh), prints a summary, returns non-zero if any failed.
run_suite() {
    local dir="$1" label="$2"
    local total=0 failed=0 f

    echo "== $label =="
    for f in "$dir"/test_*.sh; do
        [ -e "$f" ] || continue
        total=$((total + 1))
        echo "--- $(basename "$f") ---"
        if ! "$f"; then
            failed=$((failed + 1))
        fi
    done

    echo "$label: $((total - failed))/$total test files passed"
    [ "$failed" -eq 0 ]
}

if [ "$run_integration" = true ] || [ "$run_security" = true ]; then
    if ! command -v docker >/dev/null 2>&1; then
        echo "Error: --integration/--security/--all require docker, which isn't available here." >&2
        exit 1
    fi
fi

overall_ok=true

if [ "$run_unit" = true ]; then
    if ! run_suite "$SCRIPT_DIR/unit" "Unit tests"; then
        overall_ok=false
    fi
fi

if [ "$run_integration" = true ]; then
    echo
    if ! run_suite "$SCRIPT_DIR/integration" "Integration tests"; then
        overall_ok=false
    fi
fi

if [ "$run_security" = true ]; then
    echo
    if ! run_suite "$SCRIPT_DIR/security" "Security tests"; then
        overall_ok=false
    fi
fi

if [ "$overall_ok" = true ]; then
    echo
    echo "All test files passed."
    exit 0
else
    echo
    echo "Some test files failed -- see FAIL lines above." >&2
    exit 1
fi
