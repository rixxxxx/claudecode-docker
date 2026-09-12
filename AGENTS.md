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
| `.squid-upstream-proxy/` | Generated (gitignored) by `bin/cc-container` from `.env`: enterprise proxy chaining for `egress-proxy` + build-time proxy secrets — see "Enterprise proxy support" below |
| `.squid-empty-secret`  | Tracked, always-present empty fallback for the build-time proxy secrets when `docker compose build` is run directly, bypassing `cc-container` |
| `Dockerfile.proxy-auth` | Builds the `proxy-auth` sidecar (px) for NTLM/Kerberos corporate proxies |
| `Dockerfile.security-monitor` | Builds the optional `security-monitor` sidecar (Falco) — see "Runtime monitoring" below |
| `falco/`               | Falco config (`falco.yaml`) + custom rules (`claude-code-rules.yaml`) for `security-monitor` |
| `falco-notify.sh`      | Turns a Falco alert into a native desktop notification via the host's D-Bus session bus |
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
- `security-monitor` (see "Runtime monitoring" below) is the **one
  deliberate exception** to "no privileged/root/extra capabilities" in
  this repo — eBPF-based syscall observation needs `cap_add`. This
  exception is scoped narrowly: only that one service, never started by
  default (`monitoring` Compose profile), and it grants `claude-code`
  itself nothing. Don't extend `cap_add`/`privileged`/a `docker.sock`
  mount to any other service, and don't add capabilities to
  `security-monitor` beyond what Falco's modern eBPF driver actually
  needs. `tests/security/test_static_hardening.sh` enforces this — its
  checks exempt `security-monitor` specifically, nothing else.

## Enterprise proxy support

`egress-proxy` can chain to a corporate forward proxy instead of reaching
the internet directly — see `README.md` "Enterprise proxy support" for the
user-facing setup (`.env` variables). Mechanics, for anyone touching this
code:

- `bin/cc-container` reads `HTTP_PROXY`/`HTTPS_PROXY`/`ENTERPRISE_PROXY_AUTH`
  from `.env` (loaded explicitly there — Compose's own `.env` auto-load
  doesn't extend to this script) and renders
  `.squid-upstream-proxy/{upstream.conf,px.ini,px.env}` before `docker
  compose up`. Regenerated every run, gitignored (may contain credentials),
  never committed.
- `px.ini` never gets a `password` key — px has none (only `--password`,
  which writes to the OS keyring interactively, or the `PX_PASSWORD` env
  var). The password, when set, is rendered separately as `px.env`
  (`PX_PASSWORD=...`, chmod 600, same gitignored/regenerated-every-run
  treatment) and sourced by `proxy-auth-entrypoint.sh` before it execs
  `px`.
- Basic auth: `upstream.conf` gets a `cache_peer ... login=user:pass`
  directly — no sidecar needed.
- NTLM/Kerberos: Squid can't do this itself, so `upstream.conf` instead
  points `cache_peer` at `proxy-auth` (the `px`-based sidecar, built from
  `Dockerfile.proxy-auth`), which handles the real corporate auth and
  exposes a plain local proxy. Only built/started via the `enterprise-proxy`
  Compose profile, which `bin/cc-container` adds automatically when needed.
- **Build-time proxy: BuildKit secrets, never `ARG`/`build.args`.**
  `Dockerfile`/`Dockerfile.proxy-auth` pull `HTTP_PROXY`/`HTTPS_PROXY`/
  `NO_PROXY` into individual RUN steps via
  `--mount=type=secret,id=...,env=VAR`, sourced from
  `docker-compose.yml`'s top-level `secrets:` block (file-backed,
  `render_build_secret_files()` in `bin/cc-container` writes the real
  files into `.squid-upstream-proxy/*.secret` and exports the
  `*_SECRET_FILE` vars those `secrets:` entries reference; without them —
  e.g. `docker compose build` run directly, bypassing `cc-container` — the
  `${VAR:-./.squid-empty-secret}` fallback resolves to a tracked, always-
  present, empty file, the same pattern already used for
  `SQUID_WORKSPACE_DIR`/`.squid-empty`). **Do not** reintroduce `ARG
  HTTP_PROXY`/`build.args` for these — Docker's own docs warn that `ARG`
  values persist in `docker history`/image metadata even though never
  written to the image filesystem, which would leak a corporate proxy
  password baked into a shared image. `tests/security/test_static_hardening.sh`
  guards against this regressing.
