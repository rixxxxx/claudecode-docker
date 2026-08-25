#!/bin/bash
# Claude Code Docker — Entrypoint

# Re-link statusline.py from the live /workspace mount on every start, so
# edits committed to the repo take effect without an image rebuild (the
# Dockerfile's COPY only captures the file at build time).
if [ -f /workspace/statusline.py ]; then
    ln -sf /workspace/statusline.py /home/claudecode/.claude/statusline.py
fi

# Fix terminal settings for TUI apps
if [ -t 0 ] && [ -t 1 ]; then
    stty sane 2>/dev/null || true
    export TERM="${TERM:-xterm-256color}"
    if command -v resize &>/dev/null; then
        eval "$(resize)" 2>/dev/null || true
    elif [ -n "$LINES" ] && [ -n "$COLUMNS" ]; then
        stty rows "$LINES" cols "$COLUMNS" 2>/dev/null || true
    fi
fi

cat <<'WELCOME'
╔════════════════════════════════════════════════════════════════════════════╗
║                          Claude Code Docker                                ║
╠════════════════════════════════════════════════════════════════════════════╣
║                                                                            ║
║  First time? Login with your Claude Pro/Max subscription:                  ║
║    claude                               Launch, then /login                ║
║                                                                            ║
║  Or set an API key in .env:                                                ║
║    ANTHROPIC_API_KEY                                                       ║
║                                                                            ║
╚════════════════════════════════════════════════════════════════════════════╝
WELCOME

if [ $# -gt 0 ]; then
    exec "$@"
else
    exec /bin/bash
fi
