# Updating dependencies

`bin/update-deps.sh` is a host-side script (run it on your host, not inside
the container) that keeps the image current:

```bash
bin/update-deps.sh
```

Alternatively, run it via `cc-container --update` (add `--force`, or its
short form `-f`, to skip the "anything newer?" check and always rebuild),
which runs the updater and then starts the stack as usual:

```bash
cc-container --update
cc-container --update --force
cc-container --update -f            # same as --force
```

Any other argument is rejected outright (`bin/update-deps.sh` exits 1 with a
usage message) — unlike `cc-container` itself, which silently ignores
arguments it doesn't recognize (see the README's "Setup" section).

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

It also keeps the optional `security-monitor` (Falco) sidecar's image in
sync with any local edits to `Dockerfile.security-monitor`/`falco/*.yaml`/
`falco-notify.sh`, regardless of whether `--monitor` is passed to that
particular invocation — a plain cached rebuild (no-op if nothing changed),
only restarting it if the image actually changed. See
[runtime-monitoring.md](runtime-monitoring.md).

Since builds/pulls go through the host Docker daemon, not through the
`claude-code` container's network, this doesn't touch `squid.conf` or the
network isolation. There's no scheduled/automatic run (no cron in the
container, see the README's "Known limitations") — call it manually when you
want fresh dependencies. If it does find an update, it terminates any
interactive `claude` session inside the container (`--force-recreate`), so
run it from the host, not from within a `cc-container` session.

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
