#!/usr/bin/env bash
# Host-side auto-updater for third-party tools and the OS layer of the
# claude-code image. First checks upstream sources (ubuntu base image,
# egress-proxy image, gh, Node patch release, npm claude-code, rtk) for
# anything newer than what's currently installed. Only if something is
# actually newer does it rebuild the image with --pull --no-cache (which
# also happens to pick up any apt package bumps within the pulled ubuntu
# layer) and restart the stack. Pass --force to skip the check and always
# rebuild. Major version bumps (Ubuntu, Node) are only ever reported, never
# applied automatically -- see README.md "Updating dependencies".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

if [ -z "${COMPOSE_PROJECT_NAME:-}" ]; then
    echo "Note: not invoked via 'cc-container --update' — operating on Compose's" >&2
    echo "      default project ($(basename "$PROJECT_ROOT")), not a specific workspace." >&2
    echo "      The shared claude-code:latest image is still rebuilt correctly;" >&2
    echo "      other running cc-container instances pick it up on their next recreate." >&2
fi

FORCE=false
for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE=true ;;
        *) echo "Unknown option: $arg" >&2; echo "Usage: $0 [--force]" >&2; exit 1 ;;
    esac
done

# --- helpers ----------------------------------------------------------

container_running() {
    [ "$(docker compose ps -q claude-code 2>/dev/null)" != "" ] \
        && [ "$(docker inspect -f '{{.State.Running}}' "$(docker compose ps -q claude-code)" 2>/dev/null)" = "true" ]
}

# Keys snapshot_versions emits, in order -- used to build the combined
# in-container probe and to backfill "n/a" for any key missing entirely
# (e.g. the whole docker invocation failed, not just one command inside it).
SNAPSHOT_KEYS=(ubuntu node npm gh claude-code rtk python3)

snapshot_versions() {
    # One combined in-container probe instead of one `docker compose
    # run`/`exec` per tool -- avoids spinning up a throwaway container per
    # check (and paying the egress-proxy healthcheck wait each time) when
    # claude-code isn't already running.
    local probe out key
    probe='
v="$(. /etc/os-release && echo "$VERSION_ID" 2>/dev/null)"; printf "ubuntu=%s\n" "${v:-n/a}"
v="$(node --version 2>/dev/null)"; printf "node=%s\n" "${v:-n/a}"
v="$(npm --version 2>/dev/null)"; printf "npm=%s\n" "${v:-n/a}"
v="$(gh --version 2>/dev/null | head -1)"; printf "gh=%s\n" "${v:-n/a}"
v="$(claude --version 2>/dev/null)"; printf "claude-code=%s\n" "${v:-n/a}"
v="$(rtk --version 2>/dev/null)"; printf "rtk=%s\n" "${v:-n/a}"
v="$(python3 --version 2>/dev/null)"; printf "python3=%s\n" "${v:-n/a}"
'
    if container_running; then
        out="$(docker compose exec -T claude-code bash -lc "$probe" 2>/dev/null)" || out=""
    else
        echo "==> No running claude-code container -- starting a temporary one to read versions" >&2
        echo "    (first run may pause a few seconds while egress-proxy's healthcheck passes)..." >&2
        out="$(docker compose run --rm -T claude-code bash -lc "$probe" 2>/dev/null)" || out=""
    fi

    for key in "${SNAPSHOT_KEYS[@]}"; do
        grep -q "^${key}=" <<<"$out" || out+=$'\n'"${key}=n/a"
    done
    echo "$out"
}

egress_proxy_digest() {
    local cid
    cid="$(docker compose ps -q egress-proxy 2>/dev/null)"
    [ -n "$cid" ] && docker inspect --format='{{.Image}}' "$cid" 2>/dev/null || echo "n/a"
}

image_id() {
    docker image inspect "$1" --format='{{.Id}}' 2>/dev/null || echo ""
}

ver_of() {
    # $1 = version blob (BEFORE), $2 = key
    echo "$1" | grep "^${2}=" | cut -d= -f2-
}

first_semver() {
    grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' <<<"$1" | head -1
}

