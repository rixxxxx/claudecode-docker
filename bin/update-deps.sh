#!/usr/bin/env bash
# Host-side auto-updater for third-party tools and the OS layer of the
# claude-code image. Rebuilds the image with --pull --no-cache (picks up
# the latest apt packages, gh, npm claude-code, rtk, node patch release,
# and the egress-proxy squid image) and restarts the stack. Reports
# before/after versions. Major version bumps (Ubuntu, Node) are only
# reported, never applied automatically -- see README.md "Updating
# dependencies".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# --- helpers ----------------------------------------------------------

container_running() {
    [ "$(docker compose ps -q claude-code 2>/dev/null)" != "" ] \
        && [ "$(docker inspect -f '{{.State.Running}}' "$(docker compose ps -q claude-code)" 2>/dev/null)" = "true" ]
}

run_in_container() {
    # $1 = shell snippet, run via a running container if possible, else a
    # throwaway one-off container.
    if container_running; then
        docker compose exec -T claude-code bash -lc "$1" 2>/dev/null || echo "n/a"
    else
        docker compose run --rm -T claude-code bash -lc "$1" 2>/dev/null || echo "n/a"
    fi
}

snapshot_versions() {
    echo "ubuntu=$(run_in_container '. /etc/os-release && echo $VERSION_ID')"
    echo "node=$(run_in_container 'node --version')"
    echo "npm=$(run_in_container 'npm --version')"
    echo "gh=$(run_in_container 'gh --version | head -1')"
    echo "claude-code=$(run_in_container 'claude --version')"
    echo "rtk=$(run_in_container 'rtk --version')"
    echo "python3=$(run_in_container 'python3 --version')"
}

egress_proxy_digest() {
    docker inspect --format='{{.Image}}' claude-code-egress-proxy 2>/dev/null || echo "n/a"
}

# --- 1. capture "before" state -----------------------------------------

echo "==> Capturing current versions..."
BEFORE="$(snapshot_versions)"
EGRESS_BEFORE="$(egress_proxy_digest)"

# --- 2. check for available major upgrades (report only) ---------------

echo "==> Checking for available major upgrades (informational only)..."

CURRENT_UBUNTU_TAG="$(grep -m1 '^FROM ubuntu:' Dockerfile | cut -d: -f2)"
LATEST_UBUNTU_TAG="$(curl -fsSL "https://hub.docker.com/v2/repositories/library/ubuntu/tags/?page_size=100" \
    | grep -o '"name":"[0-9]*\.[0-9]*"' | grep -o '[0-9]*\.[0-9]*' | sort -V | tail -1 || echo "")"

CURRENT_NODE_MAJOR="$(grep -m1 'setup_[0-9]*\.x' Dockerfile | grep -o 'setup_[0-9]*\.x' | grep -o '[0-9]*')"
LATEST_NODE_MAJOR="$(curl -fsSL "https://nodejs.org/dist/index.json" \
    | grep -o '"version":"v[0-9]*' | grep -o '[0-9]*' | sort -n | tail -1 || echo "")"

MAJOR_UPGRADES=""
if [ -n "$LATEST_UBUNTU_TAG" ] && [ "$LATEST_UBUNTU_TAG" != "$CURRENT_UBUNTU_TAG" ]; then
    MAJOR_UPGRADES+="  - Ubuntu base image: ${CURRENT_UBUNTU_TAG} -> ${LATEST_UBUNTU_TAG} available (Dockerfile line 1: 'FROM ubuntu:${CURRENT_UBUNTU_TAG}')\n"
fi
if [ -n "$LATEST_NODE_MAJOR" ] && [ "$LATEST_NODE_MAJOR" != "$CURRENT_NODE_MAJOR" ]; then
    MAJOR_UPGRADES+="  - Node.js major: ${CURRENT_NODE_MAJOR}.x -> ${LATEST_NODE_MAJOR}.x available (Dockerfile: 'setup_${CURRENT_NODE_MAJOR}.x')\n"
fi

# --- 3. apply patch-level updates automatically -------------------------

echo "==> Pulling egress-proxy image..."
docker compose pull egress-proxy

echo "==> Rebuilding claude-code image (--pull --no-cache)..."
docker compose build --pull --no-cache

echo "==> Recreating containers..."
docker compose up -d --force-recreate

# --- 4. capture "after" state --------------------------------------------

echo "==> Capturing new versions..."
AFTER="$(snapshot_versions)"
EGRESS_AFTER="$(egress_proxy_digest)"

# --- 5. report -------------------------------------------------------------

echo ""
echo "================ Update report ================"
printf "%-14s %-30s %-30s\n" "TOOL" "BEFORE" "AFTER"
while IFS='=' read -r key before_val; do
    after_val="$(echo "$AFTER" | grep "^${key}=" | cut -d= -f2-)"
    printf "%-14s %-30s %-30s\n" "$key" "$before_val" "$after_val"
done <<< "$BEFORE"
printf "%-14s %-30s %-30s\n" "egress-proxy" "$EGRESS_BEFORE" "$EGRESS_AFTER"
echo "================================================="

if [ -n "$MAJOR_UPGRADES" ]; then
    echo ""
    echo "Available major upgrades (NOT applied automatically):"
    echo -e "$MAJOR_UPGRADES"
fi

echo "Done. Note: --force-recreate restarted the claude-code container --"
echo "any interactive 'claude' session running inside it was terminated."
