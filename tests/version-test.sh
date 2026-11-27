#!/usr/bin/env bash
# shellcheck disable=SC2016 # Single quotes keep searched or generated shell code literal.
# One repository-wide version: the three released scripts agree and report it with --version.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

constant() {
  local value
  value=$(tr -d '\r' <"$repo/$1" | grep -E "^(readonly )?SCRIPT_VERSION='[0-9]+\.[0-9]+\.[0-9]+'$") ||
    fail "$1 has no plain SCRIPT_VERSION constant"
  [[ "$(wc -l <<<"$value")" -eq 1 ]] || fail "$1 defines SCRIPT_VERSION more than once"
  value=${value#*\'}
  printf '%s\n' "${value%\'}"
}

debian=$(constant debian-init.sh)
alpine=$(constant alpine-init.sh)
gg=$(constant gg-status)
[[ "$debian" == "$alpine" && "$debian" == "$gg" ]] || fail "versions differ: debian=$debian alpine=$alpine gg-status=$gg"
version=$debian

# POSIX sh scripts keep a plain assignment; only the Bash script uses readonly.
grep -Eq "^readonly SCRIPT_VERSION='$version'\$" "$repo/debian-init.sh" || fail 'debian-init.sh must declare the constant readonly'
grep -Eq "^[[:space:]]*SCRIPT_VERSION='$version'\$" "$repo/alpine-init.sh" || fail 'alpine-init.sh needs a plain SCRIPT_VERSION assignment'
tr -d '\r' <"$repo/gg-status" | grep -Eq "^SCRIPT_VERSION='$version'\$" || fail 'gg-status needs a plain SCRIPT_VERSION assignment'
# yt-region is frozen by AGENTS.md and carries no version.
if grep -q SCRIPT_VERSION "$repo/yt-region"; then fail 'yt-region must not be modified'; fi

[[ "$(bash "$repo/debian-init.sh" --version)" == "debian-init.sh $version" ]] || fail 'debian-init.sh --version output'
[[ "$(bash "$repo/debian-init.sh" -V)" == "debian-init.sh $version" ]] || fail 'debian-init.sh -V output'
for shell_path in /bin/sh /bin/dash; do
  [[ -x "$shell_path" ]] || continue
  [[ "$("$shell_path" "$repo/alpine-init.sh" --version)" == "alpine-init.sh $version" ]] || fail "alpine-init.sh --version under $shell_path"
  [[ "$("$shell_path" "$repo/gg-status" --version)" == "gg-status $version" ]] || fail "gg-status --version under $shell_path"
done

# --version exits before any other work, even for a user who is not root and with other arguments after it.
[[ "$(bash "$repo/debian-init.sh" --version --audit)" == "debian-init.sh $version" ]] || fail 'debian-init.sh --version must exit before other options'

# The menu and the final report show the version, and the help lists the option.
grep -Fq '404-vps-tools · debian-init.sh v$SCRIPT_VERSION' "$repo/debian-init.sh" || fail 'menu does not show the version'
grep -Fq '脚本版本      : $SCRIPT_VERSION' "$repo/debian-init.sh" || fail 'final report does not show the version'
bash "$repo/debian-init.sh" --help | grep -Fq -- '--version' || fail '--help does not list --version'

echo "PASS: all scripts share version $version and report it"
