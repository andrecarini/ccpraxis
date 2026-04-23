FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    wget \
    ca-certificates \
    build-essential \
    jq \
    unzip \
    openssh-client \
    perl \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN useradd -m -s /bin/bash -u 1000 claude
USER claude

# Install Claude Code via native installer
ARG CLAUDE_VERSION=latest
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- ${CLAUDE_VERSION}
ENV PATH="/home/claude/.local/bin:${PATH}"

# Terminal — enable 24-bit color support (matches host terminal)
ENV TERM=xterm-256color
ENV COLORTERM=truecolor

# Supply chain hardening — env vars take effect whenever runtimes are installed
ENV npm_config_ignore_scripts=true
ENV NODE_OPTIONS="--dns-result-order=ipv4first"

# Git defaults
RUN git config --global core.autocrlf input \
    && git config --global init.defaultBranch main

WORKDIR /project
ENTRYPOINT ["/bin/bash", "-c", "START=$SECONDS; while [ $((SECONDS - START)) -lt 15 ] || pgrep -x -u claude claude > /dev/null; do sleep 3; done"]
