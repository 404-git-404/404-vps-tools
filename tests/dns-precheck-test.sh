#!/usr/bin/env bash
# shellcheck disable=SC2329,SC2034,SC2016 # Test doubles are called through the sourced installer.
# System DNS precheck (broken DNS, locking, failed writes, i/a attributes, dead network) and
# minimal-system directory creation (/etc/sysctl.d and friends missing).
# Never touches the host: resolver, SmartDNS, lock and sysctl paths are redirected into a temp dir.
# Every function under test runs in its own bash process, so errexit stays in force inside it.
set -Eeuo pipefail

self=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")
repo=$(cd -- "$(dirname -- "$self")/.." && pwd)

if [[ -z "${VPS_TEST_WORK:-}" ]]; then
  work=$(mktemp -d)
  work=$(cd -- "$work" && pwd -P)
  trap 'rm -rf -- "$work"' EXIT
  mkdir -p "$work/bin" "$work/lockdir"
  export VPS_TEST_WORK=$work

  sed -e "s|/etc/resolv\.conf|$work/resolv.conf|g" \
    -e "s|^readonly SMARTDNS_CONF=.*|readonly SMARTDNS_CONF='$work/smartdns/smartdns.conf'|" \
    -e "s|^readonly TCP_SYSCTL=.*|readonly TCP_SYSCTL='$work/missing/etc/sysctl.d/99-vps-init-tcp.conf'|" \
    -e "s|^readonly NETWORK_SYSCTL=.*|readonly NETWORK_SYSCTL='$work/missing/etc/sysctl.d/99-vps-init-network.conf'|" \
    -e "s|^readonly BBR_MODULES=.*|readonly BBR_MODULES='$work/missing/etc/modules-load.d/vps-init-bbr.conf'|" \
    -e "s|^readonly LOCK_FILE=.*|readonly LOCK_FILE='$work/lockdir/vps-init.lock'|" \
    -e "s|^  install -d -m 0755 /run/lock\$|  install -d -m 0755 $work/lockdir|" \
    "$repo/debian-init.sh" >"$work/installer.sh"
  grep -Fq "$work/resolv.conf" "$work/installer.sh"
  grep -Fq "$work/missing/etc/sysctl.d/99-vps-init-tcp.conf" "$work/installer.sh"
  grep -Fq "install -d -m 0755 $work/lockdir" "$work/installer.sh"

  # Fake external commands. getent resolves when the (redirected) resolv.conf lists a working
  # resolver: 1.1.1.1 (the fallback) or 9.9.9.9 (an ordinary healthy system).
  command cat >"$work/bin/getent" <<'EOF'
#!/bin/sh
echo "getent $*" >>"$VPS_TEST_WORK/getent.log"
[ "$1" = ahostsv4 ] && [ "$2" = deb.debian.org ] || exit 2
[ -z "${FAKE_DNS_BROKEN:-}" ] || exit 2
grep -Eqx 'nameserver (1\.1\.1\.1|9\.9\.9\.9)' "$VPS_TEST_WORK/resolv.conf" 2>/dev/null
EOF
  command cat >"$work/bin/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >>"$VPS_TEST_WORK/curl.log"
case "${FAKE_DIRECT:-ok}" in
  ok) ;;
  google-only) case "$*" in *dns.google*) ;; *) echo 'simulated connect failure' >&2; exit 7 ;; esac ;;
  *) echo 'simulated connect failure' >&2; exit 7 ;;
esac
printf 400
EOF
  # lsattr/chattr emulate the i and a attributes with marker files.
  command cat >"$work/bin/lsattr" <<'EOF'
#!/bin/sh
i=-; a=-
[ ! -e "$VPS_TEST_WORK/resolv.conf.i" ] || i=i
[ ! -e "$VPS_TEST_WORK/resolv.conf.a" ] || a=a
printf -- '-%s%s-------------e------- %s\n' "$i" "$a" "$3"
EOF
  command cat >"$work/bin/chattr" <<'EOF'
