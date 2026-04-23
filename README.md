# Claude Code Docker

Run [Claude Code](https://claude.ai/code) in a persistent, sandboxed Docker container. Mount any project directory, attach and detach freely, and let the container keep running in the background.

## Why?

Anthropic provides a [reference devcontainer](https://github.com/anthropics/claude-code/tree/main/.devcontainer) that works well with VS Code Dev Containers. This project solves a different problem: **running Claude Code headlessly from a terminal, with persistent containers you can reconnect to.**

The official devcontainer is designed for IDE integration. If you want to:

- Run Claude Code against **any directory** by just pointing a config at it
- Keep the container **alive between sessions** so setup (firewall, plugins, SSH) only happens once
- **Attach and detach** from your terminal without losing the container
- Run **multiple named sessions** side by side (one per project, or multiple per project)
- Forward **SSH keys** and **plugins/skills** from your host without manual setup

...then this is for you.

## What's different from the official devcontainer?

| | Official devcontainer | This project |
|---|---|---|
| **Target** | VS Code Dev Containers | Standalone terminal use |
| **Container lifecycle** | Managed by VS Code | Persistent, managed by `run-claude.sh` |
| **Workspace** | Baked into devcontainer.json | Configurable per-session via conf file |
| **Reconnect** | VS Code handles it | Re-run `./run-claude.sh` to attach |
| **Multiple sessions** | One per window | Named sessions, run in parallel |
| **Auth** | Manual setup | Keychain / credential file / API key |
| **SSH** | Manual setup | Key file / agent forwarding / none |
| **Plugins** | Manual install | Shared via `~/.claude` mount |

## Quick start

```bash
# 1. Clone
git clone https://github.com/cdowin/claude-code-docker.git
cd claude-code-docker

# 2. (Optional) Configure — works without a conf on macOS with keychain auth
cp claude-docker.conf.example claude-docker.conf

# 3. Run
./run-claude.sh
```

This builds the image, starts a detached container, waits for setup (firewall, SSH, plugins), then attaches an interactive Claude Code session.

### Pre-built images

Pre-built multi-arch images (amd64 + arm64) are published to GitHub Container Registry:

```bash
# Use the pre-built image instead of building locally
./run-claude.sh --image ghcr.io/cdowin/claude-code-docker

# Or set it as default in claude-docker.conf
IMAGE_NAME="ghcr.io/cdowin/claude-code-docker"
```

When `IMAGE_NAME` points to a registry (contains `/`), the script pulls instead of building locally.

## Usage

```bash
# Start in current directory (default session)
./run-claude.sh

# Named session — mounts $PWD as workspace
./run-claude.sh my-project

# Override workspace directory
./run-claude.sh my-project --work-dir ~/other/repo

# Use a different Docker image (e.g. a derived image with extra tools)
./run-claude.sh my-project --image ghcr.io/cdowin/claude-code-godot-docker

# Pass args to claude
./run-claude.sh my-project --model opus
./run-claude.sh my-project --work-dir ~/other/repo --model opus

# Multiple terminals on the same container
# (each gets an independent Claude process, shared workspace)
./run-claude.sh my-project        # terminal 1
./run-claude.sh my-project        # terminal 2

# List running sessions
./run-claude.sh list

# Stop a session
./run-claude.sh stop my-project

# Stop all sessions
./run-claude.sh stop-all
```

When you Ctrl+C or close your terminal, only the Claude process exits. The container stays running. Re-run the same command to start a fresh Claude session in the existing container — no rebuild, no re-setup.

## Configuration

All configuration lives in `claude-docker.conf` (gitignored). See `claude-docker.conf.example` for all options with comments.

### Authentication (pick one)

| Method | When to use |
|--------|------------|
| `keychain` | macOS — reads OAuth creds from Keychain automatically |
| `file` | Linux / CI — point to a `.credentials.json` on disk |
| `api-key` | API key auth — pass `ANTHROPIC_API_KEY` directly |

### SSH for Git (pick one)

| Method | When to use |
|--------|------------|
| `key-file` | Mount a specific private key (default) |
| `agent` | Forward your ssh-agent into the container |
| `none` | Use HTTPS for git, no SSH |

### Claude state

Your entire `~/.claude` directory is mounted read-write into the container. This means the container shares your host's identity — settings, credentials, plugins, onboarding state, session history all carry over. No separate setup needed.

See `settings.json.example` for recommended settings:

```json
{
  "alwaysThinkingEnabled": true,
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 0
  },
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
    "SHIPYARD_TEAMS_ENABLED": "true"
  }
}
```

| Setting | What it does |
|---------|-------------|
| `alwaysThinkingEnabled` | Extended thinking on every response — better reasoning |
| `statusLine` | Rich status bar showing context usage, cost, burn rate, git branch, session time |
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | [Agent teams](https://code.claude.com/docs/en/agent-teams) — multiple Claude sessions coordinating via shared task list |
| `SHIPYARD_TEAMS_ENABLED` | Enables team features in the [Shipyard](https://github.com/lgbarn/shipyard) plugin |

### Status line

A `statusline.sh` script is included that shows context usage, auth token expiry, rate limit usage (5-hour window), and token throughput. To use it:

```bash
cp statusline.sh ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

Then add the `statusLine` block to your `~/.claude/settings.json` (see above). Requires `jq` for full functionality. Rate limit data comes from Claude Code's native `rate_limits` field (v2.1.80+) — no external tools needed.

## How it works

```
run-claude.sh
├── Reads claude-docker.conf
├── Builds image (Dockerfile) or pulls from registry
├── Starts detached container
│   └── entrypoint.sh (runs as root)
│       ├── init-firewall.sh — iptables allowlist (Anthropic API, GitHub, SSH)
│       ├── Strip suid/sgid bits
│       ├── Configure SSH keys
│       ├── Touch /tmp/.claude-ready
│       └── sleep infinity (keeps container alive)
└── docker exec — runs Claude Code as non-root user
```

### Security

- **Network firewall**: Only Anthropic API, GitHub, plugin marketplace (downloads.claude.ai), and SSH traffic allowed. Everything else is rejected at the iptables level. Add more domains via `EXTRA_ALLOWED_DOMAINS` — e.g. for the Atlassian MCP, add your instance: `EXTRA_ALLOWED_DOMAINS="yourorg.atlassian.net"` (the base `api.atlassian.com` and `atlassian.net` apex are already allowed, but `*.atlassian.net` subdomains can't be wildcarded and must be listed individually).
- **Non-root execution**: Claude Code runs as an unprivileged `claude` user. Entrypoint runs as root only for firewall setup, then drops privileges.
- **No suid/sgid**: All suid/sgid bits stripped after firewall setup.
- **Shared state**: `~/.claude` is mounted read-write so the container behaves as your host's Claude identity. SSH keys are mounted read-only.

## Derived images

This image is designed to be extended. Create a child Dockerfile for project-specific tooling:

```dockerfile
FROM ghcr.io/cdowin/claude-code-docker:latest
RUN apt-get update && apt-get install -y your-tools
```

Then use `--image` to run it, or set `IMAGE_NAME` in your conf. See [claude-code-godot-docker](https://github.com/cdowin/claude-code-godot-docker) for an example that adds Godot game engine support.

## Requirements

- Docker Desktop
- **macOS** (currently the only tested/supported host)
- Claude Code account (OAuth login on host, or API key)

> **Note:** This project is built and tested on macOS. The default auth method (`keychain`) uses macOS Keychain, `gh` tokens are extracted via macOS keychain, and the timezone sync relies on macOS paths. Linux host support is possible with the `file` or `api-key` auth methods and manual `GH_TOKEN` setup, but is untested.

## License

MIT
