#!/usr/bin/env bash
# Host-side cross-compile of the Windows onboarding installer. Not part of
# the claude-code image build -- run this manually (or as a release step)
# whenever windows/main.go changes. Needs Go on the host; nothing in the
# rest of this repo depends on Go being available.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v go >/dev/null 2>&1; then
    echo "Error: go is not installed. Install it first: https://go.dev/doc/install" >&2
    exit 1
fi

OUTPUT="claudecode-sandbox-setup.exe"

echo "==> Cross-compiling $OUTPUT for Windows (amd64)..."
GOOS=windows GOARCH=amd64 go build -o "$OUTPUT" .
echo "==> Built $SCRIPT_DIR/$OUTPUT"
