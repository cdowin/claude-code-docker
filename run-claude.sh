#!/bin/bash
# Build and run Claude Code in Docker with configurable workspace, auth, and SSH.
# Container runs detached — re-run this script to attach a new Claude session.
#
# Usage:
#   ./run-claude.sh                                  # session "default", mounts $PWD
#   ./run-claude.sh my-project                       # named session, mounts $PWD
#   ./run-claude.sh my-project --work-dir ~/repo     # override workspace
#   ./run-claude.sh my-project --model opus          # pass args to claude
#   ./run-claude.sh list                             # show running sessions
#   ./run-claude.sh stop my-project                  # stop a session
#   ./run-claude.sh stop-all                         # stop all sessions

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Subcommands ──────────────────────────────────────────────────
case "${1:-}" in
  list|ls)
    echo "Running Claude sessions:"
    docker ps --filter "name=claude-" --format "  {{.Names}}\t{{.Status}}\t{{.RunningFor}}" 2>/dev/null || true
    exit 0
    ;;
  stop)
    target="${2:?Usage: $0 stop <session-name>}"
    docker rm -f "claude-${target}" 2>/dev/null && echo "Stopped claude-${target}" || echo "No session named '${target}'"
    exit 0
    ;;
  stop-all)
    docker ps -q --filter "name=claude-" | xargs -r docker rm -f
    echo "All Claude sessions stopped."
    exit 0
    ;;
esac

# ── Session name (first arg) ────────────────────────────────────
SESSION_NAME="${1:-default}"
shift 2>/dev/null || true

# ── Parse --work-dir flag ────────────────────────────────────────
WORKSPACE_OVERRIDE=""
CLAUDE_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --work-dir)
      WORKSPACE_OVERRIDE="$(cd "$2" && pwd)"
      shift 2
      ;;
    *)
      CLAUDE_ARGS+=("$1")
      shift
      ;;
  esac
done
set -- "${CLAUDE_ARGS[@]+"${CLAUDE_ARGS[@]}"}"

CONF="$SCRIPT_DIR/claude-docker.conf"
if [ -f "$CONF" ]; then
  source "$CONF"
fi

# ── Defaults ─────────────────────────────────────────────────────
IMAGE_NAME="${IMAGE_NAME:-claude-code}"
AUTH_METHOD="${AUTH_METHOD:-keychain}"
SSH_METHOD="${SSH_METHOD:-key-file}"
CLAUDE_DIR="$HOME/.claude"

# ── Resolve workspace: override > conf > $PWD ────────────────────
if [ -n "$WORKSPACE_OVERRIDE" ]; then
  WORKSPACE_DIR="$WORKSPACE_OVERRIDE"
elif [ -z "${WORKSPACE_DIR:-}" ]; then
  WORKSPACE_DIR="$PWD"
fi

if [ ! -d "$WORKSPACE_DIR" ]; then
  echo "ERROR: Workspace does not exist: $WORKSPACE_DIR"
  exit 1
fi

# ── Resolve credentials ─────────────────────────────────────────
CREDS_FILE=""
EXTRA_ENV=()

case "$AUTH_METHOD" in
  keychain)
    if ! command -v security &>/dev/null; then
      echo "ERROR: AUTH_METHOD=keychain but 'security' command not found (not macOS?)."
      exit 1
    fi
    KEYCHAIN_ACCOUNT="${KEYCHAIN_ACCOUNT:-$(whoami)}"
    CREDS=$(security find-generic-password -s "Claude Code-credentials" -a "$KEYCHAIN_ACCOUNT" -w 2>/dev/null)
    if [ -z "$CREDS" ]; then
      echo "ERROR: Could not read credentials from keychain for account '$KEYCHAIN_ACCOUNT'."
      echo "Make sure you're logged in via 'claude' on the host first."
      exit 1
    fi
    mkdir -p "$CLAUDE_DIR"
    CREDS_FILE="$CLAUDE_DIR/.credentials.json"
    echo "$CREDS" > "$CREDS_FILE"
    chmod 600 "$CREDS_FILE"
    ;;
  file)
    CREDENTIALS_FILE="${CREDENTIALS_FILE:?Set CREDENTIALS_FILE in claude-docker.conf}"
    if [ ! -f "$CREDENTIALS_FILE" ]; then
      echo "ERROR: CREDENTIALS_FILE does not exist: $CREDENTIALS_FILE"
      exit 1
    fi
    CREDS_FILE="$CREDENTIALS_FILE"
    ;;
  api-key)
    ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:?Set ANTHROPIC_API_KEY in claude-docker.conf}"
    EXTRA_ENV+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
    ;;
  *)
    echo "ERROR: Unknown AUTH_METHOD '$AUTH_METHOD'. Use: keychain, file, or api-key."
    exit 1
    ;;
