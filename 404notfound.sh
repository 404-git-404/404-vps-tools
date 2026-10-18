#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
BOOTSTRAP_TMP=''

# Prefer the adjacent implementation for a local checkout. curl | process
# substitution has no adjacent files, so stage and syntax-check it first.
main() {
  local script_dir implementation
  script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  implementation="$script_dir/debian-init.sh"
  if [[ -f "$implementation" ]]; then
    exec bash "$implementation" "$@"
  fi

  BOOTSTRAP_TMP=$(mktemp -d)
  trap 'rm -rf -- "$BOOTSTRAP_TMP"' EXIT
  trap 'exit 130' INT TERM
  curl --fail --silent --show-error --location \
    --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 120 --retry 3 \
    https://raw.githubusercontent.com/404-git-404/404-vps-tools/main/debian-init.sh \
    -o "$BOOTSTRAP_TMP/debian-init.sh"
  bash -n "$BOOTSTRAP_TMP/debian-init.sh"
  bash "$BOOTSTRAP_TMP/debian-init.sh" "$@"
}

main "$@"
