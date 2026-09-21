# Extending the domain allowlist

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

## Worked example: allowing an internal package registry for one workspace

Say Claude Code needs to `npm install` from a private registry,
`npm.internal.example.com`, but only for the `ottercache` project — you
don't want every workspace on every machine to trust it.

1. From the host, in the `ottercache` project directory (not this repo):

   ```bash
   mkdir -p .squid-claudecode-docker
   cat > .squid-claudecode-docker/internal-registry.conf <<'EOF'
   acl allowed_domains dstdomain npm.internal.example.com
   EOF
   ```

2. If `ottercache`'s stack is already running, restart just its proxy to
   pick up the change (run from inside `ottercache/`, so Compose resolves
   the right per-workspace project):

   ```bash
   docker compose restart egress-proxy
   ```

   If the stack isn't running yet, the next `cc-container` picks it up
   automatically — no restart needed.

3. Verify from inside the container:

   ```bash
   docker compose exec claude-code curl -sS -o /dev/null -w '%{http_code}\n' https://npm.internal.example.com
   ```

   A non-`000`/proxy-error status code means the domain is reachable
   through `egress-proxy`. To confirm it was actually the *new* rule that
   let it through (and not something already broader), check the proxy's
   own log:

   ```bash
   docker compose logs egress-proxy | grep npm.internal.example.com
   ```

   You should see `TCP_TUNNEL`/`TCP_MISS` (allowed) rather than
   `TCP_DENIED`. A domain that's still blocked (e.g. before the restart, or
   a typo in the ACL) shows up as `TCP_DENIED` — see the
   [README's Troubleshooting section](../README.md#troubleshooting) for
   that pattern.

4. To make this available to *every* workspace instead, move the same
   `acl allowed_domains dstdomain ...` line into
   `.squid-claudecode-docker/00-defaults.conf` **in this repo** and restart
   (or recreate) `egress-proxy` for each workspace that needs it.
