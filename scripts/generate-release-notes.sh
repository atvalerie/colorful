#!/usr/bin/env bash
set -euo pipefail

if (($# != 1)); then
  echo "usage: $0 TAG" >&2
  exit 2
fi

tag="$1"
git rev-parse --verify --quiet "$tag^{commit}" >/dev/null || {
  echo "release tag does not exist: $tag" >&2
  exit 1
}

previous="$(git describe --tags --abbrev=0 "$tag^" 2>/dev/null || true)"
range="$tag"
if [[ -n "$previous" ]]; then
  range="$previous..$tag"
fi

repo="${GITHUB_REPOSITORY:-}"
declare -A entries
types=(breaking feat fix perf refactor build ci docs test style chore revert other)

while IFS=$'\t' read -r commit subject; do
  [[ -n "$commit" ]] || continue
  type=other
  scope=
  description="$subject"
  if [[ "$subject" =~ ^(feat|fix|perf|refactor|build|ci|docs|test|style|chore|revert)(\(([A-Za-z0-9._/-]+)\))?(!)?:[[:space:]](.+)$ ]]; then
    type="${BASH_REMATCH[1]}"
    scope="${BASH_REMATCH[3]}"
    description="${BASH_REMATCH[5]}"
    [[ -z "${BASH_REMATCH[4]}" ]] || type=breaking
  fi

  prefix=
  [[ -z "$scope" ]] || prefix="**$scope:** "
  reference="\`${commit:0:7}\`"
  if [[ -n "$repo" ]]; then
    reference="[\`${commit:0:7}\`](https://github.com/$repo/commit/$commit)"
  fi
  entries["$type"]+="- ${prefix}${description} ($reference)"$'\n'
done < <(git log --reverse --no-merges --format='%H%x09%s' "$range")

declare -A titles=(
  [breaking]="Breaking changes"
  [feat]="New features"
  [fix]="Fixes"
  [perf]="Performance"
  [refactor]="Refactoring"
  [build]="Build and packaging"
  [ci]="Automation"
  [docs]="Documentation"
  [test]="Tests"
  [style]="Visual and style changes"
  [chore]="Maintenance"
  [revert]="Reverts"
  [other]="Other changes"
)

echo "## What's changed"
echo
for type in "${types[@]}"; do
  [[ -n "${entries[$type]:-}" ]] || continue
  printf '### %s\n\n%s\n' "${titles[$type]}" "${entries[$type]}"
done

if [[ -n "$repo" && -n "$previous" ]]; then
  printf '**Full changelog:** https://github.com/%s/compare/%s...%s\n' "$repo" "$previous" "$tag"
fi
