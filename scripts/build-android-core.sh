#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sdk_root="${ANDROID_SDK_ROOT:-/home/val/Android/Sdk}"
ndk_root="${ANDROID_NDK_ROOT:-$sdk_root/ndk/30.0.15729638}"
output_root="${COLORFUL_ANDROID_OUT:-$repo_root/apps/android/build/rustJniLibs}"
toolchain="$ndk_root/toolchains/llvm/prebuilt/linux-x86_64/bin"

build_target() {
    local rust_target="$1" android_abi="$2" clang_prefix="$3"
    local target_env="${rust_target^^}"
    target_env="${target_env//-/_}"
    local linker="$toolchain/${clang_prefix}28-clang"
    env "CARGO_TARGET_${target_env}_LINKER=$linker" \
        "CARGO_TARGET_${target_env}_RUSTFLAGS=-C link-arg=-Wl,-soname,libcolorful_core.so" \
        "CC_${rust_target//-/_}=$linker" \
        "AR_${rust_target//-/_}=$toolchain/llvm-ar" \
        cargo build --manifest-path "$repo_root/Cargo.toml" \
            --package colorful-core --release --target "$rust_target"
    install -Dm755 "$repo_root/target/$rust_target/release/libcolorful_core.so" \
        "$output_root/$android_abi/libcolorful_core.so"
}

build_target aarch64-linux-android arm64-v8a aarch64-linux-android
build_target x86_64-linux-android x86_64 x86_64-linux-android
