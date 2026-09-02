#!/usr/bin/env bash
# One-time host setup: puts bin/cc-container on PATH.
# Automates the "Setup" steps documented in README.md, idempotently.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

BIN_DIR="$HOME/.local/bin"
TARGET_LINK="$BIN_DIR/cc-container"
SOURCE_BIN="$PROJECT_ROOT/bin/cc-container"

MARKER_BEGIN="# >>> claude-code-docker PATH >>>"
MARKER_END="# <<< claude-code-docker PATH <<<"

check_dependencies() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "Error: docker is not installed. Install Docker first: https://docs.docker.com/get-docker/" >&2
        exit 1
    fi
    if ! docker compose version >/dev/null 2>&1; then
        echo "Error: the 'docker compose' plugin is not available. Install Docker Compose v2." >&2
        exit 1
    fi
}

install_symlink() {
    mkdir -p "$BIN_DIR"

    if [ -e "$TARGET_LINK" ] && [ ! -L "$TARGET_LINK" ]; then
        echo "Error: $TARGET_LINK already exists and is not a symlink. Remove it manually and re-run." >&2
        exit 1
    fi

    ln -sf "$SOURCE_BIN" "$TARGET_LINK"
    echo "==> Linked cc-container: $TARGET_LINK -> $SOURCE_BIN"
}

rc_file_for_shell() {
    case "${SHELL:-}" in
        */zsh) echo "$HOME/.zshrc" ;;
        */bash) echo "$HOME/.bashrc" ;;
        *) echo "$HOME/.profile" ;;
    esac
}

ensure_path_entry() {
    case ":$PATH:" in
        *":$BIN_DIR:"*)
            echo "==> $BIN_DIR is already on PATH."
            return
            ;;
    esac

    local rc_file
    rc_file="$(rc_file_for_shell)"

    if [ -f "$rc_file" ] && grep -qF "$MARKER_BEGIN" "$rc_file"; then
        echo "==> PATH entry already present in $rc_file."
        return
    fi

    {
        printf '\n%s\n' "$MARKER_BEGIN"
        printf 'export PATH="%s:$PATH"\n' "$BIN_DIR"
        printf '%s\n' "$MARKER_END"
    } >> "$rc_file"

    echo "==> Added $BIN_DIR to PATH in $rc_file."
    echo "==> Run 'source $rc_file' or open a new terminal to use cc-container right away."
}

main() {
    check_dependencies
    install_symlink
    ensure_path_entry
    echo "==> Done. From any project directory, run: cc-container"
}

main "$@"
