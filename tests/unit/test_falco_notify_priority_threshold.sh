#!/usr/bin/env bash
# Unit tests for falco-notify.sh's priority_rank() / SECURITY_MONITOR_NOTIFY_MIN_PRIORITY
# threshold logic (see that file's own comment for the design rationale).
# falco-notify.sh isn't sourceable as a whole -- it reads stdin immediately
# (message="$(cat)") and calls notify-send -- so this extracts just the
# self-contained priority_rank() function body via sed instead of sourcing
# the whole file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/assert.sh"

# shellcheck disable=SC1090
source <(sed -n '/^priority_rank() {/,/^}/p' "$REPO_ROOT/falco-notify.sh")

# The actual threshold comparison as used in falco-notify.sh.
below_threshold() { # priority min_priority
    [ "$(priority_rank "$1")" -lt "$(priority_rank "$2")" ]
}

test_ranks_are_monotonically_ordered() {
    assert_equal "7" "$(priority_rank emergency)" "emergency ranks 7"
    assert_equal "6" "$(priority_rank alert)" "alert ranks 6"
    assert_equal "5" "$(priority_rank critical)" "critical ranks 5"
    assert_equal "4" "$(priority_rank error)" "error ranks 4"
    assert_equal "3" "$(priority_rank warning)" "warning ranks 3"
    assert_equal "2" "$(priority_rank notice)" "notice ranks 2"
    assert_equal "1" "$(priority_rank informational)" "informational ranks 1"
    assert_equal "0" "$(priority_rank debug)" "debug ranks 0"
}

test_unrecognized_priority_fails_toward_showing_it() {
    assert_equal "3" "$(priority_rank bogus)" \
        "unrecognized priority word ranks as warning-equivalent, not silently swallowed"
}

test_default_warning_threshold_suppresses_lower_noise() {
    assert_equal "true" "$(below_threshold notice warning && echo true || echo false)" \
        "notice is suppressed under the new default warning threshold"
    assert_equal "true" "$(below_threshold informational warning && echo true || echo false)" \
        "informational is suppressed under the default warning threshold"
    assert_equal "true" "$(below_threshold debug warning && echo true || echo false)" \
        "debug is suppressed under the default warning threshold"
}

test_default_warning_threshold_still_shows_warning_and_above() {
    assert_equal "false" "$(below_threshold warning warning && echo true || echo false)" \
        "warning itself passes its own threshold (inclusive, not exclusive)"
    assert_equal "false" "$(below_threshold critical warning && echo true || echo false)" \
        "critical is never suppressed under the default warning threshold"
    assert_equal "false" "$(below_threshold emergency warning && echo true || echo false)" \
        "emergency is never suppressed under the default warning threshold"
}

test_stricter_threshold_suppresses_more() {
    assert_equal "true" "$(below_threshold informational critical && echo true || echo false)" \
        "a stricter threshold (critical) suppresses more, e.g. informational"
    assert_equal "true" "$(below_threshold warning critical && echo true || echo false)" \
        "a stricter threshold (critical) suppresses warning too"
}

test_debug_threshold_shows_everything() {
    assert_equal "false" "$(below_threshold debug debug && echo true || echo false)" \
        "an explicit debug threshold (opt-in to full noise) shows debug itself too"
}

run_test test_ranks_are_monotonically_ordered
run_test test_unrecognized_priority_fails_toward_showing_it
run_test test_default_warning_threshold_suppresses_lower_noise
run_test test_default_warning_threshold_still_shows_warning_and_above
run_test test_stricter_threshold_suppresses_more
run_test test_debug_threshold_shows_everything

print_summary
