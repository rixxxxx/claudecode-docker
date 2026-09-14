#!/usr/bin/env bash
# Falco program_output target (see falco/falco.yaml): Falco spawns this
# fresh per alert (keep_alive: false) and pipes one formatted alert line to
# its stdin. Forwards it as a native desktop notification via the host's
# D-Bus session bus, bind-mounted read-write into this container (see
# docker-compose.yml's security-monitor service) -- DBUS_SESSION_BUS_ADDRESS
# must already be set in the environment for this to reach the host's
# actual notification daemon.
#
# Confirmed on a real host (2026-09-11): a plain root notify-send connects
# to the socket fine but gets "The connection is closed" right after --
# D-Bus's EXTERNAL auth checks the connecting process's actual kernel
# peer-credential UID against the bus owner (HOST_UID), and this container
# runs as root, not HOST_UID. setpriv actually changes the process's real
# UID before notify-send opens the connection, which is the only thing
# D-Bus's credential check accepts (setting DBUS_SESSION_BUS_ADDRESS alone
# doesn't fake this).
set -euo pipefail

message="$(cat)"

# Falco prefixes every non-json alert line with its priority word (e.g.
# "2026-09-12T10:00:00.000000000+0000: Warning ..."), so pull that back out
# to pick urgency/icon and, for the toaster behaviour, whether the popup is
# allowed to auto-close at all.
priority="$(printf '%s' "$message" |
    grep -oiE '\b(Emergency|Alert|Critical|Error|Warning|Notice|Informational|Debug)\b' |
    head -n1)"
priority="${priority,,}"

# Auto-stop counting (see docker-compose.yml's stop-watcher service and
# SECURITY_MONITOR_STOP_THRESHOLD in .env.example). Only counts alerts that
# mention "claude-code" in their message text -- every real rule in
# falco/claude-code-rules.yaml includes that literal substring in its
# `output:` template. Two TEST-ONLY rules are exceptions, on purpose and in
# opposite directions: "TEST - Falco pipeline sanity check" deliberately
# omits "claude-code" so a manual pipeline test never burns down the stop
# counter, while "TEST - Falco auto-stop pipeline check" deliberately
# includes it so the auto-stop path itself has a harmless way to be
# exercised end to end (see that rule's comment in claude-code-rules.yaml).
# This is deliberately NOT "any CRITICAL alert on this
# host" -- Falco watches the whole host kernel (see AGENTS.md "Runtime
# monitoring"), so a bundled default-ruleset CRITICAL alert about some
# unrelated container/process on the same machine would otherwise count
# too and could stop claude-code for something it never did.
#
# Counted PER CONTAINER ID (parsed out of the alert's own "container=..."
# field -- every rule here includes %container.id in its output), not as
# one global counter. Necessary for correct behavior with more than one
# workspace running claude-code + --monitor at once: Falco's eBPF view is
# the whole host kernel, not scoped to one Compose project, so a single
# security-monitor instance can see CRITICAL alerts from every claude-code
# container on the host, not just its own workspace's. Keying by
# container.id means an unrelated workspace's alert increments that
# *other* container's own counter, never this workspace's -- and the
# eventual stop targets exactly the container.id that crossed the
# threshold (see stop-watcher-entrypoint.sh), not "whatever claude-code
# container happens to be stop-watcher's own Compose sibling".
#
# Confirmed 2026-09-14 (live, tests/security/test_auto_stop_pipeline.sh):
# container.id IS resolvable from the kernel/cgroup path alone here, unlike
# container.name/container.image.repository which are confirmed (see
# AGENTS.md) to need a docker.sock mount and show <NA> without one -- the
# fail-closed branch below (container_id empty, alert not counted) was
# never observed to trigger; every TEST ALERT produced a real, non-empty
# container.id that fed correctly into the counter and, at threshold, the
# trigger file.
#
# flock serializes the read-increment-write against concurrent
# falco-notify.sh invocations (Falco spawns one process per alert,
# keep_alive: false -- two CRITICAL alerts firing close together could
# otherwise race and lose an increment).
stop_threshold="${SECURITY_MONITOR_STOP_THRESHOLD:-3}"
if [[ "$priority" == "critical" || "$priority" == "emergency" ]] \
    && [[ "$message" == *"claude-code"* ]] \
    && [ "$stop_threshold" -gt 0 ] 2>/dev/null; then
    container_id="$(printf '%s' "$message" | grep -oE 'container=[a-f0-9]+' | head -n1 | cut -d= -f2)"
    if [ -z "$container_id" ]; then
        echo "falco-notify.sh: CRITICAL claude-code alert with no parseable container id, not counting it: $message" >&2
    else
        stop_signal_dir="/var/run/falco-stop"
        mkdir -p "$stop_signal_dir"
        # `|| echo ... >&2` at the end: bookkeeping failing here (e.g. an
        # unwritable volume) must never abort the script before the actual
        # desktop notification below -- losing the stop-count for one
        # alert is far better than losing the alert itself.
        (
            flock -x 9
            count=0
            [ -f "$stop_signal_dir/critical_count.$container_id" ] \
                && count="$(cat "$stop_signal_dir/critical_count.$container_id")"
            count=$((count + 1))
            if [ "$count" -ge "$stop_threshold" ]; then
                echo 0 > "$stop_signal_dir/critical_count.$container_id"
                : > "$stop_signal_dir/trigger.$container_id"
            else
                echo "$count" > "$stop_signal_dir/critical_count.$container_id"
            fi
        ) 9>"$stop_signal_dir/critical_count.$container_id.lock" \
            || echo "falco-notify.sh: stop-count bookkeeping failed for container $container_id" >&2
    fi
fi

# SECURITY_MONITOR_NOTIFY (see docker-compose.yml/.env.example): host-side
# on/off switch for just the desktop popup below -- deliberately checked
# only now, after the auto-stop counting above, not before it. Falco keeps
# sending alerts here either way, and auto-stop must keep working the same
# way regardless of this setting; only stdout_output/the popup are meant
# to be affected by it.
case "${SECURITY_MONITOR_NOTIFY:-true}" in
    false | 0 | no | off) exit 0 ;;
esac

# SECURITY_MONITOR_NOTIFY_TIMEOUT (see docker-compose.yml/.env.example): how
# long, in milliseconds, the toaster stays up for non-critical alerts before
# it closes itself.
timeout_ms="${SECURITY_MONITOR_NOTIFY_TIMEOUT:-8000}"

case "$priority" in
    emergency | alert | critical)
        # Deliberately not a toaster: critical/emergency alerts stay on
        # screen until dismissed by hand so they can't be missed while
        # looking away. expire-time=0 means "never auto-expire" -- most
        # notification daemons already default to this for urgency=critical,
        # this just makes it explicit instead of relying on that default.
        urgency=critical
        icon=dialog-error
        expire_time=0
        ;;
    error | warning)
        urgency=normal
        icon=dialog-warning
        expire_time="$timeout_ms"
        ;;
    *)
        urgency=low
        icon=dialog-information
        expire_time="$timeout_ms"
        ;;
esac

title="Falco: claude-code alert"
[ -n "$priority" ] && title="$title [${priority^^}]"

notify_args=(--urgency="$urgency" --icon="$icon" --expire-time="$expire_time" "$title" "$message")

if [ "$(id -u)" = 0 ] && [ -n "${HOST_UID:-}" ]; then
    setpriv --reuid="$HOST_UID" --regid="$HOST_UID" --clear-groups \
        notify-send "${notify_args[@]}"
else
    notify-send "${notify_args[@]}"
fi