- Both Dockerfiles also trust an optional `certs/*.crt` enterprise CA at
  build time, before their non-root `USER` switch — the only way to get CA
  trust without granting runtime root (see the point above).
- The `proxy-auth-entrypoint.sh` script's `px` invocation was verified
  against a live build on 2026-09-04: `px.ini`'s
  `proxy:{server,listen,port,gateway,allow,username}=` keys are correct,
  but `--config` needs `=` (`--config=/etc/px/px.ini`), not a space — px's
  flag parser only accepts `--flag=value` and silently falls back to its
  own default config search on a bare-space invocation, which crash-looped
  the `proxy-auth` container with "Could not find config file: /1". Fixed
  in `proxy-auth-entrypoint.sh`.
- **`.env` and NTLM `DOMAIN\username`**: confirmed broken by the same test
  run — `bin/cc-container` loads `.env` via bash `source` (see above), and
  bash strips an unescaped backslash in an unquoted assignment
  (`DOMAIN\username` becomes `DOMAINusername`). `.env.example`'s claim that
  "no URL-encoding needed" for the backslash is wrong for this loading
  mechanism; a literal single backslash must be written as `\\` in `.env`
  to survive `source`. Not yet fixed in `.env.example`/README — needs a
  decision on whether to fix the docs or change how `.env` is loaded.

## Runtime monitoring

Optional, off by default (`monitoring` Compose profile, `cc-container
--monitor`) — see `README.md` "Runtime monitoring (optional)" for the
user-facing explanation. Adds `security-monitor` (Falco, eBPF-based
syscall observation) watching `claude-code` **from the host kernel**,
entirely outside the container — this is a detection layer for behavior
the network allowlist can't see (e.g. exfiltration via an already-allowed
domain), not a replacement for it. Verified end-to-end against a live
build (Falco 0.39.2) on 2026-09-11 — rule matching, live stdout logging,
and desktop notification all confirmed working. Mechanics, for anyone
touching this code:

- **Container attribution matches on `user.name = claudecode`**, not
  `container.image.repository`/`container.name` (falco/claude-code-rules.yaml's
  `claude_code_container` macro). History: `container.image.repository`
  never populates without a `docker.sock` mount, which this repo
  deliberately doesn't add (see the security-critical note above) — every
  event showed `container_name=<NA>`. A first fix matched `user.uid =
  1000` instead (claude-code is the only *service* in this repo running
  as UID 1000) — confirmed false on a real host: a host user whose own
  UID also happens to be 1000 (a common default for the first non-root
  Linux account) running `docker compose build` matched the same macro,
  misattributing the build's own npm/apt activity as claude-code traffic.
  `user.name` disambiguates this correctly (Falco resolves the two
  differently, confirmed on a real host) since it matches the literal
  account name from `useradd -u 1000 claudecode` in the Dockerfile, not
  the numeric UID.
