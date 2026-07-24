#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
version="$(tr -d '[:space:]' < "$repo_dir/VERSION")"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "VERSION must contain a three-part numeric version such as 0.2.0" >&2
  exit 1
fi

if (($# > 1)); then
  echo "usage: $0 [vMAJOR.MINOR.PATCH]" >&2
  exit 2
fi

if (($# == 1)) && [[ "$1" != "v$version" ]]; then
  echo "release tag $1 does not match VERSION $version (expected v$version)" >&2
  exit 1
fi

printf '%s\n' "$version"
