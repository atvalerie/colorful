# syntax=docker/dockerfile:1.7

FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive
ARG QT_VERSION=6.8.3
ARG AQT_VERSION=3.3.0
ARG CMAKE_VERSION=3.31.6
ARG RUST_VERSION=1.97.0
ARG BUN_VERSION=1.3.14

RUN apt-get update \
    && apt-get install --no-install-recommends -y \
        appstream \
        binutils \
        build-essential \
        ca-certificates \
        curl \
        desktop-file-utils \
        ffmpeg \
        file \
        git \
        libdbus-1-3 \
        libegl1 \
        libegl-dev \
        libfontconfig1 \
        libfuse2 \
        libgl1 \
        libgl-dev \
        libglib2.0-0 \
        libmpv-dev \
        libopengl0 \
        libopengl-dev \
        libsecret-tools \
        libx11-xcb1 \
        libxcb-cursor0 \
        libxcb-icccm4 \
        libxcb-image0 \
        libxcb-keysyms1 \
        libxcb-randr0 \
        libxcb-render-util0 \
        libxcb-shape0 \
        libxcb-xinerama0 \
        libxcb-xkb1 \
        libxkbcommon-x11-0 \
        libxi6 \
        libxrender1 \
        ninja-build \
        patchelf \
        pkg-config \
        python3 \
        python3-pip \
        tar \
        unzip \
        xauth \
        xz-utils \
        xvfb \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --no-cache-dir \
        "aqtinstall==$AQT_VERSION" \
        "cmake==$CMAKE_VERSION" \
    && aqt install-qt linux desktop "$QT_VERSION" linux_gcc_64 \
        --outputdir /opt/Qt \
        --modules qtimageformats

ENV QT_ROOT=/opt/Qt/${QT_VERSION}/gcc_64
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV PATH=${QT_ROOT}/bin:/opt/cargo/bin:/opt/bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV CMAKE_PREFIX_PATH=${QT_ROOT}
ENV PKG_CONFIG_PATH=${QT_ROOT}/lib/pkgconfig
ENV QML2_IMPORT_PATH=${QT_ROOT}/qml
ENV QT_PLUGIN_PATH=${QT_ROOT}/plugins
ENV RUSTUP_HOME=/opt/rustup
ENV CARGO_HOME=/opt/cargo

RUN curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
        https://sh.rustup.rs -o /tmp/rustup.sh \
    && sh /tmp/rustup.sh -y --no-modify-path --profile minimal \
        --default-toolchain "$RUST_VERSION" \
    && rm /tmp/rustup.sh \
    && rustc --version \
    && cargo --version

RUN curl --fail --location --retry 3 \
        "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-x64.zip" \
        -o /tmp/bun.zip \
    && unzip -q /tmp/bun.zip -d /tmp/bun \
    && install -Dm755 /tmp/bun/bun-linux-x64/bun /opt/bun/bin/bun \
    && rm -rf /tmp/bun /tmp/bun.zip \
    && bun --version

WORKDIR /workspace

ENV HOME=/workspace/.cache/container/home
ENV CARGO_HOME=/workspace/.cache/container/cargo
ENV CARGO_TARGET_DIR=/workspace/.cache/container/target
ENV BUN_INSTALL_CACHE_DIR=/workspace/.cache/container/bun
ENV COLORFUL_BUILD_ROOT=/workspace/.cache/container/build
ENV COLORFUL_LINUXDEPLOY_DIR=/workspace/.cache/container/linuxdeploy
ENV COLORFUL_DIST_DIR=/workspace/dist
ENV COLORFUL_MAX_GLIBC=2.35

CMD ["./scripts/package-linux-container-entrypoint.sh"]
