#!/usr/bin/env bash
# Live verification for the Falco rules in falco/claude-code-rules.yaml that
# were, as of writing, never actually triggered on a real host (see that
# file's "OPEN ITEMS" header). Starts security-monitor under the
# "monitoring" Compose profile (NOT "auto-stop" -- stop-watcher never even
# starts here, see cleanup note below), triggers each rule's condition
# inside claude-code, and polls `docker compose logs security-monitor` for
# the expected alert line. Only checks the stdout/program_output side --
# the desktop-notification/D-Bus half of the pipeline needs a graphical
# host session and isn't covered here (see AGENTS.md "Runtime monitoring").
#
# Does NOT cover "Unexpected shell in claude-code"'s false-positive
# direction (does a REAL Claude-Code-assistant Bash tool call also get
# excluded, not just a `docker compose exec` shell?) -- that needs an
# actual interactive Claude Code session issuing a real Bash tool call,
# which can't come from this script. See AGENTS.md "Runtime monitoring"
# for that manual procedure.
#
# No -e, same rationale as test_runtime_hardening.sh: one failing
# assertion must not abort the script before later assertions/cleanup run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/assert.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/docker_lib.sh"

PROJECT="$(docker_test_project_name)"
COMPOSE=(docker compose -f "$REPO_ROOT/docker-compose.yml" -p "$PROJECT")

# Belt-and-suspenders: security-monitor's own environment: block reads this
# too. The real isolation guarantee is that we only add the "monitoring"
# profile below, never "auto-stop" -- stop-watcher (docker-compose.yml's
# only service with docker.sock) never starts as part of this test at all,
# so nothing can actually stop a container even though rules 4/5 below are
# CRITICAL and their output text does contain the literal substring
# "claude-code" (falco-notify.sh's counter/trigger-file bookkeeping still
# runs, harmlessly, with no stop-watcher present to consume the trigger).
export SECURITY_MONITOR_STOP_THRESHOLD=0

