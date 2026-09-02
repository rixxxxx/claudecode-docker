#!/usr/bin/env bash
# Unit tests for derive_compose_project_name() in bin/cc-container -- the
# per-workspace COMPOSE_PROJECT_NAME derivation (see AGENTS.md
# "Multi-instance invariants").
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/assert.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/bin/cc-container" # source-guarded: only defines functions

# Compose project names must match ^[a-z0-9][a-z0-9_-]*$.
assert_valid_project_name() { # name [message]
    if [[ "$1" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        _pass
    else
        _fail "'$1' doesn't match Compose's ^[a-z0-9][a-z0-9_-]*\$ project-name rule${2:+ ($2)}"
    fi
}

test_starts_with_cc_prefix() {
    local name
    name="$(derive_compose_project_name "/home/user/my-project")"
    assert_contains "$name" "cc-my-project-"
}

test_lowercases_and_normalizes_special_characters() {
    local name
    name="$(derive_compose_project_name "/home/user/My Cool_Project!!")"
    assert_valid_project_name "$name"
    assert_contains "$name" "cc-my-cool-project-"
}

test_empty_slug_falls_back_to_ws() {
    # A path whose basename is entirely non-alnum (e.g. "---") normalizes
    # to an empty slug -- the "ws" fallback keeps the name Compose-valid.
    local name
    name="$(derive_compose_project_name "/home/user/---")"
    assert_valid_project_name "$name"
    assert_contains "$name" "cc-ws-"
}

test_long_basename_is_truncated() {
    local long_name name
    long_name="$(printf 'a%.0s' $(seq 1 60))" # 60 a's
    name="$(derive_compose_project_name "/home/user/$long_name")"
    assert_valid_project_name "$name"
    # "cc-" + up to 32 slug chars + "-" + hash
    local slug_part="${name#cc-}"
    slug_part="${slug_part%-*}"
    if [ "${#slug_part}" -le 32 ]; then
        _pass
    else
        _fail "slug part '${slug_part}' is longer than 32 chars"
    fi
}

test_different_workspaces_get_different_names() {
    local name_a name_b
    name_a="$(derive_compose_project_name "/home/user/project-a")"
    name_b="$(derive_compose_project_name "/home/user/project-b")"
    assert_not_equal "$name_a" "$name_b"
}

test_same_workspace_is_deterministic() {
    local name_a name_b
    name_a="$(derive_compose_project_name "/home/user/same-project")"
    name_b="$(derive_compose_project_name "/home/user/same-project")"
    assert_equal "$name_a" "$name_b"
}

test_different_paths_same_basename_get_different_names() {
    # Two distinct workspaces that happen to share a directory name (e.g.
    # both called "app") must not collide -- this is what the hash suffix
    # is for, the slug alone isn't unique.
    local name_a name_b
    name_a="$(derive_compose_project_name "/home/alice/app")"
    name_b="$(derive_compose_project_name "/home/bob/app")"
    assert_not_equal "$name_a" "$name_b"
}

run_test test_starts_with_cc_prefix
run_test test_lowercases_and_normalizes_special_characters
run_test test_empty_slug_falls_back_to_ws
run_test test_long_basename_is_truncated
run_test test_different_workspaces_get_different_names
run_test test_same_workspace_is_deterministic
run_test test_different_paths_same_basename_get_different_names

print_summary
