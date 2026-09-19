# syntax=docker/dockerfile:1

FROM ubuntu:26.04

# Metadata
LABEL maintainer="claudecode-docker"
LABEL description="Isolated Docker environment for ClaudeCode"
LABEL version="1.0"

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Enterprise network support: an optional corporate forward proxy for the
# network-touching RUN steps below (apt/curl/npm/gh/rtk). Passed as BuildKit
# secrets (docker-compose.yml build.secrets, rendered by
# render_build_secret_files() in bin/cc-container from HTTP_PROXY/
# HTTPS_PROXY/NO_PROXY in .env) rather than ARG/ENV: ARG values persist in
# `docker history`/image metadata even though never written to the
# filesystem, which would leak a corporate proxy password baked into a
# shared image. Each RUN below that touches the network mounts these
# explicitly via --mount=type=secret,id=...,env=VAR -- no image ENV is ever
# set for them, so nothing proxy-related persists past its own RUN step.
# Empty secrets (the default, non-enterprise case) are a no-op.

# ca-certificates isn't guaranteed present in the base ubuntu:26.04 image
# (confirmed: it isn't). Trust an optional corporate root CA (for
# TLS-intercepting proxies) right after -- certs/ is empty by default, so
# update-ca-certificates is a no-op for the normal build. Both must run as
# root, before USER claudecode below (see AGENTS.md). Same mechanism also
# picks up certs/egress-proxy-bump-ca.crt when present (bin/generate-bump-ca.sh,
# gitignored -- see README "TLS interception") -- no separate trust path
# needed for this repo's own SSL-Bump CA.
RUN --mount=type=secret,id=http_proxy,env=HTTP_PROXY \
    --mount=type=secret,id=https_proxy,env=HTTPS_PROXY \
    --mount=type=secret,id=no_proxy,env=NO_PROXY \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends ca-certificates
COPY certs/ /usr/local/share/ca-certificates/enterprise/
RUN update-ca-certificates

# Setup gh cli
# Cache mounts persist downloaded .debs/lists across bin/update-deps.sh's
# --no-cache rebuilds (which bypass the regular layer cache on purpose to
# re-check upstream apt versions, e.g. for a gh or rtk bump -- see
# update-deps.sh), so those rebuilds don't have to re-download unchanged
# packages just to re-verify them.
RUN --mount=type=secret,id=http_proxy,env=HTTP_PROXY \
    --mount=type=secret,id=https_proxy,env=HTTPS_PROXY \
    --mount=type=secret,id=no_proxy,env=NO_PROXY \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    (type -p wget >/dev/null || (apt update && apt install wget -y)) \
    && mkdir -p -m 755 /etc/apt/keyrings \
    && out=$(mktemp) && wget -nv -O$out https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    && cat $out | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && mkdir -p -m 755 /etc/apt/sources.list.d \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null

# Install dependencies (ca-certificates already installed above).
# See cache mount note on the gh-cli step above.
RUN --mount=type=secret,id=http_proxy,env=HTTP_PROXY \
    --mount=type=secret,id=https_proxy,env=HTTPS_PROXY \
    --mount=type=secret,id=no_proxy,env=NO_PROXY \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y \
    curl \
    git \
    python3 \
    python3-pip \
    python3-venv \
    ripgrep \
    build-essential \
    fzf \
    bsdutils \
    ncurses-base \
    gh

# Pinned by bin/update-deps.sh when a newer patch is available.
ARG NODE_VERSION=24.21.0

# Install Node.js from the official upstream tarball instead of NodeSource +
# apt: NodeSource's per-release repos can lag behind brand-new Ubuntu
# releases, silently falling back to Ubuntu's own 'nodejs' package - which,
# unlike NodeSource's, does not bundle npm.
RUN --mount=type=secret,id=http_proxy,env=HTTP_PROXY \
    --mount=type=secret,id=https_proxy,env=HTTPS_PROXY \
    --mount=type=secret,id=no_proxy,env=NO_PROXY \
    ARCH="$(dpkg --print-architecture)" \
    && case "$ARCH" in \
         amd64) NODE_ARCH=x64 ;; \
         arm64) NODE_ARCH=arm64 ;; \
         *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;; \
       esac \
    && curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.gz" -o /tmp/node.tar.gz \
    && tar -xzf /tmp/node.tar.gz -C /usr/local --strip-components=1 \
    && rm /tmp/node.tar.gz

