#!/usr/bin/env bash
set -Eeuo pipefail

results=${NEEDS_JSON:?Missing workflow dependency results}
jq -r 'to_entries[] | "\(.key): \(.value.result)"' <<<"$results"
if ! jq -e '
  keys == ["migration", "release-assets", "release-package"] and
  all(.[]; .result == "success")
' <<<"$results"; then
  echo '::error::Every SmartDNS package matrix and integration job must succeed; failed, cancelled, skipped or missing jobs block merging.' >&2
  exit 1
fi
