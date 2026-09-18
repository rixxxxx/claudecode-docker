#!/usr/bin/env bash
# Generates this host's own SSL-Bump root CA for egress-proxy (see
# squid.conf's "SSL Bump" comment and README "TLS interception"). Idempotent
# -- does nothing but re-sync certs/ if .squid-bump-ca/ca.key already
# exists, so it's safe to call from bin/cc-container --ssl-bump on every
# invocation. Pass --force to rotate (generate a fresh CA, replacing the
# old one -- claude-code stops trusting the old CA the next time its image
# is rebuilt, same "rotating the CA means rebuilding the image" model as
# the existing enterprise-CA mechanism, see README "Enterprise proxy
# support").
#
# Unlike an enterprise CA (certs/*.crt, shared/non-secret, fine to commit),
# this CA is generated fresh per host/clone and its private key must never
# be committed -- .squid-bump-ca/ is gitignored (see .gitignore). The public
# half is also copied into certs/egress-proxy-bump-ca.crt (gitignored
# separately) so claude-code's existing build-time CA-trust mechanism
# (Dockerfile: COPY certs/ + update-ca-certificates + NODE_EXTRA_CA_CERTS)
# picks it up completely unchanged -- no Dockerfile edit needed for
# claude-code itself.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CA_DIR="$PROJECT_ROOT/.squid-bump-ca"
CA_KEY="$CA_DIR/ca.key"
CA_CRT="$CA_DIR/ca.crt"
DEST_CRT="$PROJECT_ROOT/certs/egress-proxy-bump-ca.crt"

if [ -f "$CA_KEY" ] && [ -f "$CA_CRT" ] && [ "${1:-}" != "--force" ]; then
    echo "==> SSL-Bump CA already exists at $CA_DIR (pass --force to rotate it)."
else
    mkdir -p "$CA_DIR"
    chmod 700 "$CA_DIR"
    echo "==> Generating a new SSL-Bump root CA (RSA 4096, 10 years) at $CA_DIR ..."
    openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
        -keyout "$CA_KEY" -out "$CA_CRT" \
        -subj "/CN=claude-code-docker egress-proxy bump CA (host-local)"
    chmod 600 "$CA_KEY"
    chmod 644 "$CA_CRT"
    echo "==> Generated."
    echo "==> IMPORTANT: rebuild the claude-code image so it trusts this CA:"
    echo "      docker compose build claude-code"
fi

mkdir -p "$PROJECT_ROOT/certs"
cp "$CA_CRT" "$DEST_CRT"
echo "==> Public cert synced to $DEST_CRT (gitignored -- never commit this file or .squid-bump-ca/)."
echo "==> Then run 'bin/cc-container --ssl-bump' (or export SQUID_SSLBUMP_DIR=\$(pwd)/.squid-sslbump-enabled"
echo "    and SQUID_BUMP_CA_DIR=\$(pwd)/.squid-bump-ca before 'docker compose up') to enable bumping."
