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
  "Quickstart" below.
- `claude-code`: runs as a non-root user (UID 1000) and has no direct
  route to the internet — the route simply doesn't exist at the Docker
  network level.
- `egress-proxy`: Squid with a domain allowlist, the only permitted
  egress path. Filters by domain (SNI), not IP — robust against
  rotating CDN IPs.

## Files

| File                  | Purpose                                                        |
|-----------------------|-----------------------------------------------------------------|
| `bin/cc-container`     | Host-side entry point: `docker compose up -d` + exec into `claude` |
| `bin/update-deps.sh`   | Host-side dependency updater: rebuild + report version changes |
| `Dockerfile`           | Builds the Claude Code image (Ubuntu 26.04, Node 24 via official tarball, gh CLI) |
| `docker-compose.yml`   | Orchestrates `claude-code` + `egress-proxy`, defines networks   |
| `squid.conf`           | Domain allowlist for the egress proxy                          |
| `entrypoint.sh`        | Terminal setup + welcome banner, starts an interactive shell (container PID 1) |
| `.dockerignore`        | Excludes secrets, node_modules, .git etc. from the build context |
| `.gitignore`           | Excludes secrets, credentials, build artifacts from the repo   |

## Setup

1. Clone this repo.
2. One-time: put `cc-container` on your `PATH`:

```bash
mkdir -p ~/.local/bin
ln -s "$(pwd)/bin/cc-container" ~/.local/bin/cc-container
export PATH="$HOME/.local/bin:$PATH"   # add to ~/.bashrc / ~/.zshrc if missing
```

3. Start the stack and enter the console:

```bash
cc-container
```

This runs `docker compose up -d` (building the image on first run, reusing
the containers on later runs) and then execs into `claude` inside the
`claude-code` container — same effect as running steps below manually.

4. First time in, log in with your Pro/Max subscription:

```bash
   /login
```

   The login link must be opened in the host browser (no browser inside
   the container). The OAuth callback goes through `claude.ai` — this
   domain is allowed in `squid.conf`. For persistent login across restarts,
   see "Persistence" below.

<details>
<summary>Manual steps (what <code>cc-container</code> does under the hood)</summary>

```bash
docker compose up -d
docker compose exec claude-code bash   # or: docker compose exec claude-code claude
```

</details>

## Persistence

By default, the OAuth login is lost on every `docker compose down`,
since `/home/claudecode/.claude` isn't mounted. For persistent login,
add this to `docker-compose.yml`:

```yaml
services:
  claude-code:
    volumes:
      - .:/workspace
      - claude-config:/home/claudecode/.claude

volumes:
  claude-config:
```

Alternatively, to reuse login data from the host (if `claude login` was
already run there):

```yaml
    volumes:
      - ${HOME}/.claude:/home/claudecode/.claude
```

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

**Caveat with persistent login (see "Persistence" above):** if you mount a
volume over `/home/claudecode/.claude` (either a named volume or your
host's `~/.claude`), it shadows the config baked into the image — including
the RTK hook. After the first `docker compose up` with such a mount, run
once inside the container:

```bash
rtk init -g --auto-patch
```

## Updating dependencies

`bin/update-deps.sh` is a host-side script (run it on your host, not inside
the container) that keeps the image current:

```bash
bin/update-deps.sh
```

It automatically, without prompting:

1. Snapshots the currently running tool versions (Ubuntu, Node, gh,
   `claude-code`, rtk, python3).
2. Checks upstream sources (the `ubuntu` base image layer, the
   `egress-proxy` image, the latest `gh` release, the latest Node patch
   within the pinned major, the latest `@anthropic-ai/claude-code` on npm,
   and the latest `rtk` release) against what's currently installed.
3. If nothing upstream is newer, it skips the rebuild entirely (just runs
   `docker compose up -d` to make sure containers are up) and exits —
   no wasted `--no-cache` rebuild, no disruption to a running `claude`
   session. Pass `--force` to skip this check and rebuild unconditionally.
4. If something is newer, it rebuilds `claude-code` with
   `docker compose build --pull --no-cache` (picking up the latest apt
   packages, `gh`, Node patch release, `@anthropic-ai/claude-code` from
   npm, and `rtk`), recreates the containers, and prints a before/after
   version report.

Available **major** upgrades (a newer Ubuntu release, a newer Node major
version) are only reported, never applied automatically — bumping
`FROM ubuntu:26.04` or the major in `ARG NODE_VERSION` in `Dockerfile` is a
deliberate manual edit, since it carries real breaking-change risk. Patch/minor
Node bumps within the pinned major *are* applied automatically: the script
rewrites `ARG NODE_VERSION` in-place before the `--no-cache` rebuild, since
the tarball install is pinned to an exact version rather than NodeSource's
rolling per-major repo.

Since builds/pulls go through the host Docker daemon, not through the
`claude-code` container's network, this doesn't touch `squid.conf` or the
network isolation. There's no scheduled/automatic run (no cron in the
container, see "Known limitations") — call it manually when you want fresh
dependencies. If it does find an update, it terminates any interactive
`claude` session inside the container (`--force-recreate`), so run it from
the host, not from within a `cc-container` session.

## Extending the domain allowlist

Add a new domain (e.g. a private registry) to `squid.conf`:
acl allowed_domains dstdomain internal.registry.company.com


Then restart the proxy:

```bash
docker compose restart egress-proxy
```

## Troubleshooting

Find blocked connections in the proxy log:

```bash
docker compose logs egress-proxy | grep TCP_DENIED
```

Test DNS resolution inside the Claude Code container:

```bash
docker compose exec claude-code nslookup api.anthropic.com
```

## Known limitations

- The firewall protects against exfiltration to unknown targets, not
  against misuse of the allowed domains themselves (e.g.
  `api.anthropic.com`).
- When using `--dangerously-skip-permissions`, the risk remains that a
  malicious project could exfiltrate anything accessible in the
  container via an allowed domain. Only use with trusted repositories.
- New Anthropic domains (e.g. from feature updates) aren't detected
  automatically — `squid.conf` must be maintained manually.

## Security model comparison

| Approach                          | Privileges in claude-code container | Robustness against CDN IP rotation |
|------------------------------------|---------------------------------------|--------------------------------------|
| iptables in container (discarded)  | root start, needs NET_ADMIN           | Low (IP-based)                       |
| Docker Compose network (current)   | non-root throughout                   | High (domain-based via SNI)          |
