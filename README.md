# Claude Code – Isolated Docker Container

Standalone Docker setup for Claude Code (Anthropic CLI), without the
Microsoft Dev Container spec. Network isolation happens at the
Docker Compose level via an internal network + egress proxy, not via
iptables inside the container itself.

## Architecture

    [host]
    cc-container ---> docker compose up -d ---> [claude-code container] ---(internal network, no internet access)---> [egress-proxy]
                                                                                                                                |
                                                                                                                      (external network)
                                                                                                                                |
                                                                                                                            Internet
                        \
                         `-> docker compose exec claude-code claude   (drops you into the console)

- `cc-container`: the only host-side entry point. Wraps `docker compose up
  -d` + `docker compose exec claude-code claude` into one command — see
  [Setup](#setup) below. When the `claude` session ends (`/exit`, Ctrl+D,
  Ctrl+C, or a crash), it asks whether to close the containers for this
  workspace (`docker compose down`); pressing Enter leaves them running.
- `claude-code`: runs as a non-root user (UID 1000) and has no direct
  route to the internet — the route simply doesn't exist at the Docker
  network level. `npm install` inside it never runs package lifecycle
  scripts (`preinstall`/`install`/`postinstall`/`prepare`) by default —
  preventive against the classic npm supply-chain attack pattern
  (malicious `postinstall` scripts), not just Falco's after-the-fact
  detection of it (see [Runtime monitoring](#runtime-monitoring-optional)
  below). Breaks packages that need those scripts for functionality
  (native binaries, `puppeteer`'s Chromium download, `husky`) — uncomment
  `NPM_CONFIG_IGNORE_SCRIPTS=false` in `.env` (see
  [.env.example](.env.example)) to allow them again for a given workspace.
- `/workspace` inside the container is bind-mounted from the host
  directory `cc-container` was invoked from (via `HOST_WORKSPACE`, set to
  `$(pwd)`) — run it from the project you want Claude Code to work on,
  not necessarily from inside this repo.
- `egress-proxy`: Squid with a domain allowlist, the only permitted
  egress path. Filters by domain (SNI), not IP — robust against
  rotating CDN IPs.

### Multiple instances

`cc-container` derives a `COMPOSE_PROJECT_NAME` from the workspace path
(a sanitized directory-name slug plus a hash of the full path, e.g.
`cc-myproject-1234567890`) and prints it on startup. This means:

- Running `cc-container` from two different host workspaces starts two
  fully independent stacks — each gets its own `claude-code` container,
  its own **dedicated `egress-proxy`**, and its own isolated
  `internal`/`external` networks. Sessions don't interfere with each
  other.
- Running `cc-container` again from the *same* workspace reuses that
  workspace's existing containers instead of creating duplicates.
- The `claude-code` image itself (`claude-code:latest`) is still built
  and shared once across all instances — only the containers are
  per-workspace, not the image.
- To tear down one workspace's stack: answer "y" to the prompt `cc-container`
  shows when the `claude` session ends, or run `docker compose down` from
  that same workspace directory, or `docker compose -p <project-name> down`
  using the project name printed at startup (since containers no longer
  have a single fixed name to `docker stop` by).

`HTTP_PROXY=http://egress-proxy:3128` inside `claude-code` still works
unchanged across all of this: `egress-proxy` is the Compose *service*
name, resolved via Docker's embedded DNS *within each project's own
isolated network* — so it always resolves to that workspace's own
dedicated proxy, never to another instance's. (Squid's
`visible_hostname egress-proxy` in `squid.conf` is unrelated to this —
it's just a static label Squid puts in its own `Via` header/error pages,
identical across every instance, with no DNS or networking behavior
behind it.)

## Files

