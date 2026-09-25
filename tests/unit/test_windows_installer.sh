#!/usr/bin/env bash
# go vet + go test + a Windows cross-compile of windows/main.go (see
# docs/windows-onboarding.md), if Go is installed. Soft-skips (exit 0, no
# failures) when it isn't -- like shellcheck, Go isn't a hard dependency of
# this repo, only of building the Windows installer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/assert.sh"

if ! command -v go >/dev/null 2>&1; then
    echo "  SKIP go not installed -- needed only for windows/, see docs/windows-onboarding.md \"Building\"."
    exit 0
fi

cd "$REPO_ROOT/windows"

test_go_vet() {
    assert_success env GOOS=windows GOARCH=amd64 go vet ./...
}

test_go_test() {
    # Only the platform-independent helpers are unit-tested, so these run on
    # the host's own GOOS -- no Windows needed.
    assert_success go test ./...
}

test_windows_cross_compile() {
    assert_success env GOOS=windows GOARCH=amd64 go build -o /dev/null .
}

run_test test_go_vet
run_test test_go_test
run_test test_windows_cross_compile

print_summary
