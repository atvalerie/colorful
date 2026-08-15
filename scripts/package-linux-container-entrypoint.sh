#!/usr/bin/env bash
set -euo pipefail

repo_dir="${COLORFUL_REPO_DIR:-/workspace}"
cd "$repo_dir"

mkdir -p \
  "$HOME" \
  "$CARGO_HOME" \
  "$CARGO_TARGET_DIR" \
  "$BUN_INSTALL_CACHE_DIR" \
  "$COLORFUL_BUILD_ROOT" \
  "$COLORFUL_LINUXDEPLOY_DIR" \
  "$COLORFUL_DIST_DIR"

bun install --cwd packages/provider-host --frozen-lockfile

if [[ ! -x "$COLORFUL_LINUXDEPLOY_DIR/linuxdeploy-x86_64.AppImage" \
   || ! -x "$COLORFUL_LINUXDEPLOY_DIR/linuxdeploy-plugin-qt" \
   || ! -x "$COLORFUL_LINUXDEPLOY_DIR/appimagetool-x86_64.AppImage" \
   || ! -x "$COLORFUL_LINUXDEPLOY_DIR/runtime-x86_64" \
   || ! -x "$COLORFUL_LINUXDEPLOY_DIR/ffmpeg/bin/ffmpeg" \
   || ! -x "$COLORFUL_LINUXDEPLOY_DIR/ffmpeg/bin/ffprobe" ]]; then
  ./scripts/provision-linux-packaging.sh
fi

./scripts/package-linux.sh

bun services/colorful-relay/src/main.ts >"$COLORFUL_BUILD_ROOT/relay-test.log" 2>&1 &
relay_pid=$!
cleanup_relay() { kill "$relay_pid" 2>/dev/null || true; }
trap cleanup_relay EXIT
for _ in $(seq 1 20); do
  curl --fail --silent http://127.0.0.1:8787/healthz >/dev/null && break
  sleep 0.25
done
ctest --test-dir "$COLORFUL_BUILD_ROOT/linux-release" --output-on-failure
