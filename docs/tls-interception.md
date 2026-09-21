# TLS interception (SSL Bump, optional)

**Status: live-verified working.** `ubuntu/squid:latest` ships the plain
`squid` package (GnuTLS, no SSL-Bump capability at all) — Debian/Ubuntu
split Squid into two mutually-exclusive packages built from the same
source, and **`squid-openssl`** (OpenSSL-linked, has
`security_file_certgen`) is the one with SSL-Bump support.
`Dockerfile.egress-proxy` installs `squid-openssl` on top before
initializing the cert-cache — see that file and
`.squid-sslbump-enabled/10-bump.conf` for the implementation details and
the bugs that surfaced getting there. `TEST_SSL_BUMP=1
tests/integration/test_ssl_bump.sh` confirms end to end: the bumped
connection's TLS chain terminates at the generated CA (not the real
site's), the illustrative `exfil_suspicious_url` rule blocks a
long-base64 query string, a non-allowlisted domain stays blocked, and an
allowlisted domain stays reachable. Default (non-SSL-Bump) usage remains
completely unaffected — the whole feature stays isolated behind
`SQUID_HTTP_PORT_DIR`/`SQUID_SSLBUMP_DIR`/`SQUID_BUMP_CA_DIR`, all
defaulting to inert placeholders (see
[AGENTS.md](../AGENTS.md#ssl-bump-support-optional) for the mechanism).

By default, `egress-proxy` only sees the *domain* of an HTTPS request (via
CONNECT) — never the path or query string, since the connection is
tunneled encrypted end-to-end. That leaves one residual gap: a request to
an already-allowed domain can still carry data in its path/query (e.g.
`curl "https://api.github.com/search/issues?q=<secret>"` — the domain is
allowed, the payload isn't inspected).

Closing that requires SSL Bump: `egress-proxy` decrypts HTTPS traffic for
already-allowed domains only (the domain-level `allowed_domains` allowlist
is unchanged and still the primary gate — see
[domain-allowlist.md](domain-allowlist.md)), so path/query-level rules can
additionally apply. This is opt-in and off by default.

**Enabling it:**
```
bin/generate-bump-ca.sh      # generates this host's own CA (once; see below)
docker compose build claude-code   # so claude-code trusts the new CA
bin/cc-container --ssl-bump        # or: docker compose up -d with
                                    # SQUID_SSLBUMP_DIR/SQUID_BUMP_CA_DIR
                                    # exported (see docker-compose.yml)
```

**How the CA works:** `bin/generate-bump-ca.sh` creates a fresh, host-local
root CA in `.squid-bump-ca/` (gitignored — this is *not* a shared secret
like an enterprise CA in `certs/`, it's generated per clone/host, and its
private key must never be committed). The public half is synced to
`certs/egress-proxy-bump-ca.crt` (also gitignored) so it's trusted inside
`claude-code` via the exact same build-time mechanism used for enterprise
CAs (`Dockerfile`: `COPY certs/` + `update-ca-certificates` +
`NODE_EXTRA_CA_CERTS`) — no separate trust mechanism to maintain.
Rotating the CA (`bin/generate-bump-ca.sh --force`) means rebuilding
`claude-code` again, same model as rotating an enterprise CA.

**What's actually filtered:** `squid.conf`'s SSL Bump section ships one
illustrative starting rule (`.squid-sslbump-enabled/10-bump.conf`), not an
exhaustive ruleset — it blocks requests to allowed domains whose path/query
contains a long base64-looking run, one concrete shape of "exfiltrate a
secret via the URL of an otherwise-allowed request." Expect to tune this;
a legitimate long token/hash in a URL will false-positive against it.

Separately, `.squid-sslbump-enabled/20-search-only.conf` restricts a
subset of the reference-domain allowlist (Stack Overflow, MDN, pkg.go.dev,
PyPI, crates.io, npm, RubyGems, Packagist, Django docs, Wikipedia,
PostgreSQL docs — see that file for the exact list) to their own
search-query endpoint only, denying everything else on those domains —
live-verified via `TEST_SSL_BUMP=1 tests/integration/test_ssl_bump.sh`
(see
[.squid-sslbump-enabled/20-search-only.conf](../.squid-sslbump-enabled/20-search-only.conf)'s
own header comment and [AGENTS.md](../AGENTS.md) "Security-critical
files" for the two real-world gotchas that surfaced along the way, e.g.
crates.io 403ing a bare `curl` request over User-Agent filtering). Domains where the site's own search has no simple,
restrictable server-side endpoint (rustdoc, devdocs.io, Python's Sphinx
docs, most Algolia-DocSearch-backed sites, Redis/AWS docs' JS-SPA search,
Docker/Falco/Google Cloud docs, MySQL docs) are deliberately left fully
open instead, since a search-only rule there would either do nothing or
break real usage. `.algolia.net`/`.algolianet.com` (the actual
third-party search backend for
react.dev/vuejs.org/angular.dev/kubernetes.io) are separately allowlisted
and restricted to just the query API path.

**Limitations (see
[falco/claude-code-rules.yaml](../falco/claude-code-rules.yaml)'s OPEN
ITEMS "Third pass" and this feature's own commit for open items):**
- Node/Bun (npm, the claude-code CLI itself) need `NODE_EXTRA_CA_CERTS`
  (already set, see above); `curl`/`git`/`gh`/apt trust the bumped CA via
  the system store. Python (`pip`/`requests`) CA trust is not explicitly
  configured for either the enterprise-CA or this case — likely fine via
  `certifi`/OpenSSL defaults, but not verified.
- Turning this on makes `egress-proxy` a decryption point for all of
  `claude-code`'s allowed HTTPS traffic, including its own conversation
  with `api.anthropic.com` — a real trade-off (see
  [AGENTS.md](../AGENTS.md#ssl-bump-support-optional) for the design
  notes), not just a filtering upgrade.

## Worked example: blocking a new exfiltration-shaped URL pattern

Say you also want to block requests that carry an obvious AWS access key
(`AKIA...`) in the query string, on top of the existing long-base64 rule.
SSL Bump ACLs live in `.squid-sslbump-enabled/10-bump.conf` — only take
effect with `--ssl-bump` enabled, so they're safe to edit without affecting
default usage.

1. Add a new ACL and deny rule, following the existing
   `exfil_suspicious_url` pattern in that file:

   ```squid
   acl exfil_aws_key urlpath_regex -i "AKIA[0-9A-Z]{16}"
   http_access deny exfil_aws_key
   ```

   Put this *before* the domain's own `http_access allow CONNECT <domain>`
   line for any domain you want it to apply to — Squid evaluates
   `http_access` top to bottom, first match wins (see
   `20-search-only.conf`'s header comment for why the ordering matters here
   specifically).

2. Apply it:

   ```bash
   docker compose restart egress-proxy
   ```

3. Verify it actually blocks the decrypted request (not just the CONNECT):

   ```bash
   docker compose exec claude-code curl -sS -o /dev/null -w '%{http_code}\n' \
     "https://api.github.com/search/issues?q=AKIAABCDEFGHIJKLMNOP"
   ```

   Expect a proxy-denied response, not GitHub's own API response. Check
   `docker compose logs egress-proxy | grep exfil_aws_key` to confirm the
   new ACL was the one that matched.

4. Add a regression test alongside the existing ones in
   `tests/integration/test_ssl_bump.sh` so a future refactor can't silently
   drop the rule — see that file for the pattern the other SSL-Bump checks
   follow.
