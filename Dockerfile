FROM node:22-slim

ARG CLAUDE_CODE_VERSION=latest

# Install tools Claude Code needs + firewall deps + PDF generation
RUN apt-get update && apt-get install -y --no-install-recommends \
  curl \
  git \
  openssh-client \
  jq \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  gosu \
  python3 \
  pandoc \
  weasyprint \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Create non-root user — entrypoint chowns mounted files at runtime
RUN useradd -m -s /bin/bash claude && \
  mkdir -p /home/claude/.claude /workspace && \
  chown -R claude:claude /home/claude /workspace

# Install Claude Code via npm
ENV DEVCONTAINER=true
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Copy firewall + entrypoint scripts (root-owned, not writable by claude)
COPY init-firewall.sh /usr/local/bin/
COPY entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh

WORKDIR /workspace

# Entrypoint runs as root: sets firewall, then drops to claude user
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
