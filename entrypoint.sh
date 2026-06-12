#!/bin/bash
set -e

# Run firewall setup as root
/usr/local/bin/init-firewall.sh

# Remove suid/sgid binaries so claude user can't escalate
echo "Stripping suid/sgid bits..."
find /usr /bin /sbin -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true

# Fix ownership on mounted directories so claude user can read/write them
chown -R claude:claude /home/claude/.claude 2>/dev/null || true
chown -R claude:claude /workspace 2>/dev/null || true

# Symlink host user's home path so plugin absolute paths resolve inside container.
# Marketplace configs store the host's absolute path (e.g. /Users/cdowin/.claude/...)
# which doesn't exist in the container where ~/.claude is at /home/claude/.claude.
HOST_HOME="${HOST_HOME:-}"
if [ -n "$HOST_HOME" ] && [ "$HOST_HOME" != "/home/claude" ]; then
  mkdir -p "$(dirname "$HOST_HOME")"
  ln -sfn /home/claude "$HOST_HOME"
fi

# Copy credentials extracted from host keychain (overwrites mounted version)
if [ -f /mnt/host-credentials.json ]; then
  cp /mnt/host-credentials.json /home/claude/.claude/.credentials.json
  chmod 600 /home/claude/.claude/.credentials.json
  chown claude:claude /home/claude/.claude/.credentials.json
fi

# Generate minimal .claude.json to skip onboarding wizard
# Claude Code requires this file with hasCompletedOnboarding to skip first-run setup
echo '{"hasCompletedOnboarding":true,"installMethod":"native"}' > /home/claude/.claude/.claude.json
ln -sf /home/claude/.claude/.claude.json /home/claude/.claude.json
chown claude:claude /home/claude/.claude/.claude.json /home/claude/.claude.json

# ── Plugin bootstrap ─────────────────────────────────────────────
# Install the declarative plugin set into the isolated plugin volume (mounted
# at ~/.claude/plugins). PLUGIN_MARKETPLACES and PLUGINS come from
# claude-docker.conf via env. Idempotent: marketplaces/plugins already present
# are skipped, so this only does real work on first run (or when an entry is
# added). Runs as the claude user with HOME set explicitly — gosu does not set
# HOME, and a wrong HOME would install plugins to the wrong place. GitHub
# sources only by default: the firewall allowlists GitHub; other sources need
# init-firewall.sh + EXTRA_ALLOWED_DOMAINS changes or the install will hang.
run_as_claude() { gosu claude env HOME=/home/claude PATH="$PATH" "$@"; }
if [ -n "${PLUGINS:-}" ]; then
  echo "Bootstrapping plugins into volume..."
  for mp in ${PLUGIN_MARKETPLACES:-}; do
    if run_as_claude claude plugin marketplace add "$mp" >/dev/null 2>&1; then
      echo "  + marketplace added: $mp"
    else
      echo "  · marketplace present/skipped: $mp"
    fi
  done
  installed="$(run_as_claude claude plugin list 2>/dev/null || true)"
  for p in $PLUGINS; do
    if printf '%s\n' "$installed" | grep -qF "${p%@*}"; then
      echo "  · already installed: $p"
    elif run_as_claude claude plugin install "$p" >/dev/null 2>&1; then
      echo "  + installed: $p"
    else
      echo "  ! FAILED: $p (check marketplace name / firewall allowlist)"
    fi
  done
  echo "Plugin bootstrap done."
fi

# ── Claude Code self-update ──────────────────────────────────────
# Pull the latest CLI on every start so newer model defaults (e.g. Opus 4.8)
# are picked up without rebuilding the image. Runs as the claude user — the
# binary lives in /home/claude/.local/bin and self-updates there. Needs the
# firewall up (claude.ai allowlisted, done above) and network reachable.
# Non-fatal: a transient failure must not block container startup (set -e).
echo "Updating Claude Code..."
if run_as_claude claude update; then
  echo "Claude Code: $(run_as_claude claude --version 2>/dev/null || echo unknown)"
else
  echo "Claude Code update skipped (offline or unreachable) — using bundled version."
fi

# Set up SSH based on method passed via environment
SSH_METHOD="${SSH_METHOD:-none}"
if [ "$SSH_METHOD" != "none" ]; then
  echo "Configuring SSH ($SSH_METHOD)..."
  mkdir -p /home/claude/.ssh

  case "$SSH_METHOD" in
    key-file)
      # Copy the read-only mounted key so we can set ownership and permissions
      cp /home/claude/.ssh/user_key /home/claude/.ssh/id_key
      chmod 600 /home/claude/.ssh/id_key
      cat > /home/claude/.ssh/config <<'SSHEOF'
Host *
    User git
    IdentityFile /home/claude/.ssh/id_key
    StrictHostKeyChecking accept-new
SSHEOF
      ;;
    agent)
      cat > /home/claude/.ssh/config <<'SSHEOF'
Host *
    User git
    StrictHostKeyChecking accept-new
SSHEOF
      ;;
  esac

  chmod 700 /home/claude/.ssh
  chmod 600 /home/claude/.ssh/config
  # chown only the files we own — skip read-only mounted user_key
  chown claude:claude /home/claude/.ssh /home/claude/.ssh/config
  [ -f /home/claude/.ssh/id_key ] && chown claude:claude /home/claude/.ssh/id_key
fi

# Signal that setup is complete
touch /tmp/.claude-ready

# Keep container alive — Claude runs via `docker exec`
echo "Container ready. Waiting for connections..."
exec sleep infinity
