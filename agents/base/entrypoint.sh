#!/bin/bash
set -euo pipefail

# If /skills/CLAUDE.md exists (volume-mounted), symlink it into workspace
if [[ -f /skills/CLAUDE.md && ! -f /workspace/CLAUDE.md ]]; then
  ln -sf /skills/CLAUDE.md /workspace/CLAUDE.md
fi

exec "$@"