#!/bin/sh
echo "chattr $*" >>"$VPS_TEST_WORK/chattr.log"
for arg in "$@"; do
  case "$arg" in
    -i) [ -z "${CHATTR_FAIL_CLEAR:-}" ] || exit 1; rm -f "$VPS_TEST_WORK/resolv.conf.i" ;;
    -a) [ -z "${CHATTR_FAIL_CLEAR:-}" ] || exit 1; rm -f "$VPS_TEST_WORK/resolv.conf.a" ;;
    +i) : >"$VPS_TEST_WORK/resolv.conf.i" ;;
    +a) [ -z "${CHATTR_FAIL_A:-}" ] || exit 1; : >"$VPS_TEST_WORK/resolv.conf.a" ;;
  esac
done
EOF
  command chmod +x "$work/bin/"*
else
  work=$VPS_TEST_WORK
fi
export PATH="$work/bin:$PATH"

# shellcheck disable=SC1091
source "$work/installer.sh"
trap - ERR HUP INT TERM EXIT
if [[ "${1:-}" != --run ]]; then trap 'rm -rf -- "$work"' EXIT; fi
IFS=$' \t\n'
# The installer resets PATH when sourced; put the fakes back in front.
export PATH="$work/bin:$PATH"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "$3: expected [$1], got [$2]"; }
has() { grep -Fq -- "$1" "$2" || { cat "$2" >&2; fail "$3: missing [$1]"; }; }
hasnt() { if grep -Fq -- "$1" "$2"; then cat "$2" >&2; fail "$3: unexpected [$1]"; fi; }

target="$work/resolv.conf"
# An immutable or append-only file refuses removal and replacement, like the kernel would.
locked() { [[ -e "$work/resolv.conf.i" || -e "$work/resolv.conf.a" ]]; }
touches_target() { local arg; for arg in "$@"; do [[ "$arg" != "$target" ]] || return 0; done; return 1; }
rm() {
  if locked && touches_target "$@"; then echo 'rm: cannot remove: Operation not permitted' >&2; return 1; fi
  command rm "$@"
}
mv() {
  if touches_target "$@"; then
    if locked; then echo 'mv: cannot move: Operation not permitted' >&2; return 1; fi
    if [[ "${FAULT:-}" == mv-fail ]]; then echo 'mv: simulated failure' >&2; return 1; fi
  fi
  command mv "$@"
}
chmod() {
  if [[ "${FAULT:-}" == chmod-fail ]]; then echo 'chmod: simulated failure' >&2; return 1; fi
  command chmod "$@"
}
# The first copy of the new content fails half-way, as on a full disk.
cat() {
  if [[ "${FAULT:-}" == write-fail && ! -e "$work/fault.once" ]]; then
    : >"$work/fault.once"
    printf 'nameserv'
    return 1
  fi
  command cat "$@"
}
mountpoint() { [[ "${MOUNTPOINT:-}" == 1 && "${*: -1}" == "$target" ]]; }
systemctl() { return 1; }
sleep() { :; }
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
read_tty() {
  printf '%s\n' "$1" >>"$work/prompts"
  printf -v "$2" '%s' "$ANSWER"
}
dns_prompt_available() { [[ "${HAVE_TTY:-true}" == true ]]; }
BACKUP_DIR="$work/backup"
TMP_DIR="$work/tmp"

# Inner mode: run one command in this fresh process, errexit active, and exit with its status.
if [[ "${1:-}" == --run ]]; then
  eval "$2"
  exit
fi

# ================================================================ outer harness
EXPECTED_RESOLV=$'nameserver 127.0.0.1\nnameserver 1.1.1.1\noptions timeout:2 attempts:2'
ORIGINAL_RESOLV='nameserver 77.111.110.253'
saved="$work/backup/dns-precheck"

export ANSWER='' HAVE_TTY=true FAKE_DNS_BROKEN='' FAKE_DIRECT=ok FAULT='' MOUNTPOINT='' CHATTR_FAIL_CLEAR='' CHATTR_FAIL_A=''

