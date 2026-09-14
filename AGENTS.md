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
| `falco-notify.sh`      | Turns a Falco alert into a native desktop notification via the host's D-Bus session bus; also counts CRITICAL/EMERGENCY alerts toward the auto-stop threshold |
| `Dockerfile.stop-watcher` | Builds the optional `stop-watcher` sidecar — see "Runtime monitoring" below |
| `stop-watcher-entrypoint.sh` | Polls for the trigger file `falco-notify.sh` writes, stops `claude-code` via `docker.sock` |
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
- `security-monitor` (see "Runtime monitoring" below) is **one deliberate
  exception** to "no privileged/root/extra capabilities" in this repo —
  eBPF-based syscall observation needs `cap_add`. This exception is scoped
  narrowly: only that one service, never started by default (`monitoring`
  Compose profile), and it grants `claude-code` itself nothing. Don't
  extend `cap_add`/`privileged` to any other service, and don't add
  capabilities to `security-monitor` beyond what Falco's modern eBPF
  driver actually needs. `tests/security/test_static_hardening.sh`
  enforces this — its checks exempt `security-monitor` specifically,
  nothing else.
- `stop-watcher` (see "Runtime monitoring" below) is the **other
  deliberate exception**, this time to "no `docker.sock` mount" — stopping
  a container needs the Docker API from somewhere. Scoped just as
  narrowly: only that one service, never started absent `--monitor` itself
  (`bin/cc-container`'s `main()` adds the `auto-stop` Compose profile
  automatically alongside `monitoring` unless `SECURITY_MONITOR_STOP_THRESHOLD=0`
  in `.env` — kept as its own Compose profile, not folded directly into
  `monitoring` in `docker-compose.yml`, so a raw `docker compose` call
  bypassing `cc-container` still needs it requested explicitly), no
  `cap_add`/`privileged` of its own, and it deliberately does **not**
  grant `docker.sock` to `security-monitor` itself — that service already
  runs with `cap_add`/`apparmor:unconfined` for eBPF, so adding
  `docker.sock` there too would let one Falco/eBPF compromise pivot into
  full host-Docker control instead of just this one container. Don't
  extend a `docker.sock` mount to any other service, including
  `security-monitor`. `tests/security/test_static_hardening.sh` enforces
  this — its checks exempt `stop-watcher` specifically, nothing else.

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
  (`DOMAIN\username` becomes `DOMAINusername`). Fixed via the docs route:
  `.env.example`'s comment for this setting now calls out the
  doubled-backslash requirement directly (`DOMAIN\\username`) right after
  the "no URL-encoding needed" note, instead of leaving that note
  misleading on its own.

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
  - **`SECURITY_MONITOR_NOTIFY_MIN_PRIORITY`** (`.env`, default `warning`,
    added 2026-09-14) gates the same popup on a minimum priority, checked
    in `falco-notify.sh` right after the `SECURITY_MONITOR_NOTIFY` on/off
    check above (same host-only `.env` resolution, same reasoning) and
    after the auto-stop counter, so auto-stop keeps counting
    CRITICAL/EMERGENCY regardless of this setting. Does not touch
    `falco/falco.yaml`'s own `priority: debug` threshold, which stays
    maximally permissive for `stdout_output`/`docker logs` — full audit
    trail always, only the popup is filtered. Priority-rank comparison
    logic covered by `tests/unit/test_falco_notify_priority_threshold.sh`
    (extracts `priority_rank()` from `falco-notify.sh` via `sed` since the
    script isn't sourceable as a whole -- reads stdin immediately, calls
    `notify-send`).
