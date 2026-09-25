# Tests

No external test framework — a small, self-rolled bash setup consistent
with the rest of this repo (no `package.json`/`Makefile`). See
[lib/assert.sh](lib/assert.sh) for the assertion helpers used throughout.

```bash
./run-tests.sh               # unit tests only (fast, no Docker)
./run-tests.sh --integration # integration tests only (needs Docker)
./run-tests.sh --security    # security tests only (needs Docker)
./run-tests.sh --all         # unit + integration + security
```

Tier flags are additive (`--integration --security` runs both, skips
unit); with no flags at all, only unit tests run. Each `test_*.sh` file is
independently executable (`./unit/test_foo.sh`) and owns its own pass/fail
counters — `run-tests.sh` just runs every file in a tier and aggregates
their exit codes. `tests/lib/docker_lib.sh` has the shared
project-name/cleanup helpers used by both `integration/` and `security/`.

## unit/ — fast, no Docker

- `test_syntax.sh` — `bash -n` over every shell script in the repo.
- `test_shellcheck.sh` — same, via `shellcheck`, if installed
  (`apt install shellcheck` / `brew install shellcheck`); soft-skips
  otherwise, not a hard dependency of this repo.
- `test_render_upstream_proxy_conf.sh` — the `HTTP(S)_PROXY` parsing +
  Squid/`px` config rendering logic in `bin/cc-container` (see
  [docs/enterprise-proxy.md](../docs/enterprise-proxy.md)), sourced
  directly (safe: the script is guarded so sourcing it only defines
  functions, see the bottom of `bin/cc-container`).
- `test_compose_project_name.sh` — the per-workspace
  `COMPOSE_PROJECT_NAME` derivation (see [AGENTS.md](../AGENTS.md)
  "Multi-instance invariants").
- `test_install_uninstall.sh` — `install.sh`/`uninstall.sh` run as real
  subprocesses against a throwaway `HOME` with a stubbed `docker` on
  `PATH`. Doesn't cover the interactive Docker-image-purge prompt in
  `uninstall.sh` (needs a real tty) — that path is small enough to verify
  by hand when touched.
- `test_windows_installer.sh` — `go vet`, `go test` (`windows/main_test.go`:
  the platform-independent `.wslconfig`/username/checksum helpers), and a
  `GOOS=windows` cross-compile of the onboarding installer (see
  [docs/windows-onboarding.md](../docs/windows-onboarding.md)), if Go is
  installed; soft-skips otherwise, same as `test_shellcheck.sh`. Everything
  that actually calls `wsl.exe`/PowerShell is only verifiable on real
  Windows — see that doc's hardware test checklist.

## integration/ — needs Docker, slower

Builds/starts the real stack. Uses a dedicated
`COMPOSE_PROJECT_NAME=cc-selftest-$$` (never a real workspace's project
name) and tears everything down via `trap ... EXIT`, so it never touches
containers/networks started by an actual `cc-container` session.

- `test_compose_config.sh` — `docker compose config`, with and without the
  `enterprise-proxy` profile.
- `test_build.sh` — builds `claude-code` and (under the profile)
  `proxy-auth`. Slow (apt/npm/pip installs).
- `test_runtime.sh` — starts the stack and checks the security-critical
  invariants from `AGENTS.md`: `claude-code` runs as UID 1000, the domain
  allowlist actually allows `api.anthropic.com` and blocks `example.com`,
  `claude-code` isn't attached to the `proxy-chain`/`external` networks,
  and the merged `squid.conf` parses cleanly.

Not covered: an actual NTLM/Kerberos handshake against a real corporate
proxy (not realistically automatable without one) — see
[docs/enterprise-proxy.md](../docs/enterprise-proxy.md) for the setup this
would exercise.

## security/ — needs Docker, hardening/adversarial checks

Same cleanup pattern as `integration/`. Focused on the specific risks in
this repo (container escape, network exfiltration, trust-boundary
enforcement) rather than general functionality.

- `test_static_hardening.sh` — no containers started, just `docker compose
  config` (with the `enterprise-proxy` profile) and Dockerfile greps: no
  service is `privileged`, none adds Linux capabilities (`cap_add`), none
  mounts the Docker socket (even read-only, that's effectively
  root-equivalent host access — the Docker API has no granular read/write
  distinction), and neither `Dockerfile` does a full-context `COPY . .`/
  `ADD . .` that could bypass `.dockerignore`'s exclusions.
- `test_runtime_hardening.sh` — starts the stack and probes specific
  bypass attempts: a direct connection from `claude-code` with
  `HTTP_PROXY`/`HTTPS_PROXY` explicitly unset and `--noproxy '*'` (actively
  trying to go around `egress-proxy`) must still have no route out at all;
  writing into the read-only `.squid-claudecode-docker` mount inside
  `claude-code` must fail; Squid must reject CONNECT to a non-80/443 port
  even for an otherwise-allowed domain.
- `test_falco_rules.sh` — starts the stack under the `monitoring` profile
  (builds `security-monitor` too, heavier than the rest of this tier) and
  triggers every rule in `falco/claude-code-rules.yaml` (unexpected shell,
  npm-install network tool, `/proc/*/environ` reads including the `ps aux`
  false-positive regression guard, cloud metadata contact, privilege
  escalation, shell-history tampering, mount/umount, unshare, capset,
  setuid, raw sockets, credential reads, and more — see
  [falco/claude-code-rules.yaml](../falco/claude-code-rules.yaml) for the
  current, maintained list), asserting the expected alert line appears in
  `docker compose logs security-monitor`. Needs a kernel with eBPF
  support; individual checks soft-skip (not a hard failure) rather than
  fail outright where a known host/driver limitation applies (each
  soft-skip's own `SKIP` line explains why — see that same file's OPEN
  ITEMS block for the list). Does not
  cover the desktop-notification/D-Bus path, nor "Unexpected shell"'s
  false-positive direction for a *real* assistant-issued Bash tool call —
  see [AGENTS.md](../AGENTS.md#runtime-monitoring) "Runtime monitoring" for
  that manual procedure.
