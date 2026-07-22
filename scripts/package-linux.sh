#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
tools_dir="${COLORFUL_LINUXDEPLOY_DIR:-$repo_dir/.cache/linuxdeploy}"
linuxdeploy="${COLORFUL_LINUXDEPLOY:-$tools_dir/linuxdeploy-x86_64.AppImage}"
qt_plugin="${COLORFUL_LINUXDEPLOY_QT:-$tools_dir/linuxdeploy-plugin-qt}"
appimagetool="${COLORFUL_APPIMAGETOOL:-$tools_dir/appimagetool-x86_64.AppImage}"
appimage_runtime="${COLORFUL_APPIMAGE_RUNTIME:-$tools_dir/runtime-x86_64}"
yt_dlp="${COLORFUL_PACKAGING_YT_DLP:-$tools_dir/yt-dlp}"
ffmpeg="${COLORFUL_PACKAGING_FFMPEG:-$tools_dir/ffmpeg/bin/ffmpeg}"
ffprobe="${COLORFUL_PACKAGING_FFPROBE:-$tools_dir/ffmpeg/bin/ffprobe}"
build_dir="$repo_dir/build/linux-release"
dist_dir="$repo_dir/dist"
commit="$(git -C "$repo_dir" rev-parse --short=12 HEAD)"
artifact="colorful-0.1.0-$commit-x86_64"
appdir="$dist_dir/$artifact.AppDir"

"$script_dir/check-linux-deps.sh" build
"$script_dir/build-linux.sh" --release
mkdir -p "$build_dir" "$dist_dir" "$tools_dir"
bun build --compile "$repo_dir/packages/provider-host/src/main.ts" --outfile "$build_dir/colorful-provider"

for tool in "$linuxdeploy" "$qt_plugin" "$appimagetool" "$appimage_runtime" "$yt_dlp" "$ffmpeg" "$ffprobe"; do
  if [[ ! -x "$tool" ]]; then
    echo "missing packaging tool: $tool" >&2
    echo "run ./scripts/provision-linux-packaging.sh first" >&2
    exit 1
  fi
done

rm -rf -- "$appdir"
DESTDIR="$appdir" cmake --install "$build_dir" --prefix /usr
install -Dm755 "$build_dir/colorful-provider" "$appdir/usr/bin/colorful-provider"
install -Dm755 "$ffmpeg" "$appdir/usr/bin/ffmpeg"
install -Dm755 "$ffprobe" "$appdir/usr/bin/ffprobe"
install -Dm755 "$yt_dlp" "$appdir/usr/bin/yt-dlp"
install -Dm644 "$repo_dir/LICENSE" "$appdir/usr/share/doc/colorful/LICENSE"
install -Dm644 "$repo_dir/THIRD_PARTY_NOTICES.md" "$appdir/usr/share/doc/colorful/THIRD_PARTY_NOTICES.md"

export QML_SOURCES_PATHS="$repo_dir/apps/linux/qml"
export EXTRA_PLATFORM_PLUGINS="libqoffscreen.so"
if [[ -n "${COLORFUL_QMAKE:-}" ]]; then
  real_qmake="$COLORFUL_QMAKE"
elif command -v qmake6 >/dev/null 2>&1; then
  real_qmake="$(command -v qmake6)"
else
  real_qmake="$(command -v qmake)"
fi

qt_plugins="$($real_qmake -query QT_INSTALL_PLUGINS)"
plugin_stage="$build_dir/qt-plugins-for-package"
rm -rf -- "$plugin_stage"
mkdir -p "$plugin_stage"/{platforms,platforminputcontexts,imageformats,tls}
for plugin in libqxcb.so libqoffscreen.so; do
  install -Dm755 "$qt_plugins/platforms/$plugin" "$plugin_stage/platforms/$plugin"
done
for plugin in libcomposeplatforminputcontextplugin.so libibusplatforminputcontextplugin.so; do
  [[ ! -f "$qt_plugins/platforminputcontexts/$plugin" ]] || \
    install -Dm755 "$qt_plugins/platforminputcontexts/$plugin" "$plugin_stage/platforminputcontexts/$plugin"
done
for plugin in libqgif.so libqico.so libqjpeg.so libqsvg.so libqwebp.so; do
  [[ ! -f "$qt_plugins/imageformats/$plugin" ]] || \
    install -Dm755 "$qt_plugins/imageformats/$plugin" "$plugin_stage/imageformats/$plugin"
done
if [[ -d "$qt_plugins/tls" ]]; then
  find "$qt_plugins/tls" -maxdepth 1 -type f -name '*.so' -exec install -Dm755 '{}' "$plugin_stage/tls/" \;
