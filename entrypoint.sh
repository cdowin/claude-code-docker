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

# Copy credentials extracted from host keychain (overwrites mounted version)
if [ -f /mnt/host-credentials.json ]; then
  cp /mnt/host-credentials.json /home/claude/.claude/.credentials.json
  chmod 600 /home/claude/.claude/.credentials.json
  chown claude:claude /home/claude/.claude/.credentials.json
fi

# Copy .claude.json so container has its own writable copy
if [ -f /mnt/host-claude.json ]; then
  sed 's/"installMethod":\s*"[^"]*"/"installMethod": "npm"/' /mnt/host-claude.json > /home/claude/.claude.json
  chown claude:claude /home/claude/.claude.json
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
