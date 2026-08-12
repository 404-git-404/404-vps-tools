#!/usr/bin/env bash

set -Eeuo pipefail

if (( $# != 2 )); then
  printf 'Usage: %s /path/to/domain-check domain1/domain2/...\n' "$0" >&2
  exit 2
fi

readonly BINARY=$1
readonly TARGETS=$2

for workers in 2 4 8 12 16; do
  printf '\nworkers=%d targets=%d\n' \
    "$workers" "$(( $(tr -cd '/' <<<"$TARGETS" | wc -c) + 1 ))"
  /usr/bin/time -f 'REAL=%e USER=%U SYS=%S CPU=%P' \
    env DOMAIN_CHECK_CONCURRENCY="$workers" "$BINARY" "$TARGETS" \
    >/dev/null
done