# Create non-root user for security
RUN userdel -r ubuntu 2>/dev/null || true \
    && useradd -m -s /bin/bash -u 1000 claudecode

# Switch to non-root user
USER claudecode
WORKDIR /home/claudecode

# Configure npm for non-root global installs
RUN mkdir -p /home/claudecode/.npm-global \
    && npm config set prefix '/home/claudecode/.npm-global'

# Add npm global bin + local bin (rtk) to PATH and set terminal defaults
ENV PATH="/home/claudecode/.npm-global/bin:/home/claudecode/.local/bin:${PATH}"
ENV TERM=xterm-256color
ENV COLORTERM=truecolor

# Pin XDG dirs so claudecode always reads/writes to the mounted volumes
# (prevents workspace/.claudecode/ from shadowing the persistent data volume)
ENV XDG_DATA_HOME=/home/claudecode/.local/share
ENV XDG_CONFIG_HOME=/home/claudecode/.config

# Node doesn't consult the system CA trust store on Linux by default, so an
# enterprise CA trusted above (update-ca-certificates) wouldn't otherwise
# cover npm or the Claude Code CLI itself (both Node-based). Points at the
# full system bundle, not just the extra CA, so this is a safe no-op when
# no enterprise CA was trusted.
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt

# Pinned by bin/update-deps.sh when a newer npm release is available. Declared
# here rather than at the top of the file so bumping it only invalidates this
# layer and everything below -- not the apt/Node layers above -- mirroring the
# NODE_VERSION pattern above.
ARG CLAUDE_CODE_VERSION=2.1.278

