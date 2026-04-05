#!/bin/bash
set -e

# Run firewall setup as root
/usr/local/bin/init-firewall.sh

# Remove suid/sgid binaries so claude user can't escalate
echo "Stripping suid/sgid bits..."
find /usr /bin /sbin -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true

# Copy credentials so Claude Code can refresh OAuth tokens (host file is ro)
if [ -f /mnt/host-credentials.json ]; then
  cp /mnt/host-credentials.json /home/claude/.claude/.credentials.json
  chmod 600 /home/claude/.claude/.credentials.json
  chown claude:claude /home/claude/.claude/.credentials.json
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

# Set up plugins
PLUGINS_METHOD="${PLUGINS_METHOD:-none}"
case "$PLUGINS_METHOD" in
  mount)
    # Host plugins are mounted read-only at /mnt/host-plugins.
    # Copy them to the real location so Claude Code can write state,
    # and rewrite absolute host paths to container paths.
    if [ -d /mnt/host-plugins ]; then
      echo "Copying host plugins..."
      mkdir -p /home/claude/.claude/plugins
      # Copy plugins preserving .git (plugin system needs it for marketplace validation)
      rsync -a /mnt/host-plugins/ /home/claude/.claude/plugins/
      # Rewrite absolute host paths to container paths in all manifests
      for manifest in installed_plugins.json known_marketplaces.json; do
        target="/home/claude/.claude/plugins/$manifest"
        if [ -f "$target" ]; then
          sed -i "s|$HOST_HOME_DIR/.claude/plugins|/home/claude/.claude/plugins|g" "$target"
        fi
      done
      chown -R claude:claude /home/claude/.claude/plugins
      # Verify key directories exist
      echo "Plugins copied. Directories:"
      ls -d /home/claude/.claude/plugins/marketplaces/*/ 2>/dev/null || echo "  WARN: No marketplace dirs found"
      ls -d /home/claude/.claude/plugins/cache/*/ 2>/dev/null || echo "  WARN: No cache dirs found"
    else
      echo "WARN: PLUGINS_METHOD=mount but no host plugins found at /mnt/host-plugins"
    fi
    ;;
  install)
    if [ -n "${PLUGINS_INSTALL_LIST:-}" ]; then
      echo "Installing plugins: $PLUGINS_INSTALL_LIST"
      for plugin in $PLUGINS_INSTALL_LIST; do
        gosu claude claude plugins install "$plugin" 2>&1 || echo "WARN: Failed to install plugin '$plugin'"
      done
    fi
    ;;
esac

# Signal that setup is complete
touch /tmp/.claude-ready

# Keep container alive — Claude runs via `docker exec`
echo "Container ready. Waiting for connections..."
exec sleep infinity
