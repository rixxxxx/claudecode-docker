#!/bin/sh
# Entrypoint for stop-watcher (see Dockerfile.stop-watcher and
# docker-compose.yml's stop-watcher service). Polls TRIGGER_FILE -- written
# by falco-notify.sh once SECURITY_MONITOR_STOP_THRESHOLD CRITICAL/
# EMERGENCY alerts attributed to claude-code have fired (see
# falco-notify.sh and falco/claude-code-rules.yaml) -- and, when it
# appears, stops the claude-code container belonging to this same Compose
# project via the Docker Engine API over docker.sock. No docker CLI
# installed: curl --unix-socket + jq is enough surface for one job.
#
# ASSUMPTION (no Docker access at authoring time to confirm on a live
# host, same caveat as Dockerfile.security-monitor/docker-compose.yml):
# /etc/hostname holds this container's own short ID, which is Docker's
# default hostname for any container that doesn't set `hostname:`
# explicitly (none of this repo's services do). Used below to
# self-discover which Compose project this container belongs to, since
# claude-code's own container name is dynamic per workspace (see
# bin/cc-container's derive_compose_project_name) -- matching on the
# com.docker.compose.project label Docker Compose sets on every container
# in a stack, rather than a fixed name, works regardless of which
# workspace/project this stop-watcher instance is running in.
set -eu

TRIGGER_FILE="${TRIGGER_FILE:-/var/run/falco-stop/trigger}"
POLL_INTERVAL="${POLL_INTERVAL:-2}"
DOCKER_SOCK="/var/run/docker.sock"
SELF_ID="$(cat /etc/hostname)"

docker_api_get() {
    curl -s --unix-socket "$DOCKER_SOCK" "http://localhost$1"
}

docker_api_post() {
    curl -s --unix-socket "$DOCKER_SOCK" -X POST "http://localhost$1"
}

echo "stop-watcher: watching $TRIGGER_FILE (self=$SELF_ID, poll=${POLL_INTERVAL}s)"

while true; do
    if [ -f "$TRIGGER_FILE" ]; then
        project="$(docker_api_get "/containers/$SELF_ID/json" \
            | jq -r '.Config.Labels["com.docker.compose.project"] // empty')"

        if [ -z "$project" ]; then
            echo "stop-watcher: could not resolve own compose project label via docker.sock, skipping this trigger" >&2
        else
            filters_enc="$(jq -n --arg p "$project" \
                '{label: ["com.docker.compose.project=" + $p, "com.docker.compose.service=claude-code"]}' \
                | tr -d '\n' | jq -sRr @uri)"
            target="$(docker_api_get "/containers/json?filters=$filters_enc" | jq -r '.[0].Id // empty')"

            if [ -z "$target" ]; then
                echo "stop-watcher: no running claude-code container found in project '$project', skipping" >&2
            else
                echo "stop-watcher: threshold reached -- stopping claude-code container $target (project=$project)"
                docker_api_post "/containers/$target/stop" >/dev/null
            fi
        fi

        rm -f "$TRIGGER_FILE"
    fi
    sleep "$POLL_INTERVAL"
done
