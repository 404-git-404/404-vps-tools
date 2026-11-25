#!/usr/bin/env bash
# shellcheck disable=SC2329,SC2034 # Test doubles are called through the sourced installer.
# System DNS precheck (broken DNS, immutable resolv.conf, dead network) and
# minimal-system directory creation (/etc/sysctl.d and friends missing).
# Never touches the host: resolver, SmartDNS and sysctl paths are redirected into a temp dir.
set -Eeuo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
work=$(cd -- "$work" && pwd -P)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin"

sed -e "s|/etc/resolv\.conf|$work/resolv.conf|g" \
  -e "s|^readonly SMARTDNS_CONF=.*|readonly SMARTDNS_CONF='$work/smartdns/smartdns.conf'|" \
  -e "s|^readonly TCP_SYSCTL=.*|readonly TCP_SYSCTL='$work/missing/etc/sysctl.d/99-vps-init-tcp.conf'|" \
  -e "s|^readonly NETWORK_SYSCTL=.*|readonly NETWORK_SYSCTL='$work/missing/etc/sysctl.d/99-vps-init-network.conf'|" \
  -e "s|^readonly BBR_MODULES=.*|readonly BBR_MODULES='$work/missing/etc/modules-load.d/vps-init-bbr.conf'|" \
  "$repo/debian-init.sh" >"$work/installer.sh"
grep -Fq "$work/resolv.conf" "$work/installer.sh"
grep -Fq "$work/missing/etc/sysctl.d/99-vps-init-tcp.conf" "$work/installer.sh"

# Fake external commands. getent resolves when the (redirected) resolv.conf lists a working
# resolver: 1.1.1.1 (the fallback) or 9.9.9.9 (an ordinary healthy system).
cat >"$work/bin/getent" <<'EOF'
#!/bin/sh
echo "getent $*" >>"$WORK/getent.log"
[ "$1" = ahostsv4 ] && [ "$2" = deb.debian.org ] || exit 2
[ -z "${FAKE_DNS_BROKEN:-}" ] || exit 2
grep -Eqx 'nameserver (1\.1\.1\.1|9\.9\.9\.9)' "$WORK/resolv.conf" 2>/dev/null
EOF
cat >"$work/bin/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >>"$WORK/curl.log"
case "${FAKE_DIRECT:-ok}" in
  ok) ;;
  google-only) case "$*" in *dns.google*) ;; *) echo 'simulated connect failure' >&2; exit 7 ;; esac ;;
  *) echo 'simulated connect failure' >&2; exit 7 ;;
esac
printf 400
EOF
# lsattr/chattr emulate the immutable bit with a marker file.
cat >"$work/bin/lsattr" <<'EOF'
#!/bin/sh
if [ -e "$WORK/resolv.conf.immutable" ]; then echo "----i---------e------- $3"; else echo "--------------e------- $3"; fi
EOF
cat >"$work/bin/chattr" <<'EOF'
#!/bin/sh
echo "chattr $*" >>"$WORK/chattr.log"
case "$1" in
  -i) rm -f "$WORK/resolv.conf.immutable" ;;
  +i) : >"$WORK/resolv.conf.immutable" ;;
esac
EOF
chmod +x "$work/bin/"*
export WORK=$work
export PATH="$work/bin:$PATH"

# shellcheck disable=SC1091
source "$work/installer.sh"
trap - ERR HUP INT TERM EXIT
trap 'rm -rf -- "$work"' EXIT
IFS=$' \t\n'
# The installer resets PATH when sourced; put the fakes back in front.
export PATH="$work/bin:$PATH"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "$3: expected [$1], got [$2]"; }
has() { grep -Fq -- "$1" "$2" || { cat "$2" >&2; fail "$3: missing [$1]"; }; }
hasnt() { if grep -Fq -- "$1" "$2"; then cat "$2" >&2; fail "$3: unexpected [$1]"; fi; }

EXPECTED_RESOLV=$'nameserver 127.0.0.1\nnameserver 1.1.1.1\noptions timeout:2 attempts:2'
ORIGINAL_RESOLV='nameserver 77.111.110.253'

