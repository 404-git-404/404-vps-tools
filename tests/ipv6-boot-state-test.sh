#!/usr/bin/env bash
# Runs the real systemd-sysctl in a throw-away network namespace against the real
# sysctl directories. Needs Linux, root and systemd; CI runs it with sudo.
# Without --require it skips when the environment cannot do that.
set -Eeuo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd)
require=false
[[ "${1:-}" != --require ]] || require=true

skip() {
  if [[ "$require" == true ]]; then printf 'FAIL: %s\n' "$*" >&2; exit 1; fi
  printf 'SKIP: %s\n' "$*"
  exit 0
}
[[ "$(uname -s)" == Linux ]] || skip 'not Linux'
(( EUID == 0 )) || skip 'not root'
[[ -d /proc/sys/net/ipv6 ]] || skip 'kernel without IPv6'

# shellcheck disable=SC1091
source "$REPO_ROOT/debian-init.sh"
trap - EXIT ERR HUP INT TERM
IFS=$' \t\n'
systemd_sysctl_path >/dev/null || skip 'systemd-sysctl not installed'
command -v unshare >/dev/null 2>&1 || skip 'unshare not installed'

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "$3: expected [$1], got [$2]"; }

declare -a created=()
cleanup_files() {
  local f
  for f in "${created[@]}"; do rm -f -- "$f"; done
  created=()
}
trap cleanup_files EXIT
put() {
  local path=$1
  shift
  mkdir -p -- "${path%/*}"
  printf '%s\n' "$@" >"$path"
  created+=("$path")
}
host_values() { cat /proc/sys/net/ipv6/conf/all/disable_ipv6 /proc/sys/net/ipv6/conf/default/disable_ipv6 | paste -sd ' ' -; }
# Lowest-priority baseline so every case starts from a known "on" state.
baseline() { put /etc/sysctl.d/10-vpstest-zero.conf 'net.ipv6.conf.all.disable_ipv6 = 0' 'net.ipv6.conf.default.disable_ipv6 = 0'; }
check() {
  local expected=$1 label=$2
  eq "$expected" "$(ipv6_boot_state)" "$label"
  cleanup_files
}

before=$(host_values)

baseline
check on 'baseline'

baseline
put /usr/lib/sysctl.d/60-vpstest-a.conf 'net.ipv6.conf.all.disable_ipv6 = 1'
check off 'vendor sets 1'

baseline
put /usr/lib/sysctl.d/60-vpstest-a.conf 'net.ipv6.conf.all.disable_ipv6 = 1' 'net.ipv6.conf.default.disable_ipv6 = 1'
put /etc/sysctl.d/61-vpstest-b.conf 'net/ipv6/conf/all/disable_ipv6 = 0' 'net/ipv6/conf/default/disable_ipv6 = 0'
check on 'vendor 1 then /etc slash-style 0'

baseline
put /usr/lib/sysctl.d/60-vpstest-a.conf 'net.ipv6.conf.all.disable_ipv6 = 1' 'net.ipv6.conf.default.disable_ipv6 = 1'
put /etc/sysctl.d/60-vpstest-a.conf 'net/ipv6/conf/all/disable_ipv6 = 0' 'net/ipv6/conf/default/disable_ipv6 = 0'
check on 'same-named /etc file masks the vendor file'

baseline
put /etc/sysctl.d/60-vpstest-a.conf 'net/ipv6/conf/all/disable_ipv6 = 0' 'net/ipv6/conf/default/disable_ipv6 = 0'
put /usr/lib/sysctl.d/61-vpstest-b.conf 'net.ipv6.conf.all.disable_ipv6 = 1' 'net.ipv6.conf.default.disable_ipv6 = 1'
check off 'vendor file that sorts later wins'

# Wildcards are applied after explicit keys and never override them (systemd semantics),
# so this case runs without the explicit baseline.
put /etc/sysctl.d/60-vpstest-a.conf 'net.ipv6.conf.*.disable_ipv6=1'
check off 'wildcard'

baseline
put /etc/sysctl.d/60-vpstest-a.conf 'net.ipv6.conf.*.disable_ipv6=1'
check on 'wildcard does not override explicit keys'

baseline
put /etc/sysctl.d/60-vpstest-a.conf '-net.ipv6.conf.all.disable_ipv6=1'
check off 'line with a leading dash'

baseline
put /etc/sysctl.d/60-vpstest-a.conf 'net.ipv6.conf.lo.disable_ipv6 = 1'
check on 'only lo is set'

baseline
put /etc/sysctl.d/60-vpstest-a.conf 'net.ipv6.conf.eth0.disable_ipv6 = 1'
check on 'interface-specific keys cannot be judged (documented limitation)'

baseline
put /run/sysctl.d/60-vpstest-a.conf 'net.ipv6.conf.default.disable_ipv6 = 1'
check off '/run/sysctl.d'

baseline
put /usr/local/lib/sysctl.d/60-vpstest-a.conf 'net.ipv6.conf.all.disable_ipv6 = 1'
check off '/usr/local/lib/sysctl.d'

# The script's own override file beats the legacy file name, and is the only difference.
baseline
put /etc/sysctl.d/99-disable-ipv6.conf 'net.ipv6.conf.all.disable_ipv6 = 1' 'net.ipv6.conf.default.disable_ipv6 = 1' 'net.ipv6.conf.lo.disable_ipv6 = 1'
eq off "$(ipv6_boot_state)" 'legacy file alone'
lines=$(ipv6_boot_disable_lines)
grep -Fq '/etc/sysctl.d/99-disable-ipv6.conf: net.ipv6.conf.all.disable_ipv6 = 1' <<<"$lines" || fail "display list lacks the legacy file: $lines"
write_ipv6_restore_policy
created+=("$NETWORK_SYSCTL")
auto_restore_policy_file "$NETWORK_SYSCTL" || fail 'restore file not recognised'
eq on "$(ipv6_boot_state)" 'script override beats 99-disable-ipv6.conf'
cleanup_files

eq "$before" "$(host_values)" 'host values changed by the checks'
for f in /etc/sysctl.d/*vpstest* /usr/lib/sysctl.d/*vpstest* /run/sysctl.d/*vpstest* /usr/local/lib/sysctl.d/*vpstest*; do
  [[ ! -e "$f" ]] || fail "test file left behind: $f"
done
printf 'PASS: systemd-sysctl boot state in a network namespace (%s)\n' "$(systemd_sysctl_path)"
