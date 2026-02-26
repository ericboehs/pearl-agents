# PEARL Agents

**P**rotected **E**ARL — Docker-isolated agent profiles for [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

Each agent runs in an ephemeral Docker container with scoped credentials, volume-mounted skills, and no host access beyond what's explicitly configured.

## Quick Start

```bash
# 1. Build images
docker build -t pearl-base:latest agents/base/
docker build -t pearl-code:latest agents/code/

# 2. Run — setup wizard runs automatically on first use
bin/pearl code "What tools do you have? List your versions."
```

Or configure explicitly:

```bash
# Interactive setup wizard
bin/pearl setup code

# List available agents and their config status
bin/pearl setup
```

## Architecture

```
pearl-agents/
├── agents/
│   ├── base/             # Base image: node + claude-cli + git + dumb-init
│   └── code/             # Code agent: + ruby, python, go, build-essential
│       ├── skills/       # Volume-mounted at /skills (no rebuild needed)
│       │   ├── CLAUDE.md
│       │   └── references/
│       └── tools/        # Custom CLI scripts (baked into image)
├── bin/
│   ├── pearl             # Wrapper script (handles auth, mounts, docker run)
│   ├── pearl-setup       # Interactive setup wizard
│   └── test-agent        # Smoke test for built images
└── examples/
    ├── env.apikey.example
    ├── env.keychain.example
    └── env.proxy.example
```

### Image Layers

```
node:22-bookworm-slim
  └── pearl-base          # claude-cli, git, dumb-init, ripgrep, jq
        └── pearl-code    # ruby, python, go, build-essential, shellcheck
        └── pearl-pptx    # (future) libreoffice, python-pptx
```

### Runtime Mounts

| Mount | Source | Target | Purpose |
|-------|--------|--------|---------|
| Skills | `agents/<name>/skills/` | `/skills` (ro) | CLAUDE.md + reference docs |
| Workspace | `$(pwd)` | `/workspace` | Code being worked on |
| State | `~/.config/pearl/state/<name>/` | `/home/agent/.claude` | Persistent Claude config |

## Auth Models

PEARL supports three authentication models, configured via `pearl setup <agent>` or manually via env files:

### Direct API Key
Set `ANTHROPIC_API_KEY` in the env file. Simplest setup.
```bash
cp examples/env.apikey.example ~/.config/pearl/agents/code.env
```

### macOS Keychain
Set `KEYCHAIN_AUTH=true` in the env file. The wrapper extracts credentials from macOS Keychain at launch (same as `claude login` on host).
```bash
cp examples/env.keychain.example ~/.config/pearl/agents/code.env
```

### Copilot Proxy
Set `ANTHROPIC_BASE_URL` to your local proxy. The wrapper adds `--add-host=host.docker.internal:host-gateway` automatically.
```bash
cp examples/env.proxy.example ~/.config/pearl/agents/code.env
```

## Adding a New Agent

1. Create `agents/<name>/Dockerfile` extending `pearl-base:latest`
2. Add any agent-specific tools
3. Create `agents/<name>/skills/CLAUDE.md` with agent identity and instructions
4. Add `agents/<name>/skills/references/` for reference docs
5. Build: `docker build -t pearl-<name>:latest agents/<name>/`
6. Run: `pearl <name>` (setup wizard will run automatically)
7. Test: `bin/test-agent <name>`

## Skills (Volume-Mounted)

Skills live in `agents/<name>/skills/` and are mounted read-only at `/skills` in the container. The entrypoint symlinks `/skills/CLAUDE.md` into `/workspace/CLAUDE.md` so Claude picks it up automatically.

**Edit skills without rebuilding the image** — changes take effect on the next `bin/pearl` invocation.

## Development

```bash
# Build all images
docker build -t pearl-base:latest agents/base/
docker build -t pearl-code:latest agents/code/

# Run smoke tests
bin/test-agent code

# Interactive shell inside container
docker run -it --rm pearl-code:latest bash
```

## Host Config Structure

```
~/.config/pearl/
├── agents/
│   ├── code.env          # Secrets for code agent
│   └── pptx.env          # (future)
└── state/
    └── code/             # Persistent Claude state
        ├── .claude.json
        └── .credentials.json
```
