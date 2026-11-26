#!/usr/bin/env bash
# Print the Release notes for TAG: the README commands, with latest/download replaced by download/TAG.
#   release-notes.sh TAG [README]
set -Eeuo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
tag=${1:-}
readme=${2:-README.md}
bash "$here/release-checks.sh" tag-format "$tag"

printf '%s\n\n' "Install exactly this version. Each command verifies the download against SHA256SUMS before it runs anything."
bash "$here/readme-commands.sh" "$readme" | while IFS=$'\t' read -r lang command; do
  pinned=${command//releases\/latest\/download/releases\/download\/$tag}
  if [[ "$pinned" == "$command" || "$pinned" == *latest* ]]; then
    printf '::error::README command cannot be pinned to %s\n' "$tag" >&2
    exit 1
  fi
# shellcheck disable=SC2016 # The backticks are literal Markdown fences.
  printf '```%s\n%s\n```\n\n' "$lang" "$pinned"
done
printf '%s\n' 'Files: debian-init.sh, alpine-init.sh, gg-status, SHA256SUMS (sha256sum format).'
