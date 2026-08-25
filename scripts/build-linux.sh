#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
manifest="$repo_dir/packaging/desktop-dependencies.json"
build_root="${COLORFUL_BUILD_ROOT:-$repo_dir/build}"
target_dir="${CARGO_TARGET_DIR:-$repo_dir/target}"
mpv_mode="${COLORFUL_MPV_MODE:-compatibility}"
expected_mpv="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["mpv"]["sourceVersion"])' "$manifest")"

configuration=Debug
profile=debug
build_dir="$build_root/linux"
if [[ "${1:-}" == "--release" ]]; then
  configuration=Release
  profile=release
  build_dir="$build_root/linux-release"
  shift
fi
if (($#)); then
  echo "usage: $0 [--release]" >&2
  exit 2
fi

cargo_args=(build --manifest-path "$repo_dir/Cargo.toml" -p colorful-core)
[[ "$configuration" == Release ]] && cargo_args+=(--release)
cargo "${cargo_args[@]}"
cmake -S "$repo_dir/apps/linux" -B "$build_dir" -G Ninja \
  -DCMAKE_BUILD_TYPE="$configuration" \
  -DCOLORFUL_MPV_MODE="$mpv_mode" \
  -DCOLORFUL_EXPECTED_MPV_VERSION="$expected_mpv" \
  -DCOLORFUL_CORE_LIBRARY="$target_dir/$profile/libcolorful_core.so"
cmake --build "$build_dir" -j2
