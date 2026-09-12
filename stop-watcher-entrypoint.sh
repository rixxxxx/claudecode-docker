#!/bin/sh
# Entrypoint for stop-watcher (see Dockerfile.stop-watcher and
# docker-compose.yml's stop-watcher service). Polls for
# SIGNAL_DIR/trigger.<container_id> files -- written by falco-notify.sh
# once SECURITY_MONITOR_STOP_THRESHOLD CRITICAL/EMERGENCY alerts for that
# specific container id have fired (see falco-notify.sh and
# falco/claude-code-rules.yaml) -- and stops that exact container via the
# Docker Engine API over docker.sock. No docker CLI installed: curl
# --unix-socket is enough surface for one job.
#
# Deliberately does NOT try to self-discover "my own Compose project's
# claude-code sibling" (an earlier version of this script did, via
# /etc/hostname + a com.docker.compose.project label lookup). The
# container id comes straight from the alert that actually fired (see
# falco-notify.sh's container_id parsing), which is the container that
# misbehaved -- not necessarily the one in this same Compose stack, since
# Falco's eBPF view spans the whole host kernel (see AGENTS.md "Runtime
# monitoring"). Stopping by that id directly is simpler and more correct
# than resolving a sibling that might not even be the actual offender in a
# multi-workspace setup.
set -eu

SIGNAL_DIR="${SIGNAL_DIR:-/var/run/falco-stop}"
POLL_INTERVAL="${POLL_INTERVAL:-2}"
DOCKER_SOCK="/var/run/docker.sock"

echo "stop-watcher: watching $SIGNAL_DIR/trigger.* (poll=${POLL_INTERVAL}s)"

while true; do
    for trigger in "$SIGNAL_DIR"/trigger.*; do
        [ -e "$trigger" ] || continue
        container_id="${trigger##*/trigger.}"

        # Defense in depth: only this container.id-shaped value should
        # ever appear here (falco-notify.sh only writes trigger.<hex id>),
        # but validate anyway before splicing it into a docker.sock URL --
        # this is the one docker.sock-bearing surface in the repo, worth
        # being strict about what it acts on.
        case "$container_id" in
            *[!a-f0-9]* | "")
                echo "stop-watcher: skipping trigger file with unexpected name: $trigger" >&2
                rm -f "$trigger"
                continue
                ;;
        esac

        echo "stop-watcher: threshold reached -- stopping container $container_id"
        if ! curl -s --unix-socket "$DOCKER_SOCK" -X POST \
            "http://localhost/containers/$container_id/stop" >/dev/null; then
            echo "stop-watcher: failed to stop container $container_id" >&2
        fi
        rm -f "$trigger"
    done
    sleep "$POLL_INTERVAL"
done
