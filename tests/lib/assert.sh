#!/usr/bin/env bash
# Minimal assertion helpers for this repo's hand-rolled test suite. Each
# test file sources this, defines test_* functions, calls run_test on each,
# then exits non-zero if TESTS_FAILED > 0. See tests/run-tests.sh.

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_TEST=""

_pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    printf '  \033[32mPASS\033[0m %s\n' "$CURRENT_TEST"
}

_fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  \033[31mFAIL\033[0m %s: %s\n' "$CURRENT_TEST" "$1"
}

# run_test <test_function_name> -- calls it with CURRENT_TEST set, so
# assertions inside it can report which test they belong to.
run_test() {
    CURRENT_TEST="$1"
    "$1"
}

assert_equal() { # expected actual [message]
    if [ "$1" = "$2" ]; then
        _pass
    else
        _fail "expected '$1', got '$2'${3:+ ($3)}"
    fi
}

assert_not_equal() { # unexpected actual [message]
    if [ "$1" != "$2" ]; then
        _pass
    else
        _fail "expected value other than '$1'${3:+ ($3)}"
    fi
}

assert_contains() { # haystack needle [message]
    case "$1" in
        *"$2"*) _pass ;;
        *) _fail "expected to contain '$2', got '$1'${3:+ ($3)}" ;;
    esac
}

assert_not_contains() { # haystack needle [message]
    case "$1" in
        *"$2"*) _fail "expected NOT to contain '$2', got '$1'${3:+ ($3)}" ;;
        *) _pass ;;
    esac
}

assert_file_exists() { # path [message]
    if [ -f "$1" ]; then
        _pass
    else
        _fail "file not found: $1${2:+ ($2)}"
    fi
}

assert_file_not_exists() { # path [message]
    if [ ! -e "$1" ]; then
        _pass
    else
        _fail "file unexpectedly exists: $1${2:+ ($2)}"
    fi
}

# assert_success <command...> -- runs the command, asserts exit code 0.
assert_success() {
    local out
    if out="$("$@" 2>&1)"; then
        _pass
    else
        _fail "command failed ($?): $* -- output: $out"
    fi
}

# assert_failure <command...> -- runs the command, asserts a non-zero exit.
assert_failure() {
    local out
    if out="$("$@" 2>&1)"; then
        _fail "expected failure, command succeeded: $* -- output: $out"
    else
        _pass
    fi
}

# print_summary -- call at the end of a test file; exits with the test
# file's own exit status (0 = all passed).
print_summary() {
    echo "  --- ${TESTS_RUN} run, $((TESTS_RUN - TESTS_FAILED)) passed, ${TESTS_FAILED} failed ---"
    [ "$TESTS_FAILED" -eq 0 ]
}
