#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"

cargo test --manifest-path "$repo_dir/Cargo.toml" --workspace
"$script_dir/test-storage-schema.sh"

(
  cd "$repo_dir/packages/provider-kit"
  bun run typecheck
  bun test
)

(
  cd "$repo_dir/packages/provider-host"
  bun run typecheck
  bun test
)

"$script_dir/build-linux.sh"

qmllint -I "$repo_dir/build/linux" \
  "$repo_dir/apps/linux/qml/Main.qml" \
  "$repo_dir/apps/linux/qml/AppIcon.qml" \
  "$repo_dir/apps/linux/qml/ColorButton.qml" \
  "$repo_dir/apps/linux/qml/IconButton.qml" \
  "$repo_dir/apps/linux/qml/ResizeHandle.qml" \
  "$repo_dir/apps/linux/qml/TitleButton.qml" \
  "$repo_dir/apps/linux/qml/TrackDelegate.qml" \
  "$repo_dir/apps/linux/qml/CatalogCard.qml" \
  "$repo_dir/apps/linux/qml/CatalogPage.qml" \
  "$repo_dir/apps/linux/qml/MetadataLink.qml"

dbus-run-session -- bash -c '
  set -euo pipefail
  repo_dir="$1"
  log_file="$(mktemp)"
  app_pid=""
  cleanup() {
    if [[ -n "$app_pid" ]]; then kill "$app_pid" 2>/dev/null || true; fi
    rm -f "$log_file"
  }
  trap cleanup EXIT
  QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
    COLORFUL_PROVIDER_HOST="$repo_dir/apps/linux/tests/fake-provider.ts" \
    COLORFUL_SMOKE_SEARCH="fixture" \
    COLORFUL_SMOKE_DETAIL=1 \
    "$repo_dir/build/linux/colorful-linux" >"$log_file" 2>&1 &
  app_pid=$!
  for _ in {1..40}; do
    if qdbus6 org.mpris.MediaPlayer2.colorful /org/mpris/MediaPlayer2 \
      org.freedesktop.DBus.Properties.Get org.mpris.MediaPlayer2 Identity >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  identity="$(qdbus6 org.mpris.MediaPlayer2.colorful /org/mpris/MediaPlayer2 \
    org.freedesktop.DBus.Properties.Get org.mpris.MediaPlayer2 Identity)"
  status="$(qdbus6 org.mpris.MediaPlayer2.colorful /org/mpris/MediaPlayer2 \
    org.freedesktop.DBus.Properties.Get org.mpris.MediaPlayer2.Player PlaybackStatus)"
  [[ "$identity" == "colorful" ]]
  [[ "$status" == "Stopped" ]]
  if grep -E "ReferenceError|TypeError|QQmlApplicationEngine failed" "$log_file"; then
    echo "QML runtime error detected" >&2
    exit 1
  fi
' _ "$repo_dir"

echo "colorful Linux checks passed"
