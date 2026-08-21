FROM ubuntu:26.04

# Metadata
LABEL maintainer="claudecode-docker"
LABEL description="Isolated Docker environment for ClaudeCode"
LABEL version="1.0"

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Setup gh cli
RUN (type -p wget >/dev/null || (apt update && apt install wget -y)) \
    && mkdir -p -m 755 /etc/apt/keyrings \
    && out=$(mktemp) && wget -nv -O$out https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    && cat $out | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && mkdir -p -m 755 /etc/apt/sources.list.d \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null

RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install dependencies
RUN apt-get update && apt-get install -y \
    curl \
    git \
    python3 \
    python3-pip \
    python3-venv \
    npm \
    ripgrep \
    build-essential \
    ca-certificates \
    fzf \
    bsdutils \
    ncurses-base \
    gh \
    && rm -rf /var/lib/apt/lists/*

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

# Install ClaudeCode via npm (more reliable than curl install script)
RUN npm install -g @anthropic-ai/claude-code

# Install RTK (compresses dev-command output before it reaches the LLM
# context window) and register its Claude Code PreToolUse hook globally.
# --auto-patch is RTK's non-interactive install mode (see rtk-ai/rtk docs).
RUN curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh \
    && rtk init -g --auto-patch

# Create directories for persistent config
RUN mkdir -p /home/claudecode/.config/claudecode /home/claudecode/.local/share/claudecode

# Copy entrypoint script
COPY entrypoint.sh /home/claudecode/entrypoint.sh

# Set working directory
WORKDIR /workspace

ENTRYPOINT ["/home/claudecode/entrypoint.sh"]
