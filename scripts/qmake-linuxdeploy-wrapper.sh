#!/usr/bin/env bash
set -euo pipefail

real_qmake="${COLORFUL_REAL_QMAKE:?COLORFUL_REAL_QMAKE is required}"
plugin_stage="${COLORFUL_QT_PLUGIN_STAGE:?COLORFUL_QT_PLUGIN_STAGE is required}"

if [[ "${1:-}" == "-query" && $# -eq 1 ]]; then
  "$real_qmake" -query | sed "s|^QT_INSTALL_PLUGINS:.*|QT_INSTALL_PLUGINS:$plugin_stage|"
elif [[ "${1:-}" == "-query" && "${2:-}" == "QT_INSTALL_PLUGINS" ]]; then
  printf '%s\n' "$plugin_stage"
else
  exec "$real_qmake" "$@"
fi
