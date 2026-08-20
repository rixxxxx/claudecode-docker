# Claude Code – Isolated Docker Container

Standalone Docker setup for Claude Code (Anthropic CLI), without the
Microsoft Dev Container spec. Network isolation happens at the
Docker Compose level via an internal network + egress proxy, not via
iptables inside the container itself.

## Architecture

    [claude-code container] ---(internal network, no internet access)---> [egress-proxy]
                                                                                    |
                                                                          (external network)
                                                                                    |
                                                                                Internet

- `claude-code`: runs as a non-root user (UID 1000) and has no direct
  route to the internet — the route simply doesn't exist at the Docker
  network level.
- `egress-proxy`: Squid with a domain allowlist, the only permitted
  egress path. Filters by domain (SNI), not IP — robust against
  rotating CDN IPs.

## Files

| File                  | Purpose                                                        |
|-----------------------|-----------------------------------------------------------------|
| `Dockerfile`           | Builds the Claude Code image (Ubuntu 26.04, Node 24 via NodeSource, gh CLI) |
| `docker-compose.yml`   | Orchestrates `claude-code` + `egress-proxy`, defines networks   |
| `squid.conf`           | Domain allowlist for the egress proxy                          |
| `entrypoint.sh`        | Terminal setup + welcome banner, starts an interactive shell    |
| `.dockerignore`        | Excludes secrets, node_modules, .git etc. from the build context |
| `.gitignore`           | Excludes secrets, credentials, build artifacts from the repo   |

## Setup

1. Create a repo/project folder with these files
2. Build and start the container:

```bash
   docker compose up -d
```

3. Log into the container:

```bash
   docker compose exec claude-code bash
```

4. Start Claude Code and log in with your Pro/Max subscription:

```bash
   claude
   # then: /login
```

   The login link must be opened in the host browser (no browser inside
   the container). The OAuth callback goes through `claude.ai` — this
   domain is allowed in `squid.conf`.

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
