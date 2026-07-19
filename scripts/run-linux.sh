#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
mocha_env="$repo_dir/../mocha/.env"

if [[ -f "$mocha_env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$mocha_env"
  set +a
fi

if [[ "${1:-}" == "--no-build" ]]; then
  shift
else
  "$script_dir/build-linux.sh"
fi

if [[ ! -x "$repo_dir/build/linux/colorful-linux" ]]; then
  echo "colorful has not been built yet; run ./scripts/run-linux.sh once first" >&2
  exit 1
fi

export XDG_DATA_DIRS="$repo_dir/apps/linux:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
exec "$repo_dir/build/linux/colorful-linux" "$@"
