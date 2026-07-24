#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"

if (($# < 1 || $# > 2)) || { (($# == 2)) && [[ "$2" != "--force" ]]; }; then
  echo "usage: $0 MAJOR.MINOR.PATCH [--force]" >&2
  exit 2
fi

next="$1"
current="$(tr -d '[:space:]' < "$repo_dir/VERSION")"
for value in "$current" "$next"; do
  if [[ ! "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "versions must contain three numeric parts, such as 0.2.0" >&2
    exit 1
  fi
done

if [[ "${2:-}" != "--force" ]]; then
  greatest="$(printf '%s\n%s\n' "$current" "$next" | sort -V | tail -1)"
  if [[ "$next" == "$current" || "$greatest" != "$next" ]]; then
    echo "new version must be greater than $current; use --force only to correct a mistake" >&2
    exit 1
  fi
fi

printf '%s' "$next" > "$repo_dir/VERSION"
echo "colorful version: $current -> $next"
echo "commit VERSION with the release changes before creating distributable packages"
