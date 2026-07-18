#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
lab_dir="$repo_dir/apps/design-lab"

if [[ ! -d "$lab_dir/node_modules" ]]; then
  bun install --cwd "$lab_dir"
fi

exec bun run --cwd "$lab_dir" dev

