#!/usr/bin/env bash
set -euo pipefail

manifest="${COLORFUL_DEPENDENCY_MANIFEST:-/tmp/desktop-dependencies.json}"
pin() {
    python3 -c 'import json,sys; value=json.load(open(sys.argv[1], encoding="utf-8")); [value := value[key] for key in sys.argv[2].split(".")]; print(value)' \
        "$manifest" "$1"
}

readonly MPV_VERSION="$(pin mpv.sourceVersion)"
readonly MPV_COMMIT="$(pin mpv.sourceCommit)"
readonly MPV_CLIENT_API_VERSION="$(pin mpv.clientApiVersion)"
readonly MPV_URL="$(pin mpv.sourceArchiveUrl)"
readonly MPV_SHA256="$(pin mpv.sourceArchiveSha256)"
readonly FFMPEG_VERSION="$(pin linux.libmpv.ffmpeg.version)"
readonly FFMPEG_URL="$(pin linux.libmpv.ffmpeg.url)"
readonly FFMPEG_SHA256="$(pin linux.libmpv.ffmpeg.sha256)"
readonly LIBPLACEBO_VERSION="$(pin linux.libmpv.libplacebo.version)"
readonly LIBPLACEBO_COMMIT="$(pin linux.libmpv.libplacebo.commit)"
readonly LIBPLACEBO_URL="$(pin linux.libmpv.libplacebo.url)"
readonly LIBPLACEBO_SHA256="$(pin linux.libmpv.libplacebo.sha256)"
readonly FAST_FLOAT_COMMIT="$(pin linux.libmpv.fastFloat.commit)"
readonly FAST_FLOAT_URL="$(pin linux.libmpv.fastFloat.url)"
readonly FAST_FLOAT_SHA256="$(pin linux.libmpv.fastFloat.sha256)"
readonly PREFIX="$(pin linux.libmpv.prefix)"
readonly WORK_ROOT="${COLORFUL_MPV_BUILD_ROOT:-/tmp/colorful-mpv-source}"
readonly JOBS="${COLORFUL_MPV_JOBS:-$(nproc)}"

download_verified() {
    local url="$1" expected="$2" output="$3"
    curl --fail --location --retry 3 --retry-delay 2 --proto '=https' --tlsv1.2 \
        "$url" --output "$output"
    printf '%s  %s\n' "$expected" "$output" | sha256sum --check --status -
}

extract_archive() {
    local archive="$1" destination="$2"
    mkdir -p "$destination"
    tar --extract --file "$archive" --strip-components=1 --directory "$destination"
}

rm -rf "$WORK_ROOT"
mkdir -p "$WORK_ROOT/downloads" "$WORK_ROOT/ffmpeg/source" \
    "$WORK_ROOT/libplacebo/source" "$WORK_ROOT/mpv/source"

download_verified "$FFMPEG_URL" "$FFMPEG_SHA256" "$WORK_ROOT/downloads/ffmpeg.tar.xz"
download_verified "$LIBPLACEBO_URL" "$LIBPLACEBO_SHA256" "$WORK_ROOT/downloads/libplacebo.tar.gz"
download_verified "$FAST_FLOAT_URL" "$FAST_FLOAT_SHA256" "$WORK_ROOT/downloads/fast-float.tar.gz"
download_verified "$MPV_URL" "$MPV_SHA256" "$WORK_ROOT/downloads/mpv.tar.gz"

extract_archive "$WORK_ROOT/downloads/ffmpeg.tar.xz" "$WORK_ROOT/ffmpeg/source"
extract_archive "$WORK_ROOT/downloads/libplacebo.tar.gz" "$WORK_ROOT/libplacebo/source"
extract_archive "$WORK_ROOT/downloads/mpv.tar.gz" "$WORK_ROOT/mpv/source"
extract_archive "$WORK_ROOT/downloads/fast-float.tar.gz" \
    "$WORK_ROOT/libplacebo/source/3rdparty/fast_float"

grep -Fq "$MPV_COMMIT" <<<"$MPV_URL"
grep -Fq "$LIBPLACEBO_COMMIT" <<<"$LIBPLACEBO_URL"
grep -Fq "$FAST_FLOAT_COMMIT" <<<"$FAST_FLOAT_URL"

# Build shared FFmpeg libraries for libmpv. The standalone ffmpeg/ffprobe
# binaries bundled by package-linux.sh remain independently pinned there.
pushd "$WORK_ROOT/ffmpeg/source" >/dev/null
./configure \
    --prefix="$PREFIX" \
    --libdir="$PREFIX/lib" \
    --enable-shared \
    --disable-static \
    --enable-pic \
    --disable-autodetect \
    --enable-gnutls \
    --disable-programs \
    --disable-doc \
    --disable-debug
make -j"$JOBS"
make install
popd >/dev/null

# Make the freshly installed FFmpeg libraries discoverable by libplacebo and
# then by mpv, even though the private prefix is outside pkg-config defaults.
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="$PREFIX/lib:${LD_LIBRARY_PATH:-}"

pushd "$WORK_ROOT/libplacebo/source" >/dev/null
meson setup build \
    --prefix="$PREFIX" \
    --libdir=lib \
    --buildtype=release \
    -Dtests=false \
    -Ddemos=false \
    -Dvulkan=disabled \
    -Dopengl=disabled \
    -Dglslang=disabled \
    -Dshaderc=disabled \
    -Dlcms=disabled
meson compile -C build -j "$JOBS"
meson install -C build
popd >/dev/null

# mpv itself is shared-library enabled. This produces the official libmpv
# ABI (libmpv.so.2) and installs mpv.pc for pkg-config consumers.
pushd "$WORK_ROOT/mpv/source" >/dev/null
printf '%s\n' "$MPV_VERSION" > MPV_VERSION
meson setup build \
    --prefix="$PREFIX" \
    --libdir=lib \
    --buildtype=release \
    -Ddefault_library=shared \
    -Dlibmpv=true \
    -Dcplayer=false \
    -Dbuild-date=false \
    -Dalsa=enabled \
    -Dpulse=enabled \
    -Dpipewire=disabled \
    -Dgl=disabled \
    -Dvulkan=disabled \
    -Dx11=disabled \
    -Dwayland=disabled \
    -Degl=disabled
meson compile -C build -j "$JOBS"
meson install -C build
popd >/dev/null

printf '%s\n' "$PREFIX/lib" > /etc/ld.so.conf.d/colorful-mpv.conf
mkdir -p "$PREFIX/share/colorful"
printf '%s\n' "$MPV_VERSION" > "$PREFIX/share/colorful/mpv-source-version"
ldconfig
test -f "$PREFIX/lib/pkgconfig/mpv.pc"
test -f "$PREFIX/lib/libmpv.so.2"
test "$(pkg-config --modversion mpv)" = "$MPV_CLIENT_API_VERSION"
test "$(pkg-config --variable=libdir mpv)" = "$PREFIX/lib"
pkg-config --exists alsa libpulse libavcodec libavformat libplacebo
test "$(pkg-config --modversion libplacebo)" = "$LIBPLACEBO_VERSION"
printf 'Built mpv %s (%s) with FFmpeg %s and libplacebo %s.\n' \
    "$MPV_VERSION" "$MPV_COMMIT" "$FFMPEG_VERSION" "$LIBPLACEBO_VERSION"

rm -rf "$WORK_ROOT"
