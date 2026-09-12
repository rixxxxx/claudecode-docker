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

# SECURITY_MONITOR_NOTIFY (see docker-compose.yml/.env.example): host-side
# on/off switch for just this popup. Falco keeps sending alerts here either
# way, so stdout_output (docker logs) is unaffected.
case "${SECURITY_MONITOR_NOTIFY:-true}" in
    false | 0 | no | off) exit 0 ;;
esac

# Falco prefixes every non-json alert line with its priority word (e.g.
# "2026-09-12T10:00:00.000000000+0000: Warning ..."), so pull that back out
# to pick urgency/icon and, for the toaster behaviour, whether the popup is
# allowed to auto-close at all.
priority="$(printf '%s' "$message" |
    grep -oiE '\b(Emergency|Alert|Critical|Error|Warning|Notice|Informational|Debug)\b' |
    head -n1)"
priority="${priority,,}"

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