- Alert delivery has two independent gotchas, both fixed and confirmed
  working on a real host:
  - **stdout is block-buffered, not unbuffered, once it isn't a TTY**
    (always true under `docker logs`) — Falco's own status/init logging
    goes to stderr (always unbuffered by the C standard, hence always
    appeared live), but alerts go through `stdout_output`, which sat in
    glibc's stdio buffer for minutes until it filled or the process
    exited. `docker-compose.yml`'s `security-monitor.command` wraps the
    entrypoint in `stdbuf -oL -eL` to force line buffering. Falco's own
    `buffered_outputs: false` config key does *not* fix this — that
    controls Falco's internal output queue, not the underlying process's
    stdio buffering.
  - **`falco-notify.sh` needs `setpriv` to drop from root to `HOST_UID`**
    before calling `notify-send` — `security-monitor` runs as root (the
    one deliberate capability exception in this repo), but the host's
    D-Bus session bus belongs to a specific non-root user. D-Bus's
    `EXTERNAL` auth mechanism checks the connecting process's actual
    kernel peer-credential UID, not just whatever
    `DBUS_SESSION_BUS_ADDRESS` points at — a root `notify-send` opens the
    socket fine but gets the connection closed immediately after. Needs
    `HOST_UID` in `security-monitor`'s `environment:` (separate from its
    existing use in the D-Bus socket *path*) and `util-linux` installed in
    `Dockerfile.security-monitor` (for `setpriv`).
  - No external service, no network egress needed for any of this —
    `security-monitor` runs with `network_mode: none`. Desktop
    notifications only work with an active graphical Linux session (D-Bus
    session bus running) on the host; deliberate trade-off, not a bug, for
    a tool meant to run on a dev workstation.
  - **`SECURITY_MONITOR_NOTIFY`** (`.env`, see `.env.example`) toggles just
    the `notify-send` popup in `falco-notify.sh` — `stdout_output` keeps
    logging every alert either way. Deliberately wired only through
    `docker compose`'s own `.env` resolution
    (`docker-compose.yml`'s `security-monitor.environment`), never read
    from inside `claude-code`: the whole point of this sidecar is watching
    the sandboxed agent from outside it, so the toggle for its own alarm
    must stay somewhere that agent has no visibility into or control over
    (consistent with `claude-code` having no `docker.sock` and no network
    path to `security-monitor` to begin with).
- `falco/falco.yaml` schema drifted across three keys between whatever
  Falco version the doc-only draft assumed and the 0.39.2 actually
  pulled: `rules_file` → `rules_files` (plural; singular still works with
  a deprecation warning in 0.39.x, hard-fails in 0.40.0), top-level
  `outputs: {rate, max_burst}` (removed entirely, no replacement — distinct
  from the still-valid `syscall_event_drops.rate/max_burst`, which this
  repo doesn't set), and `metadata_download` (also removed; unrelated to
  and not needed given `network_mode: none`). All three are fixed in the
  current file; if bumping the `falcosecurity/falco-no-driver` base image
  tag later, re-check `schema validation: ok` in the startup log for all
  three files (`falco.yaml`, `falco_rules.yaml`, `claude-code-rules.yaml`)
  before trusting anything past that point.
- **Rule set** (`falco/claude-code-rules.yaml`) covers: unexpected shell
  spawn, the read-only Squid-override write attempt (see caveat below),
  outbound connection bypassing `egress-proxy`, a non-Claude read of the
  OAuth credentials file (relevant only when the optional
  `~/.claude`-reuse mount is active), privilege escalation attempts
  (`sudo`/`su`/`pkexec`/`doas`), shell-history tampering, a network tool
  executed with an npm/yarn/pnpm/bun ancestor (adapted from
  [falcosecurity/rules](https://github.com/falcosecurity/rules)'
  `falco-sandbox_rules.yaml`), reads of `/proc/*/environ` (adapted from the
  same repo's `falco-incubating_rules.yaml`), contact with the cloud
  metadata service (`169.254.169.254`, same source), and a process
  impersonating a trusted name (`claude`/`node`/`Bun`) via
  `prctl(PR_SET_NAME)`.
  - The Squid-override rule is suspected dead in practice: it fires on
    `open_write`, but the write attempt fails at the read-only mount
    itself (`EROFS`) before a file descriptor exists, and `open_write`
    likely requires a successful open. Confirmed no alert on a real host
    for a failing `touch` against that path; not yet fixed (would need a
    condition that doesn't depend on `open_write`'s success requirement).
  - Several rules exclude `proc.name`/`proc.pname in (claude, node)` (or
    the real runtime name, see below) as "this is claude-code itself, not
    an attacker" — this is spoofable, since `proc.name` is just the
    self-reported `comm` string (settable via `prctl(PR_SET_NAME)` or by
    naming a binary accordingly). Hardened where possible with
    `proc.exepath`/`proc.pexepath` instead (the kernel-resolved file
    actually backing the process, not spoofable by renaming): the real
    claude-code CLI is a **Bun-compiled single-file ELF executable** at
    `/home/claudecode/.npm-global/bin/claude` (confirmed on a real host —
    `file`/hexdump showed an ELF header; no separate `bun` binary exists
    anywhere on the image), and its actual process/thread name is `Bun`
    (and `Bun Pool N` for worker threads), not literally `claude` or
    `node`. An earlier attempt to harden this via
    `proc.is_exe_upper_layer=false` (same field the bundled "Executing
    binary not part of base image" rule uses) false-positived: claude-code
    itself turned out to be upper-layer on a real host (likely npm
    self-updated at container runtime rather than baked into the image at
    build time), so that field can't distinguish "legitimate but
    runtime-updated" from "foreign binary". `proc.exepath` doesn't have
    that problem. `proc.pexepath` for the "Unexpected shell" rule and the
    `prctl` impersonation rule (both added 2026-09-11) are **not yet
    confirmed by triggering them on a live host** — verified against
    Falco/libs source only (`sinsp_filtercheck_thread.cpp`,
    `driver/event_table.c`, `driver/flags_table.c`). See the "OPEN ITEMS"
    block at the top of `falco/claude-code-rules.yaml` for the current,
    maintained list of what's untested/unresolved per rule — kept there,
    not duplicated here, since it changes faster than this file does.
  - Known, deliberately unclosed blind spots (limits of syscall-based
    detection, not bugs): bash **builtins** (`history -c`, `unset
    HISTFILE` typed into an already-open shell) never `execve` anything,
    so Falco can't see them at all. `curl`/`wget` are deliberately absent
    from the npm-install network-tool list (upstream's own choice, to
    avoid flagging every normal install) even though they're the most
    likely real exfiltration tools. Exfiltration over an
    **already-allowlisted** domain via a normal-looking tool remains
    invisible to every rule here — that's the exact scenario this whole
    feature exists for, and it's still not solved. A reverse shell that
    never `execve`s a new binary (e.g. a script opening a raw socket
    in-process) won't trigger any `spawned_process`-based rule. The
    npm-install ancestor check only looks 5 levels up
    (`proc.aname[2..5]`).
- `Dockerfile.security-monitor`'s `apt-get install` also needs
  `util-linux` now (for `setpriv`, see above), in addition to
  `libnotify-bin`.
- `bin/cc-container` now has a `sync_security_monitor_sidecar()` function
  (mirrors the existing `sync_proxy_auth_sidecar()` pattern), called from
  `update-deps.sh` so `cc-container --update` keeps this sidecar's image
  in sync with local `Dockerfile.security-monitor`/`falco/*.yaml`/
  `falco-notify.sh` edits regardless of whether `--monitor` was passed to
  that particular invocation. Does a plain cached `docker compose build`
  (no-op when nothing changed, via Docker's own layer-checksum cache —
  confirmed stable across repeated no-op builds on a real host, same
  image ID each time) and only `--force-recreate`s a running
  `security-monitor` if the build actually produced a new image ID —
  otherwise every `--update` would restart Falco for no reason. `up -d`
  alone (what `cc-container --monitor` did before this) never rebuilds an
  already-existing image, cached or not — this was the actual reason
  `--monitor` kept silently running a stale image across several manual
  fix attempts.

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
./tests/run-tests.sh              # unit tests: fast, no Docker (bash -n, shellcheck if
                                    #   installed, render_upstream_proxy_conf()/
                                    #   derive_compose_project_name() logic, install.sh/
                                    #   uninstall.sh against a fakehome sandbox)
./tests/run-tests.sh --all        # + integration tests: needs Docker, builds/starts the
                                    #   real stack under its own throwaway Compose project
                                    #   and checks the security-critical invariants below
                                    #   (non-root, domain allowlist, network isolation)
                                    # + security tests: hardening/adversarial checks --
                                    #   no privileged/cap_add/docker.sock on any service,
                                    #   no network route out even bypassing egress-proxy
                                    #   deliberately, .squid-claudecode-docker stays
                                    #   read-only, Squid rejects non-80/443 CONNECT
./tests/run-tests.sh --security   # just the security tier on its own
```

See `tests/README.md` for the test layout. `tests/security/`'s checks are
static/network-only (see "Runtime monitoring" above) — nothing in the
automated suite actually starts `security-monitor` or verifies a Falco
alert fires; that needs a manual check on a real Docker host with an
active desktop session (`docker compose --profile monitoring up -d
security-monitor`, trigger something, watch for the notification).

For anything the suite doesn't cover, or to debug a failure by hand, the
same checks it automates are also useful standalone:

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
  `image: claude-code-proxy-auth:latest` on `proxy-auth`,
  `image: claude-code-security-monitor:latest` on `security-monitor`) in
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