| File                  | Purpose                                                        |
|-----------------------|-----------------------------------------------------------------|
| `install.sh`           | One-time host setup: symlinks `cc-container` onto `PATH`       |
| `uninstall.sh`         | Reverses `install.sh`; optionally removes the built image      |
| `bin/cc-container`     | Host-side entry point: `docker compose up -d` + exec into `claude` |
| `bin/update-deps.sh`   | Host-side dependency updater: rebuild + report version changes |
| `Dockerfile`           | Builds the Claude Code image (Ubuntu 26.04, Node 24 via official tarball, gh CLI) |
| `Dockerfile.proxy-auth` | Builds the `proxy-auth` sidecar (NTLM/Kerberos corporate proxy relay, see [Enterprise proxy support](#enterprise-proxy-support)) |
| `proxy-auth-entrypoint.sh` | Entrypoint for `proxy-auth`, launches `px` against the rendered config |
| `Dockerfile.security-monitor` | Builds the optional `security-monitor` sidecar (Falco), see [Runtime monitoring](#runtime-monitoring-optional) |
| `falco/`               | Falco config + custom rules for `security-monitor`             |
| `falco-notify.sh`      | Turns a Falco alert into a native desktop notification, counts alerts toward the auto-stop threshold |
| `Dockerfile.stop-watcher` | Builds the optional `stop-watcher` sidecar, stops `claude-code` after repeated CRITICAL alerts, see [Runtime monitoring](#runtime-monitoring-optional) |
| `stop-watcher-entrypoint.sh` | Watches for the stop trigger and calls the Docker API over `docker.sock` |
| `docker-compose.yml`   | Orchestrates `claude-code` + `egress-proxy` (+ optional `proxy-auth`/`security-monitor`/`stop-watcher`), defines networks |
| `squid.conf`           | Domain allowlist for the egress proxy                          |
| `certs/`               | Optional enterprise root CA(s) (`*.crt`), trusted at image build time |
| `.env.example`         | Template for `.env` — API key, enterprise proxy settings       |
| `tests/`               | Test suite — see [Testing](#testing) below and [tests/README.md](tests/README.md) |
| `entrypoint.sh`        | Terminal setup + welcome banner, starts an interactive shell (container PID 1) |
| `.dockerignore`        | Excludes secrets, node_modules, .git etc. from the build context |
| `.gitignore`           | Excludes secrets, credentials, build artifacts from the repo   |

## Setup

1. Clone this repo.
2. One-time: put `cc-container` on your `PATH`:

```bash
./install.sh
```

This checks for Docker/Compose, symlinks `bin/cc-container` into
`~/.local/bin`, and adds `~/.local/bin` to `PATH` in your shell rc file if
it isn't there yet (idempotent — safe to re-run). To undo it later, run
`./uninstall.sh` (also offers to remove the built `claude-code:latest`
image).

Equivalent manual steps, if you'd rather not run a script:

```bash
mkdir -p ~/.local/bin
ln -s "$(pwd)/bin/cc-container" ~/.local/bin/cc-container
export PATH="$HOME/.local/bin:$PATH"   # add to ~/.bashrc / ~/.zshrc if missing
```

3. From the project directory you want Claude Code to work on, start the
   stack and enter the console:

```bash
cc-container
```

This mounts your current directory into the container as `/workspace`,
runs `docker compose up -d` (building the image on first run, reusing
the containers on later runs) and then execs into `claude` inside the
`claude-code` container — same effect as running steps below manually.

`cc-container` accepts three optional flags, combinable in one invocation:

| Flag | Effect | Details |
|------|--------|---------|
| `--update` | Rebuilds if a dependency moved; add `--force` to skip the "anything newer?" check | [docs/updating-dependencies.md](docs/updating-dependencies.md) |
| `--monitor` | Enables runtime security monitoring (Falco) | [docs/runtime-monitoring.md](docs/runtime-monitoring.md) |
| `--ssl-bump` | Enables path/query-level filtering, not just domain-level | [docs/tls-interception.md](docs/tls-interception.md) |

`--monitor` and `--ssl-bump` can go anywhere in the argument list;
`--update` must come first among the *remaining* arguments after those two
are stripped out (so `cc-container --monitor --update --force` works, but
`cc-container --force --update` doesn't — `--update` only ever looks at
what's left in position one). Anything else on the command line is
silently ignored rather than passed through to `claude` or erroring.

4. First time in, log in with your Pro/Max subscription:

```bash
   /login
```

   The login link must be opened in the host browser (no browser inside
   the container). The OAuth callback goes through `claude.ai` — this
   domain is allowed in `squid.conf`. For persistent login across restarts,
   see [Persistence](#persistence) below.

<details>
<summary>Manual steps (what <code>cc-container</code> does under the hood)</summary>

```bash
export HOST_WORKSPACE="$(pwd)"              # directory to mount as /workspace
export COMPOSE_PROJECT_NAME="cc-myproject"  # optional: omit to use Compose's default project
cd /path/to/this/repo                       # docker-compose.yml lives here
docker compose up -d
docker compose exec claude-code bash   # or: docker compose exec claude-code claude
```

</details>

## Persistence

By default, the OAuth login is lost whenever the `claude-code` container
itself is removed or recreated, since `/home/claudecode/.claude` isn't
mounted — including the automatic prompt `cc-container` shows every time
your `claude` session ends (`/exit`, Ctrl+D, Ctrl+C, or a crash; see
[Architecture](#architecture) above), not just a manually-typed
`docker compose down`:

| Event | Login survives? |
|-------|------------------|
| Leaving the container running (answering "N"/Enter at the prompt, or a plain `docker stop`) | Yes |
| Host machine reboot alone (container not removed — `restart: unless-stopped` even auto-starts it again) | Yes |
| Answering "y" at the prompt, or running `docker compose down` yourself | No |
| `cc-container --update` actually finding something newer (force-recreates the container the same way) | No |

For persistent login across the container-destroying cases above,
add this to `docker-compose.yml`. Note `~/.claude.json` (OAuth token,
`disabledMcpServers`, and other per-user/per-project state) is a separate
file next to `~/.claude/`, not inside it -- both need mounting, or login
and MCP-server toggles like disabling a connector still reset on every
`docker compose down`:

```yaml
services:
  claude-code:
    volumes:
      - ${HOST_WORKSPACE:-.}:/workspace
      - claude-config:/home/claudecode/.claude
      - claude-config-json:/home/claudecode/.claude.json

volumes:
  claude-config:
  claude-config-json:
```

Alternatively, to reuse login data from the host (if `claude login` was
already run there):

```yaml
    volumes:
      - ${HOME}/.claude:/home/claudecode/.claude
      - ${HOME}/.claude.json:/home/claudecode/.claude.json
```

The host `~/.claude.json` must already exist as a file before the first
`docker compose up` with this mount -- Docker creates a directory instead
at the target path if the host source doesn't exist yet, which breaks
Claude Code's own use of that path. `touch ~/.claude.json` first if
you've never run `claude` on the host.

**Note on multiple instances:** a named volume like `claude-config` above
is scoped to the Compose project, and each workspace now runs as its own
project (see [Multiple instances](#multiple-instances)) — so every workspace would get its
own separate login/config, requiring `/login` again in each. The host
bind-mount alternative (`${HOME}/.claude:/home/claudecode/.claude`) isn't
project-scoped and is shared across all workspaces automatically; use
that if you want one login for every instance.

## RTK (dev-command output compression)

The image installs [RTK](https://github.com/rtk-ai/rtk), a local CLI proxy
that compresses verbose command output (git, build tools, docker, etc.)
before it reaches Claude's context window. It runs entirely locally — no
outbound network access needed at runtime, so no `squid.conf` changes were
required. Setup happens at build time in `Dockerfile`:

```dockerfile
RUN curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh \
    && rtk init -g --auto-patch
```

`rtk init -g` registers a PreToolUse hook in Claude Code's **global**
config, which lives under `/home/claudecode/.claude`.

**Caveat with persistent login (see [Persistence](#persistence) above):** if you mount a
volume over `/home/claudecode/.claude` (either a named volume or your
host's `~/.claude`), it shadows the config baked into the image — including
the RTK hook. After the first `docker compose up` with such a mount, run
once inside the container:

```bash
rtk init -g --auto-patch
```

## Updating dependencies

`bin/update-deps.sh` (or `cc-container --update`) keeps the image current:
checks upstream sources, skips the rebuild if nothing's newer, and stamps
each build with version/build-date labels so `docker ps` can show you
what's actually running. See [docs/updating-dependencies.md](docs/updating-dependencies.md)
for the full mechanics.

## Extending the domain allowlist

Add a domain to `.squid-claudecode-docker/00-defaults.conf` (every
workspace) or to a `.squid-claudecode-docker/` folder in the *target*
project (that workspace only), then `docker compose restart egress-proxy`.
See [docs/domain-allowlist.md](docs/domain-allowlist.md) for the scoping
rules and a worked example (adding an internal package registry).

## Enterprise proxy support

Set `HTTP_PROXY`/`HTTPS_PROXY` (and `ENTERPRISE_PROXY_AUTH=ntlm`/`kerberos`
if needed) in `.env` to route `egress-proxy` through a corporate forward
proxy — used at both image build time and runtime. See
[docs/enterprise-proxy.md](docs/enterprise-proxy.md) for NTLM/Kerberos
setup, TLS-intercepting proxies, and known limitations.

## TLS interception (SSL Bump, optional)

Optional, off by default: `egress-proxy` can decrypt already-allowed-domain
HTTPS traffic so Squid rules can also filter on path/query, not just
domain (closing the gap where a secret could ride in the URL of an
otherwise-allowed request). See [docs/tls-interception.md](docs/tls-interception.md)
for setup (`bin/generate-bump-ca.sh` + `cc-container --ssl-bump`), what's
filtered by default, and a worked example of adding a new filter rule.

## Runtime monitoring (optional)

Optional, off by default (`cc-container --monitor`): an eBPF-based Falco
sidecar watches `claude-code` from the host kernel for behavior the domain
allowlist can't see (e.g. a compromised dependency reading `~/.ssh/id_rsa`
and exfiltrating it over an already-allowed domain) — desktop
notifications, an auto-stop after repeated CRITICAL alerts, and a test
suite that live-fire-verifies every rule. See
[docs/runtime-monitoring.md](docs/runtime-monitoring.md) for what it
watches for, how notifications/auto-stop work, known blind spots, and a
worked example of adding a custom detection rule.

## Testing

```bash
./tests/run-tests.sh                # unit tests only: fast, no Docker
./tests/run-tests.sh --integration  # integration tests only: needs Docker
./tests/run-tests.sh --security     # security tests only: needs Docker, probes
                                     #   hardening/bypass attempts
./tests/run-tests.sh --all          # all three tiers (flags are additive,
                                     #   e.g. --integration --security also works)
```

See [tests/README.md](tests/README.md) for what each tier covers.

## Troubleshooting

Find blocked connections in the proxy log:

```bash
docker compose logs egress-proxy | grep TCP_DENIED
```

Test DNS resolution inside the Claude Code container (no `nslookup`/`dig`
in this image -- use Python's resolver instead):

```bash
# Resolving the Compose service name should work -- Docker's embedded
# resolver (127.0.0.11) answers this locally, no forwarding involved:
docker compose exec claude-code python3 -c "import socket; print(socket.gethostbyname('egress-proxy'))"

# Resolving an external hostname directly is EXPECTED TO FAIL -- claude-code
# doesn't need it (Squid resolves target hostnames itself when proxying)
# and the `internal: true` network plus claude-code's `dns:` override (see
# docker-compose.yml) are specifically designed to make this fail with
# "Temporary failure in name resolution". A working real answer here would
# indicate the CVE-2024-29018 isolation-bypass gap that override closes,
# not a healthy config:
docker compose exec claude-code python3 -c "import socket; print(socket.gethostbyname('api.anthropic.com'))"   # should raise socket.gaierror
```

## Known limitations

- The firewall protects against exfiltration to unknown targets, not
  against misuse of the allowed domains themselves (e.g.
  `api.anthropic.com`).
- DNS resolution from inside `claude-code` is deliberately broken for
  external hostnames (only the `egress-proxy` Compose service name
  resolves, via Docker's embedded DNS) -- this is intentional isolation,
  not a bug, and closes a real vulnerability class (CVE-2024-29018 /
  GHSA-mq39-4gv4-mvpx) where an unpatched Docker Engine could otherwise
  resolve a container's DNS queries from the host's network namespace,
  bypassing `internal: true` entirely. See docker-compose.yml's
  claude-code `dns:` override comment and falco/claude-code-rules.yaml's
  OPEN ITEMS for the full writeup.
- When using `--dangerously-skip-permissions`, the risk remains that a
  malicious project could exfiltrate anything accessible in the
  container via an allowed domain. Only use with trusted repositories.
- New Anthropic domains (e.g. from feature updates) aren't detected
  automatically — `squid.conf` must be maintained manually.
- Stale per-workspace Docker projects aren't cleaned up automatically —
  if a workspace directory is later moved or deleted, its containers,
  networks, and (if configured) named volumes stick around until torn
  down manually with `docker compose -p <project-name> down`.
  `cc-container` only offers to close the containers for the workspace
  it was just run from (when the `claude` session ends); there's still no
  "list/close all instances" helper for workspaces you're not currently in.
- Running `cc-container --update` from two workspaces at the same time
  isn't guarded against — both would race to rebuild/retag the same
  shared `claude-code:latest` image. Harmless, but their before/after
  version reports can interleave; avoid updating from two terminals at
  once.

## Security model comparison

| Approach                          | Privileges in claude-code container | Robustness against CDN IP rotation |
|------------------------------------|---------------------------------------|--------------------------------------|
| iptables in container (discarded)  | root start, needs NET_ADMIN           | Low (IP-based)                       |
| Docker Compose network (current)   | non-root throughout                   | High (domain-based via SNI)          |
