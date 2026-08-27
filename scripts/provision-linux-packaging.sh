#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
tools_dir="${COLORFUL_LINUXDEPLOY_DIR:-$repo_dir/.cache/linuxdeploy}"
manifest="$repo_dir/packaging/desktop-dependencies.json"
mkdir -p "$tools_dir"

pin() {
  python3 -c 'import json,sys; value=json.load(open(sys.argv[1], encoding="utf-8")); [value := value[key] for key in sys.argv[2].split(".")]; print(value)' \
    "$manifest" "$1"
}

download() {
  local url="$1" destination="$2" expected="$3"
  local temporary="$destination.part"
  if [[ -f "$destination" ]] \
      && [[ "$(sha256sum "$destination" | awk '{print $1}')" == "$expected" ]]; then
    chmod +x "$destination"
    return
  fi
  curl --fail --location --retry 3 --output "$temporary" "$url"
  local actual
  actual="$(sha256sum "$temporary" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || {
    rm -f -- "$temporary"
    echo "Checksum mismatch for $(basename "$destination"): expected $expected, got $actual" >&2
    exit 1
  }
  chmod +x "$temporary"
  mv -f -- "$temporary" "$destination"
}

download \
  "$(pin linux.linuxdeploy.url)" \
  "$tools_dir/linuxdeploy-x86_64.AppImage" \
  "$(pin linux.linuxdeploy.sha256)"
download \
  "$(pin linux.linuxdeployQt.url)" \
  "$tools_dir/linuxdeploy-plugin-qt" \
  "$(pin linux.linuxdeployQt.sha256)"
download \
  "$(pin linux.appimagetool.url)" \
  "$tools_dir/appimagetool-x86_64.AppImage" \
  "$(pin linux.appimagetool.sha256)"
download \
  "$(pin linux.appimageRuntime.url)" \
  "$tools_dir/runtime-x86_64" \
  "$(pin linux.appimageRuntime.sha256)"

ffmpeg_name="$(pin linux.ffmpeg.asset)"
# Keep the shared CI cache from compressing obsolete media archives forever.
find "$tools_dir" -maxdepth 1 -type f -name 'ffmpeg-*.tar.xz' ! -name "$ffmpeg_name" -delete
rm -f -- "$tools_dir/ffmpeg-checksums.sha256"
download \
  "$(pin linux.ffmpeg.url)" \
  "$tools_dir/$ffmpeg_name" \
  "$(pin linux.ffmpeg.sha256)"
ffmpeg_stage="$tools_dir/ffmpeg"
rm -rf -- "$ffmpeg_stage"
mkdir -p "$ffmpeg_stage"
tar -xJf "$tools_dir/$ffmpeg_name" -C "$ffmpeg_stage" --strip-components=1
[[ -x "$ffmpeg_stage/bin/ffmpeg" && -x "$ffmpeg_stage/bin/ffprobe" ]] || {
  echo "FFmpeg archive did not contain bin/ffmpeg and bin/ffprobe" >&2
  exit 1
}

echo "Linux packaging tools installed beneath $tools_dir"
