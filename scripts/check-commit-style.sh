#!/usr/bin/env bash
set -euo pipefail

if (($# != 2)); then
  echo "usage: $0 BASE HEAD" >&2
  exit 2
fi

base="$1"
head="$2"
zero_sha=0000000000000000000000000000000000000000
if [[ "$base" == "$zero_sha" ]]; then
  range="$head"
else
  range="$base..$head"
fi

pattern='^(feat|fix|perf|refactor|build|ci|docs|test|style|chore|revert)(\([A-Za-z0-9._/-]+\))?!?: .+$'
failed=0
while IFS= read -r commit; do
  [[ -n "$commit" ]] || continue
  subject="$(git show -s --format=%s "$commit")"
  if ((${#subject} > 100)); then
    printf 'invalid commit %.12s: subject exceeds 100 characters\n  %s\n' "$commit" "$subject" >&2
    failed=1
  elif [[ ! "$subject" =~ $pattern ]]; then
    printf 'invalid commit %.12s: expected type(optional-scope): description\n  %s\n' \
      "$commit" "$subject" >&2
    failed=1
  fi
done < <(git rev-list --reverse --no-merges "$range")

if ((failed)); then
  echo "See CONTRIBUTING.md for the colorful commit convention." >&2
  exit 1
fi

echo "Commit subjects follow the colorful convention."
