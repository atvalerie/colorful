#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
manifest="$repo_dir/packaging/desktop-dependencies.json"
pin() {
  python3 -c 'import json,sys; value=json.load(open(sys.argv[1], encoding="utf-8")); [value := value[key] for key in sys.argv[2].split(".")]; print(value)' \
    "$manifest" "$1"
}

mode="${1:-build}"
shift || true

failures=0
missing() { echo "missing: $*" >&2; failures=$((failures + 1)); }
need_command() { command -v "$1" >/dev/null 2>&1 || missing "$1"; }

if [[ "$mode" == build ]]; then
  for command in cargo bun cmake ninja pkg-config git timeout appstreamcli python3; do need_command "$command"; done
  for package in Qt6Core Qt6Gui Qt6Quick Qt6QuickControls2 Qt6Network Qt6DBus mpv; do
    pkg-config --exists "$package" 2>/dev/null || missing "pkg-config module $package"
  done
  need_command secret-tool
  if ((failures)); then exit 1; fi
  qmake="$(command -v qmake6 || command -v qmake || true)"
  [[ -n "$qmake" ]] || missing "Qt 6 qmake"
  expected_qt="$(pin toolchains.qt)"
  if [[ -n "$qmake" ]] && [[ "$("$qmake" -query QT_VERSION)" != "$expected_qt" ]]; then
    missing "Qt $expected_qt qmake (found $qmake for Qt $("$qmake" -query QT_VERSION))"
  fi
  expected_mpv_api_min="$(pin mpv.minimumClientApi)"
  if ! pkg-config --atleast-version="$expected_mpv_api_min" mpv; then
    missing "mpv client API >= $expected_mpv_api_min (found $(pkg-config --modversion mpv 2>/dev/null || echo none))"
  fi
  if [[ "${COLORFUL_MPV_MODE:-compatibility}" == official ]]; then
    expected_mpv="$(pin mpv.sourceVersion)"
    source_marker="$(pkg-config --variable=prefix mpv)/share/colorful/mpv-source-version"
    actual_mpv="$(tr -d '[:space:]' < "$source_marker" 2>/dev/null || echo none)"
    [[ "$actual_mpv" == "$expected_mpv" ]] || missing "mpv source exactly $expected_mpv for an official build (found $actual_mpv)"
  fi
  if ((failures)); then exit 1; fi
  echo "Linux build dependencies are ready"
  echo "Qt $(pkg-config --modversion Qt6Core), mpv $(pkg-config --modversion mpv)"
  exit 0
fi

