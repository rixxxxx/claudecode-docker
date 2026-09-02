#!/usr/bin/env bash
# Reverses install.sh: removes the cc-container symlink and its PATH entry.
# Optionally offers (interactively) to also remove the built Docker image.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

BIN_DIR="$HOME/.local/bin"
TARGET_LINK="$BIN_DIR/cc-container"
SOURCE_BIN="$PROJECT_ROOT/bin/cc-container"

MARKER_BEGIN="# >>> claude-code-docker PATH >>>"
MARKER_END="# <<< claude-code-docker PATH <<<"

RC_FILES=("$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile")

remove_symlink() {
    if [ ! -e "$TARGET_LINK" ] && [ ! -L "$TARGET_LINK" ]; then
        echo "==> No symlink at $TARGET_LINK, nothing to remove."
        return
    fi

    if [ ! -L "$TARGET_LINK" ] || [ "$(readlink -f "$TARGET_LINK")" != "$(readlink -f "$SOURCE_BIN")" ]; then
        echo "==> $TARGET_LINK does not point to $SOURCE_BIN, leaving it untouched."
        return
    fi

    rm -f "$TARGET_LINK"
    echo "==> Removed symlink: $TARGET_LINK"
}

remove_path_entry_from_file() {
    local rc_file="$1"

    if [ ! -f "$rc_file" ] || ! grep -qF "$MARKER_BEGIN" "$rc_file"; then
        return
    fi

    local tmp_file
    tmp_file="$(mktemp)"
    sed "/$(printf '%s' "$MARKER_BEGIN" | sed 's/[.[\*^$/]/\\&/g')/,/$(printf '%s' "$MARKER_END" | sed 's/[.[\*^$/]/\\&/g')/d" \
        "$rc_file" > "$tmp_file"
    mv "$tmp_file" "$rc_file"

    echo "==> Removed PATH entry from $rc_file."
}

remove_path_entries() {
    local rc_file
    for rc_file in "${RC_FILES[@]}"; do
        remove_path_entry_from_file "$rc_file"
    done
}

offer_docker_cleanup() {
    if [ ! -t 0 ]; then
        echo "==> Non-interactive shell: skipping the Docker image cleanup prompt."
        echo "==> Remove it manually later with: docker image rm claude-code:latest"
        return
    fi

    if ! command -v docker >/dev/null 2>&1; then
        return
    fi

    if ! docker image inspect claude-code:latest >/dev/null 2>&1; then
        return
    fi

    echo "==> The image 'claude-code:latest' is shared across all workspaces that use cc-container."
    echo "    Removing it does not stop containers from other workspaces still using it."
    read -r -p "Also remove the Docker image claude-code:latest? [y/N] " reply
    case "$reply" in
        y|Y|yes|Yes)
            if docker image rm claude-code:latest; then
                echo "==> Removed image claude-code:latest."
            else
                echo "==> Could not remove the image. If containers still reference it, stop them first with: docker compose down" >&2
            fi
            ;;
        *)
            echo "==> Leaving the Docker image in place."
            ;;
    esac
}

main() {
    remove_symlink
    remove_path_entries
    offer_docker_cleanup
    echo "==> Done."
}

main "$@"
