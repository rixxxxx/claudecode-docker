# Enterprise proxy support

If your network requires all outbound traffic to go through a corporate
forward proxy, set it in `.env` (copy from `.env.example`):

```bash
HTTP_PROXY=http://user:password@proxy.corp.example.com:8080
HTTPS_PROXY=http://user:password@proxy.corp.example.com:8080
NO_PROXY=localhost,127.0.0.1
```

This is used two ways:

- **At image build time**, passed into `Dockerfile`/`Dockerfile.proxy-auth`
  as BuildKit secrets (not build args — a corporate proxy password in a
  build arg would persist in `docker history`), since `apt`, `curl`, `npm`,
  `gh`, `rtk`, and `pip` all fetch over the network during the build.
- **At runtime**, parsed by `bin/cc-container` into a Squid `cache_peer`
  directive, so `egress-proxy` chains to your corporate proxy instead of
  reaching the internet directly. `claude-code` itself is unaffected — it
  keeps talking to `egress-proxy` exactly as before; the corporate proxy is
  one hop further out.

By default this assumes **Basic auth**. For **NTLM** or **Kerberos**, also
set:

```bash
ENTERPRISE_PROXY_AUTH=ntlm   # or: kerberos
```

Squid can't do NTLM/Kerberos itself, so `bin/cc-container` automatically
builds and starts an additional sidecar, `proxy-auth` (running
[px](https://github.com/genotrance/px)), which authenticates against the
corporate proxy and exposes a plain local proxy that `egress-proxy` chains
to instead. It only runs when actually needed (via a Compose profile) — no
extra container for the common Basic-auth-or-no-proxy case. `proxy-auth`
sits on a dedicated `proxy-chain` network that `claude-code` never joins,
so the sandbox can't reach it directly (see
[AGENTS.md](../AGENTS.md#enterprise-proxy-support)).

For Kerberos specifically, also set (Linux hosts with an existing `kinit`
ticket only — Windows/macOS domain SSO passthrough isn't supported):

```bash
KRB5_CCNAME_PATH=/tmp/krb5cc_1000   # your ticket cache, from `klist`
KRB5_CONFIG_PATH=/etc/krb5.conf
```

**TLS-intercepting proxies:** if your corporate proxy re-signs HTTPS
traffic with its own root CA, drop that CA certificate at
`certs/<name>.crt` before building. It's trusted system-wide in the image
at build time (before the container's non-root user is created), covering
`curl`/`git`/`gh`/`rtk`/apt as well as Node/npm/the Claude Code CLI (which
don't read the system trust store by default — handled via
`NODE_EXTRA_CA_CERTS`). Rotating the CA means rebuilding the image
(`bin/update-deps.sh` or `docker compose build`).

**Limitations:**
- Only Basic, NTLM, and Kerberos are supported for the corporate proxy
  itself (via Squid `cache_peer` or the `px` sidecar).
- Proxy passwords must not contain characters that break `px.env`/Squid
  config syntax (e.g. unescaped `#`).
- `cc-container`/`bin/update-deps.sh --update` keep the `proxy-auth`
  sidecar in sync automatically: a cached rebuild picks up local
  `Dockerfile.proxy-auth`/`proxy-auth-entrypoint.sh`/`certs/` edits every
  run, `--update` additionally checks `python:3.12-slim` and the
  `px-proxy` pip package upstream and forces `--no-cache` if either moved,
  and the sidecar is restarted (or torn down, if the corporate proxy was
  removed from `.env`) so it always reflects the current config.
- The **Docker daemon's own** proxy configuration (needed to pull the
  `ubuntu`/`ubuntu/squid`/`python` base images in the first place) is a
  host/OS-level prerequisite this repo doesn't configure — see
  [Docker's docs on configuring the daemon to use a proxy](https://docs.docker.com/config/daemon/proxy/).
- This repo doesn't alter your host's own CA trust store (e.g. for
  `bin/update-deps.sh`'s direct `curl` calls) — that must already be set up
  outside this repo if your host itself sits behind TLS interception.