reset_case() {
  command rm -rf -- "$work/resolv.conf" "$work/resolv.conf.i" "$work/resolv.conf.a" "$work/resolv-target" \
    "$work/backup" "$work/tmp" "$work/prompts" "$work/curl.log" "$work/chattr.log" "$work/getent.log" \
    "$work/smartdns" "$work/out" "$work/missing" "$work/fault.once" "$work/trace" "$work"/.resolv.conf.*
  mkdir -p "$work/backup" "$work/tmp"
  printf '%s\n' "$ORIGINAL_RESOLV" >"$work/resolv.conf"
  command chmod 0644 "$work/resolv.conf"
  ANSWER='' HAVE_TTY=true FAKE_DNS_BROKEN='' FAKE_DIRECT=ok FAULT='' MOUNTPOINT='' CHATTR_FAIL_CLEAR='' CHATTR_FAIL_A=''
}
resolv() { command cat "$work/resolv.conf"; }
leftovers() { compgen -G "$work/.resolv.conf.*" >/dev/null && echo yes || echo no; }

run_case() {
  local rc=0
  bash "$self" --run "$1" >"$work/out" 2>&1 || rc=$?
  return "$rc"
}
ok() { run_case "$1" || { cat "$work/out" >&2; fail "expected success: $1"; }; }
bad() { if run_case "$1"; then cat "$work/out" >&2; fail "expected failure: $1"; fi; }

# ---------------------------------------------------------------- ipv4_https_works
reset_case
ok ipv4_https_works
eq 1 "$(wc -l <"$work/curl.log" | tr -d ' ')" 'first provider is enough'
has 'PASS (HTTP 400)' "$work/out" 'any HTTP response passes'
for arg in --disable -4 --noproxy '*' --resolve 'cloudflare-dns.com:443:1.1.1.1' https://cloudflare-dns.com/dns-query; do
  grep -Fq -- " $arg" "$work/curl.log" || fail "probe lacks curl argument: $arg"
done
hasnt ' -k' "$work/curl.log" 'probe verifies certificates'
hasnt '--insecure' "$work/curl.log" 'probe verifies certificates'
hasnt 'google.com' "$work/curl.log" 'probe no longer depends on DNS names that need resolving'
command rm -f "$work/curl.log"
FAKE_DIRECT=google-only ok ipv4_https_works
has '--resolve dns.google:443:8.8.8.8' "$work/curl.log" 'Google probe uses a fixed address'
FAKE_DIRECT=none bad ipv4_https_works

# ---------------------------------------------------------------- DNS healthy
reset_case
printf 'nameserver 9.9.9.9\n' >"$work/resolv.conf"
ok ensure_system_dns
eq 'nameserver 9.9.9.9' "$(resolv)" 'healthy resolv.conf is left alone'
[[ ! -e "$work/prompts" && ! -e "$work/curl.log" && ! -e "$saved" ]] || fail 'healthy DNS triggered the precheck'

# ---------------------------------------------------------------- DNS dead, direct OK
for answer in '' y Yes; do
  reset_case
  ANSWER=$answer ok ensure_system_dns
  eq "$EXPECTED_RESOLV" "$(resolv)" "resolv.conf after answer [$answer]"
  eq "$ORIGINAL_RESOLV" "$(command cat "$saved/resolv.conf")" 'original resolv.conf is backed up'
  eq 644 "$(stat -c %a "$target")" 'resolv.conf mode'
  eq no "$(leftovers)" 'no temporary file is left behind'
  has '临时写入备用 DNS 以继续？' "$work/prompts" 'prompt text'
  has '[Y/n]' "$work/prompts" 'default is Y'
  has '已提前修复系统 DNS' "$work/out" 'repair is announced'
  has "$saved/resolv.conf" "$work/out" 'backup path is announced'
  ok 'ensure_system_dns; [[ ${#ORIGINAL_ATTRS[@]} == 0 ]]'
done
# The report names the repair and the backup.
reset_case
ok 'ensure_system_dns; [[ $EARLY_DNS_FIXED == true && $EARLY_DNS_BACKUP == "$BACKUP_DIR/dns-precheck/resolv.conf" ]]'

# Declined: nothing changes, no backup is created.
reset_case
ANSWER=n bad ensure_system_dns
eq "$ORIGINAL_RESOLV" "$(resolv)" 'resolv.conf untouched after declining'
[[ ! -e "$saved" ]] || fail 'a backup was made although nothing was changed'
has '已取消' "$work/out" 'declined message'
has '系统 DNS 不可用' "$work/out" 'declined message names the cause'

