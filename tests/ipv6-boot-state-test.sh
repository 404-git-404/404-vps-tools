#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031,SC2329 # Subshell self-tests and function overrides are intentional.
# Runs the real systemd-sysctl in a throw-away network namespace against the real
# sysctl directories. Needs Linux, root and systemd; CI runs it with sudo and in
# Debian 12/13 containers (systemd 252 and 257).
# Without --require it skips when the environment cannot do that. It also skips,
# and says why, when one of the files it would create already exists.
# Every file it creates has a unique name and is registered before it is written;
# the one fixed name (the script's own network file) is backed up first and restored.
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

tag="vpstest$$"
f_zero="/etc/sysctl.d/10-$tag-zero.conf"
f_etc_a="/etc/sysctl.d/60-$tag-a.conf"
f_etc_b="/etc/sysctl.d/61-$tag-b.conf"
f_lib_a="/usr/lib/sysctl.d/60-$tag-a.conf"
f_lib_b="/usr/lib/sysctl.d/61-$tag-b.conf"
f_run_a="/run/sysctl.d/60-$tag-a.conf"
f_local_a="/usr/local/lib/sysctl.d/60-$tag-a.conf"
f_legacy="/etc/sysctl.d/99-disable-ipv6-$tag.conf"
f_self="/etc/sysctl.d/70-$tag-selftest.conf"
for f in "$f_zero" "$f_etc_a" "$f_etc_b" "$f_lib_a" "$f_lib_b" "$f_run_a" "$f_local_a" "$f_legacy" "$f_self"; do
  [[ ! -e "$f" && ! -L "$f" ]] || skip "$f already exists; not touching it"
done
[[ ! -L "$NETWORK_SYSCTL" ]] || skip "$NETWORK_SYSCTL is a symlink; not touching it"

declare -a created=()
declare -a created_dirs=()
network_backup=''
network_existed=false
network_registered=false

restore_network_sysctl() {
  if [[ "$network_registered" == true ]]; then
    if [[ "$network_existed" == true ]]; then
      cat "$network_backup" >"$NETWORK_SYSCTL"
    else
      rm -f -- "$NETWORK_SYSCTL"
    fi
    network_registered=false
  fi
  if [[ -n "$network_backup" ]]; then rm -f -- "$network_backup"; network_backup=''; fi
}
cleanup_files() {
  local f
  for f in "${created[@]}"; do rm -f -- "$f"; done
  created=()
}
cleanup_all() {
  set +e
  cleanup_files
  restore_network_sysctl
  local d
  for d in "${created_dirs[@]}"; do rmdir -- "$d" 2>/dev/null; done
  created_dirs=()
}
trap cleanup_all EXIT
trap 'exit 143' TERM INT HUP

# Register first, then write. Existing files are never overwritten.
put() {
  local path=$1
  shift
  [[ ! -e "$path" && ! -L "$path" ]] || fail "refusing to overwrite $path"
  created+=("$path")
  if [[ ! -d "${path%/*}" ]]; then
    created_dirs+=("${path%/*}")
    mkdir -p -- "${path%/*}"
  fi
  printf '%s\n' "$@" >"$path"
}
# The fixed network file: take the backup, then register the restore, then allow writes.
protect_network_sysctl() {
  network_backup=$(mktemp)
  # Debian 13 may not have /etc/sysctl.d at all: remember to remove it if we end up creating it.
  [[ -d "${NETWORK_SYSCTL%/*}" ]] || created_dirs+=("${NETWORK_SYSCTL%/*}")
  if [[ -e "$NETWORK_SYSCTL" ]]; then
    network_existed=true
    cat "$NETWORK_SYSCTL" >"$network_backup"
  else
    network_existed=false
  fi
  network_registered=true
}
host_values() { cat /proc/sys/net/ipv6/conf/all/disable_ipv6 /proc/sys/net/ipv6/conf/default/disable_ipv6 | paste -sd ' ' -; }
# Lowest-priority baseline so every case starts from a known "on" state.
baseline() { put "$f_zero" 'net.ipv6.conf.all.disable_ipv6 = 0' 'net.ipv6.conf.default.disable_ipv6 = 0'; }
check() {
  local expected=$1 label=$2
  eq "$expected" "$(ipv6_boot_state)" "$label"
  cleanup_files
}

before=$(host_values)
protect_network_sysctl

# --- the cleanup itself: failure midway, termination, and a pre-existing fixed file ----------
selftest_failure() {
  (
    created=()
    created_dirs=()
    trap cleanup_all EXIT
    protect_network_sysctl
    put "$f_self" 'net.ipv6.conf.all.disable_ipv6 = 1'
    write_ipv6_restore_policy
    exit 1
  ) || true
}
selftest_term() {
  (
    created=()
    created_dirs=()
    trap cleanup_all EXIT
    trap 'exit 143' TERM
    protect_network_sysctl
    put "$f_self" 'net.ipv6.conf.all.disable_ipv6 = 1'
    write_ipv6_restore_policy
    kill -TERM "$BASHPID"
    sleep 5
  ) || true
}
# No fixed file before: it is gone again.
selftest_failure
[[ ! -e "$f_self" ]] || fail 'failure midway left a created file behind'
[[ ! -e "$NETWORK_SYSCTL" ]] || fail 'failure midway left the network file behind'
selftest_term
[[ ! -e "$f_self" ]] || fail 'termination left a created file behind'
[[ ! -e "$NETWORK_SYSCTL" ]] || fail 'termination left the network file behind'
# A file that already existed keeps its exact content, whatever happens in between.
fixture=$'# an administrator wrote this\nnet.ipv6.conf.all.accept_ra = 2'
mkdir -p -- "${NETWORK_SYSCTL%/*}"
printf '%s\n' "$fixture" >"$NETWORK_SYSCTL"
selftest_failure
eq "$fixture" "$(cat "$NETWORK_SYSCTL")" 'failure midway changed the pre-existing network file'
selftest_term
eq "$fixture" "$(cat "$NETWORK_SYSCTL")" 'termination changed the pre-existing network file'
[[ ! -e "$f_self" ]] || fail 'created file left behind next to a pre-existing network file'
rm -f -- "$NETWORK_SYSCTL"

