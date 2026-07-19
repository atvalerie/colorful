#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 TIDAL_TRACK_ID [VOLUME_0_TO_0.25|inspect|mpv]" >&2
  exit 2
fi

test_volume="${2:-0.02}"
inspect_only=false
if [[ "$test_volume" == inspect ]]; then inspect_only=true; fi
use_mpv=false
if [[ "$test_volume" == mpv ]]; then use_mpv=true; test_volume=0.02; fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
mocha_env="$repo_dir/../mocha/.env"

if [[ -f "$mocha_env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$mocha_env"
  set +a
fi

required_commands=(bun jq)
if [[ "$inspect_only" == true ]]; then required_commands+=(curl xmllint); fi
if [[ "$use_mpv" == true ]]; then required_commands+=(mpv); else required_commands+=(gst-play-1.0); fi
for command in "${required_commands[@]}"; do
  if ! command -v "$command" >/dev/null; then
    echo "$command is required" >&2
    exit 1
  fi
done

if [[ "$inspect_only" != true ]] && ! jq -en --arg value "$test_volume" \
    '($value | tonumber? // -1) as $volume | $volume >= 0 and $volume <= 0.25' >/dev/null; then
  echo "Diagnostic volume must be between 0 and 0.25" >&2
  exit 2
fi

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

if [[ "$inspect_only" == true ]]; then
  manifest="$(curl --fail --silent --show-error --location "$manifest_uri")"
  echo "body bytes: ${#manifest}"
  printf 'first bytes: '
  printf '%s' "$manifest" | od -An -tx1 -N16 | tr -d '\n'
  echo
  if [[ "$manifest" == '<?xml'* ]]; then
    echo "--- DASH timeline (all resource URIs redacted) ---"
    xmllint --format - <<<"$manifest" \
      | sed -E 's#<BaseURL>.*</BaseURL>#<BaseURL>REDACTED</BaseURL>#; s/(media|initialization|sourceURL|href|url)="[^"]+"/\1="REDACTED"/g' \
      | grep -E '<(MPD|Period|AdaptationSet|Representation|SegmentTemplate|SegmentTimeline|S)([ >]|$)'
    exit 0
  fi
  echo "--- manifest tags (all resource URIs redacted) ---"
  sed -E 's/URI="[^"]+"/URI="<redacted>"/g; /^[^#]/d' <<<"$manifest"
  while IFS= read -r child_uri; do
    [[ -z "$child_uri" ]] && continue
    child_uri="$(bun -e 'console.log(new URL(process.argv[1], process.argv[2]).href)' "$child_uri" "$manifest_uri")"
    echo "--- child manifest tags (all resource URIs redacted) ---"
    curl --fail --silent --show-error --location "$child_uri" \
      | sed -E 's/URI="[^"]+"/URI="<redacted>"/g; /^[^#]/d'
  done < <(sed -n '/^[^#[:space:]]/p' <<<"$manifest")
  exit 0
fi

if [[ "$use_mpv" == true ]]; then
  echo "Starting mpv at 2% volume; the signed URL is not printed or saved."
  echo "Use space to pause/resume and the arrow keys to seek. Press q to quit."
  exec mpv --no-video --volume=2 --cache=yes "$manifest_uri"
fi

echo "Starting vanilla GStreamer at volume $test_volume; the signed URL is not printed or saved."
echo "Use space to pause/resume and the arrow keys to seek. Press q to quit."
exec gst-play-1.0 --accurate-seeks --instant-uri --volume="$test_volume" "$manifest_uri"
