# AGENTS.md

Guidance for AI coding agents (Claude Code, Codex, etc.) working in this
repository.

## What this repo is

Not application code, but the definition of an isolated Docker setup in
which Claude Code itself runs (see `README.md` for the architecture).
Key files:

| File                  | Purpose                                                  |
|-----------------------|-------------------------------------------------------------|
| `bin/cc-container`     | Host-side entry point: mounts the invoking directory as `/workspace` (`HOST_WORKSPACE`), `docker compose up -d` + exec into `claude` |
| `bin/update-deps.sh`   | Host-side dependency updater, invoked via `cc-container --update` |
| `Dockerfile`           | Builds the Claude Code image                                |
| `docker-compose.yml`   | Orchestrates `claude-code` + `egress-proxy`, networks       |
| `squid.conf`           | Squid skeleton (ports/safety rules + `include`s) for the egress proxy |
| `.squid-claudecode-docker/` | This repo's default domain allowlist (`include`d by `squid.conf`) |
| `.squid-empty/`        | Placeholder mounted when a target workspace has no `.squid-claudecode-docker/` of its own |
| `.squid-upstream-proxy/` | Generated (gitignored) by `bin/cc-container` from `.env`: enterprise proxy chaining for `egress-proxy` — see "Enterprise proxy support" below |
| `Dockerfile.proxy-auth` | Builds the `proxy-auth` sidecar (px) for NTLM/Kerberos corporate proxies |
| `entrypoint.sh`        | Container entrypoint (terminal setup, welcome banner)       |

## Security-critical files — change with care

`squid.conf`, `.squid-claudecode-docker/`, and the `networks:` section in
`docker-compose.yml` form the entire network isolation of the container.
That's the actual purpose of this repo, not incidental config.

- Only add new domains to `.squid-claudecode-docker/` when actually needed,
  with a short comment explaining what they're for (see existing blocks:
  Auth/API, npm, GitHub, Node.js). The same rules apply to a target
  workspace's own `.squid-claudecode-docker/*.conf` files (see "Per-workspace
  `.squid-claudecode-docker` overrides" below).
- Never propose wildcard grants (`.com`, entire CDNs without reason) or
  `allow all` — that undermines the allowlist model.
- Don't remove `internal: true` on the `internal` network in
  `docker-compose.yml` — that's the mechanism that removes the default
  internet route from the `claude-code` container.
- `claude-code` intentionally runs as non-root (UID 1000, see
  `Dockerfile`). Don't make changes that remove `USER claudecode` or add
  root privileges at runtime without explicit confirmation.
- `claude-code` must never join the `proxy-chain` network in
  `docker-compose.yml` (only `egress-proxy` and `proxy-auth` do). That
  network is how `egress-proxy` reaches the NTLM/Kerberos sidecar; if
  `claude-code` could reach it too, the sandbox could bypass Squid's domain
  allowlist entirely by talking to `proxy-auth` directly. See "Enterprise
  proxy support" below.

## Enterprise proxy support

`egress-proxy` can chain to a corporate forward proxy instead of reaching
the internet directly — see `README.md` "Enterprise proxy support" for the
user-facing setup (`.env` variables). Mechanics, for anyone touching this
code:

