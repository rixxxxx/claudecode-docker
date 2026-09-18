Tracked placeholder keypair, committed on purpose (subject CN says so too:
"claude-code-docker ssl-bump PLACEHOLDER (inert)").

The SSL-Bump-capable `http_port` variant (`.squid-http-port-sslbump/`, see
squid.conf's own comment) needs a syntactically valid `cert=`/`key=` pair to
start -- this directory is the default bind-mount source for that path
(`SQUID_BUMP_CA_DIR` in docker-compose.yml), mirroring `.squid-empty`'s role
for the other no-op includes in this repo. Irrelevant when
`SQUID_HTTP_PORT_DIR` is also at its default (`.squid-http-port-plain/`,
which declares a plain `http_port 3128` with no `cert=`/`key=` reference at
all) -- this placeholder only matters once `bin/cc-container --ssl-bump`
switches all three of `SQUID_HTTP_PORT_DIR`/`SQUID_SSLBUMP_DIR`/
`SQUID_BUMP_CA_DIR` together. This placeholder is never used to sign
anything by default, so it carries no real security weight and is safe to
commit (unlike `.squid-bump-ca/`, the real host-generated CA, which is
gitignored and must never be committed).

Regenerate with:
```
openssl req -x509 -newkey rsa:2048 -nodes -days 36500 \
  -keyout ca.key -out ca.crt \
  -subj "/CN=claude-code-docker ssl-bump PLACEHOLDER (inert)"
```
