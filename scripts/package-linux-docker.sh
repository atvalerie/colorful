#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
image="${COLORFUL_LINUX_BUILDER_IMAGE:-colorful-linux-builder:ubuntu-22.04}"

if (($#)); then
  echo "usage: $0" >&2
  exit 2
fi

command -v docker >/dev/null 2>&1 || {
  echo "Docker is required for the containerized Linux release build" >&2
  exit 1
}

mkdir -p "$repo_dir/.cache/container" "$repo_dir/dist"

docker build \
  --file "$repo_dir/packaging/linux/Dockerfile" \
  --tag "$image" \
  "$repo_dir"

docker run --rm \
  --user "$(id -u):$(id -g)" \
  --volume "$repo_dir:/workspace" \
  --workdir /workspace \
  "$image"