fi
export COLORFUL_REAL_QMAKE="$real_qmake"
export COLORFUL_QT_PLUGIN_STAGE="$plugin_stage"
export QMAKE="$script_dir/qmake-linuxdeploy-wrapper.sh"
export PATH="$tools_dir:$PATH"
export APPIMAGE_EXTRACT_AND_RUN=1
# linuxdeploy's embedded binutils can lag behind rolling distributions and do
# not understand newer ELF sections such as RELR. Release binaries are already
# stripped; leave deployed libraries intact instead of corrupting the bundle.
export NO_STRIP=1
"$linuxdeploy" --verbosity=2 --appdir "$appdir" \
  --executable "$appdir/usr/bin/colorful-linux" \
  --executable "$appdir/usr/bin/colorful-provider" \
  --executable "$appdir/usr/bin/ffmpeg" \
  --executable "$appdir/usr/bin/ffprobe" \
  --executable "$appdir/usr/bin/yt-dlp" \
  --desktop-file "$appdir/usr/share/applications/sh.valerie.colorful.desktop" \
  --icon-file "$appdir/usr/share/icons/hicolor/scalable/apps/colorful.svg" \
  --plugin qt

# linuxdeploy's bundled patchelf cannot safely rewrite newer RELR-bearing ELF
# files found on rolling distributions. Dependency discovery is still useful,
# but restore the pristine source files and use AppRun's LD_LIBRARY_PATH rather
# than relying on rewritten RPATHs.
while IFS= read -r -d '' destination; do
  relative="${destination#"$appdir/usr/lib/"}"
  source_file="/usr/lib/$relative"
  if [[ ! -f "$source_file" ]]; then
    source_file="$(ldconfig -p 2>/dev/null | awk -v name="$(basename "$destination")" \
      '$1 == name && /x86-64/ {print $NF; exit}')"
  fi
  [[ -z "$source_file" || ! -f "$source_file" ]] || cp -Lf -- "$source_file" "$destination"
done < <(find "$appdir/usr/lib" -type f -print0)
while IFS= read -r -d '' destination; do
  relative="${destination#"$appdir/usr/plugins/"}"
  source_file="$qt_plugins/$relative"
  [[ ! -f "$source_file" ]] || cp -Lf -- "$source_file" "$destination"
done < <(find "$appdir/usr/plugins" -type f -print0)
while IFS= read -r -d '' destination; do
  relative="${destination#"$appdir/usr/qml/"}"
  source_file="$($real_qmake -query QT_INSTALL_QML)/$relative"
  [[ ! -f "$source_file" ]] || cp -Lf -- "$source_file" "$destination"
done < <(find "$appdir/usr/qml" -type f -print0)
install -Dm755 "$build_dir/colorful-linux" "$appdir/usr/bin/colorful-linux"
install -Dm755 "$build_dir/colorful-provider" "$appdir/usr/bin/colorful-provider"
install -Dm755 "$ffmpeg" "$appdir/usr/bin/ffmpeg"
install -Dm755 "$ffprobe" "$appdir/usr/bin/ffprobe"
install -Dm755 "$yt_dlp" "$appdir/usr/bin/yt-dlp"
install -Dm644 "$repo_dir/target/release/libcolorful_core.so" "$appdir/usr/lib/libcolorful_core.so"
install -Dm755 "$script_dir/AppRun-linux" "$appdir/AppRun"

"$script_dir/check-linux-deps.sh" bundle "$appdir"

smoke_root="$(mktemp -d)"
mkdir -p "$smoke_root"/{runtime,data,config}
chmod 700 "$smoke_root/runtime"
set +e
QT_QPA_PLATFORM=offscreen COLORFUL_DISABLE_DISCORD_RPC=1 \
  XDG_RUNTIME_DIR="$smoke_root/runtime" XDG_DATA_HOME="$smoke_root/data" \
  XDG_CONFIG_HOME="$smoke_root/config" timeout 5s "$appdir/AppRun" >/dev/null 2>&1
smoke_status=$?
set -e
if [[ $smoke_status -ne 124 ]]; then
  echo "packaged colorful failed its startup smoke test (exit $smoke_status)" >&2
  exit 1
fi

tarball="$dist_dir/$artifact-portable.tar.gz"
rm -f -- "$tarball"
tar -C "$appdir" -czf "$tarball" .

appimage="$dist_dir/$artifact.AppImage"
rm -f -- "$appimage"
appstreamcli validate --no-net \
  "$appdir/usr/share/metainfo/sh.valerie.colorful.appdata.xml"
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$appimagetool" \
  --no-appstream --runtime-file "$appimage_runtime" "$appdir" "$appimage"
echo "Portable archive: $tarball"
echo "AppImage: $appimage"