- `bin/cc-container` reads `HTTP_PROXY`/`HTTPS_PROXY`/`ENTERPRISE_PROXY_AUTH`
  from `.env` (loaded explicitly there — Compose's own `.env` auto-load
  doesn't extend to this script) and renders
  `.squid-upstream-proxy/{upstream.conf,px.ini}` before `docker compose up`.
  Regenerated every run, gitignored (may contain credentials), never
  committed.
- Basic auth: `upstream.conf` gets a `cache_peer ... login=user:pass`
  directly — no sidecar needed.
- NTLM/Kerberos: Squid can't do this itself, so `upstream.conf` instead
  points `cache_peer` at `proxy-auth` (the `px`-based sidecar, built from
  `Dockerfile.proxy-auth`), which handles the real corporate auth and
  exposes a plain local proxy. Only built/started via the `enterprise-proxy`
  Compose profile, which `bin/cc-container` adds automatically when needed.
- `Dockerfile` and `Dockerfile.proxy-auth` both accept `HTTP_PROXY`/
  `HTTPS_PROXY`/`NO_PROXY` build args (for their own RUN steps: apt, curl,
  npm, gh, rtk, pip) and both trust an optional `certs/*.crt` enterprise CA
  at build time, before their non-root `USER` switch — the only way to get
  CA trust without granting runtime root (see the point above).
- The `proxy-auth-entrypoint.sh` script's exact `px` invocation was written
  from documentation knowledge, not verified live (no network access at
  authoring time) — see the verification comment at its top before relying
  on NTLM/Kerberos in production.

## Per-workspace `.squid-claudecode-docker` overrides

`bin/cc-container` creates `$HOST_WORKSPACE/.squid-claudecode-docker` (as
the invoking host user, if it doesn't already exist) and exports
`SQUID_WORKSPACE_DIR` to it — creating it here rather than letting Docker
auto-create the bind-mount source avoids Docker creating it as root and
leaving it unwritable for future edits. `docker-compose.yml`'s own
`${SQUID_WORKSPACE_DIR:-./.squid-empty}` default only matters if
`docker compose` is invoked directly, bypassing `cc-container`.
`docker-compose.yml` bind-mounts it into `egress-proxy` at
`/etc/squid/conf.d/workspace`, alongside this repo's own
`.squid-claudecode-docker/` (always mounted at `/etc/squid/conf.d/defaults`).
`squid.conf` `include`s both directories via `*.conf` glob — a workspace
can split its rules across as many files as it wants there. This is
additive, not override: a workspace's rules extend this repo's defaults,
they don't replace them. The `-claudecode-docker` suffix on the folder
name is deliberate — it keeps this unambiguous even if a workspace
happens to have some other, unrelated `.squid` folder of its own.

Trust boundary: the `acl allowed_domains`/`http_access` rules in a target
repo's `.squid-claudecode-docker/*.conf` are only ever as broad as whoever
committed them to that repo intended — the `claude-code` container itself
cannot widen its own allowlist. `docker-compose.yml`'s `claude-code`
service mounts `${SQUID_WORKSPACE_DIR:-./.squid-empty}` a second time,
read-only, at `/workspace/.squid-claudecode-docker` — this shadows that one
subpath of the otherwise read-write `/workspace` mount, so a session
running inside `claude-code` can read its own effective network policy
but never create or modify it. Anyone changing a workspace's
`.squid-claudecode-docker/` therefore has to do so from outside the sandbox
(the host, or another trusted process) before/between `cc-container`
runs — never keep this mount writable inside `claude-code`. This override
is scoped to that workspace's own dedicated `egress-proxy` instance (see
"Multi-instance invariants" below) — it can't affect other workspaces.

## Validating changes

```bash
./tests/run-tests.sh          # unit tests: fast, no Docker (bash -n, shellcheck if
                                #   installed, render_upstream_proxy_conf()/
                                #   derive_compose_project_name() logic, install.sh/
                                #   uninstall.sh against a fakehome sandbox)
./tests/run-tests.sh --all    # + integration tests: needs Docker, builds/starts the
                                #   real stack under its own throwaway Compose project
                                #   and checks the security-critical invariants below
                                #   (non-root, domain allowlist, network isolation)
```

See `tests/README.md` for the test layout. For anything the suite doesn't
cover, or to debug a failure by hand, the same checks it automates are also
useful standalone:

```bash
docker compose config          # check compose file syntax/interpolation
docker compose build           # build Dockerfile changes
docker compose up -d
docker compose exec egress-proxy squid -k parse   # check merged squid.conf + .squid-claudecode-docker/ syntax
docker compose logs egress-proxy | grep TCP_DENIED # see blocked connections
```

## Style

- `squid.conf`, `.squid-claudecode-docker/*.conf`, and a target workspace's
  own `.squid-claudecode-docker/*.conf`: comments group domains by purpose
  (block header, then `acl allowed_domains dstdomain ...` lines). Follow
  this pattern rather than introducing new structures.
- Keep documentation in English, consistent with `README.md`.
- Keep `entrypoint.sh` minimal (terminal setup + `exec "$@"`/shell) —
  don't put business logic there.
- Keep `bin/cc-container` minimal (resolve project root, export
  `HOST_WORKSPACE`/`COMPOSE_PROJECT_NAME` for the per-workspace bind mount
  and Compose project, optionally delegate to `update-deps.sh` on
  `--update`, `docker compose up -d`, `exec ... claude`, then — once the
  `claude` session ends — prompt whether to `docker compose down` this
  workspace's containers) — it's the host-side wrapper, not a place for
  container-side logic (that belongs in `entrypoint.sh`). The exit prompt
  is intentionally host-side only: `claude-code` has no Docker
  socket/CLI, so a hook running inside the container could never actually
  stop the containers itself.

## Multi-instance invariants — don't break these

Each workspace runs as its own Compose project (`COMPOSE_PROJECT_NAME`,
derived from `HOST_WORKSPACE` in `bin/cc-container`), giving every
instance its own containers, networks, and dedicated `egress-proxy`. This
depends on:

- No top-level `name:` key in `docker-compose.yml` — that would outrank
  the `COMPOSE_PROJECT_NAME` env var and collapse every workspace back
  onto one shared project.
- The `image: claude-code:latest` pin on the `claude-code` service (and
  `image: claude-code-proxy-auth:latest` on `proxy-auth`) in
  `docker-compose.yml` staying in place — without it, Compose tags the
  built image per-project (`<project>-claude-code`), causing a separate
  image build per workspace instead of one shared image.
- Neither service getting a fixed `container_name:` again — that's what
  originally made parallel instances collide (Docker enforces host-wide
  container-name uniqueness).
- Any script that looks up a running container doing so via
  `docker compose ps -q <service>` / `docker compose exec <service>`
  (project-relative), never via a literal hardcoded container name —
  `bin/update-deps.sh`'s `egress_proxy_digest()` was fixed to follow this
  pattern; keep new code consistent with it.

`egress-proxy` in `HTTP_PROXY`/`HTTPS_PROXY` (`docker-compose.yml`) is the
Compose *service* name, resolved via Docker's embedded DNS scoped to each
project's own `internal` network — it correctly resolves to a different,
dedicated proxy container per workspace without any extra code. Don't
confuse this with `squid.conf`'s `visible_hostname egress-proxy`, which is
just a static label in Squid's own `Via` header/error pages (identical
across every instance, no DNS/networking behavior) — no need to make it
"unique per instance".
