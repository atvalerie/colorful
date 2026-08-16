#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rust_target="${1:-aarch64-apple-ios-sim}"

case "$rust_target" in
    aarch64-apple-ios|aarch64-apple-ios-sim|x86_64-apple-ios)
        ;;
    *)
        echo "Unsupported iOS Rust target: $rust_target" >&2
        echo "Use aarch64-apple-ios, aarch64-apple-ios-sim, or x86_64-apple-ios." >&2
        exit 2
        ;;
esac

rustup target add "$rust_target"
cargo rustc \
    --locked \
    --manifest-path "$repo_root/Cargo.toml" \
    --package colorful-core \
    --lib \
    --release \
    --target "$rust_target" \
    --crate-type staticlib

output_root="$repo_root/apps/ios/Support/ColorfulCore/$rust_target"
mkdir -p "$output_root"
cp "$repo_root/target/$rust_target/release/libcolorful_core.a" "$output_root/libcolorful_core.a"
cp "$repo_root/crates/colorful-core/include/colorful_core.h" "$output_root/colorful_core.h"

echo "Built colorful-core for $rust_target"
echo "Static library: $output_root/libcolorful_core.a"
