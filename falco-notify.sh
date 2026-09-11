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

if [ "$(id -u)" = 0 ] && [ -n "${HOST_UID:-}" ]; then
    setpriv --reuid="$HOST_UID" --regid="$HOST_UID" --clear-groups \
        notify-send --urgency=critical "Falco: claude-code alert" "$message"
else
    notify-send --urgency=critical "Falco: claude-code alert" "$message"
fi