# An immutable file refuses removal and replacement, like the kernel would.
rm() {
  if [[ -e "$work/resolv.conf.immutable" && "$*" == *"$work/resolv.conf"* ]]; then
    echo 'rm: cannot remove: Operation not permitted' >&2
    return 1
  fi
  command rm "$@"
}
install() {
  if [[ -e "$work/resolv.conf.immutable" && "$*" == *"$work/resolv.conf" ]]; then
    echo 'install: Operation not permitted' >&2
    return 1
  fi
  command install "$@"
}
mountpoint() { return 1; }
systemctl() { return 1; }
sleep() { :; }
read_tty() {
  printf '%s\n' "$1" >>"$work/prompts"
  printf -v "$2" '%s' "$ANSWER"
}

reset_case() {
  command rm -rf -- "$work/resolv.conf" "$work/resolv.conf.immutable" "$work/resolv-target" "$work/backup" \
    "$work/tmp" "$work/prompts" "$work/curl.log" "$work/chattr.log" "$work/getent.log" "$work/smartdns" \
    "$work/out" "$work/missing"
  mkdir -p "$work/backup" "$work/tmp"
  printf '%s\n' "$ORIGINAL_RESOLV" >"$work/resolv.conf"
  BACKUP_DIR="$work/backup"
  TMP_DIR="$work/tmp"
  EARLY_DNS_FIXED=false
  EARLY_DNS_BACKUP=''
  ORIGINAL_ATTRS=()
  DNS_TX=false
  ANSWER=''
  HAVE_TTY=true
  export FAKE_DNS_BROKEN='' FAKE_DIRECT=ok
  dns_prompt_available() { [[ "$HAVE_TTY" == true ]]; }
}
resolv() { cat "$work/resolv.conf"; }
saved="$work/backup/dns-precheck"

# ---------------------------------------------------------------- ipv4_https_works
reset_case
ipv4_https_works >"$work/out" 2>&1 || fail 'direct probe failed with a reachable network'
eq 1 "$(wc -l <"$work/curl.log" | tr -d ' ')" 'first provider is enough'
has 'PASS (HTTP 400)' "$work/out" 'any HTTP response passes'
for arg in --disable -4 --noproxy '*' --resolve 'cloudflare-dns.com:443:1.1.1.1' https://cloudflare-dns.com/dns-query; do
  grep -Fq -- " $arg" "$work/curl.log" || fail "probe lacks curl argument: $arg"
done
hasnt ' -k' "$work/curl.log" 'probe verifies certificates'
hasnt '--insecure' "$work/curl.log" 'probe verifies certificates'
hasnt 'google.com' "$work/curl.log" 'probe no longer depends on DNS names that need resolving'
FAKE_DIRECT=google-only
command rm -f "$work/curl.log"
ipv4_https_works >"$work/out" 2>&1 || fail 'second provider was not tried'
has '--resolve dns.google:443:8.8.8.8' "$work/curl.log" 'Google probe uses a fixed address'
FAKE_DIRECT=none
if ipv4_https_works >"$work/out" 2>&1; then fail 'a dead network passed the probe'; fi

# ---------------------------------------------------------------- DNS healthy
reset_case
printf 'nameserver 9.9.9.9\n' >"$work/resolv.conf"
ensure_system_dns >"$work/out" 2>&1
eq 'nameserver 9.9.9.9' "$(resolv)" 'healthy resolv.conf is left alone'
[[ ! -e "$work/prompts" && ! -e "$work/curl.log" && ! -e "$saved" ]] || fail 'healthy DNS triggered the precheck'
eq false "$EARLY_DNS_FIXED" 'no early repair flag'

# ---------------------------------------------------------------- DNS dead, direct OK
for answer in '' y Yes; do
  reset_case
  ANSWER=$answer
  ensure_system_dns >"$work/out" 2>&1
  eq "$EXPECTED_RESOLV" "$(resolv)" "resolv.conf after answer [$answer]"
  eq "$ORIGINAL_RESOLV" "$(cat "$saved/resolv.conf")" 'original resolv.conf is backed up'
  eq true "$EARLY_DNS_FIXED" 'early repair flag'
  eq "$saved/resolv.conf" "$EARLY_DNS_BACKUP" 'reported backup path'
  has '临时写入备用 DNS 以继续？' "$work/prompts" 'prompt text'
  has '[Y/n]' "$work/prompts" 'default is Y'
  has '已提前修复系统 DNS' "$work/out" 'repair is announced'
  has "$saved/resolv.conf" "$work/out" 'backup path is announced'
  eq 0 "${#ORIGINAL_ATTRS[@]}" 'the repair leaves no attribute to restore'
  [[ "$(getent ahostsv4 deb.debian.org >/dev/null 2>&1 && echo ok)" == ok ]] || fail 'name resolution still broken after repair'
