# Runtime monitoring (optional)

The domain allowlist (`egress-proxy`) stops `claude-code` from reaching
anywhere unexpected, but it can't see what happens *inside* the container
— e.g. a compromised dependency reading `~/.ssh/id_rsa` and exfiltrating
it over an already-allowed domain would sail straight through. For that,
this repo has an optional runtime security monitor based on
[Falco](https://falco.org) (eBPF-based syscall observation), watching
`claude-code` from the host kernel — not by giving `claude-code` itself
any extra privileges, but as a completely separate, off-by-default sidecar.

Enable it per session with:

```bash
cc-container --monitor          # combine with --update if you also want that
```

or directly via `docker compose --profile monitoring up -d
security-monitor` -- though that bypasses the auto-rebuild described below,
so prefer `cc-container --monitor` unless you have a specific reason not to.

Verified end-to-end against a live build — rule matching, live log
output, and desktop notification all confirmed working; see `AGENTS.md`
"Runtime monitoring" for the verification history across Falco upgrades.

`cc-container --monitor` (with or without `--update`) always rebuilds this
sidecar's image first (cached, so a no-op when nothing changed) before
starting it, picking up local `Dockerfile.security-monitor`/`falco/*.yaml`/
`falco-notify.sh` edits automatically. This matters because its image tag
is fixed rather than per-session, so a plain `docker compose ... up -d`
would otherwise happily keep running whatever was built last, silently
ignoring newer local edits -- confirmed live 2026-09-16 as the cause of a
new rule's own test failing with a completely empty log.

When `--monitor` is used, `claude-code` waits for `security-monitor` (and
`stop-watcher`, its auto-stop companion — see below) to actually report
healthy before it starts, so monitoring is already watching from the
first syscall `claude-code` makes, not started in a race against it. This
adds a few seconds to startup; without `--monitor`, it has no effect at
all.

**What it watches for** (see `falco/claude-code-rules.yaml`, plus Falco's
own bundled default ruleset):
- An unexpected interactive shell spawned inside `claude-code` (typical of
  a compromised `postinstall` hook or an attempted reverse shell).
- A write attempt against the read-only `.squid-claudecode-docker` mount
  (an attempt to widen the sandbox's own network policy from inside) —
  note: suspected to never actually fire in practice, see "Known blind
  spots" below.
- An outbound connection attempt from `claude-code` to anything other than
  `egress-proxy` (shouldn't be able to succeed given the network topology,
  but the attempt itself is worth knowing about), including specifically
  the cloud instance metadata service (`169.254.169.254`) used by
  AWS/GCP/Azure to serve credentials.
- A non-Claude process reading claude-code's OAuth credentials file —
  relevant if you've enabled the optional host-credential-reuse mount
  (see the README's "Setup" section).
- A privilege escalation attempt (`sudo`/`su`/`pkexec`/`doas`) —
  `claude-code` always runs as a non-root user and never needs these.
- Shell history being deleted or cleared (`history -c` and similar) —
  classic cover-your-tracks behavior.
- A network tool (`nc`, `socat`, `tcpdump`, ...) launched with an
  npm/yarn/pnpm/bun install somewhere in its ancestry — the classic
  npm supply-chain attack pattern (malicious `postinstall` scripts).
  Defense-in-depth only as of 2026-09-14: the primary defense is
  `NPM_CONFIG_IGNORE_SCRIPTS=true` (Dockerfile default, see `.env.example`
  to opt out per workspace) — npm lifecycle scripts don't run at all by
  default, so there's usually nothing here for this rule to catch.
- A process reading another process's environment variables via
  `/proc/*/environ` (`ANTHROPIC_API_KEY` and other secrets are passed in
  as container environment variables).
- A process trying to impersonate `claude-code` itself by renaming itself
  (`prctl(PR_SET_NAME)`) to blend in with the exclusions above.

**How you're notified:** natively, via your desktop's own notification
system — `security-monitor` bind-mounts your host's D-Bus session bus and
calls `notify-send` on each alert, so it shows up as a normal OS
notification (tested against Linux Mint/Cinnamon; works the same way on
GNOME/KDE/XFCE/MATE, since it's the standard freedesktop.org notification
spec). No external service, no account, no second device to configure —
but it does mean this only works while you have an active graphical
session on the machine running Docker; it won't do anything useful on a
headless server.

Set `SECURITY_MONITOR_NOTIFY=false` in `.env` to turn the popup off
without losing anything else — alerts keep landing in `docker logs
security-monitor` (`stdout_output`) regardless. Deliberately a `.env`-only
setting, read by `docker compose` on the host, not something the
`claude-code` container (or the agent running inside it) can see or
change — it can't silence its own alarm. See `.env.example`.

For finer control than all-or-nothing, `SECURITY_MONITOR_NOTIFY_MIN_PRIORITY`
(default: `warning`) sets a minimum priority for the popup specifically —
`informational`/`notice`/`debug` alerts (mostly noise from Falco's bundled
default ruleset; this repo's own rules in `falco/claude-code-rules.yaml`
are already `warning`/`critical` only) no longer pop up by default. Same
`docker logs`-always-shows-everything guarantee as above — this only
affects the popup. Lower it (e.g. to `informational`) to see everything
again. See `.env.example`.

**Automatic stop on repeated CRITICAL alerts:** `cc-container --monitor`
starts a second, intentionally tiny sidecar, `stop-watcher` (no eBPF, no
extra Linux capabilities), alongside `security-monitor` automatically —
it stops `claude-code` once `SECURITY_MONITOR_STOP_THRESHOLD` (default 3)
CRITICAL/EMERGENCY alerts have fired **for that same container**. It's
kept as a separate sidecar from `security-monitor` itself because it
needs `docker.sock` to stop a container, and that access is deliberately
not given to the same service that already runs Falco (see "Trade-offs"
below).

If you run more than one workspace at once with `--monitor`, this is
counted per `claude-code` container, not globally — `security-monitor`
watches the whole host kernel (see intro above), so without this it could
otherwise stop one workspace's `claude-code` over alerts that actually
came from a different workspace's. `stop-watcher` also double-checks over
`docker.sock` that a container it's about to stop actually belongs to its
own workspace (same Compose project) before acting — so even if one
workspace's `security-monitor` ends up counting another workspace's
alerts, only that *other* workspace's own `stop-watcher` will ever
actually stop it, never this one. See `AGENTS.md` "Runtime monitoring"
for the mechanics.

To turn this off (keep alerting, drop the auto-stop), set in `.env`:

```bash
SECURITY_MONITOR_STOP_THRESHOLD=0
```

`cc-container --monitor` then skips starting `stop-watcher` entirely, so
no `docker.sock`-bearing container runs at all — not just "counts alerts
but never acts". (A raw `docker compose --profile monitoring --profile
auto-stop up -d`, bypassing `cc-container`, always starts `stop-watcher`
regardless of this setting; there it only gates whether the trigger ever
fires. Going through `cc-container` is the supported path.)

Only alerts from this repo's own `claude-code`-scoped rules
(`falco/claude-code-rules.yaml`) count toward the threshold — not every
CRITICAL alert Falco produces host-wide (see `AGENTS.md` "Runtime
monitoring" for why that distinction matters). Once stopped,
`claude-code` stays stopped (`restart: unless-stopped` doesn't restart a
manually-stopped container) — start it again the normal way
(`cc-container`) when you're ready to investigate.

**Testing this without waiting for a real violation:** `falco/claude-code-rules.yaml`
includes a harmless `TEST - Falco auto-stop pipeline check` rule for
exactly this. Run, inside the `claude-code` container,
`SECURITY_MONITOR_STOP_THRESHOLD` times in a row (default 3):

```bash
touch /tmp/falco-stop-test-trigger
```

Each run logs a CRITICAL "TEST ALERT" in `docker compose logs -f
security-monitor`; after the last one, `claude-code` genuinely stops —
only run this against a container you're fine losing. This is separate
from the also-included `TEST - Falco pipeline sanity check` rule
(`touch /tmp/falco-pipeline-test`), which checks that alerts reach you at
all but is deliberately excluded from the auto-stop count.

For verifying that individual detection rules (not just the pipeline
itself) actually fire, `tests/security/test_falco_rules.sh` automates this
for the rules in `falco/claude-code-rules.yaml` via `./run-tests.sh
--security`, and `tests/security/test_auto_stop_pipeline.sh` covers the
auto-stop path itself end-to-end, including the cross-project safety
boundary. Every rule in `falco/claude-code-rules.yaml` has been
live-fire-verified at least once — automated where scriptable, manually
where it needs a real interactive session (e.g. confirming "Unexpected
shell"'s `proc.pexepath` hardening doesn't false-positive on a genuine,
assistant-issued Bash tool call); see `AGENTS.md` "Runtime monitoring" for
that manual procedure and the full verification history.

**Trade-offs, on purpose:**
- `security-monitor` is the one service in this repo that runs with
  extra Linux capabilities (`cap_add`, needed for Falco's eBPF driver) —
  scoped to only that one, never-on-by-default service; `claude-code`
  itself gets nothing extra from this (see `AGENTS.md` "Runtime
  monitoring").
- No `docker.sock` mount in `security-monitor` itself, on purpose (even
  read-only, that's effectively root-equivalent host access) — container
  attribution relies on Falco's own `/proc`-based enrichment instead,
  which is coarser. The one place `docker.sock` does exist in this repo is
  `stop-watcher` (see "Automatic stop" above), a separate, minimal,
  never-on-by-default service kept apart from `security-monitor` for
  exactly this reason — see `AGENTS.md` "Runtime monitoring".
- This is a detection layer, not prevention — Falco doesn't block
  anything, it only alerts (optionally followed by a stop once a
  threshold is hit, see above). The domain allowlist remains the primary
  enforcement mechanism.

**Known blind spots** (limits of syscall-based detection, not bugs to fix):
- Bash **builtins** (`history -c`, `unset HISTFILE` typed into an
  already-open shell) never execute a new process, so Falco can't see
  them at all — only a `history -c` passed to a *new* shell invocation is
  caught.
- `curl`/`wget` are deliberately not treated as suspicious during an npm
  install (too noisy — normal installs use them too), even though they're
  the most likely real exfiltration tools.
- Exfiltration over a domain that's already on the allowlist, using a
  normal-looking tool, remains invisible to every rule here. That's the
  exact scenario this whole feature exists for (see the intro above) —
  runtime monitoring narrows this gap, it doesn't close it.
- A reverse shell that never executes a new binary (e.g. a script opening
  a raw socket from within an already-running process) won't trigger any
  of the shell/process-based rules.

## Worked example: adding a custom Falco rule

Say you want to catch `curl`/`wget` being used to *send* data (`-d`,
`--data`, `--upload-file`, `-T`) from inside `claude-code`, rather than
just fetch it — a common data-exfiltration shape not covered by any
existing rule.

1. Add a new rule to `falco/claude-code-rules.yaml`, following the shape
   of the existing rules (scoped via the `claude_code_container` macro,
   excluding claude-code's own processes the same way other rules do):

   ```yaml
   - rule: Outbound data upload via curl or wget in claude-code
     desc: >
       curl or wget was invoked with a flag that sends a request body
       (-d/--data/--upload-file/-T) inside claude-code. Not inherently
       malicious, but combined with the domain allowlist this narrows
       where a compromised dependency could exfiltrate data to.
     condition: >
       spawned_process
       and claude_code_container
       and proc.name in (curl, wget)
       and proc.cmdline contains " -d "
       or proc.cmdline contains "--data"
       or proc.cmdline contains "--upload-file"
       or proc.cmdline contains " -T "
     output: >
       Outbound data upload via curl/wget in claude-code
       (command=%proc.cmdline parent=%proc.pname user=%user.name container=%container.id)
     priority: WARNING
     tags: [claude-code, exfiltration]
   ```

   Mind operator precedence in the `condition` — group the `or` branch so
   it doesn't accidentally escape the `claude_code_container` scoping, e.g.
   wrap the flag checks in parentheses:
   `and (proc.cmdline contains "-d " or proc.cmdline contains "--data" or ...)`.

2. **Live-verify it before trusting it**, using this repo's own
   established workflow (see `AGENTS.md` for the general procedure): add
   the rule, rebuild and restart just the monitor sidecar:

   ```bash
   docker compose --profile monitoring build security-monitor
   docker compose --profile monitoring up -d --force-recreate security-monitor
   ```

   Trigger it from inside `claude-code`:

   ```bash
   docker compose exec claude-code curl -s -d "test=1" https://example.com >/dev/null
   ```

   Confirm it fired:

   ```bash
   docker compose logs security-monitor | grep "Outbound data upload"
   ```

3. Once confirmed, add a regression test to
   `tests/security/test_falco_rules.sh` so future refactors can't
   silently break it — follow the pattern of the existing
   `test_*_fires` functions in that file (trigger the condition, then
   `assert_alert_seen` for your rule's exact output text), and register it
   in the `run_test` list near the bottom.

4. Run the full security tier to make sure nothing else regressed:

   ```bash
   ./tests/run-tests.sh --security
   ```

New rules are picked up automatically the next time `cc-container
--monitor` runs (it always rebuilds the sidecar first, see above) — no
separate registration step needed beyond adding the YAML.
