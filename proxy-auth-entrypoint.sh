#!/usr/bin/env bash
# Entrypoint for the proxy-auth sidecar (Dockerfile.proxy-auth). Launches
# px (genotrance/px) against the config bin/cc-container rendered into
# .squid-upstream-proxy/px.ini, mounted read-only at /etc/px/px.ini.
#
# VERIFY BEFORE RELYING ON THIS: the px.ini keys this script/its config
# rely on were written from documentation knowledge, not confirmed against
# a live `px --help` (no network access at authoring time). After building,
# run `docker compose run --rm proxy-auth px --help` and adjust this script
# and the px.ini rendering in bin/cc-container if flags/keys differ.
set -euo pipefail

if [ -f /tmp/krb5cc ]; then
    export KRB5CCNAME="FILE:/tmp/krb5cc"
fi

exec px --config /etc/px/px.ini
