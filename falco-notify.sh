#!/usr/bin/env bash
# Falco program_output target (see falco/falco.yaml): Falco spawns this
# fresh per alert (keep_alive: false) and pipes one formatted alert line to
# its stdin. Forwards it as a native desktop notification via the host's
# D-Bus session bus, bind-mounted read-write into this container (see
# docker-compose.yml's security-monitor service) -- DBUS_SESSION_BUS_ADDRESS
# must already be set in the environment for this to reach the host's
# actual notification daemon.
#
# VERIFY BEFORE RELYING ON THIS: whether a root process in this container
# can write to the host's /run/user/<uid>/bus session socket, and whether
# notify-send needs anything beyond DBUS_SESSION_BUS_ADDRESS (e.g.
# XDG_RUNTIME_DIR) to work reliably -- not confirmed on a live host at
# authoring time. See AGENTS.md "Runtime monitoring".
set -euo pipefail

message="$(cat)"

notify-send --urgency=critical "Falco: claude-code alert" "$message"
