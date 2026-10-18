#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"
for script in scripts/*.sh; do bash -n "$script"; done
command -v bun >/dev/null || { echo "Install Bun to run repository checks: https://bun.sh" >&2; exit 1; }
bun scripts/export-catalog.js --check
bun scripts/check-repository.js "$@"
