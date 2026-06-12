FROM node:22-slim

# Install tools Claude Code needs + firewall deps + PDF generation + browser rendering
RUN apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  git \
  openssh-client \
  jq \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  gosu \
  procps \
  python3 \
  python3-pip \
  pandoc \
  weasyprint \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install gh CLI (separate layer — needs ca-certificates for HTTPS)
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update && apt-get install -y --no-install-recommends gh \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Create non-root user — entrypoint chowns mounted files at runtime
RUN useradd -m -s /bin/bash claude && \
  mkdir -p /home/claude/.claude /workspace && \
  chown -R claude:claude /home/claude /workspace

# Headless Chromium for visual verification (HTML→PNG screenshots). Baked in at
# build time because the running session has no root and a locked firewall (the
# Playwright/Chrome download CDNs are blocked), so it cannot fetch a browser
# later — only what ships in the image is usable offline. Two steps because the
# pieces have different owners: the system libraries (libnss3/libgbm/fonts/…)
# need root via apt, while the browser binary must be installed AS claude so its
# cache lands in /home/claude/.cache/ms-playwright — that home is not a mount, so
# it persists into the session and is owned by the user that runs it.
RUN pip3 install --no-cache-dir --break-system-packages playwright \
  && apt-get update \
  && python3 -m playwright install-deps chromium \
  && apt-get clean && rm -rf /var/lib/apt/lists/*
RUN su - claude -c "python3 -m playwright install chromium"

# ccusage (usage tracker) still ships via npm
ENV DEVCONTAINER=true
RUN npm install -g ccusage

# Claude Code via native installer (npm package deprecated). Installs to
# /home/claude/.local/bin/claude and self-updates from claude.ai at runtime —
# both domains are allowlisted in init-firewall.sh.
# CACHEBUST forces a fresh download: `docker build --build-arg CACHEBUST=$(date +%s) ...`
ARG CACHEBUST=1
ENV PATH=/home/claude/.local/bin:$PATH
RUN su - claude -c "curl -fsSL https://claude.ai/install.sh | bash"

# Copy firewall + entrypoint + helper scripts (root-owned, not writable by claude)
COPY init-firewall.sh /usr/local/bin/
COPY entrypoint.sh /usr/local/bin/
COPY render-html /usr/local/bin/
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh /usr/local/bin/render-html

WORKDIR /workspace

# Entrypoint runs as root: sets firewall, then drops to claude user
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
