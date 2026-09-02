# syntax=docker/dockerfile:1

FROM ubuntu:26.04

# Metadata
LABEL maintainer="claudecode-docker"
LABEL description="Isolated Docker environment for ClaudeCode"
LABEL version="1.0"

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Enterprise network support, part 1: forward-proxy for build-time RUN steps
# (apt/curl/npm/gh/rtk below all fetch over the network during the build).
# Empty by default (no-op for the normal, non-enterprise build). Compose's
# `environment:` block for the running claude-code container already sets
# its own HTTP_PROXY/HTTPS_PROXY (pointing at egress-proxy) and overrides
# whatever is baked in here as an image ENV default, so there's no runtime
# conflict — these only affect this build.
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ENV HTTP_PROXY=${HTTP_PROXY} \
    HTTPS_PROXY=${HTTPS_PROXY} \
    NO_PROXY=${NO_PROXY}

# Enterprise network support, part 2: trust an optional corporate root CA
# (for TLS-intercepting corporate proxies) before any RUN step below makes
# an HTTPS request. certs/ is empty by default, so update-ca-certificates
# is a no-op for the normal build. Must run as root, before USER claudecode
# below, since claude-code runs non-root at runtime (see AGENTS.md).
# ca-certificates isn't guaranteed present in the base ubuntu:26.04 image
# (confirmed: it isn't), so it's installed explicitly before relying on it.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
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
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
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
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
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
ARG NODE_VERSION=24.20.0

# Install Node.js from the official upstream tarball instead of NodeSource +
# apt: NodeSource's per-release repos can lag behind brand-new Ubuntu
# releases, silently falling back to Ubuntu's own 'nodejs' package - which,
# unlike NodeSource's, does not bundle npm.
RUN ARCH="$(dpkg --print-architecture)" \
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
ARG CLAUDE_CODE_VERSION=2.1.258

# Install ClaudeCode via npm (more reliable than curl install script)
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Install RTK (compresses dev-command output before it reaches the LLM
# context window) and register its Claude Code PreToolUse hook globally.
# --auto-patch is RTK's non-interactive install mode (see rtk-ai/rtk docs).
RUN mkdir -p /home/claudecode/.claude \
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
with open(p, 'w') as f:
    json.dump(s, f, indent=2)
EOF

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