# --- the boot state against the real tool ------------------------------------------------------
baseline
check on 'baseline'

baseline
put "$f_lib_a" 'net.ipv6.conf.all.disable_ipv6 = 1'
check off 'vendor sets 1'

baseline
put "$f_lib_a" 'net.ipv6.conf.all.disable_ipv6 = 1' 'net.ipv6.conf.default.disable_ipv6 = 1'
put "$f_etc_b" 'net/ipv6/conf/all/disable_ipv6 = 0' 'net/ipv6/conf/default/disable_ipv6 = 0'
check on 'vendor 1 then /etc slash-style 0'

baseline
put "$f_lib_a" 'net.ipv6.conf.all.disable_ipv6 = 1' 'net.ipv6.conf.default.disable_ipv6 = 1'
put "$f_etc_a" 'net/ipv6/conf/all/disable_ipv6 = 0' 'net/ipv6/conf/default/disable_ipv6 = 0'
check on 'same-named /etc file masks the vendor file'

baseline
put "$f_etc_a" 'net/ipv6/conf/all/disable_ipv6 = 0' 'net/ipv6/conf/default/disable_ipv6 = 0'
put "$f_lib_b" 'net.ipv6.conf.all.disable_ipv6 = 1' 'net.ipv6.conf.default.disable_ipv6 = 1'
check off 'vendor file that sorts later wins'

# Wildcards are applied after explicit keys and never override them (systemd semantics),
# so this case runs without the explicit baseline.
put "$f_etc_a" 'net.ipv6.conf.*.disable_ipv6=1'
check off 'wildcard'

baseline
put "$f_etc_a" 'net.ipv6.conf.*.disable_ipv6=1'
check on 'wildcard does not override explicit keys'

baseline
put "$f_etc_a" '-net.ipv6.conf.all.disable_ipv6=1'
check off 'line with a leading dash'

baseline
put "$f_etc_a" 'net.ipv6.conf.lo.disable_ipv6 = 1'
check on 'only lo is set'

# An interface-specific key has no device in the namespace. systemd-sysctl must still exit 0
# (otherwise such machines would always be "unknown"), and the key cannot be judged.
baseline
put "$f_etc_a" 'net.ipv6.conf.eth0.disable_ipv6 = 1'
tool=$(systemd_sysctl_path)
unshare --net -- "$tool" --prefix=net.ipv6.conf >/dev/null 2>&1 ||
  fail "systemd-sysctl exits non-zero for an interface-specific key ($("$tool" --version | head -1))"
check on 'interface-specific keys cannot be judged (documented limitation)'

baseline
put "$f_run_a" 'net.ipv6.conf.default.disable_ipv6 = 1'
check off '/run/sysctl.d'

baseline
put "$f_local_a" 'net.ipv6.conf.all.disable_ipv6 = 1'
check off '/usr/local/lib/sysctl.d'

# --- tool failures are never read as "on" ---------------------------------------------------------
fake_dir=$(mktemp -d)
created+=("$fake_dir/fail" "$fake_dir/noop")
printf '#!/bin/sh\nexit 1\n' >"$fake_dir/fail"
printf '#!/bin/sh\nexit 0\n' >"$fake_dir/noop"
chmod 0755 "$fake_dir/fail" "$fake_dir/noop"
(
  systemd_sysctl_path() { printf '%s\n' "$fake_dir/fail"; }
  eq unknown "$(ipv6_boot_state)" 'a failing systemd-sysctl must not look like on'
)
(
  systemd_sysctl_path() { printf '%s\n' "$fake_dir/noop"; }
  eq on "$(ipv6_boot_state)" 'a tool that succeeds without changing anything'
)
(
  systemd_sysctl_path() { printf '%s\n' "$fake_dir/missing"; return 1; }
  eq unknown "$(ipv6_boot_state)" 'a missing systemd-sysctl'
)
cleanup_files
rmdir -- "$fake_dir"

# --- the script's own override file beats the legacy file name ------------------------------------
baseline
put "$f_legacy" 'net.ipv6.conf.all.disable_ipv6 = 1' 'net.ipv6.conf.default.disable_ipv6 = 1' 'net.ipv6.conf.lo.disable_ipv6 = 1'
eq off "$(ipv6_boot_state)" 'legacy file alone'
lines=$(ipv6_boot_disable_lines)
grep -Fq "$f_legacy: net.ipv6.conf.all.disable_ipv6 = 1" <<<"$lines" || fail "display list lacks the legacy file: $lines"
write_ipv6_restore_policy
auto_restore_policy_file "$NETWORK_SYSCTL" || fail 'restore file not recognised'
eq on "$(ipv6_boot_state)" 'script override beats the legacy file'
cleanup_files

eq "$before" "$(host_values)" 'host values changed by the checks'
cleanup_all
for f in "$f_zero" "$f_etc_a" "$f_etc_b" "$f_lib_a" "$f_lib_b" "$f_run_a" "$f_local_a" "$f_legacy" "$f_self"; do
  [[ ! -e "$f" ]] || fail "test file left behind: $f"
done
printf 'PASS: systemd-sysctl boot state in a network namespace (%s)\n' "$("$(systemd_sysctl_path)" --version | head -1)"