# No terminal: the fix runs by itself, with a warning.
reset_case
HAVE_TTY=false ok ensure_system_dns
eq "$EXPECTED_RESOLV" "$(resolv)" 'resolv.conf without a terminal'
[[ ! -e "$work/prompts" ]] || fail 'prompted without a terminal'
has '没有可用的交互终端，自动写入备用 DNS' "$work/out" 'warning without a terminal'

# ---------------------------------------------------------------- DNS dead and network dead
reset_case
FAKE_DIRECT=none bad ensure_system_dns
has 'IPv4 网络不可用' "$work/out" 'dead network is reported as such'
hasnt '故障在系统 DNS' "$work/out" 'dead network is not blamed on DNS'
eq 2 "$(wc -l <"$work/curl.log" | tr -d ' ')" 'both providers were probed'
eq "$ORIGINAL_RESOLV" "$(resolv)" 'resolv.conf untouched when the network is dead'
[[ ! -e "$work/prompts" && ! -e "$saved" ]] || fail 'asked or backed up although nothing can be fixed'

# ---------------------------------------------------------------- attributes i and a
for attrs in i a ia; do
  reset_case
  for flag in i a; do if [[ "$attrs" == *"$flag"* ]]; then : >"$work/resolv.conf.$flag"; fi; done
  ok ensure_system_dns
  eq "$EXPECTED_RESOLV" "$(resolv)" "resolv.conf behind chattr +$attrs"
  eq "$ORIGINAL_RESOLV" "$(command cat "$saved/resolv.conf")" "original with +$attrs is backed up"
  grep -Fq 'chattr -i -a' "$work/chattr.log" || fail 'attributes were not cleared first'
  [[ ! -e "$work/resolv.conf.i" && ! -e "$work/resolv.conf.a" ]] || fail "attributes still set after a repair with +$attrs"

  # A repair whose resolution check fails puts content AND attributes back (item 3).
  reset_case
  for flag in i a; do if [[ "$attrs" == *"$flag"* ]]; then : >"$work/resolv.conf.$flag"; fi; done
  FAKE_DNS_BROKEN=1 bad ensure_system_dns
  eq "$ORIGINAL_RESOLV" "$(resolv)" "original restored after a failed check with +$attrs"
  for flag in i a; do
    if [[ "$attrs" == *"$flag"* ]]; then
      [[ -e "$work/resolv.conf.$flag" ]] || fail "attribute $flag was not restored"
    else
      [[ ! -e "$work/resolv.conf.$flag" ]] || fail "attribute $flag appeared from nowhere"
    fi
  done
  has '已恢复原' "$work/out" 'failed check message'
  has "$saved/resolv.conf" "$work/out" 'failed check names the backup'
  eq no "$(leftovers)" 'no temporary file after a failed check'
done

# An attribute that cannot be restored is reported, not hidden.
reset_case
: >"$work/resolv.conf.a"
FAKE_DNS_BROKEN=1 CHATTR_FAIL_A=1 bad ensure_system_dns
has '未能完整恢复' "$work/out" 'unrestorable attribute is reported'
eq "$ORIGINAL_RESOLV" "$(resolv)" 'content is restored even when the attribute is not'

# ---------------------------------------------------------------- failed writes keep the original (item 2)
for fault in write-fail mv-fail chmod-fail; do
  for attrs in none i a; do
    reset_case
    if [[ "$attrs" != none ]]; then : >"$work/resolv.conf.$attrs"; fi
    FAULT=$fault bad ensure_system_dns
    eq "$ORIGINAL_RESOLV" "$(resolv)" "original intact after $fault with attrs=$attrs"
    eq 644 "$(stat -c %a "$target")" "mode intact after $fault"
    eq no "$(leftovers)" "temporary file removed after $fault"
    has '已恢复原' "$work/out" "$fault message"
    if [[ "$attrs" != none ]]; then [[ -e "$work/resolv.conf.$attrs" ]] || fail "attribute $attrs lost after $fault"; fi
  done