# --- 1. capture "before" state -----------------------------------------

echo "==> Capturing current versions..."
BEFORE="$(snapshot_versions)"

CURRENT_UBUNTU_TAG="$(grep -m1 '^FROM ubuntu:' Dockerfile | cut -d: -f2)"
CURRENT_NODE_VERSION="$(grep -m1 '^ARG NODE_VERSION=' Dockerfile | cut -d= -f2)"
CURRENT_NODE_MAJOR="$(echo "$CURRENT_NODE_VERSION" | cut -d. -f1)"

GH_CURRENT="$(first_semver "$(ver_of "$BEFORE" gh)")"
NPM_CURRENT="$(first_semver "$(ver_of "$BEFORE" claude-code)")"
RTK_CURRENT="$(first_semver "$(ver_of "$BEFORE" rtk)")"
NODE_CURRENT="$(ver_of "$BEFORE" node)"

# --- 2. check for available major upgrades (report only) ---------------

echo "==> Checking for available major upgrades (informational only)..."

LATEST_UBUNTU_TAG="$(curl -fsSL "https://hub.docker.com/v2/repositories/library/ubuntu/tags/?page_size=100" \
    | grep -o '"name":"[0-9]*\.[0-9]*"' | grep -o '[0-9]*\.[0-9]*' | sort -V | tail -1 || echo "")"

NODE_INDEX="$(curl -fsSL "https://nodejs.org/dist/index.json" 2>/dev/null || echo "")"
LATEST_NODE_MAJOR="$(echo "$NODE_INDEX" | grep -o '"version":"v[0-9]*' | grep -o '[0-9]*' | sort -n | tail -1 || echo "")"
NODE_LATEST_PATCH="$(echo "$NODE_INDEX" | grep -o "\"version\":\"v${CURRENT_NODE_MAJOR}\.[0-9]*\.[0-9]*\"" | head -1 | grep -o 'v[0-9][0-9.]*' || echo "")"

MAJOR_UPGRADES=""
if [ -n "$LATEST_UBUNTU_TAG" ] && [ "$LATEST_UBUNTU_TAG" != "$CURRENT_UBUNTU_TAG" ]; then
    MAJOR_UPGRADES+="  - Ubuntu base image: ${CURRENT_UBUNTU_TAG} -> ${LATEST_UBUNTU_TAG} available (Dockerfile line 1: 'FROM ubuntu:${CURRENT_UBUNTU_TAG}')\n"
fi
if [ -n "$LATEST_NODE_MAJOR" ] && [ "$LATEST_NODE_MAJOR" != "$CURRENT_NODE_MAJOR" ]; then
    MAJOR_UPGRADES+="  - Node.js major: ${CURRENT_NODE_MAJOR}.x -> ${LATEST_NODE_MAJOR}.x available (Dockerfile: 'ARG NODE_VERSION=${CURRENT_NODE_VERSION}')\n"
fi

# --- 3. check whether a rebuild is actually necessary -------------------

echo "==> Checking upstream sources for newer patch/minor versions..."

REBUILD_REASONS=()

UBUNTU_ID_BEFORE="$(image_id "ubuntu:${CURRENT_UBUNTU_TAG}")"
docker pull -q "ubuntu:${CURRENT_UBUNTU_TAG}" >/dev/null 2>&1 || true
UBUNTU_ID_AFTER="$(image_id "ubuntu:${CURRENT_UBUNTU_TAG}")"
if [ -z "$UBUNTU_ID_BEFORE" ] || [ "$UBUNTU_ID_BEFORE" != "$UBUNTU_ID_AFTER" ]; then
    REBUILD_REASONS+=("ubuntu:${CURRENT_UBUNTU_TAG} base image has a newer layer available")
fi

EGRESS_BEFORE="$(egress_proxy_digest)"
docker compose pull egress-proxy
EGRESS_TAG_ID_AFTER="$(image_id "ubuntu/squid:latest")"
if [ -n "$EGRESS_TAG_ID_AFTER" ] && [ "$EGRESS_TAG_ID_AFTER" != "$EGRESS_BEFORE" ]; then
    REBUILD_REASONS+=("egress-proxy image updated upstream")