# Install ClaudeCode via npm (more reliable than curl install script).
# The secret mounts work the same way post-USER-switch: BuildKit injects the
# env var for this RUN's process directly, independent of the RUN's UID --
# confirmed by a live build with HTTP_PROXY/HTTPS_PROXY secrets set
# (2026-09-04, see AGENTS.md "Enterprise proxy support").
RUN --mount=type=secret,id=http_proxy,env=HTTP_PROXY \
    --mount=type=secret,id=https_proxy,env=HTTPS_PROXY \
    --mount=type=secret,id=no_proxy,env=NO_PROXY \
    npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Preventive default against npm supply-chain attacks (most postinstall-
# delivered payloads -- crypto miners, credential theft, backdoors -- never
# run at all instead of only being caught after the fact by Falco's
# "Network tool executed during npm install" rule, which becomes
# defense-in-depth rather than the primary defense). Placed after this
# file's own npm install above so the build itself is unaffected either
# way. Overridable per workspace via .env (NPM_CONFIG_IGNORE_SCRIPTS=false)
# -- env_file in docker-compose.yml passes .env straight through, no
# compose change needed. Breaks packages that need postinstall for
# functionality (native binaries, puppeteer's Chromium download, husky) --
# silently, not as an install-time error -- hence the opt-out.
ENV NPM_CONFIG_IGNORE_SCRIPTS=true

# Install RTK (compresses dev-command output before it reaches the LLM
# context window) and register its Claude Code PreToolUse hook globally.
# --auto-patch is RTK's non-interactive install mode (see rtk-ai/rtk docs).
RUN --mount=type=secret,id=http_proxy,env=HTTP_PROXY \
    --mount=type=secret,id=https_proxy,env=HTTPS_PROXY \
    --mount=type=secret,id=no_proxy,env=NO_PROXY \
    mkdir -p /home/claudecode/.claude \
    && curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh \
    && rtk init -g --auto-patch

# Statusline showing live context-window usage (context_window.used_percentage
# from Claude Code's statusLine stdin payload). Merged into the settings.json
# rtk init already created above, so its PreToolUse hook is preserved.
COPY --chown=claudecode:claudecode statusline.py /home/claudecode/.claude/statusline.py
RUN chmod +x /home/claudecode/.claude/statusline.py
RUN python3 <<'EOF'
import json
p = '/home/claudecode/.claude/settings.json'
with open(p) as f:
    s = json.load(f)
s['statusLine'] = {'type': 'command', 'command': 'python3 /home/claudecode/.claude/statusline.py'}
s.setdefault('permissions', {})
# WebFetch: allow (2026-09-18, third revision) -- a live test confirmed
# WebFetch actually routes its request through this container's
# HTTP_PROXY/HTTPS_PROXY and is gated by Squid's domain allowlist same as
# curl (see falco/claude-code-rules.yaml OPEN ITEMS "Third pass" CORRECTED
# entry), so the enforcement already happens at the proxy layer regardless
# of this permission -- `allow` only drops the interactive per-use prompt,
# it does not widen what's actually reachable (a non-allowlisted domain
# still gets "proxy refused the connection" same as a bare curl call).
# WebSearch: deny (2026-09-18, later same day) -- confirmed live that
# WebSearch is the one genuinely server-side tool of the two: its actual
# search request is made by Anthropic's own backend, never touches this
# container's network namespace, so it's invisible to both Squid's domain
# allowlist and Falco regardless of SSL Bump. Unlike WebFetch there is no
# proxy layer underneath to fall back on, so permissions gating is the only
# control point -- `deny` removes the tool from context entirely. The
# read-only lockdown below still applies -- a compromised session can't
# silently rewrite either list back.
allow = set(s['permissions'].get('allow', []))
allow.add('WebFetch')
s['permissions']['allow'] = sorted(allow)
ask = set(s['permissions'].get('ask', []))
ask.discard('WebSearch')
ask.discard('WebFetch')
s['permissions']['ask'] = sorted(ask)
deny = set(s['permissions'].get('deny', []))
deny.discard('WebFetch')
deny.add('WebSearch')
s['permissions']['deny'] = sorted(deny)
with open(p, 'w') as f:
    json.dump(s, f, indent=2)
EOF

# Locks the ask/deny lists above against being edited back out from inside a
# compromised/prompt-injected session: WebSearch is a server-side tool whose
# actual outbound request is made by Anthropic's backend, not by any process
# in this container's network namespace -- invisible to both egress-proxy's
# domain allowlist and Falco (see falco/claude-code-rules.yaml OPEN ITEMS
# "Third pass" for the full writeup), so the permissions.deny above is the
# only control point that closes this gap, and it only works if claudecode
# (UID 1000, the same user a compromised session runs as) can't just rewrite
# it. Same "sandboxed UID can read, not write" pattern already used for
# /workspace/.squid-claudecode-docker (see docker-compose.yml).
# settings.json only holds build-time config (hooks/statusLine/theme/
# permissions) -- confirmed nothing later in this Dockerfile or
# entrypoint.sh writes to it -- so dropping its write bits doesn't break
# normal operation; per-session state lives in ~/.claude.json instead, which
# stays writable.
USER root
RUN chown root:root /home/claudecode/.claude/settings.json \
    && chmod 644 /home/claudecode/.claude/settings.json
USER claudecode

# Create directories for persistent config
RUN mkdir -p /home/claudecode/.config/claudecode /home/claudecode/.local/share/claudecode

# Copy entrypoint script
COPY entrypoint.sh /home/claudecode/entrypoint.sh

# Set working directory
WORKDIR /workspace

# Declared/used this late (not at the top) so BUILD_DATE -- which changes on
# every single build -- doesn't cascade-invalidate the cache for every layer
# above it. Stamped by bin/update-deps.sh so a running container's build can
# be identified via 'docker ps --format ...' without shelling into it, since
# the image is always tagged claude-code:latest regardless of which build it is.
ARG BUILD_DATE=unknown
LABEL dev.claudecode-docker.version="${CLAUDE_CODE_VERSION}"
LABEL dev.claudecode-docker.build-date="${BUILD_DATE}"

ENTRYPOINT ["/home/claudecode/entrypoint.sh"]
