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
| `squid.conf`           | Domain allowlist for the egress proxy                       |
| `entrypoint.sh`        | Container entrypoint (terminal setup, welcome banner)       |

## Security-critical files — change with care

`squid.conf` and the `networks:` section in `docker-compose.yml` form the
entire network isolation of the container. That's the actual purpose of
this repo, not incidental config.

- Only add new domains to `squid.conf` when actually needed, with a short
  comment explaining what they're for (see existing blocks: Auth/API,
  npm, GitHub, Node.js).
- Never propose wildcard grants (`.com`, entire CDNs without reason) or
  `allow all` — that undermines the allowlist model.
- Don't remove `internal: true` on the `internal` network in
  `docker-compose.yml` — that's the mechanism that removes the default
  internet route from the `claude-code` container.
- `claude-code` intentionally runs as non-root (UID 1000, see
  `Dockerfile`). Don't make changes that remove `USER claudecode` or add
  root privileges at runtime without explicit confirmation.

## Validating changes

There's no test suite. Validation happens by actually building/starting:

```bash
docker compose config          # check compose file syntax/interpolation
docker compose build           # build Dockerfile changes
docker compose up -d
docker compose exec egress-proxy squid -k parse   # check squid.conf syntax
docker compose logs egress-proxy | grep TCP_DENIED # see blocked connections
```

## Style

- `squid.conf`: comments group domains by purpose (block header, then
  `acl allowed_domains dstdomain ...` lines). Follow this pattern rather
  than introducing new structures.
- Keep documentation in English, consistent with `README.md`.
- Keep `entrypoint.sh` minimal (terminal setup + `exec "$@"`/shell) —
  don't put business logic there.
- Keep `bin/cc-container` minimal (resolve project root, export
  `HOST_WORKSPACE`/`COMPOSE_PROJECT_NAME` for the per-workspace bind mount
  and Compose project, optionally delegate to `update-deps.sh` on
  `--update`, `docker compose up -d`, `exec ... claude`) — it's the
  host-side wrapper, not a place for container-side logic (that belongs
  in `entrypoint.sh`).

## Multi-instance invariants — don't break these

Each workspace runs as its own Compose project (`COMPOSE_PROJECT_NAME`,
derived from `HOST_WORKSPACE` in `bin/cc-container`), giving every
instance its own containers, networks, and dedicated `egress-proxy`. This
depends on:

- No top-level `name:` key in `docker-compose.yml` — that would outrank
  the `COMPOSE_PROJECT_NAME` env var and collapse every workspace back
  onto one shared project.
- The `image: claude-code:latest` pin on the `claude-code` service in
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