- **Auto-stop** (`stop-watcher`): stops `claude-code` automatically after
  **`SECURITY_MONITOR_STOP_THRESHOLD`** (`.env`, default 3)
  CRITICAL/EMERGENCY alerts attributed to it. `cc-container --monitor`
  starts `stop-watcher` alongside `security-monitor` automatically (adds
  the `auto-stop` Compose profile in addition to `monitoring`) — there is
  no separate `--auto-stop` flag. The only way to keep `stop-watcher` from
  starting at all while still using `--monitor` is
  `SECURITY_MONITOR_STOP_THRESHOLD=0` in `.env`, which `main()` checks
  before adding the profile (see "one deliberate exception" above).
  - `falco-notify.sh` does the counting (persisted in `falco-stop-signal`,
    a named volume shared with `stop-watcher`), **keyed by container id**
    — one `critical_count.<container_id>` file per offending container,
    guarded by a per-container-id `flock` against the race of two alerts
    for the same container firing close together (Falco spawns one
    `falco-notify.sh` process per alert, `keep_alive: false`). At the
    threshold for a given container id it resets that container's counter
    and writes `trigger.<container_id>`; it does **not** talk to
    `docker.sock` itself.
  - Per-container-id keying (not a single global counter) matters because
    Falco's eBPF view is the whole host kernel, not one Compose project
    (see intro above) — with more than one workspace running `claude-code`
    + `--monitor` at once, a single `security-monitor` instance can see
    CRITICAL alerts from every `claude-code` container on the host.
    Keying by `container.id` (parsed out of the alert's own
    `container=%container.id` field, present in every rule's `output:`
    template) means an unrelated workspace's alerts increment *that other
    container's* own counter, never this workspace's, and the eventual
    stop targets exactly the container id that crossed the threshold —
    not "whichever `claude-code` container happens to be `stop-watcher`'s
    own Compose sibling" (an earlier version of this design assumed that
    and got it wrong for the multi-workspace case).
  - Counting is additionally scoped to alerts whose message text contains
    the literal substring `claude-code` — every real rule in
    `falco/claude-code-rules.yaml` includes that in its `output:` template
    (the TEST-ONLY pipeline-sanity rule deliberately doesn't, so a manual
    pipeline test never burns down the stop counter). This is intentionally
    narrower than "any CRITICAL alert Falco produces": a bundled
    default-ruleset CRITICAL alert about a completely unrelated,
    non-`claude-code` container/process on the same host would otherwise
    count too.
  - `falco/claude-code-rules.yaml` has a second TEST-ONLY rule, `TEST -
    Falco auto-stop pipeline check`, that goes the other way on purpose:
    its output *does* include `claude-code`, specifically so the auto-stop
    path itself (counter → trigger file → `stop-watcher` actually stopping
    the container) has a harmless way to be exercised end to end, instead
    of needing to reproduce a real CRITICAL violation
    `SECURITY_MONITOR_STOP_THRESHOLD` times in a row. Trigger: `touch
    /tmp/falco-stop-test-trigger` inside `claude-code`, repeated
    `SECURITY_MONITOR_STOP_THRESHOLD` times (default 3) — the container
    genuinely stops after the last one. Only run this against a container
    you intend to have stopped.
  - `stop-watcher` (see the "one deliberate exception" note above for why
    this is a separate service, not folded into `security-monitor`) polls
    for `trigger.<container_id>` files and, for each one, first resolves
    its OWN `com.docker.compose.project` label via `docker.sock` (self id
    from `/etc/hostname` — Docker's default container hostname, which none
    of this repo's services override), then looks up the *target*
    container's `com.docker.compose.project`/`com.docker.compose.service`
    labels the same way. It only actually stops the container if both
    match (same project, `service=claude-code`) — otherwise it logs a
    refusal and drops the trigger file. This is the same-instance
    enforcement: without it, one workspace's `stop-watcher` (unrestricted
    `docker.sock` is inherently host-wide, not scoped to "its own"
    containers by anything Docker itself enforces) could end up stopping a
    *different* workspace's `claude-code` if its own `security-monitor`
    ever mis-attributed a foreign container's alerts into its own
    `falco-stop-signal` volume (see the counting note above — the trigger
    filename alone already names the right target, but nothing stopped a
    stop-watcher from acting on a trigger naming someone else's container
    before this check existed). Resolves its own project once at startup;
    if that lookup ever fails, the container refuses to start at all
    (fail closed — `restart: unless-stopped` keeps retrying) rather than
    run without being sure of its own scope.
  - **Confirmed live 2026-09-14** (`tests/security/test_auto_stop_pipeline.sh`):
    `container.id` does resolve correctly without a `docker.sock` mount in
    `security-monitor` (unlike `container.name`/`container.image.repository`,
    confirmed to need one), so `container_id` parsing in `falco-notify.sh`
    never hit its fail-closed empty-string branch in testing; and the
    `/etc/hostname`-as-self-id assumption in `stop-watcher-entrypoint.sh`
    resolves correctly too. Both the happy path (own container genuinely
    stopped after threshold) and the same-instance safety check (a second,
    unrelated throwaway project's `claude-code` container was made to
    alert; this instance's `security-monitor` observed it host-wide,
    wrote a trigger naming it, and `stop-watcher` correctly refused —
    confirmed the foreign container was still running afterward) were
    exercised live, not just the mechanically-fires-in-isolation case.
  - Bypassing `cc-container` with a raw `docker compose --profile
    monitoring --profile auto-stop up -d` always starts `stop-watcher`
    regardless of `SECURITY_MONITOR_STOP_THRESHOLD` — there, the variable
    only gates whether `falco-notify.sh` ever writes the trigger file, not
    whether the container runs. Only `cc-container`'s own flag handling
    reads it to decide whether to add the profile in the first place.
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
  `falco-sandbox_rules.yaml` -- defense-in-depth only as of 2026-09-14,
  since `NPM_CONFIG_IGNORE_SCRIPTS=true` (Dockerfile default) now prevents
  the underlying npm-lifecycle-script attack pattern structurally instead
  of just detecting it; see the rule's own comment in
  `falco/claude-code-rules.yaml` and `.env.example` for the per-workspace
  opt-out), reads of `/proc/*/environ` (adapted from the
  same repo's `falco-incubating_rules.yaml`), contact with the cloud
  metadata service (`169.254.169.254`, same source), and a process
  impersonating a trusted name (`claude`/`node`/`Bun`) via
  `prctl(PR_SET_NAME)`.
  - The Squid-override rule was dead in practice until fixed 2026-09-14:
    it used to fire on `open_write`, but the write attempt fails at the
    read-only mount itself (`EROFS`) before a file descriptor exists, and
    `open_write` requires `fd.num>=0` (a successful open) — confirmed via
    a throwaway DEBUG rule on a live host, which also disproved the
    initial theory that `fd.name` was the problem (it was correctly
    populated even on the failing exit event). Rewritten to match directly
    on the open-family syscall's exit event, write-intent flags, and
    `fd.name`, none of which require a successful fd. Verified live via
    `tests/security/test_falco_rules.sh`'s
    `test_squid_override_write_attempt_fires` (plus a read-regression
    guard so the write-intent-flags restriction doesn't false-positive on
    normal reads of this deliberately-readable path).
  - Several rules exclude `proc.name`/`proc.pname in (claude, node)` (or
    the real runtime name, see below) as "this is claude-code itself, not
    an attacker" — this is spoofable, since `proc.name` is just the
    self-reported `comm` string (settable via `prctl(PR_SET_NAME)` or by
    naming a binary accordingly). Hardened where possible with
    `proc.exepath`/`proc.pexepath` instead (the kernel-resolved file
    actually backing the process, not spoofable by renaming): the real
    claude-code CLI is a **Bun-compiled single-file ELF executable** at
    `/home/claudecode/.npm-global/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe`
    (confirmed on a real host — `file`/hexdump showed an ELF header; no
    separate `bun` binary exists anywhere on the image; this is the
    canonical resolved path, not the `/home/claudecode/.npm-global/bin/claude`
    npm shim/symlink that an earlier version of this doc and these rules
    both wrongly used), and its actual process/thread name is `Bun` (and
    `Bun Pool N` for worker threads), not literally `claude` or `node`. An
    earlier attempt to harden this via `proc.is_exe_upper_layer=false`
    (same field the bundled "Executing binary not part of base image" rule
    uses) false-positived: claude-code itself turned out to be
    upper-layer on a real host (likely npm self-updated at container
    runtime rather than baked into the image at build time), so that
    field can't distinguish "legitimate but runtime-updated" from
    "foreign binary". `proc.exepath` doesn't have that problem.
    `proc.pexepath` for the "Unexpected shell" rule (added 2026-09-11) is
    now confirmed both directions on a live host as of 2026-09-14: a
    `docker compose exec` shell is correctly detected (true positive), and
    a real, assistant-issued Bash tool call is correctly excluded (no
    false positive) — see `falco/claude-code-rules.yaml`'s OPEN ITEMS for
    the dated writeup. The `prctl` impersonation rule (also added
    2026-09-11) is now confirmed live too, as of 2026-09-14: `docker
    compose exec claude-code python3 -c "import ctypes;
    ctypes.CDLL('libc.so.6').prctl(15, b'Bun', 0, 0, 0)"` (PR_SET_NAME=15,
    a process that isn't the real claude.exe renaming itself to "Bun")
    fired the CRITICAL alert as designed. Now also covered by an
    automated test (`test_prctl_impersonation_fires` in
    `tests/security/test_falco_rules.sh`) -- every rule in this file has
    at least one live-fired confirmation as of 2026-09-14. See the "OPEN ITEMS"
    block at the top of `falco/claude-code-rules.yaml` for the current,
    maintained list of what's untested/unresolved per rule — kept there,
    not duplicated here, since it changes faster than this file does.
  - **Falco reports only ONE alert per matching event here, not all
    matching rules** — confirmed live 2026-09-13 (0.39.2) via a controlled
    reordering experiment: whichever rule matches an event FIRST in load
    order (bundled `falco_rules.yaml` first, then `claude-code-rules.yaml`
    top-to-bottom) wins; any other rule whose condition is also true for
    that same event stays completely silent, regardless of its own
    priority or specificity. Discovered because "Shell history disabling
    command" was being silently swallowed by "Unexpected shell" for every
    matching event until moved earlier in the file. See the "OPEN ITEMS"
    block for the full writeup and the check already done for other
    overlapping-condition pairs in this file — matters for any new rule
    added whose condition could also satisfy an earlier rule's on the same
    `evt.type`.
  - **Manual procedure for "Unexpected shell"'s open false-positive
    question** (does a *real* assistant-issued Bash tool call get excluded
    by the `proc.pexepath` check, or does something — e.g. RTK's
    PreToolUse hook, see `RTK.md`/README "RTK" — sit in between such that
    it has a different parent chain and false-positives?). Not scriptable:
    `tests/security/test_falco_rules.sh` only exercises the true-positive
    direction via `docker compose exec`, which has a different parent
    chain (containerd-shim) than an assistant-issued command. To check the
    false-positive direction by hand:
    1. `cc-container --monitor` from the repo root.
    2. In a second host terminal, from the same workspace directory:
       `docker compose logs -f security-monitor`. Note the current
       position as a checkpoint.
    3. In the live Claude Code chat itself (not a raw shell), ask the
       assistant to run something trivial via its Bash tool, e.g. "Use the
       Bash tool to run `echo falco-real-bash-tool-check`." This has to go
       through the assistant's own agentic tool-call path (and any
       `PreToolUse` hook) — a scripted `docker compose exec` can't reach
       this code path.
    4. Watch the log tail for ~15 seconds after the tool call completes.
       No `Shell spawned in claude-code` line → the exclusion holds for
       real Bash-tool calls too. The line appears → confirmed
       false-positive on ordinary Bash-tool use (record as a bug, don't
       fix inline as part of verification).
    5. To capture the actual `proc.pexepath`/`proc.pname` value either way
       (a holding exclusion means the real rule produces no output to read
       values from): temporarily add a throwaway, non-excluding debug rule
       to `falco/claude-code-rules.yaml` (never commit it) —
       `condition: spawned_process and claude_code_container and proc.name
       in (bash, sh, dash, zsh, ash)`, `output: DEBUG shell spawn
       pexepath=%proc.pexepath pname=%proc.pname cmdline=%proc.cmdline`,
       `priority: DEBUG` (visible since `falco.yaml`'s `priority: debug`
       threshold). `docker compose --profile monitoring up -d
       --force-recreate security-monitor`, repeat step 3, read the value,
       remove the debug rule, and `--force-recreate` again to restore the
       real ruleset.
    6. Record the dated outcome (and, if it false-positives, the observed
       `pexepath` value) in `falco/claude-code-rules.yaml`'s OPEN ITEMS
       header.
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
- **Startup ordering**: `claude-code` has an optional `depends_on` on both
  `security-monitor` and `stop-watcher` (`condition: service_healthy`,
  `required: false`). `required: false` is what makes this safe when the
  `monitoring`/`auto-stop` profiles aren't active at all — without it,
  Compose would refuse to resolve the file at all ("service claude-code
  depends on undefined service ...") on a plain `docker compose up -d` or
  `cc-container` without `--monitor`, since the two sidecars wouldn't
  exist as services in that run. When the profiles ARE active,
  `claude-code` genuinely waits for both to report healthy first, same as
  its existing `egress-proxy` dependency. Both sidecars needed a
  `healthcheck:` added for this to have something to wait on
  (`security-monitor`: `pgrep -x falco`, since `network_mode: none` and no
  `docker.sock` there rule out an HTTP probe or reading its own container
  logs — this only proves the process hasn't died, not that the eBPF probe
  attached or rules loaded cleanly; `stop-watcher`: `curl` against
  `docker.sock`'s own `/_ping`, the one thing that service actually
  depends on). `security-monitor`'s `pgrep` needs `procps` added to its
  `apt-get install` list.
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

See `tests/README.md` for the test layout. Most of `tests/security/` is
static/network-only, but `test_falco_rules.sh` does start `security-monitor`
under the `monitoring` profile and verifies six `falco/claude-code-rules.yaml`
rules fire correctly via `docker compose logs security-monitor` (see
`tests/README.md` for exactly which). Still not automated: the
desktop-notification/D-Bus half of the pipeline (needs an active graphical
host session — `docker compose --profile monitoring up -d security-monitor`,
trigger something, watch for the notification) and "Unexpected shell"'s
false-positive direction for a *real* assistant-issued Bash tool call, which
needs a live interactive session — see "Runtime monitoring" above for that
manual procedure.

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