done

# Declined: nothing changes, no backup is created.
reset_case
ANSWER=n
if (ensure_system_dns) >"$work/out" 2>&1; then fail 'declining the fix continued'; fi
eq "$ORIGINAL_RESOLV" "$(resolv)" 'resolv.conf untouched after declining'
[[ ! -e "$saved" ]] || fail 'a backup was made although nothing was changed'
has '已取消' "$work/out" 'declined message'
has '系统 DNS 不可用' "$work/out" 'declined message names the cause'

# No terminal: the fix runs by itself, with a warning.
reset_case
HAVE_TTY=false
ensure_system_dns >"$work/out" 2>&1
eq "$EXPECTED_RESOLV" "$(resolv)" 'resolv.conf without a terminal'
[[ ! -e "$work/prompts" ]] || fail 'prompted without a terminal'
has '没有可用的交互终端，自动写入备用 DNS' "$work/out" 'warning without a terminal'

# ---------------------------------------------------------------- DNS dead and network dead
reset_case
FAKE_DIRECT=none
if (ensure_system_dns) >"$work/out" 2>&1; then fail 'continued with no IPv4 network'; fi
has 'IPv4 网络不可用' "$work/out" 'dead network is reported as such'
hasnt '故障在系统 DNS' "$work/out" 'dead network is not blamed on DNS'
eq 2 "$(wc -l <"$work/curl.log" | tr -d ' ')" 'both providers were probed'
eq "$ORIGINAL_RESOLV" "$(resolv)" 'resolv.conf untouched when the network is dead'
[[ ! -e "$work/prompts" && ! -e "$saved" ]] || fail 'asked or backed up although nothing can be fixed'

# ---------------------------------------------------------------- immutable resolv.conf
reset_case
: >"$work/resolv.conf.immutable"
ensure_system_dns >"$work/out" 2>&1
eq "$EXPECTED_RESOLV" "$(resolv)" 'resolv.conf behind chattr +i'
eq "$ORIGINAL_RESOLV" "$(cat "$saved/resolv.conf")" 'immutable original is backed up'
grep -Fq 'chattr -i -a' "$work/chattr.log" || fail 'immutable flag was not cleared first'
[[ ! -e "$work/resolv.conf.immutable" ]] || fail 'immutable flag is still set'
eq 0 "${#ORIGINAL_ATTRS[@]}" 'cleanup will not re-lock the repaired file'

# ---------------------------------------------------------------- symlink and missing resolv.conf
reset_case
printf '%s\n' "$ORIGINAL_RESOLV" >"$work/resolv-target"
command rm -f "$work/resolv.conf"
ln -s "$work/resolv-target" "$work/resolv.conf"
ensure_system_dns >"$work/out" 2>&1
[[ -f "$work/resolv.conf" && ! -L "$work/resolv.conf" ]] || fail 'resolv.conf is still a symlink'
eq "$EXPECTED_RESOLV" "$(resolv)" 'resolv.conf replacing a symlink'
eq "$work/resolv-target" "$(readlink "$saved/resolv.conf.symlink")" 'symlink target is backed up'
eq "$ORIGINAL_RESOLV" "$(cat "$work/resolv-target")" 'symlink target file is untouched'
reset_case
command rm -f "$work/resolv.conf"
ensure_system_dns >"$work/out" 2>&1
eq "$EXPECTED_RESOLV" "$(resolv)" 'resolv.conf created when missing'
[[ -e "$saved/no-resolv-conf" ]] || fail 'missing original is not recorded'

# ---------------------------------------------------------------- repair that does not resolve is undone
reset_case
: >"$work/resolv.conf.immutable"
FAKE_DNS_BROKEN=1
if (ensure_system_dns) >"$work/out" 2>&1; then fail 'unresolvable DNS accepted'; fi
eq "$ORIGINAL_RESOLV" "$(resolv)" 'original resolv.conf restored after a failed repair'
[[ -e "$work/resolv.conf.immutable" ]] || fail 'immutable flag not restored'
has '已恢复原 resolv.conf' "$work/out" 'failed repair message'
has "$saved/resolv.conf" "$work/out" 'failed repair names the backup'

