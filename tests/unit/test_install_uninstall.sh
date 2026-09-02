#!/usr/bin/env bash
# Formalizes the ad hoc fakehome tests used while writing install.sh/
# uninstall.sh: runs both as real subprocesses against a throwaway HOME,
# with a stubbed `docker` on PATH (neither script needs a real Docker
# daemon for the paths tested here).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/assert.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/docker" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "compose" ] && [ "$2" = "version" ]; then
    echo "Docker Compose version v2.99.0 (fake)"
    exit 0
fi
if [ "$1" = "image" ] && [ "$2" = "inspect" ]; then
    exit 1 # no image present in this fake environment
fi
echo "fake docker: unsupported args: $*" >&2
exit 1
EOF
chmod +x "$WORK/fakebin/docker"

# fresh_home <name> -- sets up an isolated HOME under $WORK/<name> with an
# existing .bashrc (to prove install.sh/uninstall.sh don't clobber
# unrelated content), and exports HOME/SHELL/PATH for the caller.
fresh_home() {
    local home="$WORK/$1"
    rm -rf "$home"
    mkdir -p "$home"
    echo "# pre-existing bashrc content" > "$home/.bashrc"
    export HOME="$home"
    export SHELL="/bin/bash"
    export PATH="$WORK/fakebin:/usr/bin:/bin"
}

test_install_fails_cleanly_without_docker() {
    fresh_home "no_docker"
    export PATH="/usr/bin:/bin" # no fakebin -- docker genuinely missing
    assert_failure "$REPO_ROOT/install.sh"
    assert_file_not_exists "$HOME/.local/bin/cc-container"
}

test_install_creates_symlink_and_path_entry() {
    fresh_home "basic_install"
    assert_success "$REPO_ROOT/install.sh"
    assert_file_exists "$HOME/.local/bin/cc-container"
    [ "$(readlink -f "$HOME/.local/bin/cc-container")" = "$(readlink -f "$REPO_ROOT/bin/cc-container")" ] \
        && _pass || _fail "symlink doesn't point at bin/cc-container"
    assert_contains "$(cat "$HOME/.bashrc")" "claude-code-docker PATH"
    assert_contains "$(cat "$HOME/.bashrc")" "pre-existing bashrc content"
}

test_install_is_idempotent() {
    fresh_home "idempotent_install"
    assert_success "$REPO_ROOT/install.sh"
    assert_success "$REPO_ROOT/install.sh"
    local marker_count
    marker_count="$(grep -c "claude-code-docker PATH >>>" "$HOME/.bashrc")"
    assert_equal 1 "$marker_count" "second install.sh run must not duplicate the PATH block"
}

test_install_refuses_to_overwrite_foreign_file() {
    fresh_home "foreign_file"
    mkdir -p "$HOME/.local/bin"
    echo "not a symlink" > "$HOME/.local/bin/cc-container"
    assert_failure "$REPO_ROOT/install.sh"
    assert_contains "$(cat "$HOME/.local/bin/cc-container")" "not a symlink"
}


# uninstall_ni -- runs uninstall.sh with stdin from /dev/null, so the
# interactive Docker-purge prompt (which needs a real tty) deterministically
# takes its "non-interactive: skip" branch regardless of how this test
# suite itself was invoked. The interactive (tty, answering y/N) path isn't
# covered by this automated suite -- see tests/README.md.
uninstall_ni() {
    bash -c "'$REPO_ROOT/uninstall.sh'" < /dev/null
}

test_uninstall_removes_symlink_and_path_entry() {
    fresh_home "basic_uninstall"
    "$REPO_ROOT/install.sh" >/dev/null
    assert_success uninstall_ni
    assert_file_not_exists "$HOME/.local/bin/cc-container"
    assert_not_contains "$(cat "$HOME/.bashrc")" "claude-code-docker PATH"
    assert_contains "$(cat "$HOME/.bashrc")" "pre-existing bashrc content"
}

test_uninstall_is_idempotent() {
    fresh_home "idempotent_uninstall"
    "$REPO_ROOT/install.sh" >/dev/null
    uninstall_ni >/dev/null
    assert_success uninstall_ni
}

test_uninstall_leaves_foreign_symlink_untouched() {
    fresh_home "foreign_symlink"
    mkdir -p "$HOME/.local/bin"
    ln -s /usr/bin/env "$HOME/.local/bin/cc-container"
    assert_success uninstall_ni
    assert_file_exists "$HOME/.local/bin/cc-container"
}

test_uninstall_skips_docker_prompt_when_noninteractive() {
    fresh_home "noninteractive_uninstall"
    "$REPO_ROOT/install.sh" >/dev/null
    # stdin from /dev/null (not a tty) -- must not hang on the read prompt.
    assert_success uninstall_ni
}

run_test test_install_fails_cleanly_without_docker
run_test test_install_creates_symlink_and_path_entry
run_test test_install_is_idempotent
run_test test_install_refuses_to_overwrite_foreign_file
run_test test_uninstall_removes_symlink_and_path_entry
run_test test_uninstall_is_idempotent
run_test test_uninstall_leaves_foreign_symlink_untouched
run_test test_uninstall_skips_docker_prompt_when_noninteractive

print_summary
