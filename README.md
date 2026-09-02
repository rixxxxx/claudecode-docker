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
  "Quickstart" below. When the `claude` session ends (`/exit`, Ctrl+D,
  Ctrl+C, or a crash), it asks whether to close the containers for this
  workspace (`docker compose down`); pressing Enter leaves them running.
- `claude-code`: runs as a non-root user (UID 1000) and has no direct
  route to the internet — the route simply doesn't exist at the Docker
  network level.
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
| `docker-compose.yml`   | Orchestrates `claude-code` + `egress-proxy`, defines networks   |
| `squid.conf`           | Domain allowlist for the egress proxy                          |
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
export HOST_WORKSPACE="$(pwd)"              # directory to mount as /workspace
export COMPOSE_PROJECT_NAME="cc-myproject"  # optional: omit to use Compose's default project
cd /path/to/this/repo                       # docker-compose.yml lives here
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
      - ${HOST_WORKSPACE:-.}:/workspace
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

**Note on multiple instances:** a named volume like `claude-config` above
is scoped to the Compose project, and each workspace now runs as its own
project (see "Multiple instances") — so every workspace would get its
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

Alternatively, run it via `cc-container --update` (add `--force` to skip the
"anything newer?" check and always rebuild), which runs the updater and then
starts the stack as usual:

```bash
cc-container --update
cc-container --update --force
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
4. If something is newer, it rebuilds `claude-code` and recreates the
   containers, then prints a before/after version report. `@anthropic-ai/claude-code`
   and Node are pinned via Dockerfile `ARG`s that `update-deps.sh` rewrites in
   place, so if a bump to either of those is the *only* thing that changed,
   the rebuild uses a plain `docker compose build --pull` — Docker's normal
   layer cache already reuses everything above that `ARG` (apt packages, the
   Node download), only re-running the affected layer onward. If anything
   *not* pinned in the Dockerfile changed instead (`gh`, `rtk`, the `ubuntu`
   base image, or `--force`), it falls back to a full
   `docker compose build --pull --no-cache`, since those RUN layers have no
   version in their command text for Docker to key the cache on, and only
   `--no-cache` forces them to re-check upstream.

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

Run via `cc-container --update`, it targets that specific workspace's
instance (recreating only its containers). Run standalone
(`bin/update-deps.sh` directly, without `HOST_WORKSPACE`/
`COMPOSE_PROJECT_NAME` set), it prints a note and falls back to Compose's
default project — the shared `claude-code:latest` image still gets
rebuilt correctly either way; other running instances just pick it up on
their next recreate rather than immediately.

Because every workspace shares the single `claude-code:latest` tag,
`docker ps` alone can't tell you whether a still-running container (from a
workspace nobody has recreated in a while) is behind the latest build.
`update-deps.sh` stamps each build with the `claude-code` version it
installed and the build timestamp as custom image labels (kept out of the
`org.opencontainers.image.*` namespace so they don't clobber the base
image's own `version`/`created` labels), so you can check without
shelling in:

```bash
docker ps --format 'table {{.Names}}\t{{.Label "dev.claudecode-docker.version"}}\t{{.Label "dev.claudecode-docker.build-date"}}'
```

## Extending the domain allowlist

There are two ways to add a domain, depending on scope:

**Tool-wide default** (applies to every workspace): add it to
`.squid-claudecode-docker/00-defaults.conf` in this repo:
```
acl allowed_domains dstdomain internal.registry.company.com
```

**Single workspace only**: create a `.squid-claudecode-docker/` folder in the
*target* project you run `cc-container` from (e.g.
`ottercache/.squid-claudecode-docker/extra.conf`), with the same
`acl allowed_domains dstdomain ...` line. `cc-container` picks it up
automatically via `$HOST_WORKSPACE/.squid-claudecode-docker` and merges it in
alongside this repo's defaults for that workspace's own `egress-proxy`
instance — other workspaces are unaffected. If the workspace has no
`.squid-claudecode-docker/` folder yet, `cc-container` creates an empty one
for you (as your own user, so it's writable) and the workspace just gets
the defaults until you add a `.conf` file to it. (The `-claudecode-docker`
suffix keeps this unambiguous in case the workspace ever has some other,
unrelated `.squid` folder of its own.)

Create or edit that `.squid-claudecode-docker/` folder from the host (or
another trusted process) *before* or *between* `cc-container` runs — it's
intentionally mounted read-only inside the `claude-code` container itself
(shadowing that one subpath of the otherwise read-write `/workspace`
mount), so a Claude Code session can see its own effective network policy
but can never widen it from inside the sandbox.

Either way, restart the proxy to pick up the change:

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