done
# On a mount point the file is rewritten in place: a half-written file must be restored.
reset_case
: >"$work/resolv.conf.i"
MOUNTPOINT=1 FAULT=write-fail bad ensure_system_dns
eq "$ORIGINAL_RESOLV" "$(resolv)" 'mount point: half-written file restored'
[[ -e "$work/resolv.conf.i" ]] || fail 'mount point: attribute lost'
has '已恢复原' "$work/out" 'mount point failure message'
reset_case
MOUNTPOINT=1 ok ensure_system_dns
eq "$EXPECTED_RESOLV" "$(resolv)" 'mount point: successful in-place write'
# Clearing the attributes fails: nothing was changed, so nothing may be lost.
reset_case
: >"$work/resolv.conf.i"
CHATTR_FAIL_CLEAR=1 bad ensure_system_dns
eq "$ORIGINAL_RESOLV" "$(resolv)" 'attribute clearing failed: original intact'
[[ -e "$work/resolv.conf.i" ]] || fail 'attribute clearing failed: attribute lost'
eq "$ORIGINAL_RESOLV" "$(command cat "$saved/resolv.conf")" 'backup exists after a failed write'

# ---------------------------------------------------------------- symlink and missing resolv.conf
reset_case
printf '%s\n' "$ORIGINAL_RESOLV" >"$work/resolv-target"
command rm -f "$work/resolv.conf"
ln -s "$work/resolv-target" "$work/resolv.conf"
ok ensure_system_dns
[[ -f "$work/resolv.conf" && ! -L "$work/resolv.conf" ]] || fail 'resolv.conf is still a symlink'
eq "$EXPECTED_RESOLV" "$(resolv)" 'resolv.conf replacing a symlink'
eq "$work/resolv-target" "$(readlink "$saved/resolv.conf.symlink")" 'symlink target is backed up'
eq "$ORIGINAL_RESOLV" "$(command cat "$work/resolv-target")" 'symlink target file is untouched'
# A failed write leaves the symlink as it was.
reset_case
printf '%s\n' "$ORIGINAL_RESOLV" >"$work/resolv-target"
command rm -f "$work/resolv.conf"
ln -s "$work/resolv-target" "$work/resolv.conf"
FAULT=write-fail bad ensure_system_dns
[[ -L "$work/resolv.conf" ]] || fail 'symlink lost after a failed write'
eq "$work/resolv-target" "$(readlink "$work/resolv.conf")" 'symlink target after a failed write'
# A failed resolution check puts the symlink back.
reset_case
printf '%s\n' "$ORIGINAL_RESOLV" >"$work/resolv-target"
command rm -f "$work/resolv.conf"
ln -s "$work/resolv-target" "$work/resolv.conf"
FAKE_DNS_BROKEN=1 bad ensure_system_dns
[[ -L "$work/resolv.conf" ]] || fail 'symlink not restored after a failed check'
eq "$work/resolv-target" "$(readlink "$work/resolv.conf")" 'symlink target after a failed check'
# Missing resolv.conf: created, and removed again when the check fails.
reset_case
command rm -f "$work/resolv.conf"
ok ensure_system_dns
eq "$EXPECTED_RESOLV" "$(resolv)" 'resolv.conf created when missing'
[[ -e "$saved/no-resolv-conf" ]] || fail 'missing original is not recorded'
reset_case
command rm -f "$work/resolv.conf"
FAKE_DNS_BROKEN=1 bad ensure_system_dns
[[ ! -e "$work/resolv.conf" && ! -L "$work/resolv.conf" ]] || fail 'resolv.conf that did not exist was left behind'

# ---------------------------------------------------------------- a later failure keeps the repair
reset_case
: >"$work/resolv.conf.i"
# Same order as a real run: the transaction backup is taken after the early repair.
bad 'ensure_system_dns; backup_dns_state; DNS_TX=true; die "simulated later failure"'
has '正在回滚 SmartDNS / resolv.conf' "$work/out" 'the DNS transaction really rolled back'
eq "$EXPECTED_RESOLV" "$(resolv)" 'rollback must not restore the broken resolv.conf'
eq "$ORIGINAL_RESOLV" "$(command cat "$saved/resolv.conf")" 'original is still in the backup after rollback'
ok 'ensure_system_dns; restore_attrs'
[[ ! -e "$work/resolv.conf.i" ]] || fail 'cleanup re-locked the repaired resolv.conf'