# ---------------------------------------------------------------- a later failure keeps the repair
reset_case
: >"$work/resolv.conf.immutable"
if (
  ensure_system_dns >"$work/out" 2>&1
  # Same order as a real run: the transaction backup is taken after the early repair.
  backup_dns_state
  DNS_TX=true
  die 'simulated later failure' >>"$work/out" 2>&1
); then fail 'simulated failure did not exit'; fi
eq "$EXPECTED_RESOLV" "$(resolv)" 'rollback must not restore the broken resolv.conf'
eq "$ORIGINAL_RESOLV" "$(cat "$saved/resolv.conf")" 'original is still in the backup after rollback'
has '正在回滚 SmartDNS / resolv.conf' "$work/out" 'the DNS transaction really rolled back'
(
  ORIGINAL_ATTRS=()
  restore_attrs
)
[[ ! -e "$work/resolv.conf.immutable" ]] || fail 'cleanup re-locked the repaired resolv.conf'
eq "$EXPECTED_RESOLV" "$(resolv)" 'resolv.conf after cleanup'

# ---------------------------------------------------------------- where the precheck runs
body=$(declare -f preflight)
[[ "$body" == *ensure_system_dns* ]] || fail 'preflight does not run the DNS precheck'
[[ "${body%%qemu-agent-remove*}" != *ensure_system_dns* ]] || fail 'precheck runs before the offline qemu-agent-remove return'
[[ "$body" == *'!= fail2ban'* ]] || fail 'fail2ban-only should check lazily'
[[ "$(declare -f run_fail2ban_only)" == *ensure_system_dns* ]] || fail 'fail2ban-only never checks DNS'

# ---------------------------------------------------------------- ensure_dir
reset_case
(
  umask 077
  ensure_dir "$work/missing/a/b/c"
  for d in "$work/missing" "$work/missing/a" "$work/missing/a/b" "$work/missing/a/b/c"; do
    eq 755 "$(stat -c %a "$d")" "mode of $d"
  done
  mkdir -m 0750 "$work/existing"
  ensure_dir "$work/existing"
  eq 750 "$(stat -c %a "$work/existing")" 'existing directory mode is not changed'
  command rm -rf "$work/existing"
)

# ---------------------------------------------------------------- /etc/sysctl.d missing
sysctl() {
  case "$1:${2:-}" in
    -n:net.ipv4.tcp_available_congestion_control) echo 'reno cubic bbr' ;;
    -n:net.ipv4.tcp_congestion_control) echo bbr ;;
    -n:*) echo fq ;;
    -w:*) return 0 ;;
    *) return 1 ;;
  esac
}
modprobe() { :; }
reset_case
[[ ! -e "$work/missing" ]] || fail 'precondition: directory exists'
configure_tcp_tuning >"$work/out" 2>&1 || { cat "$work/out" >&2; fail 'configure_tcp_tuning failed without /etc/sysctl.d'; }
tcp_file="$work/missing/etc/sysctl.d/99-vps-init-tcp.conf"
has 'net.core.rmem_max = 33554432' "$tcp_file" 'TCP settings'
has 'net.ipv4.tcp_congestion_control = bbr' "$tcp_file" 'BBR setting'
eq tcp_bbr "$(cat "$work/missing/etc/modules-load.d/vps-init-bbr.conf")" 'BBR module file'
for d in "$work/missing/etc" "$work/missing/etc/sysctl.d" "$work/missing/etc/modules-load.d"; do
  eq 755 "$(stat -c %a "$d")" "mode of $d"
done
# Second run is idempotent and keeps the directory.
configure_tcp_tuning >"$work/out" 2>&1
eq 1 "$(grep -c '^net.core.rmem_max' "$tcp_file")" 'no duplicate settings after a rerun'

reset_case
write_ipv6_restore_policy
policy="$work/missing/etc/sysctl.d/99-vps-init-network.conf"
eq 644 "$(stat -c %a "$policy")" 'override file mode'
eq 755 "$(stat -c %a "${policy%/*}")" 'override directory mode'
eq "$AUTO_RESTORE_MARK" "$(sed -n 2p "$policy")" 'override marker line'
managed_ipv6_policy "$policy" || fail 'override file is not recognised as managed'

printf 'dns-precheck tests passed\n'
