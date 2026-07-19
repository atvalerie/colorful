#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 TIDAL_TRACK_ID" >&2
  exit 2
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
mocha_env="$repo_dir/../mocha/.env"

if [[ -f "$mocha_env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$mocha_env"
  set +a
fi

for command in bun jq gst-play-1.0; do
  if ! command -v "$command" >/dev/null; then
    echo "$command is required" >&2
    exit 1
  fi
done

coproc PROVIDER { bun "$repo_dir/packages/provider-host/src/main.ts"; }
provider_pid="$PROVIDER_PID"
cleanup() {
  kill "$provider_pid" 2>/dev/null || true
  wait "$provider_pid" 2>/dev/null || true
}
trap cleanup EXIT

printf '%s\n' '{"id":9000,"type":"status","payload":{}}' >&"${PROVIDER[1]}"
linked=false
while IFS= read -r -t 20 line <&"${PROVIDER[0]}"; do
  if [[ "$(jq -r '.id // empty' <<<"$line")" == "9000" ]]; then
    if [[ "$(jq -r '.data.linked // false' <<<"$line")" != "true" ]]; then
      echo "colorful's TIDAL account is not linked" >&2
      exit 1
    fi
    linked=true
    break
  fi
done
if [[ "$linked" != true ]]; then
  echo "The provider did not report its login state before the diagnostic timed out" >&2
  exit 1
fi

request="$(jq -cn --arg track_id "$1" '{id:9001,type:"source",payload:{provider:"tidal",trackId:$track_id,manifestType:"MPEG_DASH"}}')"
printf '%s\n' "$request" >&"${PROVIDER[1]}"
manifest_uri=""
while IFS= read -r -t 20 line <&"${PROVIDER[0]}"; do
  if [[ "$(jq -r '.id // empty' <<<"$line")" != "9001" ]]; then continue; fi
  if [[ "$(jq -r '.ok // false' <<<"$line")" != "true" ]]; then
    jq -r '.error // "TIDAL source request failed"' <<<"$line" >&2
    exit 1
  fi
  manifest_uri="$(jq -r '.data.uri // empty' <<<"$line")"
  break
done

if [[ -z "$manifest_uri" ]]; then
  echo "TIDAL did not return a manifest before the diagnostic timed out" >&2
  exit 1
fi

cleanup
trap - EXIT

echo "Starting vanilla GStreamer at 2% volume; the signed URL is not printed or saved."
echo "Use space to pause/resume and the arrow keys to seek. Press q to quit."
exec gst-play-1.0 --accurate-seeks --instant-uri --volume=0.02 "$manifest_uri"
