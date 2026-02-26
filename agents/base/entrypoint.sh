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

if [[ $# -eq 0 ]]; then
  echo "Error: No command provided. Usage: docker run pearl-<agent> claude [args...]" >&2
  exit 1
fi

exec "$@"