esac

# ── Resolve SSH ──────────────────────────────────────────────────
SSH_ARGS=()

case "$SSH_METHOD" in
  key-file)
    if [ -z "${SSH_KEY_PATH:-}" ]; then
      for key in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa" "$HOME/.ssh/id_ecdsa"; do
        if [ -f "$key" ]; then
          SSH_KEY_PATH="$key"
          break
        fi
      done
    fi
    if [ -z "${SSH_KEY_PATH:-}" ] || [ ! -f "$SSH_KEY_PATH" ]; then
      echo "ERROR: No SSH key found. Set SSH_KEY_PATH or use SSH_METHOD=none."
      exit 1
    fi
    SSH_ARGS+=(-v "$SSH_KEY_PATH:/home/claude/.ssh/user_key:ro")
    SSH_ARGS+=(-e "SSH_METHOD=key-file")
    ;;
  agent)
    if [ -z "${SSH_AUTH_SOCK:-}" ]; then
      echo "ERROR: SSH_METHOD=agent but SSH_AUTH_SOCK is not set. Is ssh-agent running?"
      exit 1
    fi
    SSH_ARGS+=(-v "$SSH_AUTH_SOCK:/run/ssh-agent.sock")
    SSH_ARGS+=(-e "SSH_AUTH_SOCK=/run/ssh-agent.sock")
    SSH_ARGS+=(-e "SSH_METHOD=agent")
    ;;
  none)
    SSH_ARGS+=(-e "SSH_METHOD=none")
    ;;
  *)
    echo "ERROR: Unknown SSH_METHOD '$SSH_METHOD'. Use: key-file, agent, or none."
    exit 1
    ;;
esac

# ── Pass extra allowed domains to firewall ───────────────────────
if [ -n "${EXTRA_ALLOWED_DOMAINS:-}" ]; then
  EXTRA_ENV+=(-e "EXTRA_ALLOWED_DOMAINS=$EXTRA_ALLOWED_DOMAINS")
fi

# ── Build ────────────────────────────────────────────────────────
docker build -t "$IMAGE_NAME" --build-arg HOST_UID="$(id -u)" -f "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR"

# ── Claude state mount ──────────────────────────────────────────
# Mount the entire ~/.claude directory so all state carries over:
# credentials, settings, statsig, onboarding, session history, etc.
CLAUDE_STATE_ARGS=()
if [ -d "$CLAUDE_DIR" ]; then
  CLAUDE_STATE_ARGS+=(-v "$CLAUDE_DIR:/home/claude/.claude")
fi

# Mount .claude.json if it exists (session state)
SESSION_ARGS=()
if [ -f "$HOME/.claude.json" ]; then
  SESSION_ARGS+=(-v "$HOME/.claude.json:/home/claude/.claude.json")
fi

# ── Container name ───────────────────────────────────────────────
CONTAINER_NAME="claude-${SESSION_NAME}"

# ── Reconnect if container is already running ────────────────────
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  if [ -n "$WORKSPACE_OVERRIDE" ]; then
    echo "WARN: Container '$SESSION_NAME' is already running. Workspace override ignored."
    echo "      Stop it first to change workspace: $0 stop $SESSION_NAME"
  fi
  echo "Attaching to existing container '$SESSION_NAME'..."
  exec docker exec -it "$CONTAINER_NAME" gosu claude claude --dangerously-skip-permissions "$@"
fi

# Clean up any stopped container with the same name
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

# ── Run ──────────────────────────────────────────────────────────
docker run -d \
  --name "$CONTAINER_NAME" \
  --cap-add=NET_ADMIN \
  --cap-add=NET_RAW \
  "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}" \
  "${SSH_ARGS[@]+"${SSH_ARGS[@]}"}" \
  "${CLAUDE_STATE_ARGS[@]+"${CLAUDE_STATE_ARGS[@]}"}" \
  "${SESSION_ARGS[@]+"${SESSION_ARGS[@]}"}" \
  -v "$WORKSPACE_DIR:/workspace" \
  "$IMAGE_NAME"

# Wait for setup (firewall, plugins) to finish
echo "Container started. Waiting for setup..."
for i in $(seq 1 30); do
  if docker exec "$CONTAINER_NAME" test -f /tmp/.claude-ready 2>/dev/null; then
    echo "Attaching..."
    exec docker exec -it "$CONTAINER_NAME" gosu claude claude --dangerously-skip-permissions "$@"
  fi
  sleep 1
done
echo "ERROR: Container setup did not complete within 30s. Check: docker logs $CONTAINER_NAME"
exit 1
