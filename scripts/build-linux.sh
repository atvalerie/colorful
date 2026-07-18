#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"

cargo build --manifest-path "$repo_dir/Cargo.toml" -p colorful-core
cmake -S "$repo_dir/apps/linux" -B "$repo_dir/build/linux" -G Ninja -DCMAKE_BUILD_TYPE=Debug
cmake --build "$repo_dir/build/linux" -j2
