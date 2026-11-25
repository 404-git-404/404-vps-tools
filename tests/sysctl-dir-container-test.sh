#!/usr/bin/env bash
# shellcheck disable=SC2329 # Hooks are called through the sourced installer.
# Runs the real configure_tcp_tuning and write_ipv6_restore_policy on the real paths of a
# minimal Debian container that has no /etc/sysctl.d, as on a minimal Debian 13 install.
# Destructive by design (it removes /etc/sysctl.d): refuses to run outside a container.
set -Eeuo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "$3: expected [$1], got [$2]"; }

[[ "${VPS_TEST_CONTAINER:-}" == 1 && -f /.dockerenv ]] || {
  echo 'SKIP: needs a throw-away container (docker run -e VPS_TEST_CONTAINER=1)'
  exit 0
}
(( EUID == 0 )) || fail 'needs root'
command -v sysctl >/dev/null 2>&1 || fail 'needs procps (sysctl)'

# shellcheck disable=SC1091
source "$repo/debian-init.sh"
trap - EXIT ERR HUP INT TERM
IFS=$' \t\n'

# Start from a system with none of the directories the installer writes into.
for dir in /etc/sysctl.d /etc/modules-load.d; do
  rm -rf -- "$dir"
  [[ ! -e "$dir" ]] || fail "could not remove $dir"
done
BACKUP_DIR=$(mktemp -d)
TMP_DIR=$(mktemp -d)

configure_tcp_tuning
[[ -f "$TCP_SYSCTL" ]] || fail 'TCP sysctl file was not written'
grep -Fxq 'net.core.rmem_max = 33554432' "$TCP_SYSCTL" || fail 'TCP sysctl content'
eq 755 "$(stat -c %a /etc/sysctl.d)" '/etc/sysctl.d mode'
if [[ -e "$BBR_MODULES" ]]; then eq 755 "$(stat -c %a /etc/modules-load.d)" '/etc/modules-load.d mode'; fi

rm -rf -- /etc/sysctl.d
write_ipv6_restore_policy
[[ -f "$NETWORK_SYSCTL" ]] || fail 'IPv6 override file was not written'
eq 644 "$(stat -c %a "$NETWORK_SYSCTL")" 'override file mode'
eq 755 "$(stat -c %a /etc/sysctl.d)" '/etc/sysctl.d mode (override)'
eq "$AUTO_RESTORE_MARK" "$(sed -n 2p "$NETWORK_SYSCTL")" 'override marker'

rm -f -- "$TCP_SYSCTL" "$NETWORK_SYSCTL" "$BBR_MODULES"
rm -rf -- "$BACKUP_DIR" "$TMP_DIR"
# shellcheck disable=SC1091
. /etc/os-release
printf 'sysctl-dir container test passed (%s)\n' "$PRETTY_NAME"
