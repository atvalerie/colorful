#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/home/val/Android/Sdk}"
export JAVA_HOME="${COLORFUL_JAVA_HOME:-/home/val/.local/share/JetBrains/Toolbox/apps/android-studio/jbr}"
exec "$repo_root/apps/android/gradlew" -p "$repo_root/apps/android" :app:assembleDebug "$@"