fi

GH_LATEST="$(curl -fsSL -m 10 https://api.github.com/repos/cli/cli/releases/latest 2>/dev/null | grep -m1 '"tag_name"' | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' || echo "")"
if [ -n "$GH_LATEST" ] && [ -n "$GH_CURRENT" ] && [ "$GH_LATEST" != "$GH_CURRENT" ]; then
    REBUILD_REASONS+=("gh ${GH_CURRENT} -> ${GH_LATEST}")
fi

NPM_LATEST="$(curl -fsSL -m 10 https://registry.npmjs.org/@anthropic-ai/claude-code/latest 2>/dev/null | grep -o '"version":"[0-9.]*"' | head -1 | cut -d'"' -f4 || echo "")"
if [ -n "$NPM_LATEST" ] && [ -n "$NPM_CURRENT" ] && [ "$NPM_LATEST" != "$NPM_CURRENT" ]; then
    REBUILD_REASONS+=("claude-code (npm) ${NPM_CURRENT} -> ${NPM_LATEST}")
fi

RTK_LATEST="$(curl -fsSL -m 10 https://api.github.com/repos/rtk-ai/rtk/releases/latest 2>/dev/null | grep -m1 '"tag_name"' | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' || echo "")"
if [ -n "$RTK_LATEST" ] && [ -n "$RTK_CURRENT" ] && [ "$RTK_LATEST" != "$RTK_CURRENT" ]; then
    REBUILD_REASONS+=("rtk ${RTK_CURRENT} -> ${RTK_LATEST}")
fi

if [ -n "$NODE_LATEST_PATCH" ] && [[ ! "$NODE_LATEST_PATCH" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Warning: unexpected value from nodejs.org/dist/index.json for node ${CURRENT_NODE_MAJOR}.x: '${NODE_LATEST_PATCH}' -- skipping node update check." >&2
    NODE_LATEST_PATCH=""
fi

if [ -n "$NODE_LATEST_PATCH" ] && [ -n "$NODE_CURRENT" ] && [ "$NODE_LATEST_PATCH" != "$NODE_CURRENT" ]; then
    REBUILD_REASONS+=("node ${NODE_CURRENT} -> ${NODE_LATEST_PATCH}")
    # Unlike NodeSource's rolling repo, the tarball install is pinned to an
    # exact version -- bump it here so the upcoming --no-cache build actually
    # picks up the newer patch instead of just re-fetching the same one.
    sed -i "s/^ARG NODE_VERSION=.*/ARG NODE_VERSION=${NODE_LATEST_PATCH#v}/" Dockerfile
fi

if [ "$FORCE" = true ]; then
    REBUILD_REASONS+=("--force requested")
fi

if [ "${#REBUILD_REASONS[@]}" -eq 0 ]; then
    echo ""
    echo "==> Everything is already up to date (ubuntu, egress-proxy, gh, node, npm claude-code, rtk)."
    echo "==> Skipping image rebuild. Making sure containers are up..."
    docker compose up -d
    if [ -n "$MAJOR_UPGRADES" ]; then
        echo ""
        echo "Available major upgrades (NOT applied automatically):"
        echo -e "$MAJOR_UPGRADES"
    fi
    echo "Nothing to do. Use --force to rebuild anyway."
    exit 0
fi

echo ""
echo "==> Rebuild needed:"
for reason in "${REBUILD_REASONS[@]}"; do
    echo "  - $reason"
done
echo ""

# --- 4. apply updates ----------------------------------------------------

echo "==> Rebuilding claude-code image (--pull --no-cache)..."
export CLAUDE_CODE_VERSION="${NPM_LATEST:-${NPM_CURRENT:-unknown}}"
export BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
docker compose build --pull --no-cache

echo "==> Recreating containers..."
docker compose up -d --force-recreate

# --- 5. capture "after" state --------------------------------------------

echo "==> Capturing new versions..."
AFTER="$(snapshot_versions)"
EGRESS_AFTER="$(egress_proxy_digest)"

# --- 6. report -------------------------------------------------------------

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
