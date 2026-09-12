#!/bin/sh
# Entrypoint for stop-watcher (see Dockerfile.stop-watcher and
# docker-compose.yml's stop-watcher service). Polls for
# SIGNAL_DIR/trigger.<container_id> files -- written by falco-notify.sh
# once SECURITY_MONITOR_STOP_THRESHOLD CRITICAL/EMERGENCY alerts for that
# specific container id have fired (see falco-notify.sh and
# falco/claude-code-rules.yaml) -- and stops that exact container via the
# Docker Engine API over docker.sock, but ONLY if it's this same instance's
# own claude-code container.
#
# Same-instance enforcement: security-monitor's eBPF view is the whole
# host kernel, not scoped to one Compose project (see AGENTS.md "Runtime
# monitoring"), so a workspace's own security-monitor can in principle
# observe and count another workspace's claude-code alerts too, and end up
# writing a trigger file naming a foreign container id into THIS
# instance's own falco-stop-signal volume. Without a check, this
# instance's stop-watcher -- which holds unrestricted docker.sock, a
# host-wide capability -- would happily stop that foreign container.
# Closed by resolving this container's own com.docker.compose.project
# label once at startup (self id from /etc/hostname -- Docker's default
# hostname, none of this repo's services override it) and refusing to act
# on any trigger whose target container isn't in that same project (and
# isn't the claude-code service specifically).
#
# VERIFY (no Docker access at authoring time): /etc/hostname holding this
# container's own id, and container.id (used in the trigger filename,
# parsed by falco-notify.sh) matching what docker.sock's
# /containers/<id>/json accepts -- same open items as before, now load-
# bearing for the same-instance guarantee too, not just for picking the
# right target.
set -eu

SIGNAL_DIR="${SIGNAL_DIR:-/var/run/falco-stop}"
POLL_INTERVAL="${POLL_INTERVAL:-2}"
DOCKER_SOCK="/var/run/docker.sock"

docker_api_get() {
    curl -s --unix-socket "$DOCKER_SOCK" "http://localhost$1"
}

docker_api_post() {
    curl -s --unix-socket "$DOCKER_SOCK" -X POST "http://localhost$1"
}

self_id="$(cat /etc/hostname)"
own_project="$(docker_api_get "/containers/$self_id/json" | jq -r '.Config.Labels["com.docker.compose.project"] // empty')"

if [ -z "$own_project" ]; then
    # Fail closed: without knowing our own project, there is no way to
    # tell "own container" from "someone else's" -- refuse to run at all
    # rather than risk stopping the wrong thing. restart: unless-stopped
    # will keep retrying (e.g. across a docker.sock hiccup at boot).
    echo "stop-watcher: FATAL -- could not resolve own com.docker.compose.project label via docker.sock (self_id=$self_id); refusing to start" >&2
    exit 1
fi

echo "stop-watcher: watching $SIGNAL_DIR/trigger.* (own project=$own_project, poll=${POLL_INTERVAL}s)"

while true; do
    for trigger in "$SIGNAL_DIR"/trigger.*; do
        [ -e "$trigger" ] || continue
        container_id="${trigger##*/trigger.}"

        # Defense in depth: only this container.id-shaped value should
        # ever appear here (falco-notify.sh only writes trigger.<hex id>),
        # but validate anyway before splicing it into a docker.sock URL.
        case "$container_id" in
            *[!a-f0-9]* | "")
                echo "stop-watcher: skipping trigger file with unexpected name: $trigger" >&2
                rm -f "$trigger"
                continue
                ;;
        esac

        target="$(docker_api_get "/containers/$container_id/json")"
        target_project="$(printf '%s' "$target" | jq -r '.Config.Labels["com.docker.compose.project"] // empty')"
        target_service="$(printf '%s' "$target" | jq -r '.Config.Labels["com.docker.compose.service"] // empty')"

        if [ "$target_project" != "$own_project" ] || [ "$target_service" != "claude-code" ]; then
            echo "stop-watcher: refusing to stop container $container_id (project=${target_project:-?} service=${target_service:-?}) -- not this instance's own claude-code container (own project=$own_project)" >&2
            rm -f "$trigger"
            continue
        fi

        echo "stop-watcher: threshold reached -- stopping own claude-code container $container_id (project=$own_project)"
        if ! docker_api_post "/containers/$container_id/stop" >/dev/null; then
            echo "stop-watcher: failed to stop container $container_id" >&2
        fi
        rm -f "$trigger"
    done
    sleep "$POLL_INTERVAL"
done
