#!/usr/bin/env bash
# Live verification for the auto-stop pipeline (stop-watcher + falco-notify.sh's
# CRITICAL/EMERGENCY counter) -- never actually exercised on a real host before
# this test existed. See the "VERIFY (no Docker access at authoring time)"
# comments this resolves:
#   - docker-compose.yml's stop-watcher service comment: falco-notify.sh's
#     assumption that Falco resolves container.id without a docker.sock mount
#     on security-monitor, and stop-watcher-entrypoint.sh's /etc/hostname-as-
#     self-id assumption.
#   - stop-watcher-entrypoint.sh's own header comment: same self-id/container.id
#     assumptions, load-bearing for the same-instance safety guarantee.
#   - falco-notify.sh's own comment: container.id resolvable from the
#     kernel/cgroup path alone (fails closed if not, but never confirmed which
#     branch actually happens).
#
# Uses the existing "TEST - Falco auto-stop pipeline check" rule
# (falco/claude-code-rules.yaml) -- a harmless, unambiguous CRITICAL trigger
# built specifically for this (touch a file containing
# "falco-stop-test-trigger"), so the auto-stop path can be exercised without
# reproducing a real CRITICAL violation.
#
# Two scenarios:
#   test_auto_stop_stops_own_container -- happy path: a throwaway project's
#     own claude-code container actually gets stopped after
#     SECURITY_MONITOR_STOP_THRESHOLD CRITICAL alerts.
#   test_auto_stop_refuses_foreign_container -- the actual safety boundary:
#     security-monitor watches the whole host kernel via eBPF, not just its
#     own Compose project (see AGENTS.md "Runtime monitoring"), so a SECOND,
#     unrelated project's claude-code container can produce alerts that a
#     FIRST project's security-monitor observes and writes into its own
#     trigger volume. stop-watcher must refuse to act on those -- this is the
#     one thing standing between this repo's only unrestricted-docker.sock
#     service and stopping the wrong workspace's container.
#
# No -e, same rationale as the other security tests: one failing assertion
# must not abort the script before later assertions/cleanup run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/assert.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/docker_lib.sh"

BASE_PROJECT="$(docker_test_project_name)"
PROJECT_A="${BASE_PROJECT}-a"
PROJECT_B="${BASE_PROJECT}-b"
COMPOSE_A=(docker compose -f "$REPO_ROOT/docker-compose.yml" -p "$PROJECT_A")
COMPOSE_B=(docker compose -f "$REPO_ROOT/docker-compose.yml" -p "$PROJECT_B")

# A single trigger is enough to cross the threshold -- faster and more
# deterministic than reproducing the real default (3) three times.
export SECURITY_MONITOR_STOP_THRESHOLD=1

