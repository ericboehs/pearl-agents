# PEARL Agents

**P**rotected **E**ARL — Docker-isolated agent profiles for [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

Each agent runs in an ephemeral Docker container with scoped credentials, volume-mounted skills, and no host access beyond what's explicitly configured.

## Quick Start

```bash
# 1. Build images
docker build -t pearl-base:latest agents/base/
docker build -t pearl-code:latest agents/code/

# 2. Create an auth profile
bin/pearl auth add

# 3. Run — agent setup wizard runs automatically on first use
bin/pearl code "What tools do you have? List your versions."
```

Or configure explicitly:

```bash
# Interactive agent setup wizard
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
│       ├── firewall/     # Network firewall config (iptables whitelisting)
│       │   └── domains.txt # Agent-specific allowed domains
│       ├── skills/       # Volume-mounted at /skills (no rebuild needed)
│       │   ├── CLAUDE.md
│       │   └── references/
│       └── tools/        # MCP configs + custom scripts (volume-mounted)
│           └── .mcp.json # Playwright MCP config
├── bin/
│   ├── pearl             # Wrapper script (handles auth, mounts, docker run)
│   ├── pearl-auth        # Auth profile manager (list, switch, add)
│   ├── pearl-setup       # Interactive agent setup wizard
│   └── test-agent        # Smoke test for built images
└── examples/
    ├── auth/
    │   ├── keychain.env.example
    │   ├── proxy.env.example
    │   └── apikey.env.example
    └── agents/
        └── code.env.example
```

### Image Layers

```
node:22-bookworm-slim
  └── pearl-base          # claude-cli, git, dumb-init, ripgrep, jq, iptables
        └── pearl-code    # ruby, python, go, build-essential, shellcheck
        └── pearl-pptx    # (future) libreoffice, python-pptx
```

### Runtime Mounts

| Mount | Source | Target | Purpose |
|-------|--------|--------|---------|
| Skills | `agents/<name>/skills/` | `/skills` (ro) | CLAUDE.md + reference docs |
| Tools | `agents/<name>/tools/` | `/tools` (ro) | MCP configs + custom scripts |
| Workspace | `$(pwd)` | `/workspace` | Code being worked on |
| State | `~/.config/pearl/state/<name>/` | `/home/agent/.claude` | Persistent Claude config |

## Auth Profiles

Auth is managed globally via profiles in `~/.config/pearl/auth/`. Any agent can use any profile, avoiding duplication of proxy/keychain/API key config across agent env files.

### Managing Profiles

```bash
# List profiles and show which is active
pearl auth

# Create a new profile interactively
pearl auth add

# Switch the active profile
pearl auth proxy

# Override for a single run
pearl code --auth keychain "hello"
```

### Auth Methods

PEARL supports three authentication methods, configured via `pearl auth add`:

#### macOS Keychain
Uses your existing `claude login` credentials. The wrapper extracts them from macOS Keychain at launch.
```bash
cp examples/auth/keychain.env.example ~/.config/pearl/auth/keychain.env
```

#### Copilot Proxy
Routes through a local proxy. The wrapper adds `--add-host=host.docker.internal:host-gateway` automatically.
```bash
cp examples/auth/proxy.env.example ~/.config/pearl/auth/proxy.env
```

#### Direct API Key
Set `ANTHROPIC_API_KEY` directly. Simplest setup.
```bash
cp examples/auth/apikey.env.example ~/.config/pearl/auth/apikey.env
```

### Backwards Compatibility

Existing monolithic agent env files (with auth + git + token in one file) still work. Auth profiles take precedence via Docker env-file ordering, and a migration warning is printed to stderr.

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

## Network Firewall

PEARL includes an iptables-based network firewall that whitelists allowed domains and blocks all other outbound traffic. The firewall is **enabled by default** for all agents — no configuration needed.

If firewall initialization fails, the container **refuses to start** — it will not fall back to an unprotected state.

### Disabling the Firewall

To opt out for a specific agent, create a `disabled` marker file:

```bash
mkdir -p agents/<name>/firewall
touch agents/<name>/firewall/disabled
```

### Core Domains (Always Allowed)

Every agent with the firewall enabled can reach:

- `registry.npmjs.org` — npm packages
- `api.anthropic.com` — Claude API
- `sentry.io` — error reporting
- `statsig.anthropic.com` / `statsig.com` — feature flags
- GitHub (`*.github.com`) — IPs fetched dynamically from the [GitHub meta API](https://api.github.com/meta)

DNS (UDP/TCP port 53) and SSH (port 22) are always permitted. Localhost traffic is unrestricted.

### Per-Agent Domains

Add agent-specific domains to `agents/<name>/firewall/domains.txt` (one domain per line, `#` comments supported):

```
# Example: allow PyPI for pip installs
pypi.org
files.pythonhosted.org
```

### Host Access

By default the firewall blocks all traffic to the Docker host. Two levels of access are available:

- **Proxy only (automatic):** When `ANTHROPIC_BASE_URL` points to a local proxy (e.g. `http://host.docker.internal:4141`), the firewall allows traffic to that specific host and port.
- **Unrestricted:** To allow the agent to reach any service on the Docker host (local databases, dev servers, MCP servers, etc.), create an `allow-host-access` marker:

```bash
touch agents/<name>/firewall/allow-host-access
```

### Other Details

- **IPv6** is blocked entirely (all policies set to DROP).
- **Verification**: on startup the firewall self-tests by confirming `example.com` is blocked and `api.github.com` is reachable. If either check fails, the container exits.

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
├── auth/
│   ├── active              # Plain text: name of active profile
│   ├── keychain.env        # KEYCHAIN_AUTH=true
│   └── proxy.env           # ANTHROPIC_BASE_URL, model vars, etc.
├── agents/
│   ├── code.env            # Git identity + GITHUB_TOKEN only
│   └── pptx.env            # (future)
└── state/
    └── code/               # Persistent Claude state
        ├── .claude.json
        └── .credentials.json
```