# ---------------------------------------------------------------- the lock comes first (item 1)
reset_case
exec 8>"$work/lockdir/vps-init.lock"
flock -n 8 || fail 'could not take the test lock'
bad 'preflight() { :; }; main --base-only'
has '已有另一个 vps-init.sh 正在运行' "$work/out" 'second instance is refused'
eq "$ORIGINAL_RESOLV" "$(resolv)" 'a refused second instance must not rewrite resolv.conf'
[[ ! -e "$saved" && ! -e "$work/prompts" && ! -e "$work/curl.log" ]] || fail 'refused instance already probed or backed up'
flock -u 8
exec 8>&-
# With the lock free, the order is preflight, lock, DNS, then the mode itself.
order() { # mode-argument expected-trace
  local mode=$1 expected=$2 body
  reset_case
  body='t() { echo "$1" >>"$VPS_TEST_WORK/trace"; }
    preflight() { t preflight; }; acquire_lock() { t lock; }; ensure_system_dns() { t dns; }
    run_smartdns_only() { t smartdns; }; run_singbox_only() { t singbox; }
    run_fail2ban_only() { t fail2ban; }; run_system_update_only() { t update; }
    remove_qemu_guest_agent() { t qemu; }'
  if [[ "$mode" == qemu ]]; then
    ok "$body; INSTALL_MODE=qemu-agent-remove; main"
  else
    ok "$body; main $mode"
  fi
  eq "$expected" "$(paste -sd, "$work/trace")" "call order for $mode"
}
order --smartdns-only preflight,lock,dns,smartdns
order --sing-box-only preflight,lock,dns,singbox
order --update-only preflight,lock,dns,update
order --fail2ban-only preflight,lock,fail2ban
order qemu preflight,lock,qemu
body=$(declare -f preflight)
[[ "$body" != *ensure_system_dns* ]] || fail 'preflight must not touch resolv.conf before the lock'
[[ "$(declare -f run_fail2ban_only)" == *ensure_system_dns* ]] || fail 'fail2ban-only never checks DNS'

# ---------------------------------------------------------------- ensure_dir
reset_case
ok "umask 077; ensure_dir '$work/missing/a/b/c'"
for d in "$work/missing" "$work/missing/a" "$work/missing/a/b" "$work/missing/a/b/c"; do
  eq 755 "$(stat -c %a "$d")" "mode of $d"
done
mkdir -m 0750 "$work/existing"
ok "ensure_dir '$work/existing'"
eq 750 "$(stat -c %a "$work/existing")" 'existing directory mode is not changed'
command rm -rf "$work/existing"

# ---------------------------------------------------------------- /etc/sysctl.d missing
reset_case
[[ ! -e "$work/missing" ]] || fail 'precondition: directory exists'
ok configure_tcp_tuning
tcp_file="$work/missing/etc/sysctl.d/99-vps-init-tcp.conf"
eq 644 "$(stat -c %a "$tcp_file")" 'TCP file mode'
has 'net.core.rmem_max = 33554432' "$tcp_file" 'TCP settings'
has 'net.ipv4.tcp_congestion_control = bbr' "$tcp_file" 'BBR setting'
eq tcp_bbr "$(command cat "$work/missing/etc/modules-load.d/vps-init-bbr.conf")" 'BBR module file'
for d in "$work/missing/etc" "$work/missing/etc/sysctl.d" "$work/missing/etc/modules-load.d"; do
  eq 755 "$(stat -c %a "$d")" "mode of $d"
done
# Second run also migrates the old restrictive mode.
chmod 0600 "$tcp_file"
ok configure_tcp_tuning
eq 644 "$(stat -c %a "$tcp_file")" 'TCP rerun file mode'
eq 1 "$(grep -c '^net.core.rmem_max' "$tcp_file")" 'no duplicate settings after a rerun'

reset_case
ok write_ipv6_restore_policy
policy="$work/missing/etc/sysctl.d/99-vps-init-network.conf"
eq 644 "$(stat -c %a "$policy")" 'override file mode'
eq 755 "$(stat -c %a "${policy%/*}")" 'override directory mode'
eq "$AUTO_RESTORE_MARK" "$(sed -n 2p "$policy")" 'override marker line'
managed_ipv6_policy "$policy" || fail 'override file is not recognised as managed'

printf 'dns-precheck tests passed\n'
