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
        rm -f ~/.bash_history
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

assert_alert_seen() { # checkpoint substring [timeout_seconds]
    local checkpoint="$1" substring="$2" timeout="${3:-15}"
    if wait_for_log "$checkpoint" "$substring" "$timeout"; then
        assert_equal "seen" "seen" "alert '$substring' appeared within ${timeout}s"
    else
        assert_equal "seen" "not-seen" "alert '$substring' did not appear within ${timeout}s"
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

test_network_tool_during_npm_install() {
    # None of network_tool_binaries are installed in the base image and
    # the Squid allowlist can't reach an apt mirror to install real ones --
    # the rule only checks proc.name, not real functionality, so a dummy
    # script named "nc" run via an npm postinstall script is sufficient.
    local checkpoint; checkpoint="$(log_line_count)"
    "${COMPOSE[@]}" exec -T claude-code sh -c '
        mkdir -p ~/.local/bin
        printf "#!/bin/sh\nexit 0\n" > ~/.local/bin/nc
        chmod +x ~/.local/bin/nc
        mkdir -p /tmp/falco-test-npm-pkg
        cd /tmp/falco-test-npm-pkg
        printf "%s" "{\"name\":\"falco-test\",\"version\":\"1.0.0\",\"scripts\":{\"postinstall\":\"nc\"}}" > package.json
        npm install --no-audit --no-fund >/dev/null 2>&1
    '
    assert_alert_seen "$checkpoint" "Network tool executed during npm install in claude-code" 20
    "${COMPOSE[@]}" exec -T claude-code sh -c \
        'rm -f ~/.local/bin/nc; rm -rf /tmp/falco-test-npm-pkg' >/dev/null 2>&1 || true
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
    # The connection itself fails (internal: true network, no route out)
    # but the rule watches the connect/sendto attempt, which the kernel
    # still observes even though it never succeeds.
    local checkpoint; checkpoint="$(log_line_count)"
    "${COMPOSE[@]}" exec -T claude-code sh -c \
        'curl --max-time 3 http://169.254.169.254/ >/dev/null 2>&1 || true'
    assert_alert_seen "$checkpoint" "Outbound connection from claude-code to cloud metadata service" 15
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

test_history_file_deletion() {
    local checkpoint; checkpoint="$(log_line_count)"
    "${COMPOSE[@]}" exec -T claude-code sh -c 'touch ~/.bash_history && rm ~/.bash_history'
    assert_alert_seen "$checkpoint" "Shell history tampering in claude-code" 15
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
    assert_alert_seen "$checkpoint" "Shell history tampering in claude-code" 15
}

run_test test_unexpected_shell_fires
run_test test_network_tool_during_npm_install
run_test test_env_read_from_proc
run_test test_ps_aux_does_not_false_positive
run_test test_cloud_metadata_contact_attempt
run_test test_privilege_escalation_attempt
run_test test_history_file_deletion
run_test test_history_env_tampering_spawned_process

print_summary