cleanup() {
    "${COMPOSE[@]}" exec -T claude-code sh -c '
        rm -f ~/.local/bin/nc ~/.local/bin/sudo ~/.local/bin/su ~/.local/bin/pkexec ~/.local/bin/doas
        rm -f ~/.bash_history /tmp/node
        rm -rf /tmp/falco-test-npm-pkg /tmp/falco-pipeline-test
    ' >/dev/null 2>&1 || true
    docker_test_cleanup "$PROJECT"
    "${COMPOSE[@]}" --profile monitoring down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "  (using COMPOSE_PROJECT_NAME=$PROJECT -- can take a while on first run, builds security-monitor too)"

if ! "${COMPOSE[@]}" --profile monitoring up -d --wait 2>&1 | sed 's/^/  /'; then
    # Distinguish "this environment structurally can't run Falco's eBPF
    # driver" (soft-skip, exit 0, doesn't fail the tier) from a genuine
    # regression (hard fail). Falco logs an explicit driver/probe failure
    # on stderr when the kernel doesn't support modern_ebpf; a container
    # that merely never reaches "healthy" for some other reason should
    # still count as a real failure.
    driver_log="$("${COMPOSE[@]}" logs security-monitor 2>&1 || true)"
    if echo "$driver_log" | grep -qiE "unable to load|probe|ebpf.*fail|failed to init"; then
        echo "  SKIP: security-monitor's eBPF driver failed to initialize in this environment"
        echo "  (no kernel eBPF support here -- see AGENTS.md \"Runtime monitoring\") -- skipping Falco rule checks."
        echo "$driver_log" | tail -n 20 | sed 's/^/    /'
        exit 0
    fi
    CURRENT_TEST="stack startup (monitoring profile)"
    _fail "docker compose --profile monitoring up -d --wait failed -- see output above"
    print_summary
    exit 1
fi

log_line_count() {
    "${COMPOSE[@]}" logs security-monitor 2>&1 | wc -l
}

# wait_for_log <checkpoint> <substring> [timeout_seconds] -- polls
# security-monitor's log for <substring> appearing after line <checkpoint>.
wait_for_log() {
    local checkpoint="$1" substring="$2" timeout="${3:-15}" waited=0
    while [ "$waited" -lt "$timeout" ]; do
        if "${COMPOSE[@]}" logs security-monitor 2>&1 \
            | tail -n "+$((checkpoint + 1))" | grep -qF -- "$substring"; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

log_slice_since() { # checkpoint
    "${COMPOSE[@]}" logs security-monitor 2>&1 | tail -n "+$(($1 + 1))"
}

# assert_alert_seen <checkpoint> <substring> [timeout_seconds] [extra_diagnostic_text]
# On failure, dumps the security-monitor log slice since <checkpoint> (and
# any caller-supplied extra diagnostic text) so a FAIL here can be
# triaged -- test artifact vs. real rule gap -- without re-running by hand.
assert_alert_seen() {
    local checkpoint="$1" substring="$2" timeout="${3:-15}" extra="${4:-}"
    if wait_for_log "$checkpoint" "$substring" "$timeout"; then
        assert_equal "seen" "seen" "alert '$substring' appeared within ${timeout}s"
    else
        assert_equal "seen" "not-seen" "alert '$substring' did not appear within ${timeout}s"
        echo "    --- diagnostic: security-monitor log since checkpoint ---"
        log_slice_since "$checkpoint" | sed 's/^/    log> /'
        if [ -n "$extra" ]; then
            echo "    --- diagnostic: extra context ---"
            echo "$extra" | sed 's/^/    /'
        fi
    fi
}

assert_alert_absent() { # checkpoint substring [grace_seconds]
    local checkpoint="$1" substring="$2" grace="${3:-5}"
    sleep "$grace"
    local slice
    slice="$("${COMPOSE[@]}" logs security-monitor 2>&1 | tail -n "+$((checkpoint + 1))")"
    assert_not_contains "$slice" "$substring"
}

# Readiness gate: prove rules are actually loaded, not just that the falco
# process hasn't crashed (security-monitor's healthcheck is only `pgrep -x
# falco`, which doesn't prove that). Reuses the existing, already-documented
# TEST-ONLY sanity rule (falco/claude-code-rules.yaml) rather than adding a
# new one.
checkpoint="$(log_line_count)"
"${COMPOSE[@]}" exec -T claude-code touch /tmp/falco-pipeline-test >/dev/null 2>&1
if ! wait_for_log "$checkpoint" "TEST ALERT - Falco pipeline is working" 30; then
    CURRENT_TEST="monitoring readiness gate"
    _fail "TEST - Falco pipeline sanity check rule never fired -- rules not loaded, aborting per-rule checks"
    "${COMPOSE[@]}" exec -T claude-code rm -f /tmp/falco-pipeline-test >/dev/null 2>&1 || true
    print_summary
    exit 1
fi
"${COMPOSE[@]}" exec -T claude-code rm -f /tmp/falco-pipeline-test >/dev/null 2>&1 || true

test_claude_exe_path_anchor_current() {
    # Companion check for falco/claude-code-rules.yaml's
    # claude_code_binary_exepath / claude_code_binary_pexepath macros (see
    # that file's "Maintenance trap" comment). Those macros hardcode the
    # claude-code CLI's real, kernel-resolved executable path as an
    # anti-spoofing anchor in three rules. If the npm global prefix or
    # install method ever changes, this test fails loudly instead of the
    # rules silently stopping to exclude legitimate claude-code activity.
    # Independent of the Falco/monitoring pipeline -- just resolves the
    # installed binary's real path the same way the kernel would.
    local expected="/home/claudecode/.npm-global/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
    local shim actual
    shim="$("${COMPOSE[@]}" exec -T claude-code sh -c 'command -v claude' 2>&1 | tr -d '\r')"
    actual="$("${COMPOSE[@]}" exec -T claude-code sh -c "readlink -f '$shim'" 2>&1 | tr -d '\r')"
    assert_equal "$expected" "$actual" \
        "update claude_code_binary_exepath AND claude_code_binary_pexepath in falco/claude-code-rules.yaml to the new path"
}

test_unexpected_shell_fires() {
    # True-positive direction only: a docker-compose-exec'd shell has a
    # parent chain (containerd-shim) that is neither claude/node nor the
    # claude.exe pexepath, so the exclusion shouldn't apply. The
    # false-positive direction (a REAL assistant-issued Bash tool call)
    # needs a live interactive session -- see AGENTS.md "Runtime
    # monitoring" for that manual procedure.
    local checkpoint; checkpoint="$(log_line_count)"
    "${COMPOSE[@]}" exec -T claude-code bash -c 'echo falco-shell-test' >/dev/null
    assert_alert_seen "$checkpoint" "Shell spawned in claude-code" 15
}

test_unexpected_shell_catches_renamed_impersonator() {
    # Regression test for the 2026-09-14 proc.name-spoofing fix (found by
    # cross-referencing BlackBerry's "Falco-bypasses" writeup, technique
    # (c), against this repo's own rules): before the fix, a shell whose
    # PARENT was simply named "node" from birth (execve'd from a binary
    # literally called that, never calling prctl at all) was silently
    # excluded by the old `proc.pname in (claude, node)` OR-branch,
    # completely bypassing the pexepath hardening AND going undetected by
    # "Process impersonating trusted name via prctl" (which only reacts to
    # an actual prctl(PR_SET_NAME) syscall, not a process that's simply
    # named that way from exec). /tmp/node here is a copy of /bin/bash --
    # not the real node.binary_exepath -- that spawns a child shell.
    local checkpoint; checkpoint="$(log_line_count)"
    "${COMPOSE[@]}" exec -T claude-code sh -c \
        'cp /bin/bash /tmp/node && chmod +x /tmp/node && /tmp/node -c "bash -c \"echo falco-fake-node-test\""' >/dev/null 2>&1
    assert_alert_seen "$checkpoint" "Shell spawned in claude-code" 15
    "${COMPOSE[@]}" exec -T claude-code rm -f /tmp/node >/dev/null 2>&1 || true
}

test_network_tool_during_npm_install() {
    # None of network_tool_binaries are installed in the base image and
    # the Squid allowlist can't reach an apt mirror to install real ones --
    # the rule only checks proc.name, not real functionality, so a dummy
    # script named "nc" run via an npm postinstall script is sufficient.
    # The dummy "nc" also drops a marker file, so a FAIL here can
    # distinguish "postinstall never invoked nc at all" (npm/test-harness
    # issue) from "nc ran but Falco's ancestor-chain match missed it"
    # (an actual rule-condition gap, e.g. npm's proc.name not being what
    # npm_package_install_ancestor expects).
    local checkpoint; checkpoint="$(log_line_count)"
    local npm_out
    npm_out="$("${COMPOSE[@]}" exec -T claude-code sh -c '
        mkdir -p ~/.local/bin
        printf "#!/bin/sh\ntouch /tmp/falco-nc-invoked\nexit 0\n" > ~/.local/bin/nc
        chmod +x ~/.local/bin/nc
        rm -f /tmp/falco-nc-invoked
        mkdir -p /tmp/falco-test-npm-pkg
        cd /tmp/falco-test-npm-pkg
        printf "%s" "{\"name\":\"falco-test\",\"version\":\"1.0.0\",\"scripts\":{\"postinstall\":\"nc\"}}" > package.json
        npm install --no-audit --no-fund 2>&1
        echo "---marker---"
        [ -f /tmp/falco-nc-invoked ] && echo "nc WAS invoked (marker file exists)" || echo "nc was NEVER invoked (no marker file) -- npm postinstall did not run it"
    ' 2>&1)"
    assert_alert_seen "$checkpoint" "Network tool executed during npm install in claude-code" 20 "npm install output + marker check:
$npm_out"

    # Regression guard for the 2026-09-14 node_binary_pexepath hardening
    # (see falco/claude-code-rules.yaml's "Unexpected shell" comment): npm
    # always runs a lifecycle script as `sh -c "<script>"` with the real
    # node process (comm=node) as parent -- this postinstall run just did
    # exactly that. That sh spawn must stay excluded via the real node
    # binary's exepath, not fire "Unexpected shell", now that the old
    # blanket proc.pname="node" exclusion is gone.
    #
    # NOT a blanket assert_alert_absent: the `docker compose exec sh -c
    # '...'` wrapper around this whole trigger is ITSELF a legitimate,
    # expected "Shell spawned" true positive (parent=containerd-shim, same
    # mechanism as test_unexpected_shell_fires) -- unrelated to this guard
    # and present in every run. Only check specifically for a
    # parent=node-attributed alert, which is what the npm-lifecycle-script
    # sh would produce if the node_binary_pexepath exclusion regressed.
    local node_parented_shell_alerts
    node_parented_shell_alerts="$("${COMPOSE[@]}" logs security-monitor 2>&1 \
        | tail -n "+$((checkpoint + 1))" | grep "Shell spawned in claude-code" \
        | grep -c 'parent=node ' || true)"
    assert_equal "0" "${node_parented_shell_alerts:-0}" \
        "npm's own lifecycle-script shell (parent=node) did not additionally trigger 'Unexpected shell'"

    "${COMPOSE[@]}" exec -T claude-code sh -c \
        'rm -f ~/.local/bin/nc /tmp/falco-nc-invoked; rm -rf /tmp/falco-test-npm-pkg' >/dev/null 2>&1 || true
}

test_env_read_from_proc() {
    local checkpoint; checkpoint="$(log_line_count)"
    "${COMPOSE[@]}" exec -T claude-code cat /proc/self/environ >/dev/null
    assert_alert_seen "$checkpoint" "Environment variables read from /proc in claude-code" 15
}

test_ps_aux_does_not_false_positive() {
    # Regression guard for the proc_inspection_binaries exclusion --
    # AGENTS.md documents that plain `ps aux` false-positived against this
    # rule before the exclusion was added.
    local checkpoint; checkpoint="$(log_line_count)"
    "${COMPOSE[@]}" exec -T claude-code ps aux >/dev/null
    assert_alert_absent "$checkpoint" "Environment variables read from /proc in claude-code" 5
}

test_cloud_metadata_contact_attempt() {
    # Must bypass egress-proxy explicitly (same pattern as
    # test_runtime_hardening.sh's test_direct_network_bypass_fails):
    # claude-code has HTTP_PROXY/HTTPS_PROXY set, so a plain `curl
    # http://169.254.169.254/` would transparently connect to
    # egress-proxy:3128 instead of attempting a direct connect() to
    # 169.254.169.254 at all.
    #
    # Soft-skips instead of hard-failing: confirmed via a throwaway DEBUG
    # rule (see falco/claude-code-rules.yaml OPEN ITEMS, "Known, accepted
    # limitation") that Falco's fd.rip/fd.rport/fd.sip enrichment comes
    # back <NA> for a connect() that fails with ENETUNREACH on this
    # Falco/driver build -- this repo's internal:true network has no route
    # to 169.254.169.254 at all, so this specific check cannot pass here
    # regardless of the rule's condition. Left in (not deleted) so it
    # self-upgrades to a real PASS if a Falco fix or a routable environment
    # ever changes this, instead of silently forgetting to re-check.
    local checkpoint; checkpoint="$(log_line_count)"
    "${COMPOSE[@]}" exec -T claude-code sh -c \
        'env -u HTTP_PROXY -u HTTPS_PROXY curl --noproxy "*" --max-time 3 http://169.254.169.254/ >/dev/null 2>&1 || true'
    if wait_for_log "$checkpoint" "Outbound connection from claude-code to cloud metadata service" 15; then
        assert_equal "seen" "seen" "alert fired (fd.sip enrichment worked on this host)"
    else
        echo "  SKIP test_cloud_metadata_contact_attempt: known Falco/eBPF limitation on this host/network (fd.sip/fd.rip/fd.rport not populated for a synchronously-failing connect() -- see falco/claude-code-rules.yaml OPEN ITEMS). Not counted as a failure."
    fi
}

test_privilege_escalation_attempt() {
    # The rule's own desc claims none of sudo/su/pkexec/doas are installed
    # in the base image -- verify per-binary rather than assume, since
    # `su` in particular could ship as part of Ubuntu's base rootfs.
    local bin
    for bin in sudo su pkexec doas; do
        local checkpoint; checkpoint="$(log_line_count)"
        if "${COMPOSE[@]}" exec -T claude-code sh -c "command -v $bin" >/dev/null 2>&1; then
            # Real binary present on this image -- use a harmless,
            # non-interactive invocation to avoid a password-prompt hang.
            "${COMPOSE[@]}" exec -T claude-code "$bin" --help >/dev/null 2>&1 || true
        else
            "${COMPOSE[@]}" exec -T claude-code sh -c "
                mkdir -p ~/.local/bin
                printf '#!/bin/sh\nexit 0\n' > ~/.local/bin/$bin
                chmod +x ~/.local/bin/$bin
                $bin
                rm -f ~/.local/bin/$bin
            "
        fi
        assert_alert_seen "$checkpoint" "Privilege escalation attempt in claude-code" 15
    done
}

test_prctl_impersonation_fires() {
    # Confirmed live 2026-09-14 (manually first, see
    # falco/claude-code-rules.yaml's own comment on this rule): a process
    # that is NOT claude-code's own real executable renaming itself to
    # "Bun"/"claude"/"node" via prctl(PR_SET_NAME) is exactly what this
    # rule is designed to catch. python3 (not claude.exe) is a convenient,
    # always-available way to trigger this without a throwaway C program
    # -- PR_SET_NAME is prctl option 15.
    local checkpoint; checkpoint="$(log_line_count)"
    "${COMPOSE[@]}" exec -T claude-code python3 -c \
        "import ctypes; ctypes.CDLL('libc.so.6').prctl(15, b'Bun', 0, 0, 0)" >/dev/null 2>&1
    assert_alert_seen "$checkpoint" "Process impersonating trusted name via prctl in claude-code" 15
}

test_history_file_deletion() {
    # Was "Shell history tampering in claude-code" (one combined rule)
    # until 2026-09-13, split into two rules after the combined one was
    # confirmed dead for both branches -- see falco/claude-code-rules.yaml
    # OPEN ITEMS "Fixed 2026-09-13" for the full root-cause writeup.
    local checkpoint; checkpoint="$(log_line_count)"
    "${COMPOSE[@]}" exec -T claude-code sh -c 'touch ~/.bash_history && rm ~/.bash_history'
    assert_alert_seen "$checkpoint" "Shell history file deleted or renamed in claude-code" 15
}

test_history_env_tampering_spawned_process() {
    # Test-harness technicality, not a claim that bash builtins are
    # detectable in the wild (see AGENTS.md "Known blind spots"): `bash -c
    # 'unset HISTFILE'` spawns a NEW bash process whose own proc.cmdline
    # literally contains "HISTFILE", satisfying the condition's
    # spawned_process branch. A builtin typed into an already-open shell
    # would NOT execve and would NOT be caught -- that gap is real and
    # this test doesn't claim to cover it.
    local checkpoint; checkpoint="$(log_line_count)"
    "${COMPOSE[@]}" exec -T claude-code bash -c 'unset HISTFILE'
    assert_alert_seen "$checkpoint" "Shell history disabling command in claude-code" 15
}

test_squid_override_write_attempt_fires() {
    # Same trigger as test_runtime_hardening.sh's
    # test_workspace_squid_override_is_readonly (the enforcement-side
    # counterpart) -- this is the detection-side check. Was dead until
    # 2026-09-14: the rule used to depend on the bundled open_write macro,
    # which requires fd.num>=0 (a successful open); a write against this
    # read-only mount always fails with EROFS before that. See
    # falco/claude-code-rules.yaml OPEN ITEMS for the full root-cause
    # writeup.
    local checkpoint; checkpoint="$(log_line_count)"
    "${COMPOSE[@]}" exec -T claude-code sh -c \
        'touch /workspace/.squid-claudecode-docker/security-test-write-attempt' >/dev/null 2>&1
    assert_alert_seen "$checkpoint" "Write attempt to read-only Squid override in claude-code" 15
}

test_squid_override_read_does_not_false_positive() {
    # Regression guard for the write-intent-flags restriction: this path is
    # deliberately readable (claude-code can see its own effective network
    # policy, just never change it, see AGENTS.md "Per-workspace
    # .squid-claudecode-docker overrides") -- a plain read must not alert.
    #
    # Reads the directory itself (ls), not a specific file inside it: the
    # mount's contents are SQUID_WORKSPACE_DIR (docker-compose.yml, defaults
    # to ./.squid-empty), which varies per workspace/test-harness run and
    # may be empty -- a hardcoded filename here (00-defaults.conf) was
    # observed present in one environment but missing in another, making
    # the test environment-dependent. The directory itself, as the mount
    # point, is always present regardless of contents.
    local checkpoint; checkpoint="$(log_line_count)"
    "${COMPOSE[@]}" exec -T claude-code ls -la /workspace/.squid-claudecode-docker/ >/dev/null
    assert_alert_absent "$checkpoint" "Write attempt to read-only Squid override in claude-code" 5
}

run_test test_claude_exe_path_anchor_current
run_test test_unexpected_shell_fires
run_test test_unexpected_shell_catches_renamed_impersonator
run_test test_network_tool_during_npm_install
run_test test_env_read_from_proc
run_test test_ps_aux_does_not_false_positive
run_test test_cloud_metadata_contact_attempt
run_test test_privilege_escalation_attempt
run_test test_prctl_impersonation_fires
run_test test_history_file_deletion
run_test test_history_env_tampering_spawned_process
run_test test_squid_override_write_attempt_fires
run_test test_squid_override_read_does_not_false_positive

print_summary
