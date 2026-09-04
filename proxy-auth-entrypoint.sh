#!/usr/bin/env bash
# Entrypoint for the proxy-auth sidecar (Dockerfile.proxy-auth). Launches
# px (genotrance/px) against the config bin/cc-container rendered into
# .squid-upstream-proxy/px.ini, mounted read-only at /etc/px/px.ini.
#
# Verified against a live `px --help` (px v0.12.0): --config, and the
# proxy/listen/port/gateway/allow/username keys rendered into px.ini by
# bin/cc-container's render_upstream_proxy_conf(), all match. px has no
# `password` key for px.ini though -- only --password (interactive
# keyring) or the PX_PASSWORD env var -- so the password, when set, is
# rendered separately as px.env and sourced below instead.
set -euo pipefail

if [ -f /tmp/krb5cc ]; then
    export KRB5CCNAME="FILE:/tmp/krb5cc"
fi

if [ -f /etc/px/px.env ]; then
    set -a
    # shellcheck disable=SC1091
    source /etc/px/px.env
    set +a
fi

exec px --config /etc/px/px.ini "$@"
