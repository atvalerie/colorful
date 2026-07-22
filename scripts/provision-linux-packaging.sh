#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
tools_dir="${COLORFUL_LINUXDEPLOY_DIR:-$repo_dir/.cache/linuxdeploy}"
mkdir -p "$tools_dir"

download() {
  local url="$1" destination="$2"
  local temporary="$destination.part"
  curl --fail --location --retry 3 --output "$temporary" "$url"
  chmod +x "$temporary"
  mv -f -- "$temporary" "$destination"
}

download \
  "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage" \
  "$tools_dir/linuxdeploy-x86_64.AppImage"
download \
  "https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/1-alpha-20250213-1/linuxdeploy-plugin-qt-x86_64.AppImage" \
  "$tools_dir/linuxdeploy-plugin-qt"
download \
  "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage" \
  "$tools_dir/appimagetool-x86_64.AppImage"
download \
  "https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-x86_64" \
  "$tools_dir/runtime-x86_64"

yt_dlp_url="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_linux"
yt_dlp_sums_url="https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS"
download "$yt_dlp_url" "$tools_dir/yt-dlp"
curl --fail --location --retry 3 --output "$tools_dir/SHA2-256SUMS" "$yt_dlp_sums_url"
expected="$({ grep -E '[ *]yt-dlp_linux$' "$tools_dir/SHA2-256SUMS" || true; } | awk '{print $1}' | head -1)"
[[ -n "$expected" ]] || { echo "yt-dlp_linux is missing from SHA2-256SUMS" >&2; exit 1; }
actual="$(sha256sum "$tools_dir/yt-dlp" | awk '{print $1}')"
[[ "$actual" == "$expected" ]] || {
  echo "yt-dlp checksum mismatch: expected $expected, got $actual" >&2
  exit 1
}

ffmpeg_name="ffmpeg-master-latest-linux64-gpl.tar.xz"
download \
  "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/$ffmpeg_name" \
  "$tools_dir/$ffmpeg_name"
curl --fail --location --retry 3 --output "$tools_dir/ffmpeg-checksums.sha256" \
  "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/checksums.sha256"
expected="$({ grep -E "[ *]$ffmpeg_name$" "$tools_dir/ffmpeg-checksums.sha256" || true; } | awk '{print $1}' | head -1)"
[[ -n "$expected" ]] || { echo "$ffmpeg_name is missing from checksums.sha256" >&2; exit 1; }
actual="$(sha256sum "$tools_dir/$ffmpeg_name" | awk '{print $1}')"
[[ "$actual" == "$expected" ]] || {
  echo "FFmpeg checksum mismatch: expected $expected, got $actual" >&2
  exit 1
}
ffmpeg_stage="$tools_dir/ffmpeg"
rm -rf -- "$ffmpeg_stage"
mkdir -p "$ffmpeg_stage"
tar -xJf "$tools_dir/$ffmpeg_name" -C "$ffmpeg_stage" --strip-components=1
[[ -x "$ffmpeg_stage/bin/ffmpeg" && -x "$ffmpeg_stage/bin/ffprobe" ]] || {
  echo "FFmpeg archive did not contain bin/ffmpeg and bin/ffprobe" >&2
  exit 1
}

echo "Linux packaging tools installed beneath $tools_dir"