cleanup() {
    "${COMPOSE_A[@]}" exec -T claude-code rm -f /tmp/falco-stop-test-trigger >/dev/null 2>&1 || true
    "${COMPOSE_B[@]}" exec -T claude-code rm -f /tmp/falco-stop-test-trigger >/dev/null 2>&1 || true
    "${COMPOSE_A[@]}" --profile monitoring --profile auto-stop down -v --remove-orphans >/dev/null 2>&1 || true
    "${COMPOSE_B[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "  (using COMPOSE_PROJECT_NAME=$PROJECT_A / $PROJECT_B -- can take a while on first run, builds security-monitor + stop-watcher too)"

if ! "${COMPOSE_A[@]}" --profile monitoring --profile auto-stop up -d --wait 2>&1 | sed 's/^/  /'; then
    # Same driver-failure vs. real-regression distinction as
    # test_falco_rules.sh.
    driver_log="$("${COMPOSE_A[@]}" logs security-monitor 2>&1 || true)"
    if echo "$driver_log" | grep -qiE "unable to load|probe|ebpf.*fail|failed to init"; then
        echo "  SKIP: security-monitor's eBPF driver failed to initialize in this environment"
        echo "  (no kernel eBPF support here -- see AGENTS.md \"Runtime monitoring\") -- skipping auto-stop pipeline checks."
        echo "$driver_log" | tail -n 20 | sed 's/^/    /'
        exit 0
    fi
    CURRENT_TEST="stack startup (project A, monitoring + auto-stop profiles)"
    _fail "docker compose --profile monitoring --profile auto-stop up -d --wait failed -- see output above"
    print_summary
    exit 1
fi

# log_line_count/wait_for_log take the *name* of a COMPOSE_* array variable
# (nameref) plus a service, since this file -- unlike test_falco_rules.sh --
# juggles two independent projects.
log_line_count() { # <compose-array-varname> <service>
    local -n compose_ref="$1"
    "${compose_ref[@]}" logs "$2" 2>&1 | wc -l
}

wait_for_log() { # <compose-array-varname> <service> <checkpoint> <substring> [timeout]
    local -n compose_ref="$1"
    local service="$2" checkpoint="$3" substring="$4" timeout="${5:-15}" waited=0
    while [ "$waited" -lt "$timeout" ]; do
        if "${compose_ref[@]}" logs "$service" 2>&1 \
            | tail -n "+$((checkpoint + 1))" | grep -qF -- "$substring"; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

test_auto_stop_stops_own_container() {
    local checkpoint_sm checkpoint_sw
    checkpoint_sm="$(log_line_count COMPOSE_A security-monitor)"
    checkpoint_sw="$(log_line_count COMPOSE_A stop-watcher)"

    "${COMPOSE_A[@]}" exec -T claude-code touch /tmp/falco-stop-test-trigger >/dev/null 2>&1

    if wait_for_log COMPOSE_A security-monitor "$checkpoint_sm" \
        "TEST ALERT - Falco auto-stop pipeline test for claude-code" 15; then
        assert_equal "seen" "seen" "auto-stop TEST ALERT fired in security-monitor"
    else
        assert_equal "seen" "not-seen" "auto-stop TEST ALERT did not fire in security-monitor"
        echo "    --- diagnostic: security-monitor log ---"
        "${COMPOSE_A[@]}" logs security-monitor 2>&1 | tail -n "+$((checkpoint_sm + 1))" | sed 's/^/    log> /'
    fi

    # Resolves the "container.id needs no docker.sock mount" VERIFY item:
    # the alert's own container= field (parsed the same way falco-notify.sh
    # parses it) must not be empty.
    local container_field
    container_field="$("${COMPOSE_A[@]}" logs security-monitor 2>&1 \
        | tail -n "+$((checkpoint_sm + 1))" | grep -oE 'container=[a-f0-9]+' | head -n1)"
    assert_not_equal "" "$container_field" \
        "alert's container= field resolved to a real id -- confirms container.id works on security-monitor without a docker.sock mount"

    # Resolves the "/etc/hostname self-id via docker.sock" VERIFY item: if
    # that failed, stop-watcher would have logged its FATAL line and exited
    # instead of ever reaching "threshold reached".
    if wait_for_log COMPOSE_A stop-watcher "$checkpoint_sw" \
        "threshold reached -- stopping own claude-code container" 20; then
        assert_equal "seen" "seen" "stop-watcher resolved its own self-id and issued its own stop"
    else
        assert_equal "seen" "not-seen" "stop-watcher never logged 'threshold reached' (check for a FATAL self-id resolution failure)"
        echo "    --- diagnostic: stop-watcher log ---"
        "${COMPOSE_A[@]}" logs stop-watcher 2>&1 | tail -n "+$((checkpoint_sw + 1))" | sed 's/^/    log> /'
    fi

    # The actual end-to-end proof: the container is really stopped, not just
    # logged about.
    local waited=0 running=""
    while [ "$waited" -lt 15 ]; do
        running="$("${COMPOSE_A[@]}" ps --status=running -q claude-code 2>/dev/null || true)"
        [ -z "$running" ] && break
        sleep 1
        waited=$((waited + 1))
    done
    assert_equal "" "$running" "claude-code container (project A) was actually stopped by stop-watcher, not just logged about"
}

start_project_b() {
    if ! "${COMPOSE_B[@]}" up -d --wait 2>&1 | sed 's/^/  /'; then
        CURRENT_TEST="stack startup (project B, plain claude-code, no monitoring)"
        _fail "docker compose up -d --wait for project B failed -- see output above"
        return 1
    fi
    return 0
}

test_auto_stop_refuses_foreign_container() {
    if ! start_project_b; then
        return
    fi

    local checkpoint_sm_a checkpoint_sw_a
    checkpoint_sm_a="$(log_line_count COMPOSE_A security-monitor)"
    checkpoint_sw_a="$(log_line_count COMPOSE_A stop-watcher)"

    "${COMPOSE_B[@]}" exec -T claude-code touch /tmp/falco-stop-test-trigger >/dev/null 2>&1

    if wait_for_log COMPOSE_A security-monitor "$checkpoint_sm_a" \
        "TEST ALERT - Falco auto-stop pipeline test for claude-code" 15; then
        assert_equal "seen" "seen" \
            "project A's security-monitor observed project B's claude-code alert (host-wide eBPF, not Compose-project-scoped)"
    else
        assert_equal "seen" "not-seen" \
            "project A's security-monitor never saw project B's alert -- can't exercise the safety boundary without this"
    fi

    if wait_for_log COMPOSE_A stop-watcher "$checkpoint_sw_a" "refusing to stop container" 15; then
        assert_equal "seen" "seen" "project A's stop-watcher refused to act on a foreign container's trigger"
    else
        assert_equal "seen" "not-seen" \
            "project A's stop-watcher did not log a refusal -- see the next assertion for whether it silently stopped the wrong container instead"
        echo "    --- diagnostic: project A stop-watcher log ---"
        "${COMPOSE_A[@]}" logs stop-watcher 2>&1 | tail -n "+$((checkpoint_sw_a + 1))" | sed 's/^/    log> /'
    fi

    # The actual safety property, independent of log text: project B's
    # container must still be running.
    local still_running
    still_running="$("${COMPOSE_B[@]}" ps --status=running -q claude-code 2>/dev/null || true)"
    assert_not_equal "" "$still_running" \
        "project B's claude-code container is still running -- project A's stop-watcher did NOT stop a foreign container"
}

run_test test_auto_stop_stops_own_container
run_test test_auto_stop_refuses_foreign_container

print_summary
