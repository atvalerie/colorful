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

if [[ "${COLORFUL_SKIP_LINUX_BUILDER_BUILD:-0}" != 1 ]]; then
  docker build \
    --file "$repo_dir/packaging/linux/Dockerfile" \
    --tag "$image" \
    "$repo_dir"
fi

docker run --rm \
  --user "$(id -u):$(id -g)" \
  --env "COLORFUL_BUILD_CHANNEL=${COLORFUL_BUILD_CHANNEL:-release}" \
  --env "COLORFUL_BUILD_NUMBER=${COLORFUL_BUILD_NUMBER:-}" \
  --volume "$repo_dir:/workspace" \
  --workdir /workspace \
  "$image"
