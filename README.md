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
| **Plugins** | Manual install | Mount from host or auto-install |

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

## Usage

```bash
# Start in current directory (default session)
./run-claude.sh

# Named session — mounts $PWD as workspace
./run-claude.sh my-project

# Override workspace directory
./run-claude.sh my-project --work-dir ~/other/repo

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

### Plugins (pick one)

| Method | When to use |
|--------|------------|
| `mount` | Copy plugins from host `~/.claude/plugins` (fast, no network) |
| `install` | Fresh install from marketplace at startup (always latest) |
| `none` | No plugins |

### Settings

Your host `~/.claude/settings.json` is mounted into the container automatically. Any settings you configure locally apply inside Docker too.

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

A `statusline.sh` script is included that shows context remaining, cost tracking, tokens/minute, and session time. To use it:

```bash
cp statusline.sh ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

Then add the `statusLine` block to your `~/.claude/settings.json` (see above). Requires `jq` for full functionality. Optionally install [ccusage](https://github.com/ryoppippi/ccusage) for session time tracking.

## How it works

```
run-claude.sh
├── Reads claude-docker.conf
├── Builds image (Dockerfile)
├── Starts detached container
│   └── entrypoint.sh (runs as root)
│       ├── init-firewall.sh — iptables allowlist (Anthropic API, GitHub, SSH)
│       ├── Strip suid/sgid bits
│       ├── Copy credentials, SSH keys, plugins
│       ├── Touch /tmp/.claude-ready
│       └── sleep infinity (keeps container alive)
└── docker exec — runs Claude Code as non-root user
```

### Security

- **Network firewall**: Only Anthropic API, GitHub, and SSH traffic allowed. Everything else is rejected at the iptables level. Add more domains via `EXTRA_ALLOWED_DOMAINS`.
- **Non-root execution**: Claude Code runs as an unprivileged `claude` user. Entrypoint runs as root only for firewall setup, then drops privileges.
- **No suid/sgid**: All suid/sgid bits stripped after firewall setup.
- **Read-only mounts**: Credentials, SSH keys, and plugins are mounted read-only and copied inside the container.

## Requirements

- Docker
- macOS or Linux host
- Claude Code account (OAuth login on host, or API key)

## License

MIT