if [[ "$mode" != bundle || $# -ne 1 ]]; then
  echo "usage: $0 build | bundle APPDIR" >&2
  exit 2
fi

appdir="$(realpath "$1")"
[[ -d "$appdir/usr/bin" && -d "$appdir/usr/lib" ]] || {
  echo "invalid AppDir: $appdir" >&2
  exit 1
}
need_command readelf
need_command ldd
need_command objdump
((failures == 0)) || exit 1

mapfile -d '' elf_files < <(find "$appdir/usr" -type f -print0 | while IFS= read -r -d '' file; do
  readelf -h "$file" >/dev/null 2>&1 && printf '%s\0' "$file"
done)
if ((${#elf_files[@]} == 0)); then
  echo "bundle contains no ELF files" >&2
  exit 1
fi

for file in "${elf_files[@]}"; do
  unresolved="$(LD_LIBRARY_PATH="$appdir/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ldd "$file" 2>&1 | grep 'not found' || true)"
  if [[ -n "$unresolved" ]]; then
    echo "$file has unresolved dependencies:" >&2
    echo "$unresolved" >&2
    failures=$((failures + 1))
  fi
done

for binary in colorful-linux colorful-provider ffmpeg ffprobe; do
  [[ -x "$appdir/usr/bin/$binary" ]] || missing "bundled executable $binary"
done
[[ -f "$appdir/usr/lib/libcolorful_core.so" ]] || missing "libcolorful_core.so"
find "$appdir/usr/lib" -maxdepth 1 -type f -name 'libmpv.so*' -print -quit | grep -q . || missing "bundled libmpv runtime"
[[ -f "$appdir/usr/share/doc/colorful/BUILD_DEPENDENCIES.json" ]] || missing "build dependency manifest"

for plugin in platforms/libqxcb.so platforms/libqoffscreen.so \
  xcbglintegrations/libqxcb-glx-integration.so xcbglintegrations/libqxcb-egl-integration.so \
  imageformats/libqjpeg.so imageformats/libqwebp.so imageformats/libqsvg.so; do
  [[ -f "$appdir/usr/plugins/$plugin" ]] || missing "Qt plugin $plugin"
done
find "$appdir/usr/plugins/tls" -maxdepth 1 -type f -name '*.so' -print -quit | grep -q . || missing "Qt TLS backend"
[[ -d "$appdir/usr/qml/QtQuick" ]] || missing "bundled QtQuick QML module"

if ! LD_LIBRARY_PATH="$appdir/usr/lib" "$appdir/usr/bin/ffmpeg" -version >/dev/null 2>&1; then
  echo "bundled ffmpeg failed its runtime smoke test" >&2
  failures=$((failures + 1))
fi
expected_ffmpeg="$(pin linux.ffmpeg.version)"
if ! LD_LIBRARY_PATH="$appdir/usr/lib" "$appdir/usr/bin/ffmpeg" -version 2>&1 | head -1 | grep -Fq "$expected_ffmpeg"; then
  echo "bundled ffmpeg does not match pin $expected_ffmpeg" >&2
  failures=$((failures + 1))
fi
if ! LD_LIBRARY_PATH="$appdir/usr/lib" "$appdir/usr/bin/ffprobe" -version >/dev/null 2>&1; then
  echo "bundled ffprobe failed its runtime smoke test" >&2
  failures=$((failures + 1))
fi
leaks="$(LD_LIBRARY_PATH="$appdir/usr/lib" ldd "$appdir/usr/bin/colorful-linux" | awk '/=> \// {print $1, $3}' \
  | grep -E '^(libQt6|libmpv)' | grep -v " $appdir/" || true)"
if [[ -n "$leaks" ]]; then
  echo "bundle leaks Qt/mpv libraries from the build host:" >&2
  echo "$leaks" >&2
  failures=$((failures + 1))
fi

# Third-party libraries ship their own absolute RPATHs and are left alone; our
# own artifacts must stay relocatable so they never point back at a build host.
for file in "$appdir/usr/bin/colorful-linux" "$appdir/usr/lib/libcolorful_core.so"; do
  [[ -f "$file" ]] || continue
  absolute_rpath="$(readelf -d "$file" 2>/dev/null \
    | grep -E 'R(UN)?PATH' | grep -oE '\[[^]]*\]' | grep -E '\[/|:/' || true)"
  if [[ -n "$absolute_rpath" ]]; then
    echo "$file has an absolute RPATH/RUNPATH: $absolute_rpath" >&2
    failures=$((failures + 1))
  fi
done

required_glibc="$(objdump -T "${elf_files[@]}" 2>/dev/null | grep -o 'GLIBC_[0-9][0-9.]*' | sort -Vu | tail -1 || true)"
required_glibcxx="$(objdump -T "${elf_files[@]}" 2>/dev/null | grep -o 'GLIBCXX_[0-9][0-9.]*' | sort -Vu | tail -1 || true)"
required_cxxabi="$(objdump -T "${elf_files[@]}" 2>/dev/null | grep -o 'CXXABI_[0-9][0-9.]*' | sort -Vu | tail -1 || true)"
echo "ELF files audited: ${#elf_files[@]}"
echo "Highest required glibc symbol: ${required_glibc:-none}"
echo "Highest required libstdc++ symbols: ${required_glibcxx:-none}, ${required_cxxabi:-none}"
if [[ -n "${COLORFUL_MAX_GLIBC:-}" && -n "$required_glibc" ]]; then
  required_version="${required_glibc#GLIBC_}"
  if [[ "$(printf '%s\n%s\n' "$required_version" "$COLORFUL_MAX_GLIBC" | sort -V | tail -1)" != "$COLORFUL_MAX_GLIBC" ]]; then
    echo "glibc $required_version exceeds release ceiling $COLORFUL_MAX_GLIBC" >&2
    failures=$((failures + 1))
  fi
fi
((failures == 0)) || exit 1
echo "Linux bundle dependency audit passed"
