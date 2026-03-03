# Pearl Agents vs Claude Code Devcontainer

Both Pearl and the [official Claude Code devcontainer](https://github.com/anthropics/claude-code/tree/main/.devcontainer) run Claude Code inside Docker containers with network-level security. This document explains how they differ and when to use which.

## Overview

- **Devcontainer**: VS Code-integrated, single-container sandbox maintained by Anthropic. You open a project in VS Code, it builds the container, and you interact with Claude through the VS Code extension.
- **Pearl**: CLI-driven, multi-agent framework. Each agent has its own image, firewall rules, auth config, skills, and tools. You interact via `bin/pearl <agent>` from the terminal.

## Architecture

| Aspect | Devcontainer | Pearl Agents |
|--------|-------------|--------------|
| Runtime | VS Code Dev Container | Standalone Docker via `bin/pearl` |
| Agent model | Single container | Multiple named agents (`code`, `pptx`, etc.) |
| Configuration | `.devcontainer/devcontainer.json` | `agents/<name>/` + `~/.config/pearl/` |
| IDE integration | VS Code required | None (CLI-native) |
| Base image | `node:20` | `node:22-bookworm-slim` |
| Shell | zsh (with p10k theme) | bash (minimal) |
| User | `node` | `agent` |

## Security Model

| Feature | Devcontainer | Pearl Agents |
|---------|-------------|--------------|
| Network firewall | Always on | Enabled by default, opt-out per agent |
| Core whitelisted domains | npm, Anthropic, Sentry, Statsig, GitHub, **VS Code Marketplace** | npm, Anthropic, Sentry, Statsig, GitHub |
| Per-agent domain whitelist | No (single domain list) | Yes (`agents/<name>/firewall/domains.txt`) |
| Host network access | Entire `/24` subnet open | Blocked by default; proxy-port-only or opt-in via `allow-host-access` |
| IPv6 | Not blocked | Blocked (all policies DROP) |
| Permission mode | `--dangerously-skip-permissions` (user choice) | `--dangerously-skip-permissions` (always on) |
| Credential isolation | VS Code manages | Auth profiles (`pearl auth`) |
| GitHub token | Environment variable | Environment variable via agent env file |

Notable differences:

- The devcontainer opens the entire host `/24` subnet (`HOST_IP.0/24`), giving the container access to all services on the host network. Pearl blocks host access by default and only opens the specific proxy port when `ANTHROPIC_BASE_URL` is set, or all host traffic when `allow-host-access` is opted into.
- The devcontainer whitelists VS Code Marketplace domains (`marketplace.visualstudio.com`, `vscode.blob.core.windows.net`, `update.code.visualstudio.com`). Pearl omits these since it doesn't use VS Code.
- Pearl blocks IPv6 entirely; the devcontainer does not.

## Features

| Feature | Devcontainer | Pearl Agents |
|---------|-------------|--------------|
| Skills (CLAUDE.md) | Baked into image | Volume-mounted per agent (edit without rebuilding) |
| MCP tools | Baked into image | Volume-mounted per agent |
| Persistent state | Docker volume | `~/.config/pearl/state/<agent>/` |
| Setup wizard | Manual | `pearl setup <agent>` |
| Multi-auth | No | `pearl auth` profiles (keychain, proxy, API key) |
| Host settings sync | No | Auto-syncs statusLine, syntax highlighting, thinking mode |
| CI testing | No | `bin/test-agent` + GitHub Actions |
| Firewall customization | Edit the script | Marker files + `domains.txt` per agent |

## When to Use Which

**Use the devcontainer when:**

- You primarily use VS Code
- You want Anthropic's maintained, opinionated setup
- You need a single-agent workflow
- You want VS Code extensions (ESLint, Prettier, GitLens) pre-configured

**Use Pearl when:**

- You prefer CLI-driven workflows
- You need multiple agents with different toolchains (code, presentations, etc.)
- You want per-agent firewall and auth configuration
- You want to iterate on skills and tools without rebuilding images
- You're building automation pipelines

## How Pearl Extends the Devcontainer Approach

Pearl was inspired by the devcontainer's firewall design (the `init-firewall.sh` scripts share a common lineage) but diverges in several ways:

1. **Multi-agent architecture** -- not one container fits all. Each agent gets its own image, skills, tools, and firewall rules.
2. **Auth profiles** -- support for multiple auth methods (macOS Keychain, proxy, direct API key) switchable per-run.
3. **Volume-mounted skills/tools** -- iterate without rebuilding Docker images.
4. **Tighter host network controls** -- block host access by default instead of opening the entire subnet.
5. **IPv6 coverage** -- block IPv6 to prevent firewall bypass.
6. **Setup wizard** -- guided onboarding via `pearl setup`.
