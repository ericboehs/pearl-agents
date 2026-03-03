#!/usr/bin/env bash
set -euo pipefail

# PEARL agent entrypoint — links skills and launches the command

# If /skills/CLAUDE.md exists (volume-mounted), symlink it into workspace
if [[ -f /skills/CLAUDE.md ]]; then
  if [[ -f /workspace/CLAUDE.md && ! -L /workspace/CLAUDE.md ]]; then
    echo "Note: Workspace already contains CLAUDE.md. Agent skills from /skills/CLAUDE.md will NOT be applied." >&2
    echo "  To use agent skills, rename or remove /workspace/CLAUDE.md" >&2
  else
    ln -sf /skills/CLAUDE.md /workspace/CLAUDE.md
  fi
fi

# If /tools/.mcp.json exists (volume-mounted), always apply it — unlike CLAUDE.md
# which defers to workspace files, MCP config defines essential agent capabilities
# (Playwright, etc.) that must be present for the agent to function correctly.
if [[ -f /tools/.mcp.json ]]; then
  if [[ -f /workspace/.mcp.json && ! -L /workspace/.mcp.json ]]; then
    if [[ ! -f /workspace/.mcp.json.bak ]]; then
      echo "Warning: Overriding workspace .mcp.json with agent MCP config from /tools/.mcp.json" >&2
      echo "  Original backed up to /workspace/.mcp.json.bak" >&2
      cp /workspace/.mcp.json /workspace/.mcp.json.bak
    fi
  fi
  ln -sf /tools/.mcp.json /workspace/.mcp.json
fi

if [[ $# -eq 0 ]]; then
  echo "Error: No command provided. Usage: docker run pearl-<agent> claude [args...]" >&2
  exit 1
fi

exec "$@"
