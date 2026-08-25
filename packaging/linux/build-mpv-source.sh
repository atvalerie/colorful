#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 ffmpeg|libplacebo|mpv" >&2
    exit 2
fi
phase="$1"
case "$phase" in
    ffmpeg|libplacebo|mpv) ;;
    *)
        echo "usage: $0 ffmpeg|libplacebo|mpv" >&2
        exit 2
        ;;
esac

manifest="${COLORFUL_DEPENDENCY_MANIFEST:-/tmp/desktop-dependencies.json}"
pin() {
    python3 -c 'import json,sys; value=json.load(open(sys.argv[1], encoding="utf-8")); [value := value[key] for key in sys.argv[2].split(".")]; print(value)' \
        "$manifest" "$1"
}

readonly MPV_VERSION="$(pin mpv.sourceVersion)"
readonly MPV_COMMIT="$(pin mpv.sourceCommit)"
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
readonly VULKAN_HEADERS_COMMIT="$(pin linux.libmpv.vulkanHeaders.commit)"
readonly VULKAN_HEADERS_URL="$(pin linux.libmpv.vulkanHeaders.url)"
readonly VULKAN_HEADERS_SHA256="$(pin linux.libmpv.vulkanHeaders.sha256)"
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
trap 'rm -rf "$WORK_ROOT"' EXIT
mkdir -p "$WORK_ROOT/downloads"

build_ffmpeg() {
    mkdir -p "$WORK_ROOT/ffmpeg/source"
    download_verified "$FFMPEG_URL" "$FFMPEG_SHA256" "$WORK_ROOT/downloads/ffmpeg.tar.xz"
    extract_archive "$WORK_ROOT/downloads/ffmpeg.tar.xz" "$WORK_ROOT/ffmpeg/source"
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
}

build_libplacebo() {
    mkdir -p "$WORK_ROOT/libplacebo/source"
    download_verified "$LIBPLACEBO_URL" "$LIBPLACEBO_SHA256" "$WORK_ROOT/downloads/libplacebo.tar.gz"
    download_verified "$FAST_FLOAT_URL" "$FAST_FLOAT_SHA256" "$WORK_ROOT/downloads/fast-float.tar.gz"
    download_verified "$VULKAN_HEADERS_URL" "$VULKAN_HEADERS_SHA256" "$WORK_ROOT/downloads/vulkan-headers.tar.gz"
    extract_archive "$WORK_ROOT/downloads/libplacebo.tar.gz" "$WORK_ROOT/libplacebo/source"
    extract_archive "$WORK_ROOT/downloads/fast-float.tar.gz" \
        "$WORK_ROOT/libplacebo/source/3rdparty/fast_float"
    extract_archive "$WORK_ROOT/downloads/vulkan-headers.tar.gz" \
        "$WORK_ROOT/libplacebo/source/3rdparty/Vulkan-Headers"
    grep -Fq "$LIBPLACEBO_COMMIT" <<<"$LIBPLACEBO_URL"
    grep -Fq "$FAST_FLOAT_COMMIT" <<<"$FAST_FLOAT_URL"
    grep -Fq "$VULKAN_HEADERS_COMMIT" <<<"$VULKAN_HEADERS_URL"
    test -f "$WORK_ROOT/libplacebo/source/3rdparty/Vulkan-Headers/include/vulkan/vulkan.h"

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
}

build_mpv() {
    mkdir -p "$WORK_ROOT/mpv/source"
    download_verified "$MPV_URL" "$MPV_SHA256" "$WORK_ROOT/downloads/mpv.tar.gz"
    extract_archive "$WORK_ROOT/downloads/mpv.tar.gz" "$WORK_ROOT/mpv/source"
    grep -Fq "$MPV_COMMIT" <<<"$MPV_URL"

    export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig:${PKG_CONFIG_PATH:-}"
    export LD_LIBRARY_PATH="$PREFIX/lib:${LD_LIBRARY_PATH:-}"
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
}

case "$phase" in
    ffmpeg) build_ffmpeg ;;
    libplacebo) build_libplacebo ;;
    mpv) build_mpv ;;
esac

if [[ "$phase" == mpv ]]; then
    printf '%s\n' "$PREFIX/lib" > /etc/ld.so.conf.d/colorful-mpv.conf
    mkdir -p "$PREFIX/share/colorful"
    printf '%s\n' "$MPV_VERSION" > "$PREFIX/share/colorful/mpv-source-version"
    ldconfig
    test -f "$PREFIX/lib/pkgconfig/mpv.pc"
    test "$(pkg-config --variable=libdir mpv)" = "$PREFIX/lib"
    pkg-config --exists alsa libpulse libavcodec libavformat libplacebo
    printf 'Built mpv %s (%s) with FFmpeg %s and libplacebo %s.\n' \
        "$MPV_VERSION" "$MPV_COMMIT" "$FFMPEG_VERSION" "$LIBPLACEBO_VERSION"
fi
