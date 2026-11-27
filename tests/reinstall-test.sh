#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031,SC2317,SC2329,SC2034,SC2016,SC1003,SC1091 # Subshell isolation, mocks and literal fixtures are intentional.
set -Eeuo pipefail

# Offline tests for menu option 9 (reinstall to official Debian 13). Nothing here touches the
# host's /boot, GRUB or network: every path is redirected into a temporary tree and every
# external command the flow needs is replaced by a function.

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Terminal output (prompts and re-ask hints) goes to a plain file instead of the real /dev/tty;
# every reply comes from a read_tty double. Removing the file simulates a missing terminal.
sed "s|/dev/tty|$work/tty|g" "$repo/debian-init.sh" >"$work/installer"
: >"$work/tty"

# Real keys: the dry-run preview and the paste flow run ssh-keygen on them.
command -v ssh-keygen >/dev/null 2>&1 || fail 'ssh-keygen is required'
ssh-keygen -q -t ed25519 -N '' -C fixture -f "$work/fixture-key" >/dev/null
pub=$(cat "$work/fixture-key.pub")
ssh-keygen -q -t ed25519 -N '' -C pasted -f "$work/paste-key" >/dev/null
paste_pub=$(cat "$work/paste-key.pub")
paste_fp=$(ssh-keygen -l -f "$work/paste-key.pub")
ssh-keygen -q -t ed25519 -N '' -C second -f "$work/second-key" >/dev/null
second_pub=$(cat "$work/second-key.pub")

declare -A FAKE_ADDR4=() FAKE_ADDR6=()
FAKE_V4_ROUTE='' FAKE_V6_ROUTE='' FAKE_V6_GET=''
FAKE_GRUBENV="$work/grubenv"

install_fakes() {
  reinstall_ip() {
    local IFS=' '
    case "$*" in
      '-4 route show default') printf '%s' "$FAKE_V4_ROUTE" ;;
      '-6 route show default') printf '%s' "$FAKE_V6_ROUTE" ;;
      '-4 -o addr show scope global dev '*) printf '%s' "${FAKE_ADDR4[${*: -1}]:-}" ;;
      '-6 -o addr show scope global dev '*) printf '%s' "${FAKE_ADDR6[${*: -1}]:-}" ;;
      '-6 route get '*) printf '%s' "$FAKE_V6_GET" ;;
      *) return 1 ;;
    esac
  }
  grub-editenv() {
    case "${1:-}:${2:-}" in
      list:) cat -- "$FAKE_GRUBENV" 2>/dev/null || true ;;
      -:unset) sed -i "/^${3}=/d" "$FAKE_GRUBENV" ;;
      *) return 1 ;;
    esac
  }
}

# Point every reinstall path into $1.
use_paths() {
  local base=$1
  mkdir -p "$base/boot/grub" "$base/sys"
  REINSTALL_SYS_ROOT="$base/sys"
  REINSTALL_BOOT_DIR="$base/boot/404-reinstall"
  REINSTALL_BOOT_TMP_DIR="$base/boot/404-reinstall.tmp"
  REINSTALL_GRUB_CFG="$base/boot/grub/grub.cfg"
  REINSTALL_CUSTOM_CFG="$base/boot/grub/custom.cfg"
  REINSTALL_CUSTOM_BAK="$base/boot/grub/custom.cfg.404bak"
  FAKE_GRUBENV="$base/boot/grub/grubenv"
}

# Fixed host state using documentation addresses only (RFC 5737 / RFC 3849).
use_host() {
  REINSTALL_HOST='vps-test' REINSTALL_NEW_HOST='vps-test' REINSTALL_HOST_VALID=true REINSTALL_DISK='vda' REINSTALL_DISK_SECTORS=83886080 REINSTALL_DISK_SIZE='40G'
  REINSTALL_GRUB_FS='ext2'
  REINSTALL_V4_MODE='static' REINSTALL_V4_IFACE='eth0' REINSTALL_V4_ADDR='203.0.113.10' REINSTALL_V4_PREFIX='32'
  REINSTALL_V4_NETMASK='255.255.255.255' REINSTALL_V4_GW='198.51.100.1' REINSTALL_V4_MAC='02:00:00:00:00:01'
  REINSTALL_V6_MODE='static' REINSTALL_V6_IFACE='eth1' REINSTALL_V6_ADDR='2001:db8:1::a/64'
  REINSTALL_V6_GW='2001:db8:ff::1' REINSTALL_V6_EXTRA='' REINSTALL_V6_MAC='02:00:00:00:00:02'
  REINSTALL_KEYS=("$pub")
  REINSTALL_ROOT_HASH='$6$fixture$hash'
  REINSTALL_ROOT_PASS='FixturePassword12345'
}

# expect_ok <name> <fn>: run fn in a fresh subshell with the script loaded; it must succeed.
expect_ok() {
  local name=$1 out rc
  shift
  set +e
  out=$( (source "$work/installer"; trap - EXIT ERR HUP INT TERM; install_fakes; "$@") 2>&1 )
  rc=$?
  set -e
  (( rc == 0 )) || { printf '%s\n' "$out" >&2; fail "$name (rc=$rc)"; }
  printf '%s\n' "$out" >"$work/last.out"
}

# expect_die <name> <message> <fn>: fn must fail and print message.
expect_die() {
  local name=$1 msg=$2 out rc
  shift 2
  set +e
  out=$( (source "$work/installer"; trap - EXIT ERR HUP INT TERM; install_fakes; "$@") 2>&1 )
  rc=$?
  set -e
  (( rc != 0 )) || { printf '%s\n' "$out" >&2; fail "$name: expected failure"; }
  grep -Fq -- "$msg" <<<"$out" || { printf '%s\n' "$out" >&2; fail "$name: missing [$msg]"; }
  printf '%s\n' "$out" >"$work/last.out"
}

# ---- 1. IPv4 parsing ----------------------------------------------------------

t_v4_slash32_onlink() {
  FAKE_V4_ROUTE='default via 198.51.100.1 dev eth0 onlink'
  FAKE_ADDR4[eth0]='2: eth0    inet 203.0.113.10/32 scope global eth0\       valid_lft forever preferred_lft forever'
  reinstall_check_ipv4
  [[ "$REINSTALL_V4_MODE" == static && "$REINSTALL_V4_ADDR" == 203.0.113.10 && "$REINSTALL_V4_PREFIX" == 32 ]] || fail "v4 /32: $REINSTALL_V4_MODE $REINSTALL_V4_ADDR/$REINSTALL_V4_PREFIX"
  [[ "$REINSTALL_V4_NETMASK" == 255.255.255.255 && "$REINSTALL_V4_GW" == 198.51.100.1 && "$REINSTALL_V4_IFACE" == eth0 ]] || fail 'v4 /32 mask/gw/iface'
}
expect_ok 'IPv4 /32 with off-link gateway' t_v4_slash32_onlink

t_v4_slash24_same() {
  FAKE_V4_ROUTE='default via 192.0.2.1 dev ens3 proto static'
  FAKE_ADDR4[ens3]='2: ens3    inet 192.0.2.10/24 brd 192.0.2.255 scope global ens3\       valid_lft forever preferred_lft forever'
  reinstall_check_ipv4
  [[ "$REINSTALL_V4_MODE" == static && "$REINSTALL_V4_NETMASK" == 255.255.255.0 && "$REINSTALL_V4_IFACE" == ens3 ]] || fail 'v4 /24'
}
expect_ok 'IPv4 /24 with on-link gateway' t_v4_slash24_same

t_v4_slash24_offlink() {
  FAKE_V4_ROUTE='default via 198.51.100.1 dev eth0 onlink'
  FAKE_ADDR4[eth0]='2: eth0    inet 192.0.2.10/24 brd 192.0.2.255 scope global eth0'
  reinstall_check_ipv4
}
expect_die 'IPv4 non-/32 with off-link gateway' '无法重装：IPv4 网关不在本网段' t_v4_slash24_offlink

t_v4_dynamic() {
  FAKE_V4_ROUTE='default via 192.0.2.1 dev eth0 proto dhcp src 192.0.2.50 metric 100'
  FAKE_ADDR4[eth0]='2: eth0    inet 192.0.2.50/24 metric 100 brd 192.0.2.255 scope global dynamic eth0\       valid_lft 86000sec preferred_lft 86000sec'
  reinstall_check_ipv4
  [[ "$REINSTALL_V4_MODE" == dhcp ]] || fail "v4 dynamic -> $REINSTALL_V4_MODE"
}
expect_ok 'IPv4 dynamic becomes dhcp' t_v4_dynamic

t_v4_two_routes() {
  FAKE_V4_ROUTE=$'default via 192.0.2.1 dev eth0\ndefault via 192.0.2.2 dev eth1'
  reinstall_check_ipv4
}
expect_die 'IPv4 two default routes' '无法重装：IPv4 默认路由必须恰好 1 条（当前 2 条）' t_v4_two_routes

t_v4_none() { FAKE_V4_ROUTE=''; reinstall_check_ipv4; }
expect_die 'IPv4 no default route' '无法重装：IPv4 默认路由必须恰好 1 条（当前 0 条）' t_v4_none

# ---- 2. IPv6 parsing ----------------------------------------------------------

t_v6_static_extra() {
  FAKE_V6_ROUTE='default via 2001:db8:ff::1 dev eth0 metric 1024 onlink pref medium'
  FAKE_ADDR6[eth0]=$'2: eth0    inet6 2001:db8:1::a/64 scope global \\       valid_lft forever preferred_lft forever\n2: eth0    inet6 2001:db8:1::b/64 scope global \\       valid_lft forever preferred_lft forever'
  FAKE_V6_GET='2001:4860:4860::8888 from :: via 2001:db8:ff::1 dev eth0 proto static src 2001:db8:1::b metric 1024 pref medium'
  reinstall_check_ipv6
  [[ "$REINSTALL_V6_MODE" == static && "$REINSTALL_V6_ADDR" == 2001:db8:1::b/64 ]] || fail "v6 primary: $REINSTALL_V6_MODE $REINSTALL_V6_ADDR"
  [[ "$REINSTALL_V6_EXTRA" == 2001:db8:1::a/64 && "$REINSTALL_V6_GW" == 2001:db8:ff::1 ]] || fail "v6 extra: [$REINSTALL_V6_EXTRA]"
}
expect_ok 'IPv6 static with extra address' t_v6_static_extra

t_v6_three_addrs() {
  FAKE_V6_ROUTE='default via 2001:db8:ff::1 dev eth0 onlink'
  FAKE_ADDR6[eth0]=$'2: eth0    inet6 2001:db8:1::a/64 scope global\n2: eth0    inet6 2001:db8:1::b/64 scope global\n2: eth0    inet6 2001:db8:1::c/64 scope global'
  FAKE_V6_GET=''
  reinstall_check_ipv6
  [[ "$REINSTALL_V6_ADDR" == 2001:db8:1::a/64 && "$REINSTALL_V6_EXTRA" == '2001:db8:1::b/64 2001:db8:1::c/64' ]] || fail "v6 extras joined: [$REINSTALL_V6_EXTRA]"
}
expect_ok 'IPv6 extra addresses are space separated' t_v6_three_addrs

t_v6_temporary() {
  FAKE_V6_ROUTE='default via fe80::1 dev eth0 proto ra metric 1024 expires 1700sec pref medium'
  FAKE_ADDR6[eth0]=$'2: eth0    inet6 2001:db8:1:0:1234:5678:9abc:def0/64 scope global temporary dynamic \\       valid_lft 600sec\n2: eth0    inet6 2001:db8:1::a/64 scope global \\       valid_lft forever preferred_lft forever'
  FAKE_V6_GET=''
  reinstall_check_ipv6
  [[ "$REINSTALL_V6_MODE" == static && "$REINSTALL_V6_ADDR" == 2001:db8:1::a/64 && -z "$REINSTALL_V6_EXTRA" ]] || fail "v6 temporary: $REINSTALL_V6_MODE $REINSTALL_V6_ADDR [$REINSTALL_V6_EXTRA]"
}
expect_ok 'IPv6 temporary address excluded' t_v6_temporary

t_v6_dynamic() {
  FAKE_V6_ROUTE='default via fe80::1 dev eth0 proto ra metric 1024 pref medium'
  FAKE_ADDR6[eth0]='2: eth0    inet6 2001:db8:1:0:5054:ff:fe12:3456/64 scope global dynamic mngtmpaddr noprefixroute \       valid_lft 86000sec preferred_lft 14000sec'
  reinstall_check_ipv6
  [[ "$REINSTALL_V6_MODE" == auto ]] || fail "v6 dynamic -> $REINSTALL_V6_MODE"
}
expect_ok 'IPv6 dynamic becomes auto' t_v6_dynamic

t_v6_none() {
  FAKE_V6_ROUTE=''
  reinstall_check_ipv6
  [[ "$REINSTALL_V6_MODE" == none ]] || fail "v6 none -> $REINSTALL_V6_MODE"
}
expect_ok 'IPv6 without default route' t_v6_none

t_v6_two_routes() {
  FAKE_V6_ROUTE=$'default via 2001:db8:ff::1 dev eth0 metric 1024\ndefault via 2001:db8:ff::2 dev eth1 metric 1024'
  reinstall_check_ipv6
}
expect_die 'IPv6 two default routes' '无法重装：存在多条 IPv6 默认路由（当前 2 条）' t_v6_two_routes

# IPv4 and IPv6 on two different NICs, including MAC lookup through the fake /sys.
t_dual_nic() {
  use_paths "$work/dual"
  mkdir -p "$REINSTALL_SYS_ROOT/class/net/eth0" "$REINSTALL_SYS_ROOT/class/net/eth1"
  echo '02:00:00:AA:BB:01' >"$REINSTALL_SYS_ROOT/class/net/eth0/address"
  echo '02:00:00:aa:bb:02' >"$REINSTALL_SYS_ROOT/class/net/eth1/address"
  FAKE_V4_ROUTE='default via 198.51.100.1 dev eth0 onlink'
  FAKE_ADDR4[eth0]='2: eth0    inet 203.0.113.10/32 scope global eth0'
  FAKE_V6_ROUTE='default via 2001:db8:ff::1 dev eth1 metric 1024 onlink pref medium'
  FAKE_ADDR6[eth1]='3: eth1    inet6 2001:db8:1::a/64 scope global'
  FAKE_V6_GET='2001:4860:4860::8888 from :: via 2001:db8:ff::1 dev eth1 src 2001:db8:1::a'
  hostname() { echo vps-test; }
  reinstall_check_ipv4
  reinstall_check_ipv6
  reinstall_check_identity
  [[ "$REINSTALL_V4_IFACE" == eth0 && "$REINSTALL_V6_IFACE" == eth1 ]] || fail 'dual nic ifaces'
  [[ "$REINSTALL_V4_MAC" == 02:00:00:aa:bb:01 && "$REINSTALL_V6_MAC" == 02:00:00:aa:bb:02 ]] || fail 'dual nic macs'
  [[ "$REINSTALL_HOST" == vps-test ]] || fail 'hostname'
}
expect_ok 'IPv4 and IPv6 on different NICs' t_dual_nic

# ---- 3. Disk checks with a fake /sys -----------------------------------------

make_block() { mkdir -p "$REINSTALL_SYS_ROOT/block/$1"; echo "$2" >"$REINSTALL_SYS_ROOT/block/$1/size"; }

t_disk_ok() {
  use_paths "$work/disk-ok"
  make_block vda 83886080
  make_block sda 736
  make_block sr0 2097151
  make_block loop0 83886080
  findmnt() { echo /dev/vda1; }
  lsblk() {
    local IFS=' '
    case "$*" in
      '-no PKNAME /dev/vda1') echo vda ;;
      '-ndo SIZE /dev/vda') echo ' 40G' ;;
      *) return 1 ;;
    esac
  }
  reinstall_check_disk
  [[ "$REINSTALL_DISK" == vda && "$REINSTALL_DISK_SECTORS" == 83886080 && "$REINSTALL_DISK_SIZE" == 40G ]] || fail "disk ok: $REINSTALL_DISK $REINSTALL_DISK_SECTORS $REINSTALL_DISK_SIZE"
}
expect_ok 'disk detection ignores loop devices' t_disk_ok

t_disk_twins() {
  use_paths "$work/disk-twins"
  make_block vda 83886080
  make_block vdb 83886080
  reinstall_check_disk_sizes vda
}
expect_die 'two disks with the same sector count' '无法重装：与目标盘 /dev/vda 扇区数（83886080）相同的块设备有 2 块，要求恰好 1 块' t_disk_twins

t_disk_small() {
  use_paths "$work/disk-small"
  make_block vda 8388607
  reinstall_check_disk_sizes vda
}
expect_die 'disk smaller than 4 GiB' '无法重装：目标盘 /dev/vda 小于 4 GiB（扇区数 8388607）' t_disk_small

t_disk_dm() { findmnt() { echo /dev/mapper/vg-root; }; reinstall_check_disk; }
expect_die 'root on device mapper' '无法重装：根分区不是普通分区' t_disk_dm

t_efi() { use_paths "$work/efi"; mkdir -p "$REINSTALL_SYS_ROOT/firmware/efi"; reinstall_check_firmware; }
expect_die 'EFI firmware' '无法重装：检测到' t_efi

# ---- 3b. tools, keyring and hostname ------------------------------------------

make_stub_path() {
  local dir=$1 cmd
  mkdir -p "$dir"
  for cmd in curl cpio gzip sha256sum openssl ssh-keygen wc stty; do
    printf '#!/bin/sh\nexit 0\n' >"$dir/$cmd"
    chmod +x "$dir/$cmd"
  done
}

t_tools_without_gpgv() {
  make_stub_path "$work/stub-nogpgv"
  mkdir -p "$work/keys-gpg"
  : >"$work/keys-gpg/debian-archive-keyring.gpg"
  : >"$work/keys-gpg/debian-archive-keyring.pgp"
  REINSTALL_KEYRING_DIR="$work/keys-gpg"
  make_stub_path "$work/stub-gpgv"
  printf '#!/bin/sh\nexit 0\n' >"$work/stub-gpgv/gpgv"
  chmod +x "$work/stub-gpgv/gpgv"
  # shellcheck disable=SC2123 # The search path is replaced on purpose to hide gpgv.
  PATH="$work/stub-nogpgv"
  reinstall_check_tools
  [[ "$REINSTALL_NEED_GPGV" == true ]] || fail 'missing gpgv not flagged'
  [[ "$REINSTALL_KEYRING" == "$work/keys-gpg/debian-archive-keyring.gpg" ]] || fail "keyring preference: $REINSTALL_KEYRING"
  # shellcheck disable=SC2123
  PATH="$work/stub-gpgv"
  reinstall_check_tools
  [[ "$REINSTALL_NEED_GPGV" == false ]] || fail 'present gpgv flagged as missing'
}
expect_ok 'gpgv is optional and flagged when missing' t_tools_without_gpgv

t_tools_missing_curl() {
  make_stub_path "$work/stub-nocurl"
  rm -f "$work/stub-nocurl/curl"
  # shellcheck disable=SC2123 # The search path is replaced on purpose to hide curl.
  PATH="$work/stub-nocurl"
  reinstall_check_tools
}
expect_die 'other tools are still required' '无法重装：缺少必要工具：curl' t_tools_missing_curl

t_keyring_pgp() {
  mkdir -p "$work/keys-pgp"
  : >"$work/keys-pgp/debian-archive-keyring.pgp"
  REINSTALL_KEYRING_DIR="$work/keys-pgp"
  reinstall_pick_keyring
  [[ "$REINSTALL_KEYRING" == "$work/keys-pgp/debian-archive-keyring.pgp" ]] || fail "pgp fallback: $REINSTALL_KEYRING"
}
expect_ok 'keyring falls back to .pgp' t_keyring_pgp

t_keyring_none() { mkdir -p "$work/keys-none"; REINSTALL_KEYRING_DIR="$work/keys-none"; reinstall_pick_keyring; }
expect_die 'no keyring at all' '无法重装：缺少 Debian 密钥环' t_keyring_none

t_hostname_rules() {
  local input expected valid
  while IFS='|' read -r input expected valid; do
    REINSTALL_HOST=$input
    reinstall_pick_new_hostname
    [[ "$REINSTALL_NEW_HOST" == "$expected" && "$REINSTALL_HOST_VALID" == "$valid" ]] ||
      fail "hostname [$input] -> [$REINSTALL_NEW_HOST] valid=$REINSTALL_HOST_VALID"
  done <<EOF
vps-6993|vps-6993|true
VPS-Test|vps-test|true
a|a|true
9lives|9lives|true
vps_test|debian|false
-vps|debian|false
vps-|debian|false
vps.example|debian|false
$(printf 'a%.0s' {1..63})|$(printf 'a%.0s' {1..63})|true
$(printf 'a%.0s' {1..64})|debian|false
EOF
}
expect_ok 'hostname is lowercased or replaced by debian' t_hostname_rules

t_invalid_hostname_flow() {
  use_host
  REINSTALL_HOST='VPS_Test'
  reinstall_pick_new_hostname
  reinstall_write_preseed "$work/preseed-badhost.cfg"
  grep -Fxq 'd-i netcfg/get_hostname string debian' "$work/preseed-badhost.cfg" || fail 'preseed get_hostname not debian'
  grep -Fxq 'd-i netcfg/hostname string debian' "$work/preseed-badhost.cfg" || fail 'preseed hostname not debian'
  reinstall_generate_password() { :; }
  read_tty() { [[ "$1" == *'VPS_Test'* ]] || fail "confirm prompt: $1"; printf -v "$2" '%s' 'VPS_Test'; }
  reinstall_confirm
}
expect_ok 'invalid hostname: summary, preseed and confirmation' t_invalid_hostname_flow
grep -Fq '当前主机名不合法，新系统将使用 debian' "$work/last.out" || fail 'invalid hostname summary line'
grep -Fq '主机名确认通过' "$work/last.out" || fail 'confirmation with the current hostname failed'

t_valid_hostname_summary() {
  use_host
  REINSTALL_HOST='VPS-Test'
  reinstall_pick_new_hostname
  reinstall_print_summary
}
expect_ok 'valid hostname summary' t_valid_hostname_summary
grep -Fq '主机名：vps-test' "$work/last.out" || fail 'lowercased hostname not shown'
if grep -Fq '不合法' "$work/last.out"; then fail 'valid hostname reported as invalid'; fi
if grep -Fq '将先安装 gpgv' "$work/last.out"; then fail 'gpgv line shown although gpgv is present'; fi

# ---- 4. preseed and net.env ---------------------------------------------------

t_preseed() {
  use_host
  reinstall_write_preseed "$work/preseed.cfg"
  local line
  for line in \
    'd-i pkgsel/upgrade select safe-upgrade' \
    'd-i netcfg/do_not_use_netplan boolean true' \
    'd-i pkgsel/include string ifupdown curl ca-certificates systemd-timesyncd' \
    'd-i grub-installer/bootdev string /dev/vda' \
    'd-i debian-installer/add-kernel-opts string net.ifnames=0 biosdevname=0' \
    'd-i partman-auto/disk string /dev/vda' \
    'd-i preseed/early_command string sh /404/early.sh net' \
    'd-i partman/early_command string sh /404/early.sh check' \
    'd-i preseed/late_command string sh /404/late.sh' \
    'd-i netcfg/disable_autoconfig boolean true' \
    'd-i netcfg/get_ipaddress string 203.0.113.10' \
    'd-i netcfg/get_netmask string 255.255.255.255' \
    'd-i netcfg/get_gateway string 198.51.100.1' \
    'd-i netcfg/get_hostname string vps-test' \
    'd-i passwd/root-password-crypted password $6$fixture$hash' \
    'd-i partman-auto/expert_recipe string \' \
    '            $iflabel{ gpt } \' \
    'd-i partman-basicfilesystems/no_swap boolean false' \
    'd-i mirror/suite string trixie' \
    'tasksel tasksel/first multiselect ssh-server'; do
    grep -Fxq -- "$line" "$work/preseed.cfg" || fail "preseed lacks [$line]"
  done
  if grep -Fq 'pkgsel/upgrade select none' "$work/preseed.cfg"; then fail 'preseed still uses upgrade none'; fi
  REINSTALL_V4_MODE='dhcp'
  reinstall_write_preseed "$work/preseed-dhcp.cfg"
  grep -Fxq 'd-i netcfg/disable_autoconfig boolean false' "$work/preseed-dhcp.cfg" || fail 'dhcp preseed autoconfig'
  if grep -Fq 'get_ipaddress' "$work/preseed-dhcp.cfg"; then fail 'dhcp preseed has static address'; fi
}
expect_ok 'preseed contains the required entries' t_preseed

t_net_env() {
  use_host
  REINSTALL_V6_EXTRA="2001:db8:1::b/64 it's-quoted"
  reinstall_write_net_env "$work/net.env"
  grep -Fxq "IPV4_ADDR='203.0.113.10'" "$work/net.env" || fail 'net.env IPV4_ADDR quoting'
  grep -Fxq "EXPECTED_SECTORS='83886080'" "$work/net.env" || fail 'net.env sectors'
  grep -Fxq "SELFCHECK_DELAY='0'" "$work/net.env" || fail 'net.env delay'
  grep -Fxq "IPV4_IFACE_OLD='eth0'" "$work/net.env" || fail 'net.env old iface'
  [[ "$(grep -c '' "$work/net.env")" == 15 ]] || fail 'net.env line count'
  [[ "$(sh -c '. "$1"; printf "%s|%s|%s" "$IPV6_EXTRA_ADDRS" "$IPV4_MAC" "$IPV6_MODE"' sh "$work/net.env")" == "2001:db8:1::b/64 it's-quoted|02:00:00:00:00:01|static" ]] ||
    fail 'net.env does not round-trip through sh'
  REINSTALL_TEST_MODE='selfcheck-fail'
  reinstall_write_net_env "$work/net-selfcheck.env"
  grep -Fxq "EXPECTED_SECTORS='83886081'" "$work/net-selfcheck.env" || fail 'selfcheck-fail sectors not +1'
  grep -Fxq "SELFCHECK_DELAY='120'" "$work/net-selfcheck.env" || fail 'selfcheck-fail delay'
}
expect_ok 'net.env quoting and selfcheck-fail values' t_net_env

# ---- 5. interfaces rendering (the POSIX sh renderer embedded in late.sh) -------

write_env() {
  local out=$1
  shift
  : >"$out"
  local kv
  for kv in "$@"; do printf '%s=%s\n' "${kv%%=*}" "$(reinstall_sh_quote "${kv#*=}")" >>"$out"; done
}

t_render_single() {
  write_env "$work/single.env" IPV4_MODE=static IPV4_ADDR=203.0.113.10 IPV4_PREFIX=32 IPV4_GW=198.51.100.1 \
    IPV6_MODE=static IPV6_ADDR=2001:db8:1::a/64 IPV6_GW=2001:db8:ff::1 'IPV6_EXTRA_ADDRS=2001:db8:1::b/64 2001:db8:1::c/64'
  reinstall_render_interfaces_preview "$work/single.env" eth0 eth0 >"$work/single.out"
  cat >"$work/single.exp" <<'EOF'
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address 203.0.113.10/32
    gateway 198.51.100.1
iface eth0 inet6 static
    address 2001:db8:1::a/64
    gateway 2001:db8:ff::1
    accept_ra 0
    autoconf 0
    up ip -6 addr add 2001:db8:1::b/64 dev eth0 || true
    down ip -6 addr del 2001:db8:1::b/64 dev eth0 || true
    up ip -6 addr add 2001:db8:1::c/64 dev eth0 || true
    down ip -6 addr del 2001:db8:1::c/64 dev eth0 || true
EOF
  diff -u "$work/single.exp" "$work/single.out" || fail 'single-NIC dual-stack interfaces'
}
expect_ok 'interfaces: single NIC dual stack' t_render_single

t_render_dual() {
  write_env "$work/dual.env" IPV4_MODE=static IPV4_ADDR=203.0.113.10 IPV4_PREFIX=32 IPV4_GW=198.51.100.1 \
    IPV6_MODE=static IPV6_ADDR=2001:db8:1::a/64 IPV6_GW=2001:db8:ff::1 IPV6_EXTRA_ADDRS=
  reinstall_render_interfaces_preview "$work/dual.env" eth0 eth1 >"$work/dual.out"
  cat >"$work/dual.exp" <<'EOF'
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address 203.0.113.10/32
    gateway 198.51.100.1

auto eth1
iface eth1 inet6 static
    address 2001:db8:1::a/64
    gateway 2001:db8:ff::1
    accept_ra 0
    autoconf 0
EOF
  diff -u "$work/dual.exp" "$work/dual.out" || fail 'dual-NIC dual-stack interfaces'
}
expect_ok 'interfaces: two NICs dual stack' t_render_dual

t_render_dhcp() {
  write_env "$work/dhcp.env" IPV4_MODE=dhcp IPV4_ADDR=192.0.2.50 IPV4_PREFIX=24 IPV4_GW=192.0.2.1 \
    IPV6_MODE=auto IPV6_ADDR= IPV6_GW= IPV6_EXTRA_ADDRS=
  reinstall_render_interfaces_preview "$work/dhcp.env" eth0 eth0 >"$work/dhcp.out"
  cat >"$work/dhcp.exp" <<'EOF'
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
iface eth0 inet6 auto
EOF
  diff -u "$work/dhcp.exp" "$work/dhcp.out" || fail 'dhcp interfaces'
}
expect_ok 'interfaces: dhcp' t_render_dhcp

# ---- 6. custom.cfg, cleanup and leftover detection ----------------------------

t_custom_cfg_roundtrip() {
  use_paths "$work/cfg-user"
  printf '%s\n' '# user entry' "menuentry 'rescue' {" '  linux /vmlinuz single' '}' >"$REINSTALL_CUSTOM_CFG"
  cp -- "$REINSTALL_CUSTOM_CFG" "$work/cfg-user.orig"
  reinstall_write_custom_cfg 1111-2222 /404-reinstall ext2
  grep -Fxq "$REINSTALL_MARK_BEGIN" "$REINSTALL_CUSTOM_CFG" || fail 'marker block not written'
  grep -Fq -- "--id reinstall-debian13" "$REINSTALL_CUSTOM_CFG" || fail 'menuentry id'
  grep -Fq "menuentry 'rescue'" "$REINSTALL_CUSTOM_CFG" || fail 'user entry lost after write'
  cmp -s "$work/cfg-user.orig" "$REINSTALL_CUSTOM_BAK" || fail 'backup differs from original'
  reinstall_write_custom_cfg 1111-2222 /404-reinstall ext2
  [[ "$(grep -cFx "$REINSTALL_MARK_BEGIN" "$REINSTALL_CUSTOM_CFG")" == 1 ]] || fail 'rewrite duplicated the marker block'
  reinstall_cleanup
  cmp -s "$work/cfg-user.orig" "$REINSTALL_CUSTOM_CFG" || fail 'user custom.cfg changed after cleanup'
  [[ ! -e "$REINSTALL_CUSTOM_BAK" ]] || fail 'backup left behind'
  reinstall_cleanup
  cmp -s "$work/cfg-user.orig" "$REINSTALL_CUSTOM_CFG" || fail 'second cleanup changed custom.cfg'
}
expect_ok 'custom.cfg user content survives write and cleanup' t_custom_cfg_roundtrip

t_custom_cfg_strip() {
  use_paths "$work/cfg-strip"
  printf '%s\n' '# keep me' "$REINSTALL_MARK_BEGIN" 'menuentry x {' '}' "$REINSTALL_MARK_END" '# keep me too' >"$REINSTALL_CUSTOM_CFG"
  reinstall_cleanup
  [[ "$(cat "$REINSTALL_CUSTOM_CFG")" == $'# keep me\n# keep me too' ]] || fail 'marker block not stripped'
}
expect_ok 'cleanup strips only the marker block' t_custom_cfg_strip

t_custom_cfg_new() {
  use_paths "$work/cfg-new"
  reinstall_write_custom_cfg 1111-2222 /404-reinstall xfs
  grep -Fq 'insmod xfs' "$REINSTALL_CUSTOM_CFG" || fail 'xfs module'
  [[ ! -e "$REINSTALL_CUSTOM_BAK" ]] || fail 'backup created for a missing custom.cfg'
  reinstall_cleanup
  [[ ! -e "$REINSTALL_CUSTOM_CFG" ]] || fail 'created custom.cfg not removed'
  reinstall_cleanup
}
expect_ok 'custom.cfg created by the script is removed' t_custom_cfg_new

t_leftover_signals() {
  use_paths "$work/leftover"
  printf 'saved_entry=0\n' >"$FAKE_GRUBENV"
  if reinstall_detect_leftover; then fail "false leftover: ${REINSTALL_LEFTOVERS[*]}"; fi
  mkdir -p "$REINSTALL_BOOT_DIR"
  reinstall_detect_leftover || fail 'boot dir not detected'
  rm -rf -- "$REINSTALL_BOOT_DIR"
  mkdir -p "$REINSTALL_BOOT_TMP_DIR"
  reinstall_detect_leftover || fail 'tmp dir not detected'
  rm -rf -- "$REINSTALL_BOOT_TMP_DIR"
  printf '%s\n' "$REINSTALL_MARK_BEGIN" "$REINSTALL_MARK_END" >"$REINSTALL_CUSTOM_CFG"
  reinstall_detect_leftover || fail 'custom.cfg marker not detected'
  rm -f -- "$REINSTALL_CUSTOM_CFG"
  printf 'saved_entry=0\nnext_entry=reinstall-debian13\n' >"$FAKE_GRUBENV"
  reinstall_detect_leftover || fail 'next_entry not detected'
  reinstall_cleanup
  [[ "$(cat "$FAKE_GRUBENV")" == 'saved_entry=0' ]] || fail 'next_entry not unset'
  if reinstall_detect_leftover; then fail 'leftover after cleanup'; fi
  # Fifth signal: a custom.cfg backup without any marker block; cleanup restores it.
  printf '# original\n' >"$REINSTALL_CUSTOM_BAK"
  printf '# edited later\n' >"$REINSTALL_CUSTOM_CFG"
  reinstall_detect_leftover || fail 'custom.cfg.404bak not detected'
  [[ "${REINSTALL_LEFTOVERS[*]}" == *custom.cfg.404bak* ]] || fail "backup signal text: ${REINSTALL_LEFTOVERS[*]}"
  reinstall_cleanup
  [[ "$(cat "$REINSTALL_CUSTOM_CFG")" == '# original' && ! -e "$REINSTALL_CUSTOM_BAK" ]] || fail 'backup not restored'
  if reinstall_detect_leftover; then fail 'leftover after restoring backup'; fi
  rm -f -- "$REINSTALL_CUSTOM_CFG"
  # Someone else's next_entry is not ours: neither a leftover nor touched by cleanup.
  printf 'next_entry=1\n' >"$FAKE_GRUBENV"
  if reinstall_detect_leftover; then fail 'foreign next_entry counted as leftover'; fi
  reinstall_cleanup
  [[ "$(cat "$FAKE_GRUBENV")" == 'next_entry=1' ]] || fail 'cleanup touched a foreign next_entry'
}
expect_ok 'leftover detection recognises all five signals' t_leftover_signals

t_leftover_prompt_no() {
  use_paths "$work/leftover-no"
  mkdir -p "$REINSTALL_BOOT_DIR"
  ask_yes_no() { [[ "$1" == '是否清除这些遗留？' && "$2" == true ]] || fail "prompt: $1 $2"; return 1; }
  reinstall_check_leftover
  fail 'declining leftover cleanup did not exit'
}
expect_ok 'declining leftover cleanup exits 0' t_leftover_prompt_no
grep -Fq '检测到上次未完成的重装准备（下次重启可能会清空整机）' "$work/last.out" || fail 'leftover warning text'
[[ -d "$work/leftover-no/boot/404-reinstall" ]] || fail 'declined leftover was removed'

t_leftover_prompt_yes() {
  use_paths "$work/leftover-yes"
  mkdir -p "$REINSTALL_BOOT_DIR" "$REINSTALL_BOOT_TMP_DIR"
  ask_yes_no() { return 0; }
  acquire_lock() { :; }
  reinstall_check_leftover
  [[ ! -e "$REINSTALL_BOOT_DIR" && ! -e "$REINSTALL_BOOT_TMP_DIR" ]] || fail 'accepted leftover not removed'
}
expect_ok 'accepting leftover cleanup removes it' t_leftover_prompt_yes

# ---- 7. gpgv status parsing ---------------------------------------------------

good_sig() {
  printf '[GNUPG:] NEWSIG\n[GNUPG:] KEY_CONSIDERED %s 0\n[GNUPG:] GOODSIG %s Debian Archive Signing Key\n' "$1" "${1: -16}"
  printf '[GNUPG:] VALIDSIG %s 2026-11-01 1793500000 0 4 0 22 8 01 %s\n' "$1" "$1"
}
good_sig AAAA1111BBBB2222CCCC3333DDDD4444EEEE5555 >"$work/gpg-all-good"
good_sig 1111222233334444555566667777888899990000 >>"$work/gpg-all-good"
{
  good_sig AAAA1111BBBB2222CCCC3333DDDD4444EEEE5555
  printf '[GNUPG:] NEWSIG\n[GNUPG:] ERRSIG 0123456789ABCDEF 22 8 01 1793500000 9 -\n[GNUPG:] NO_PUBKEY 0123456789ABCDEF\n'
} >"$work/gpg-nopub"
{
  good_sig AAAA1111BBBB2222CCCC3333DDDD4444EEEE5555
  printf '[GNUPG:] NEWSIG\n[GNUPG:] BADSIG 7777888899990000 Debian Archive Signing Key\n'
} >"$work/gpg-bad"
printf '[GNUPG:] NEWSIG\n[GNUPG:] ERRSIG 0123456789ABCDEF 22 8 01 1793500000 9 -\n[GNUPG:] NO_PUBKEY 0123456789ABCDEF\n' >"$work/gpg-novalid"
{
  good_sig AAAA1111BBBB2222CCCC3333DDDD4444EEEE5555
  printf '[GNUPG:] NEWSIG\n[GNUPG:] ERRSIG 0123456789ABCDEF 22 8 01 1793500000 4 -\n'
} >"$work/gpg-errsig"
{
  good_sig AAAA1111BBBB2222CCCC3333DDDD4444EEEE5555
  printf '[GNUPG:] EXPKEYSIG 6ED0E7B82643E131 Debian Archive Signing Key\n'
} >"$work/gpg-expkey"

t_gpg_ok() { reinstall_check_gpg_status "$1"; }
t_gpg_reject() { if reinstall_check_gpg_status "$1"; then fail "accepted $1"; fi; }
expect_ok 'gpg: all signatures valid' t_gpg_ok "$work/gpg-all-good"
expect_ok 'gpg: valid plus NO_PUBKEY' t_gpg_ok "$work/gpg-nopub"
grep -Fq '0123456789ABCDEF' "$work/last.out" || fail 'tolerated NO_PUBKEY not logged'
expect_ok 'gpg: BADSIG rejected' t_gpg_reject "$work/gpg-bad"
expect_ok 'gpg: no VALIDSIG rejected' t_gpg_reject "$work/gpg-novalid"
expect_ok 'gpg: ERRSIG without NO_PUBKEY rejected' t_gpg_reject "$work/gpg-errsig"
expect_ok 'gpg: EXPKEYSIG rejected' t_gpg_reject "$work/gpg-expkey"
expect_ok 'gpg: empty status rejected' t_gpg_reject /dev/null

# ---- 8. test switch -----------------------------------------------------------

t_test_mode() {
  local mode
  for mode in dry-run selfcheck-fail no-reboot; do
    VPS_INIT_REINSTALL_TEST=$mode
    reinstall_parse_test_mode
    [[ "$REINSTALL_TEST_MODE" == "$mode" ]] || fail "test mode $mode"
  done
  unset VPS_INIT_REINSTALL_TEST
  reinstall_parse_test_mode
  [[ -z "$REINSTALL_TEST_MODE" ]] || fail 'unset test mode'
}
expect_ok 'valid VPS_INIT_REINSTALL_TEST values' t_test_mode
t_test_mode_bad() { VPS_INIT_REINSTALL_TEST=dryrun; reinstall_parse_test_mode; }
expect_die 'invalid VPS_INIT_REINSTALL_TEST' 'VPS_INIT_REINSTALL_TEST 取值无效：dryrun' t_test_mode_bad

# ---- 9. trap integration while armed -------------------------------------------

t_armed_die() {
  use_paths "$work/armed-die"
  mkdir -p "$REINSTALL_BOOT_TMP_DIR" "$REINSTALL_BOOT_DIR"
  REINSTALL_ARMED=true
  die 'simulated failure'
}
expect_die 'die while armed' 'simulated failure' t_armed_die
[[ ! -e "$work/armed-die/boot/404-reinstall" && ! -e "$work/armed-die/boot/404-reinstall.tmp" ]] || fail 'die did not clean up'

t_armed_signal() {
  use_paths "$work/armed-signal"
  mkdir -p "$REINSTALL_BOOT_DIR"
  reinstall_write_custom_cfg 1111-2222 /404-reinstall ext2
  printf 'next_entry=reinstall-debian13\n' >"$FAKE_GRUBENV"
  REINSTALL_ARMED=true
  on_signal INT
}
expect_die 'signal while armed' '收到 INT' t_armed_signal
[[ ! -e "$work/armed-signal/boot/404-reinstall" && ! -e "$work/armed-signal/boot/grub/custom.cfg" ]] || fail 'signal did not clean up'
[[ ! -s "$work/armed-signal/boot/grub/grubenv" ]] || fail 'signal did not unset next_entry'

t_armed_exit() {
  use_paths "$work/armed-exit"
  mkdir -p "$REINSTALL_BOOT_DIR"
  trap cleanup EXIT
  REINSTALL_ARMED=true
  exit 3
}
expect_die 'plain exit while armed' '重装准备未完成' t_armed_exit
[[ ! -e "$work/armed-exit/boot/404-reinstall" ]] || fail 'EXIT trap did not clean up'

t_disarmed_die() {
  use_paths "$work/disarmed"
  mkdir -p "$REINSTALL_BOOT_DIR"
  die 'not armed'
}
expect_die 'die while not armed' 'not armed' t_disarmed_die
[[ -d "$work/disarmed/boot/404-reinstall" ]] || fail 'cleanup ran while not armed'

# ---- 10. download, verification and overlay with mocked curl/gpgv ---------------

fix="$work/fixture"
mirror="$fix/mirror/dists/trixie"
images="$mirror/main/installer-amd64/current/images"
mkdir -p "$images/netboot/debian-installer/amd64"
printf 'fixture kernel\n' >"$images/netboot/debian-installer/amd64/linux"
: >"$images/netboot/debian-installer/amd64/initrd.gz"
printf 'signed fixture\n' >"$mirror/InRelease"
{
  printf '%s  ./netboot/debian-installer/amd64/linux\n' "$(sha256sum "$images/netboot/debian-installer/amd64/linux" | cut -d' ' -f1)"
  printf '%s  ./netboot/debian-installer/amd64/initrd.gz\n' "$(sha256sum "$images/netboot/debian-installer/amd64/initrd.gz" | cut -d' ' -f1)"
} >"$images/SHA256SUMS"
sums_hash=$(sha256sum "$images/SHA256SUMS" | cut -d' ' -f1)
for codename in trixie bookworm; do
  printf 'Origin: Debian\nSuite: stable\nCodename: %s\nSHA256:\n %s 1234 main/installer-amd64/current/images/SHA256SUMS\n %s 99 main/Contents-amd64\n' \
    "$codename" "$sums_hash" "$(printf '%064d' 0)" >"$fix/Release-$codename"
done
FAKE_RELEASE="$fix/Release-trixie"
FAKE_GPG_STATUS="$work/gpg-all-good"

install_download_fakes() {
  curl() {
    local IFS=' ' url='' out=''
    printf '%s\n' "$*" >>"$fix/curl.log"
    printf 'curl\n' >>"$fix/order.log"
    while (( $# )); do
      case "$1" in
        -o) out=$2; shift 2 ;;
        https://*) url=$1; shift ;;
        *) shift ;;
      esac
    done
    [[ -f "$fix/mirror/${url#https://deb.debian.org/debian/}" ]] || return 22
    cp -- "$fix/mirror/${url#https://deb.debian.org/debian/}" "$out"
  }
  gpgv() {
    local out=''
    while (( $# )); do
      case "$1" in
        --output) out=$2; shift 2 ;;
        --status-fd|--keyring) shift 2 ;;
        *) shift ;;
      esac
    done
    cat -- "$FAKE_GPG_STATUS" >&3
    cp -- "$FAKE_RELEASE" "$out"
    echo 'gpgv: fixture log' >&2
    return 2
  }
}

t_dry_run() {
  use_paths "$work/dry"
  use_host
  install_download_fakes
  printf '# user custom\n' >"$REINSTALL_CUSTOM_CFG"
  printf 'saved_entry=0\n' >"$FAKE_GRUBENV"
  REINSTALL_TEST_MODE='dry-run'
  REINSTALL_KEYS=("command=\"/bin/false\" $pub" "$paste_pub")
  reinstall_confirm() { :; }
  run_reinstall
  [[ ! -e "$REINSTALL_BOOT_DIR" && ! -e "$REINSTALL_BOOT_TMP_DIR" ]] || fail 'dry-run left files in /boot'
  [[ "$(cat "$REINSTALL_CUSTOM_CFG")" == '# user custom' && ! -e "$REINSTALL_CUSTOM_BAK" ]] || fail 'dry-run touched custom.cfg'
  [[ "$(cat "$FAKE_GRUBENV")" == 'saved_entry=0' ]] || fail 'dry-run touched grubenv'
  [[ "$REINSTALL_ARMED" == false ]] || fail 'dry-run stayed armed'
}
rm -f "$fix/curl.log"
expect_ok 'dry-run downloads, prints and cleans up' t_dry_run
# The authorized_keys preview follows the interfaces preview and lists one ssh-keygen -l line per key.
awk '/网卡配置预览/ {n=NR} /404\/authorized_keys（将写入新系统）/ {k=NR} /dry-run 完成/ {d=NR} END {exit !(n && k && d && n < k && k < d)}' "$work/last.out" ||
  fail 'dry-run authorized_keys preview missing or out of order'
grep -Fxq "$(ssh-keygen -l -f "$work/fixture-key.pub")" "$work/last.out" || fail 'dry-run preview lacks the file key fingerprint'
grep -Fxq "$paste_fp" "$work/last.out" || fail 'dry-run preview lacks the second key fingerprint'
[[ "$(sed -n '/404\/authorized_keys（将写入新系统）/,/^\[INFO\] =====/p' "$work/last.out" | grep -c 'SHA256:')" == 2 ]] ||
  fail 'dry-run preview does not list exactly one line per key'
for line in 'd-i pkgsel/upgrade select safe-upgrade' "IPV4_ADDR='203.0.113.10'" 'auto eth1' 'dry-run 完成'; do
  grep -Fq -- "$line" "$work/last.out" || fail "dry-run output lacks [$line]"
done
[[ "$(grep -c '' "$fix/curl.log")" == 4 ]] || fail 'dry-run did not make exactly four downloads'
while IFS= read -r line; do
  [[ "$line" == "--proto =https --tlsv1.2 -fsSL --retry 3 --connect-timeout 15 https://deb.debian.org/debian/dists/trixie/"*' -o '* ]] ||
    fail "curl options: $line"
done <"$fix/curl.log"

t_missing_gpgv_flow() {
  use_paths "$work/gpgv-install"
  use_host
  install_download_fakes
  REINSTALL_TEST_MODE='dry-run'
  REINSTALL_NEED_GPGV=true
  reinstall_generate_password() { :; }
  read_tty() { printf -v "$2" '%s' "$REINSTALL_HOST"; }
  apt_get() {
    local IFS=' '
    printf 'apt_get %s\n' "$*" >>"$fix/order.log"
    [[ "$REINSTALL_ARMED" == false && ! -e "$REINSTALL_BOOT_TMP_DIR" ]] || fail 'gpgv installed after arming'
  }
  run_reinstall
  [[ "$REINSTALL_NEED_GPGV" == false ]] || fail 'gpgv still flagged after install'
  [[ ! -e "$REINSTALL_BOOT_DIR" && ! -e "$REINSTALL_BOOT_TMP_DIR" ]] || fail 'dry-run with gpgv install left files'
}
rm -f "$fix/order.log" "$fix/curl.log"
expect_ok 'missing gpgv: summary line, install before download' t_missing_gpgv_flow
grep -Fq '将先安装 gpgv（Debian 官方包，用于校验安装文件签名）' "$work/last.out" || fail 'summary lacks the gpgv line'
[[ "$(head -n 2 "$fix/order.log")" == $'apt_get update\napt_get install -y --no-install-recommends gpgv' ]] ||
  fail "gpgv update/install calls or order (both before the first download): $(cat "$fix/order.log")"
[[ "$(grep -c '^apt_get' "$fix/order.log")" == 2 && "$(grep -c '^curl$' "$fix/order.log")" == 4 ]] || fail 'unexpected apt_get/curl calls'

t_gpgv_update_fails() {
  use_paths "$work/gpgv-update-fail"
  use_host
  install_download_fakes
  REINSTALL_NEED_GPGV=true
  reinstall_generate_password() { :; }
  read_tty() { printf -v "$2" '%s' "$REINSTALL_HOST"; }
  apt_get() { local IFS=' '; printf 'apt_get %s\n' "$*" >>"$fix/order.log"; [[ "$1" != update ]]; }
  run_reinstall
}
rm -f "$fix/order.log"
expect_die 'apt update failure stops before install and download' '更新软件包索引失败，无法安装 gpgv；尚未改动任何启动项' t_gpgv_update_fails
[[ "$(cat "$fix/order.log")" == 'apt_get update' ]] || fail "update failure still installed or downloaded: $(cat "$fix/order.log")"

# APT_WAIT_MAX is readonly and read from VPS_INIT_APT_WAIT when the script is sourced.
t_apt_wait() { reinstall_preflight; }
VPS_INIT_APT_WAIT=abc expect_die 'reinstall path rejects a non-numeric VPS_INIT_APT_WAIT' 'VPS_INIT_APT_WAIT 必须是 >=60 的整数秒' t_apt_wait
VPS_INIT_APT_WAIT=59 expect_die 'reinstall path rejects VPS_INIT_APT_WAIT below 60' 'VPS_INIT_APT_WAIT 必须是 >=60 的整数秒' t_apt_wait

t_gpgv_install_fails() {
  use_paths "$work/gpgv-fail"
  use_host
  install_download_fakes
  REINSTALL_NEED_GPGV=true
  reinstall_generate_password() { :; }
  read_tty() { printf -v "$2" '%s' "$REINSTALL_HOST"; }
  apt_get() { [[ "$1" != install ]] || return 100; }
  run_reinstall
}
rm -f "$fix/order.log"
expect_die 'gpgv install failure stops before download' '安装 gpgv 失败；尚未改动任何启动项' t_gpgv_install_fails
[[ ! -e "$fix/order.log" ]] || fail 'download started after a failed gpgv install'
[[ ! -e "$work/gpgv-fail/boot/404-reinstall" && ! -e "$work/gpgv-fail/boot/404-reinstall.tmp" && ! -e "$work/gpgv-fail/boot/grub/custom.cfg" ]] ||
  fail 'gpgv install failure left boot changes'

t_bad_codename() {
  use_paths "$work/codename"
  use_host
  install_download_fakes
  FAKE_RELEASE="$fix/Release-bookworm"
  reinstall_confirm() { :; }
  run_reinstall
}
expect_die 'Codename must be trixie' 'Release 的 Codename 不是 trixie（实际 bookworm）' t_bad_codename
[[ ! -e "$work/codename/boot/404-reinstall.tmp" ]] || fail 'Codename failure did not clean up'

t_bad_signature() {
  use_paths "$work/badsig"
  use_host
  install_download_fakes
  FAKE_GPG_STATUS="$work/gpg-bad"
  reinstall_confirm() { :; }
  run_reinstall
}
expect_die 'BADSIG stops the download' 'InRelease GPG 签名校验失败' t_bad_signature
[[ ! -e "$work/badsig/boot/404-reinstall.tmp" ]] || fail 'signature failure did not clean up'

t_bad_kernel_hash() {
  use_paths "$work/badhash"
  use_host
  install_download_fakes
  curl() {
    local IFS=' ' url='' out=''
    while (( $# )); do case "$1" in -o) out=$2; shift 2 ;; https://*) url=$1; shift ;; *) shift ;; esac; done
    if [[ "$url" == */linux ]]; then printf 'tampered\n' >"$out"; return 0; fi
    cp -- "$fix/mirror/${url#https://deb.debian.org/debian/}" "$out"
  }
  reinstall_confirm() { :; }
  run_reinstall
}
expect_die 'tampered kernel is rejected' 'netboot linux SHA256 校验失败' t_bad_kernel_hash
[[ ! -e "$work/badhash/boot/404-reinstall.tmp" && ! -e "$work/badhash/boot/404-reinstall" ]] || fail 'hash failure did not clean up'

t_overlay() {
  use_paths "$work/overlay"
  use_host
  install_download_fakes
  reinstall_download_and_verify
  reinstall_build_overlay
  [[ -z "$REINSTALL_STAGE_DIR" ]] || fail 'stage dir not reset'
  # The fixture initrd is empty, so initrd.gz is exactly the appended overlay.
  mkdir -p "$work/overlay/x"
  (cd "$work/overlay/x" && gzip -dc "$REINSTALL_BOOT_DIR/initrd.gz" | cpio -idm --quiet --no-absolute-filenames)
  gzip -dc "$REINSTALL_BOOT_DIR/initrd.gz" | cpio -itv --quiet >"$work/overlay/list"
}
expect_ok 'overlay archive is built' t_overlay
x="$work/overlay/x"
for path in preseed.cfg 404/net.env 404/early.sh 404/late.sh 404/authorized_keys usr/lib/finish-install.d/50404-reinstall-cleanup; do
  [[ -f "$x/$path" ]] || fail "overlay lacks $path"
done
for path in 404/early.sh 404/late.sh usr/lib/finish-install.d/50404-reinstall-cleanup; do
  [[ -x "$x/$path" ]] || fail "overlay $path not executable"
done
grep -Eq '^-rwxr-xr-x +1 root +root .* usr/lib/finish-install\.d/50404-reinstall-cleanup$' "$work/overlay/list" || fail 'finish hook mode/owner in archive'
for dir in usr usr/lib usr/lib/finish-install.d; do
  grep -Eq "^drwxr-xr-x +[0-9]+ root +root .* ${dir//./\\.}\$" "$work/overlay/list" || fail "archive dir $dir must be 0755 root"
done
grep -Fxq "$pub" "$x/404/authorized_keys" || fail 'authorized_keys content'

# ---- 11. embedded POSIX scripts ----------------------------------------------

gen="$work/gen"
mkdir -p "$gen"
t_generate() {
  reinstall_write_early_sh "$gen/early.sh"
  reinstall_write_late_sh "$gen/late.sh"
  reinstall_write_finish_cleanup "$gen/50404-reinstall-cleanup"
}
expect_ok 'generate embedded scripts' t_generate
command -v shellcheck >/dev/null 2>&1 || fail 'shellcheck is required'
for script in early.sh late.sh 50404-reinstall-cleanup; do
  sh -n "$gen/$script" || fail "sh -n $script"
  shellcheck -s sh "$gen/$script" || fail "shellcheck -s sh $script"
done
head -n 2 "$gen/50404-reinstall-cleanup" | grep -Fxq 'set -u' || fail 'finish hook must use set -u'
if grep -Eq '^[[:space:]]*set -e' "$gen/50404-reinstall-cleanup"; then fail 'finish hook must not use set -e'; fi
grep -Fq 'abort_and_reboot' "$gen/early.sh" || fail 'early.sh lacks abort_and_reboot'
grep -Fq 'sleep "$SELFCHECK_DELAY"' "$gen/early.sh" || fail 'early.sh selfcheck delay'
grep -Fq 'render_interfaces "$v4_if" "$v6_if" > /target/etc/network/interfaces' "$gen/late.sh" || fail 'late.sh uses the shared renderer'

# Run the finish hook against a fake in-target: purge only installed packages, never fail.
fake="$work/fake-bin"
mkdir -p "$fake"
cat >"$fake/in-target" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_LOG"
if [ "$1" = --pass-stdout ]; then
    shift
    case "$*" in
        *" qemu-guest-agent") printf 'install ok installed' ;;
        *" task-english") printf 'install ok installed' ;;
        *" os-prober") printf 'deinstall ok config-files' ;;
        *) exit 1 ;;
    esac
    exit 0
fi
case "$*" in
    "apt-get -y purge"*) exit 100 ;;
    *) exit 0 ;;
esac
EOF
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$FAKE_SYSLOG"\n' >"$fake/logger"
chmod +x "$fake/in-target" "$fake/logger"
FAKE_LOG="$work/in-target.log" FAKE_SYSLOG="$work/syslog" PATH="$fake:$PATH" sh "$gen/50404-reinstall-cleanup" ||
  fail 'finish hook returned non-zero'
grep -Fxq 'apt-get -y purge qemu-guest-agent task-english' "$work/in-target.log" || fail "finish hook purge list: $(cat "$work/in-target.log")"
grep -Fxq 'apt-get -y autoremove --purge' "$work/in-target.log" || fail 'finish hook autoremove'
[[ "$(grep -c -- '--pass-stdout dpkg-query' "$work/in-target.log")" == 12 ]] || fail 'finish hook did not query all 12 packages'
grep -Fq 'purge failed (rc=100), continuing' "$work/syslog" || fail 'finish hook did not log the purge failure'

# ---- 12. review follow-ups ----------------------------------------------------

# Space-joined logs even though the script runs with IFS=$'\n\t'.
t_join() { [[ "$(reinstall_join a 'b c' d)" == 'a b c d' ]] || fail "join: $(reinstall_join a 'b c' d)"; }
expect_ok 'reinstall_join uses single spaces' t_join

# gpgv: ERRSIG is tolerated only with rc 9 and a matching NO_PUBKEY.
{
  good_sig AAAA1111BBBB2222CCCC3333DDDD4444EEEE5555
  printf '[GNUPG:] NEWSIG\n[GNUPG:] ERRSIG 0123456789ABCDEF 22 8 01 1793500000 4 -\n[GNUPG:] NO_PUBKEY 0123456789ABCDEF\n'
} >"$work/gpg-errsig-rc4-nopub"
{ good_sig AAAA1111BBBB2222CCCC3333DDDD4444EEEE5555; printf '[GNUPG:] EXPSIG 6ED0E7B82643E131 Debian Archive Signing Key\n'; } >"$work/gpg-expsig"
{ good_sig AAAA1111BBBB2222CCCC3333DDDD4444EEEE5555; printf '[GNUPG:] REVKEYSIG 6ED0E7B82643E131 Debian Archive Signing Key\n'; } >"$work/gpg-revkey"
{
  good_sig AAAA1111BBBB2222CCCC3333DDDD4444EEEE5555
  printf '[GNUPG:] NEWSIG\n[GNUPG:] ERRSIG 78DBA3BC47EF2265 22 8 01 1793500000 9 -\n[GNUPG:] NO_PUBKEY 78DBA3BC47EF2265\n'
  printf '[GNUPG:] NEWSIG\n[GNUPG:] ERRSIG 762F67A0B2C39DE4 22 8 01 1793500000 9 -\n[GNUPG:] NO_PUBKEY 762F67A0B2C39DE4\n'
} >"$work/gpg-two-nopub"
expect_ok 'gpg: ERRSIG rc 4 rejected even with NO_PUBKEY' t_gpg_reject "$work/gpg-errsig-rc4-nopub"
grep -Fq 'ERRSIG 0123456789ABCDEF rc=4' "$work/last.out" || fail 'rc=4 ERRSIG not reported'
expect_ok 'gpg: EXPSIG rejected' t_gpg_reject "$work/gpg-expsig"
expect_ok 'gpg: REVKEYSIG rejected' t_gpg_reject "$work/gpg-revkey"
expect_ok 'gpg: two missing keys tolerated' t_gpg_ok "$work/gpg-two-nopub"
grep -Fq '（78DBA3BC47EF2265 762F67A0B2C39DE4），已忽略；其余 1 个签名有效' "$work/last.out" || fail 'missing-key log is not one line'

# IPv4 gateway and address must be dotted quads.
t_v4_gw_inet6() {
  FAKE_V4_ROUTE='default via inet6 fe80::1 dev eth0 proto static'
  FAKE_ADDR4[eth0]='2: eth0    inet 203.0.113.10/32 scope global eth0'
  reinstall_check_ipv4
}
expect_die 'IPv4 default route via inet6 nexthop' '无法重装：IPv4 默认路由的网关不是 IPv4 地址，暂不支持' t_v4_gw_inet6
t_v4_gw_range() {
  FAKE_V4_ROUTE='default via 198.51.100.256 dev eth0 onlink'
  FAKE_ADDR4[eth0]='2: eth0    inet 203.0.113.10/32 scope global eth0'
  reinstall_check_ipv4
}
expect_die 'IPv4 gateway octet above 255' '无法重装：IPv4 默认路由的网关不是 IPv4 地址，暂不支持' t_v4_gw_range
t_v4_addr_range() {
  FAKE_V4_ROUTE='default via 198.51.100.1 dev eth0 onlink'
  FAKE_ADDR4[eth0]='2: eth0    inet 203.0.113.300/32 scope global eth0'
  reinstall_check_ipv4
}
expect_die 'IPv4 address octet above 255' '无法重装：IPv4 地址不是合法的 IPv4 地址（203.0.113.300/32）' t_v4_addr_range
t_v4_ok_edges() {
  if ! reinstall_is_ipv4 0.0.0.0 || ! reinstall_is_ipv4 255.255.255.255; then fail 'valid edge addresses rejected'; fi
  if reinstall_is_ipv4 1.2.3 || reinstall_is_ipv4 1.2.3.4.5 || reinstall_is_ipv4 fe80::1 || reinstall_is_ipv4 1.2.3.1000; then fail 'invalid address accepted'; fi
}
expect_ok 'IPv4 address validator edges' t_v4_ok_edges

# Leftovers: custom.cfg.404tmp.* is the sixth signal; the backup is tested with -f everywhere.
t_leftover_tmp_and_bak() {
  use_paths "$work/leftover6"
  printf 'saved_entry=0\n' >"$FAKE_GRUBENV"
  printf 'partial\n' >"$REINSTALL_CUSTOM_CFG.404tmp.AbC123"
  reinstall_detect_leftover || fail 'custom.cfg.404tmp.* not detected'
  [[ "$(reinstall_join "${REINSTALL_LEFTOVERS[@]}")" == "$REINSTALL_CUSTOM_CFG.404tmp.AbC123" ]] || fail "tmp signal text: ${REINSTALL_LEFTOVERS[*]}"
  reinstall_cleanup
  [[ ! -e "$REINSTALL_CUSTOM_CFG.404tmp.AbC123" ]] || fail 'cleanup kept the custom.cfg temp file'
  if reinstall_detect_leftover; then fail 'leftover after removing temp file'; fi
  # A non-regular .404bak is neither detected nor touched (same -f test in both places).
  mkdir -p "$REINSTALL_CUSTOM_BAK"
  if reinstall_detect_leftover; then fail "directory .404bak counted as leftover: ${REINSTALL_LEFTOVERS[*]}"; fi
  reinstall_cleanup
  [[ -d "$REINSTALL_CUSTOM_BAK" && ! -e "$REINSTALL_CUSTOM_CFG" ]] || fail 'cleanup acted on a directory .404bak'
}
expect_ok 'leftover: custom.cfg temp files and consistent backup test' t_leftover_tmp_and_bak

# kexec: unquoted, double-quoted and single-quoted true are all rejected.
t_kexec() {
  REINSTALL_KEXEC_DEFAULT=$1
  reinstall_check_kexec
}
for variant in 'LOAD_KEXEC=true' 'LOAD_KEXEC="true"' "LOAD_KEXEC='true'" '  LOAD_KEXEC = true'; do
  printf '# Defaults for kexec\n%s\n' "$variant" >"$work/kexec-on"
  expect_die "kexec enabled: $variant" '启用了 LOAD_KEXEC=true，重启会绕过 GRUB' t_kexec "$work/kexec-on"
done
for variant in 'LOAD_KEXEC=false' '# LOAD_KEXEC=true' "LOAD_KEXEC='false'"; do
  printf '%s\n' "$variant" >"$work/kexec-off"
  expect_ok "kexec disabled: $variant" t_kexec "$work/kexec-off"
done
expect_ok 'kexec config missing' t_kexec "$work/no-such-kexec"

# authorized_keys: options kept verbatim. Without a usable key the check only records why, so the
# key can be pasted after all read-only checks.
t_keys() {
  REINSTALL_AUTHORIZED_KEYS=$1
  reinstall_check_keys
  printf 'keys=%s opts=%s\n' "${#REINSTALL_KEYS[@]}" "$(reinstall_join "${REINSTALL_KEY_HAS_OPTS[@]}")"
  printf 'line=%s\n' "${REINSTALL_KEYS[@]}"
  printf 'paste=%s reason=%s\n' "$REINSTALL_KEYS_NEED_PASTE" "$REINSTALL_KEYS_PASTE_REASON"
}
unusable_reason='已有公钥都不能用于新系统登录（带 command=/restrict 限制，或是 Debian 13 不再支持的 ssh-dss）'
pub_fp=$(ssh-keygen -l -f "$work/fixture-key.pub")
# OpenSSH 10 (Debian 13) can neither generate nor read DSA keys, so ssh-dss lines get a stand-in
# fingerprint; every other key still goes to the real ssh-keygen.
dss_line='ssh-dss AAAAB3NzaC1kc3M= old-dsa'
dss_fakes() {
  ssh-keygen() {
    local input
    input=$(cat)
    if [[ "$input" == *'ssh-dss '* ]]; then printf '1024 SHA256:dssFixture old-dsa (DSA)\n'; return 0; fi
    printf '%s\n' "$input" | command ssh-keygen "$@"
  }
}
printf 'from="198.51.100.0/24,restrict.example",no-agent-forwarding %s\r\n' "$pub" >"$work/ak-from"
expect_ok 'key with from= is usable' t_keys "$work/ak-from"
grep -Fxq "line=from=\"198.51.100.0/24,restrict.example\",no-agent-forwarding $pub" "$work/last.out" || fail 'options line not kept verbatim (or CR kept)'
grep -Fq 'keys=1 opts=true' "$work/last.out" || fail 'from= key bookkeeping'
grep -Fxq 'paste=false reason=' "$work/last.out" || fail 'usable key still asks for a paste'
printf 'no-port-forwarding,command="echo '\''Please login as the user \\"debian\\"'\'';sleep 10;exit 142" %s\n' "$pub" >"$work/ak-command"
expect_ok 'only command= keys: paste needed, lines kept' t_keys "$work/ak-command"
grep -Fxq "paste=true reason=$unusable_reason" "$work/last.out" || fail 'command= reason'
grep -Fq 'keys=1 opts=true' "$work/last.out" || fail 'command= line dropped'
printf 'RESTRICT,pty %s\n' "$pub" >"$work/ak-restrict"
expect_ok 'only restrict keys: paste needed' t_keys "$work/ak-restrict"
grep -Fxq "paste=true reason=$unusable_reason" "$work/last.out" || fail 'restrict reason'
printf '# only a comment\n\nnot-a-key\n' >"$work/ak-none"
expect_ok 'no valid key: paste needed' t_keys "$work/ak-none"
grep -Fxq "paste=true reason=$work/ak-none 中没有有效的 SSH 公钥" "$work/last.out" || fail 'no valid key reason'
expect_ok 'missing authorized_keys: paste needed' t_keys "$work/no-such-ak"
grep -Fxq "paste=true reason=不存在可读的 $work/no-such-ak" "$work/last.out" || fail 'missing file reason'
{
  printf 'command="/bin/false" %s\n' "$pub"
  printf '# comment\r\n\r\nnot-a-key\r\n%s\r\n' "$pub"
} >"$work/ak-mixed"
expect_ok 'command= key plus a plain CRLF key' t_keys "$work/ak-mixed"
grep -Fq 'keys=2 opts=false true' "$work/last.out" || fail 'mixed key bookkeeping (loginable line first)'
grep -Fq '丢弃空行/注释/无效行 3 行' "$work/last.out" || fail 'discarded line count'
grep -Fxq "line=$pub" "$work/last.out" || fail 'CRLF plain key not stripped of CR'
grep -Fxq 'paste=false reason=' "$work/last.out" || fail 'mixed file with a usable key asks for a paste'
# Loginable lines first, the rest after, each group in file order; the written file follows that.
[[ "$(grep '^line=' "$work/last.out" | head -n 1)" == "line=$pub" ]] || fail 'clean line not moved before the command= line'
t_keys_written() {
  REINSTALL_AUTHORIZED_KEYS=$1
  reinstall_check_keys
  reinstall_write_authorized_keys "$2"
}
expect_ok 'written authorized_keys: loginable line first' t_keys_written "$work/ak-mixed" "$work/ak-mixed.written"
[[ "$(cat "$work/ak-mixed.written")" == "$pub"$'\n'"command=\"/bin/false\" $pub" ]] || fail "written order: $(cat "$work/ak-mixed.written")"
{
  printf 'restrict %s\n' "$second_pub"
  printf '%s\n' "$dss_line"
  printf 'from="198.51.100.0/24" %s\n' "$pub"
  printf 'command="/bin/true" %s\n' "$pub"
  printf '%s\n' "$second_pub"
} >"$work/ak-order"
t_keys_order() { dss_fakes; t_keys "$work/ak-order"; }
expect_ok 'stable order: loginable lines, then the rest' t_keys_order
[[ "$(grep '^line=' "$work/last.out")" == "line=from=\"198.51.100.0/24\" $pub"$'\n'"line=$second_pub"$'\n'"line=restrict $second_pub"$'\n'"line=$dss_line"$'\n'"line=command=\"/bin/true\" $pub" ]] ||
  fail "stable order: $(grep '^line=' "$work/last.out")"
grep -Fxq 'keys=5 opts=true false true false true' "$work/last.out" || fail 'option flags not moved with their lines'
grep -Fq '可交互登录 2 把' "$work/last.out" || fail 'usable count'
# Only ssh-dss: kept, but not loginable on Debian 13, so a paste is needed.
printf '%s\n' "$dss_line" >"$work/ak-dss"
t_keys_dss() { dss_fakes; t_keys "$work/ak-dss"; }
expect_ok 'only ssh-dss: paste needed' t_keys_dss
grep -Fxq "paste=true reason=$unusable_reason" "$work/last.out" || fail 'ssh-dss reason'
grep -Fxq "line=$dss_line" "$work/last.out" || fail 'ssh-dss line not kept'
t_keys_dss_summary() { dss_fakes; use_host; UI_WIDTH=200; REINSTALL_AUTHORIZED_KEYS="$work/ak-order"; reinstall_check_keys; reinstall_print_summary; }
expect_ok 'summary marks ssh-dss' t_keys_dss_summary
grep -Fq '1024 SHA256:dssFixture old-dsa (DSA)（ssh-dss，新系统不支持）' "$work/last.out" || fail 'ssh-dss summary marker'
[[ "$(grep -c '（ssh-dss，新系统不支持）' "$work/last.out")" == 1 ]] || fail 'ssh-dss marker on other keys'
t_keys_summary() {
  use_host
  REINSTALL_AUTHORIZED_KEYS=$1
  reinstall_check_keys
  reinstall_print_summary
}
expect_ok 'summary marks keys with options' t_keys_summary "$work/ak-mixed"
[[ "$(grep -c '（带限制选项）' "$work/last.out")" == 1 ]] || fail 'option marker count in summary'
if grep -Fq '（当场粘贴）' "$work/last.out"; then fail 'file keys marked as pasted'; fi
grep -Fq '重装后 SSH 只允许公钥登录（密码登录已关闭）' "$work/last.out" || fail 'summary lacks the key-only line'
grep -Fq 'SSH 端口 22；公钥 2 把（丢弃 3 行）' "$work/last.out" || fail 'summary lacks the port/key count line'
if grep -Fq '重装后 SSH：端口 22' "$work/last.out"; then fail 'old summary SSH line still shown'; fi
awk '/只允许公钥登录/ {a=NR} /SSH 端口 22；/ {b=NR} /SHA256:/ && !c {c=NR} END {exit !(a && b && c && a < b && b < c)}' "$work/last.out" ||
  fail 'summary SSH lines out of order'

# The paste runs after every read-only check and only when needed.
(source "$work/installer"; trap - EXIT ERR HUP INT TERM; declare -f reinstall_preflight) | awk '/reinstall_check_identity/ {i=NR} /reinstall_collect_pasted_key/ {p=NR} /重装环境检查全部通过/ {d=NR} END {exit !(i && p && d && i < p && p < d)}' ||
  fail 'paste is not between the identity check and the final preflight log'

# ---- paste flow -----------------------------------------------------------------
# A scripted terminal: REPLIES answer read_tty in order; reply numbers (1-based) listed in
# PASTE_MULTI behave as if more pasted lines followed and were discarded.
paste_fakes() {
  REPLY_I=0
  : >"$work/paste.prompts"
  read_tty() {
    (( REPLY_I < ${#REPLIES[@]} )) || fail "unexpected prompt: $1"
    printf '%s\n' "$1" >>"$work/paste.prompts"
    printf -v "$2" '%s' "${REPLIES[REPLY_I]}"
    REPLY_I=$((REPLY_I + 1))
  }
  reinstall_drain_tty() { [[ " ${PASTE_MULTI:-} " == *" $REPLY_I "* ]]; }
}
t_paste() {
  use_host
  UI_WIDTH=200 # Keep each summary line whole for grep.
  REINSTALL_AUTHORIZED_KEYS=$1
  shift
  REPLIES=("$@")
  paste_fakes
  reinstall_check_keys
  [[ "$REINSTALL_KEYS_NEED_PASTE" == true ]] || fail 'fixture does not need a paste'
  reinstall_collect_pasted_key
  (( REPLY_I == ${#REPLIES[@]} )) || fail "only $REPLY_I of ${#REPLIES[@]} replies used"
  printf 'keys=%s pasted=%s opts=%s\n' "${#REINSTALL_KEYS[@]}" "$REINSTALL_KEY_PASTED_INDEX" "$(reinstall_join "${REINSTALL_KEY_HAS_OPTS[@]}")"
  printf 'line=%s\n' "${REINSTALL_KEYS[@]}"
  printf 'fp=%s\n' "${REINSTALL_KEY_FPS[@]}"
  reinstall_print_summary
  reinstall_write_authorized_keys "$work/paste.written"
}
# The real drain on a plain file standing in for the terminal (the real-terminal cases are in the
# PTY section): text is reported, blank lines only are not.
t_drain() {
  printf 'line 2\nline 3\n' >"$work/tty"
  reinstall_drain_tty || fail 'buffered lines not reported'
  printf 'partial' >"$work/tty"
  reinstall_drain_tty || fail 'buffered partial line not reported'
  printf '\n\r\n \t\n' >"$work/tty"
  if reinstall_drain_tty; then fail 'blank lines reported as more pasted lines'; fi
  : >"$work/tty"
  if reinstall_drain_tty; then fail 'nothing buffered but reported'; fi
}
expect_ok 'drain buffered terminal input' t_drain
: >"$work/tty"

paste_prompt='粘贴 SSH 公钥（直接回车放弃）: '
use_prompt='是否使用这把公钥？ [y/n] '
prompt_count() { grep -Fxc -- "$1" "$work/paste.prompts" || true; }

expect_ok 'paste: missing file, valid key, y' t_paste "$work/no-such-ak" "$paste_pub" y
grep -Fq "本机 root 没有可用的 SSH 公钥（不存在可读的 $work/no-such-ak）。" "$work/last.out" || fail 'paste intro reason'
grep -Fq '重装后新系统只允许公钥登录，请粘贴一把公钥（一整行，例如 ssh-ed25519 AAAA... 备注）。' "$work/last.out" || fail 'paste intro line 2'
grep -Fq '直接回车放弃，不会做任何改动。' "$work/last.out" || fail 'paste intro line 3'
grep -Fxq "$paste_fp" "$work/last.out" || fail 'ssh-keygen -l output of the pasted key not shown'
grep -Fq '请在你的电脑上运行 ssh-keygen -lf ~/.ssh/id_ed25519.pub（换成你的公钥文件），确认指纹一致' "$work/last.out" || fail 'fingerprint hint'
grep -Fxq 'keys=1 pasted=0 opts=false' "$work/last.out" || fail 'pasted key bookkeeping'
grep -Fxq "line=$paste_pub" "$work/last.out" || fail 'pasted key line'
grep -Fxq "fp=$paste_fp" "$work/last.out" || fail 'pasted key fingerprint entry differs from the file format'
grep -Fq "${paste_fp}（当场粘贴）" "$work/last.out" || fail 'summary lacks the pasted marker'
[[ "$(prompt_count "$paste_prompt")" == 1 && "$(prompt_count "$use_prompt")" == 1 ]] || fail 'paste prompts'

expect_ok 'paste: no valid key, invalid then valid (blanks, CRLF)' t_paste "$work/ak-none" 'ssh-ed25519 not-base64!' 'hello world' "  $paste_pub  "$'\r' y
[[ "$(grep -Fc '公钥无效，请重新粘贴（直接回车放弃）' "$work/last.out")" == 2 ]] || fail 'invalid key warnings'
grep -Fxq "line=$paste_pub" "$work/last.out" || fail 'blanks or CR kept on the pasted key'
[[ "$(prompt_count "$paste_prompt")" == 3 ]] || fail 'invalid key not re-asked'

# The usual cloud image: the user's own key, locked by command=/restrict. Pasting the same key
# puts the clean copy first, so sshd (first matching line wins) lets the user in.
expect_ok 'paste: same key as a command= file line goes first' t_paste "$work/ak-command" "$pub" y
grep -Fxq 'keys=2 pasted=0 opts=false true' "$work/last.out" || fail 'pasted key not inserted at index 0'
[[ "$(head -n 1 "$work/paste.written")" == "$pub" ]] || fail "written authorized_keys does not start with the pasted key: $(head -n 1 "$work/paste.written")"
[[ "$(sed -n 2p "$work/paste.written")" == no-port-forwarding,command=* ]] || fail 'restricted file line not kept after the pasted key'
grep -Fq "${pub_fp}（当场粘贴）" "$work/last.out" || fail 'pasted marker'
awk -v fp="$pub_fp（当场粘贴）" -v r="$pub_fp（带限制选项）" 'index($0, fp) {p=NR} index($0, r) {q=NR} END {exit !(p && q && p < q)}' "$work/last.out" ||
  fail 'summary does not list the pasted key first'
expect_ok 'paste: same key as a restrict file line goes first' t_paste "$work/ak-restrict" "$pub" y
[[ "$(cat "$work/paste.written")" == "$pub"$'\n'"RESTRICT,pty $pub" ]] || fail "restrict + paste written order: $(cat "$work/paste.written")"

# Only a bare public key line: options, ssh-dss and anything else are refused.
expect_ok 'paste: options and ssh-dss refused' t_paste "$work/ak-command" "restrict $paste_pub" "command=\"/bin/true\" $paste_pub" "from=\"198.51.100.0/24\" $paste_pub" "cert-authority $paste_pub" "$dss_line" "$paste_pub" y
[[ "$(grep -Fc '请只粘贴 .pub 文件里的公钥，不要带 from=、command= 等选项' "$work/last.out")" == 4 ]] || fail 'option lines not refused'
[[ "$(grep -Fc 'ssh-dss（DSA）公钥在 Debian 13 上已不能使用，请换一把 ed25519 或 RSA 公钥' "$work/last.out")" == 1 ]] || fail 'ssh-dss paste not refused'
if grep -Fq '公钥无效' "$work/last.out"; then fail 'option or ssh-dss line reported as invalid'; fi
grep -Fxq 'keys=2 pasted=0 opts=false true' "$work/last.out" || fail 'bare key bookkeeping'
[[ "$(grep '^line=' "$work/last.out" | head -n 1)" == "line=$paste_pub" ]] || fail 'bare pasted key not first'
[[ "$(grep -c '（当场粘贴）' "$work/last.out")" == 1 ]] || fail 'pasted marker count'
[[ "$(prompt_count "$use_prompt")" == 1 ]] || fail 'refused lines reached the confirmation'

expect_ok 'paste: private key refused' t_paste "$work/ak-restrict" '-----BEGIN OPENSSH PRIVATE KEY-----' "$paste_pub" y
grep -Fq '这是私钥，不是公钥！请粘贴 .pub 文件的内容；这把私钥已经显示在屏幕上，建议更换' "$work/last.out" || fail 'private key warning'

PASTE_MULTI=1 expect_ok 'paste: multi-line private key refused' t_paste "$work/ak-none" '-----BEGIN OPENSSH PRIVATE KEY-----' "$paste_pub" y
grep -Fq '这是私钥，不是公钥！' "$work/last.out" || fail 'multi-line private key warning'
grep -Fq '检测到多行内容，请只粘贴一行公钥' "$work/last.out" || fail 'multi-line warning for a private key'

PASTE_MULTI=1 expect_ok 'paste: a valid key followed by more lines is refused' t_paste "$work/ak-none" "$second_pub" "$paste_pub" y
grep -Fq '检测到多行内容，请只粘贴一行公钥' "$work/last.out" || fail 'multi-line warning'
grep -Fxq "line=$paste_pub" "$work/last.out" || fail 'key after a multi-line paste'
if grep -Fq "line=$second_pub" "$work/last.out"; then fail 'multi-line paste accepted'; fi
[[ "$(prompt_count "$use_prompt")" == 1 ]] || fail 'multi-line paste reached the confirmation'

expect_ok 'paste: answer n, paste again' t_paste "$work/ak-none" "$second_pub" '' n "$paste_pub" y
grep -Fxq "line=$paste_pub" "$work/last.out" || fail 'second paste after n'
if grep -Fq "line=$second_pub" "$work/last.out"; then fail 'key kept after n'; fi
# Confirmations: Enter (asked again), n, then y for the second paste.
[[ "$(prompt_count "$paste_prompt")" == 2 && "$(prompt_count "$use_prompt")" == 3 ]] || fail 'n did not return to the paste prompt'

# An empty paste exits 0 without writing anything; the current authorized_keys is untouched.
t_paste_empty() {
  use_paths "$work/paste-empty"
  t_paste "$work/ak-command" '   '
  fail 'run continued after an empty paste'
}
expect_ok 'paste: empty answer exits 0' t_paste_empty
grep -Fq '已放弃，未做任何修改' "$work/last.out" || fail 'empty paste message'
[[ "$(cd "$work/paste-empty" && find . -mindepth 1 | sort | tr '\n' ' ')" == './boot ./boot/grub ./sys ' ]] || fail 'empty paste wrote files'
[[ "$(cat "$work/ak-command")" == "no-port-forwarding,command=\"echo 'Please login as the user \\\"debian\\\"';sleep 10;exit 142\" $pub" ]] || fail 'authorized_keys changed'

t_paste_no_tty() {
  REPLIES=()
  paste_fakes
  rm -f -- "$work/tty"
  REINSTALL_AUTHORIZED_KEYS="$work/no-such-ak"
  reinstall_check_keys
  reinstall_collect_pasted_key
}
expect_die 'paste: no terminal' "无法重装：不存在可读的 $work/no-such-ak，且没有交互终端可粘贴公钥" t_paste_no_tty
: >"$work/tty"

# ---- real terminal: what the drain leaves for the next question ------------------
# Input is written into a real PTY (script). Pieces arriving together are buffered like a paste;
# "@N" sleeps N seconds, so whatever follows a long sleep is typed after the drain is over.
command -v script >/dev/null 2>&1 || fail 'script (util-linux) is required for the PTY tests'
cat >"$work/pty-drain.sh" <<PROBE
source "$repo/debian-init.sh"
trap - EXIT ERR HUP INT TERM
before=\$(stty -g)
read_tty 'P: ' first
if reinstall_drain_tty; then echo DRAIN=multi; else echo DRAIN=clean; fi
after=\$(stty -g)
if [[ "\$before" == "\$after" ]]; then echo STTY=same; else echo STTY=changed; fi
read_tty 'NEXT: ' next
printf 'FIRST=[%s]\nNEXT=[%s]\n' "\$first" "\$next"
PROBE
cat >"$work/pty-paste.sh" <<PROBE
source "$repo/debian-init.sh"
trap - EXIT ERR HUP INT TERM
REINSTALL_KEYS_PASTE_REASON=fixture REINSTALL_KEYS=() REINSTALL_KEY_FPS=() REINSTALL_KEY_HAS_OPTS=()
before=\$(stty -g)
reinstall_collect_pasted_key
after=\$(stty -g)
if [[ "\$before" == "\$after" ]]; then echo STTY=same; else echo STTY=changed; fi
printf 'KEY0=[%s] COUNT=%s\n' "\${REINSTALL_KEYS[0]}" "\${#REINSTALL_KEYS[@]}"
PROBE
pty_run() {
  local probe=$1 out=$2 piece
  shift 2
  {
    for piece in "$@"; do
      if [[ "$piece" == @* ]]; then sleep "${piece#@}"; else printf '%b' "$piece"; fi
    done
    sleep 1
  } | timeout 60 env -u NO_COLOR TERM=xterm-256color script -qec "bash \"$probe\"" /dev/null >"$out" 2>&1 ||
    fail "PTY probe did not finish: $*"
  tr -d '\r' <"$out" | sed $'s/\033\\[[0-9;]*[A-Za-z]//g' >"$out.txt"
}
pty_case() {
  local name=$1 expect=$2 first=$3
  shift 3
  pty_run "$work/pty-drain.sh" "$work/pty-$name.out" "$@"
  grep -Fq "DRAIN=$expect" "$work/pty-$name.out.txt" || { cat "$work/pty-$name.out.txt" >&2; fail "PTY $name: drain not $expect"; }
  grep -Fq 'STTY=same' "$work/pty-$name.out.txt" || fail "PTY $name: terminal mode not restored"
  grep -Fq "FIRST=[$first]" "$work/pty-$name.out.txt" || fail "PTY $name: first line"
  grep -Fq 'NEXT=[y]' "$work/pty-$name.out.txt" || { cat "$work/pty-$name.out.txt" >&2; fail "PTY $name: next answer polluted"; }
}
pty_case lf clean 'ssh-ed25519 AAAA key1' 'ssh-ed25519 AAAA key1\n' @3 'y\n'
pty_case crlf clean 'ssh-ed25519 AAAA key1' 'ssh-ed25519 AAAA key1\r\n' @3 'y\n'
pty_case extra-enter clean 'ssh-ed25519 AAAA key1' 'ssh-ed25519 AAAA key1\n' @0.1 '\n' @3 'y\n'
pty_case no-final-newline multi 'ssh-ed25519 AAAA key1' 'ssh-ed25519 AAAA key1\nssh-ed25519 BBBB key2' @3 'y\n'
# Three-line private key through the real paste flow: both warnings, then a clean next prompt.
pty_run "$work/pty-paste.sh" "$work/pty-private.out" \
  '-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ\n-----END OPENSSH PRIVATE KEY-----\n' @3 "$paste_pub\\n" @3 'y\n'
grep -Fq '这是私钥，不是公钥！' "$work/pty-private.out.txt" || { cat "$work/pty-private.out.txt" >&2; fail 'PTY private key warning'; }
grep -Fq '检测到多行内容，请只粘贴一行公钥' "$work/pty-private.out.txt" || fail 'PTY multi-line warning'
if grep -Fq '公钥无效' "$work/pty-private.out.txt"; then fail 'PTY: private key lines leaked into the next paste prompt'; fi
grep -Fq "KEY0=[$paste_pub] COUNT=1" "$work/pty-private.out.txt" || { cat "$work/pty-private.out.txt" >&2; fail 'PTY: key pasted after the private key not taken as is'; }
grep -Fq 'STTY=same' "$work/pty-private.out.txt" || fail 'PTY paste: terminal mode not restored'

# ---- test switch for the key file -----------------------------------------------
t_keys_file_alone() { unset VPS_INIT_REINSTALL_TEST; VPS_INIT_REINSTALL_KEYS_FILE="$work/ak-none"; reinstall_parse_test_mode; }
expect_die 'keys file without a test mode' 'VPS_INIT_REINSTALL_KEYS_FILE 只能与 VPS_INIT_REINSTALL_TEST 一起使用。' t_keys_file_alone
t_keys_file_dry() {
  use_host
  UI_WIDTH=200
  VPS_INIT_REINSTALL_TEST=dry-run VPS_INIT_REINSTALL_KEYS_FILE="$work/ak-mixed"
  reinstall_parse_test_mode
  [[ "$REINSTALL_AUTHORIZED_KEYS" == "$work/ak-mixed" ]] || fail "keys file not used: $REINSTALL_AUTHORIZED_KEYS"
  reinstall_check_keys
  (( ${#REINSTALL_KEYS[@]} == 2 )) || fail 'keys not read from the override file'
  reinstall_print_summary
}
expect_ok 'keys file with dry-run' t_keys_file_dry
awk '/测试模式：dry-run/ {m=NR} /测试：公钥文件改读/ {k=NR} END {exit !(m && k && k == m + 1)}' "$work/last.out" || fail 'keys file summary line missing or misplaced'
grep -Fq "测试：公钥文件改读 $work/ak-mixed" "$work/last.out" || fail 'keys file summary path'
t_keys_file_unset() {
  local default=$REINSTALL_AUTHORIZED_KEYS
  unset VPS_INIT_REINSTALL_TEST VPS_INIT_REINSTALL_KEYS_FILE
  reinstall_parse_test_mode
  [[ "$REINSTALL_AUTHORIZED_KEYS" == "$default" && -z "$REINSTALL_KEYS_FILE_OVERRIDE" ]] || fail 'keys path changed without the switch'
  use_host
  reinstall_print_summary
}
expect_ok 'no keys file switch' t_keys_file_unset
if grep -Fq '测试：公钥文件改读' "$work/last.out"; then fail 'keys file line shown without the switch'; fi

# ---- hostname confirmation and the ready box ------------------------------------
t_hostname_empty_then_ok() {
  use_host
  REPLIES=('' '  ' 'vps-test')
  paste_fakes
  reinstall_generate_password() { :; }
  reinstall_confirm
  (( REPLY_I == 3 )) || fail "hostname asked $REPLY_I times"
}
expect_ok 'hostname: empty asks again, then passes' t_hostname_empty_then_ok
grep -Fq '主机名确认通过' "$work/last.out" || fail 'hostname confirmation after re-ask'
grep -Fxq '请输入主机名 vps-test 以确认，或 Ctrl+C 退出（输错将取消）' "$work/tty" || fail 'hostname re-ask hint'
: >"$work/tty"
# The hostname prompt is styled as a warning (whole line bold yellow when colored).
t_hostname_style() {
  use_host
  reinstall_generate_password() { :; }
  read_tty() { [[ "${3:-}" == warn ]] || fail 'hostname prompt not styled as a warning'; printf -v "$2" '%s' vps-test; }
  reinstall_confirm
}
expect_ok 'hostname prompt style' t_hostname_style

t_ready() {
  use_host
  UI_WIDTH=200 # Keep each box line whole for grep.
  if [[ "$1" == unset ]]; then unset SSH_CONNECTION; else SSH_CONNECTION=$1; fi
  reinstall_print_ready
}
ready_lines=(
  'ssh -p 22 root@203.0.113.10'
  '请用私钥连接（如 Termius 需在主机设置里绑定私钥）；密码登录已关闭'
  'root 密码：FixturePassword12345'
  'root 密码只在 VNC 控制台有效；商家面板显示的旧密码会失效'
  'ssh-keygen -R 203.0.113.10'
  '下一步：用 README 的一键命令运行 [1] 快速初始化'
  '安装通常需要 2～10 分钟，期间 SSH 连不上属正常现象'
  '超过 30 分钟仍连不上，再用 VNC 查看'
)
old_port_line='若用旧端口 2222 又能连上：说明安装器自检未通过、已自动回到旧系统，磁盘未改动'
same_port_line='若连上后发现仍是旧系统：说明安装器自检未通过、已自动回到旧系统，磁盘未改动'
for ssh_connection in '198.51.100.7 50000 203.0.113.10 2222' '198.51.100.7 50000 203.0.113.10 22' unset '198.51.100.7 50000 203.0.113.10 70000' '198.51.100.7 50000 203.0.113.10 22x' ''; do
  expect_ok "ready box with SSH_CONNECTION=[$ssh_connection]" t_ready "$ssh_connection"
  prev=0
  for line in "${ready_lines[@]}"; do
    n=$(grep -Fn -- "$line" "$work/last.out" | head -n 1 | cut -d: -f1)
    [[ -n "$n" && "$n" -gt "$prev" ]] || fail "ready box line missing or out of order: $line"
    prev=$n
  done
  if [[ "$ssh_connection" == *' 2222' ]]; then expected=$old_port_line; else expected=$same_port_line; fi
  n=$(grep -Fn -- "$expected" "$work/last.out" | head -n 1 | cut -d: -f1)
  [[ -n "$n" && "$n" -gt "$prev" ]] || fail "ready box old-port line for [$ssh_connection]"
  [[ "$(grep -c '若用旧端口\|若连上后发现仍是旧系统' "$work/last.out")" == 1 ]] || fail "ready box shows both old-port lines for [$ssh_connection]"
  [[ "$(grep -c 'root 密码' "$work/last.out")" == 2 ]] || fail 'ready box repeats the root password note'
  if grep -Fq '5～20 分钟' "$work/last.out"; then fail 'old install time still shown'; fi
done

# GRUB checks: each rejection condition.
grub_fixture() {
  use_paths "$work/grub-$1"
  printf '%s\n' 'if [ "${next_entry}" ] ; then' '### BEGIN /etc/grub.d/41_custom ###' >"$REINSTALL_GRUB_CFG"
  grub-reboot() { :; }
  grub-mkrelpath() { :; }
  grub-probe() {
    case "$1" in
      --target=abstraction) printf '%s\n' "${GRUB_ABS:-}" ;;
      --target=fs) printf '%s\n' "${GRUB_FS:-ext2}" ;;
    esac
  }
}
t_grub_ok() { grub_fixture ok; GRUB_FS=xfs; reinstall_check_grub; [[ "$REINSTALL_GRUB_FS" == xfs ]] || fail 'xfs not accepted'; }
expect_ok 'grub: accepted layout' t_grub_ok
t_grub_no_cfg() { grub_fixture nocfg; rm -f "$REINSTALL_GRUB_CFG"; reinstall_check_grub; }
expect_die 'grub: missing grub.cfg' '无法重装：缺少' t_grub_no_cfg
t_grub_no_next() { grub_fixture nonext; printf '### BEGIN /etc/grub.d/41_custom ###\n' >"$REINSTALL_GRUB_CFG"; reinstall_check_grub; }
expect_die 'grub: no next_entry logic' '中没有 next_entry 逻辑' t_grub_no_next
t_grub_no_41() { grub_fixture no41; printf 'if [ "${next_entry}" ] ; then\n' >"$REINSTALL_GRUB_CFG"; reinstall_check_grub; }
expect_die 'grub: no 41_custom' '中没有 41_custom' t_grub_no_41
t_grub_abstraction() { grub_fixture lvm; GRUB_ABS=lvm; reinstall_check_grub; }
expect_die 'grub: abstraction layer' '/boot/grub 使用了不支持的抽象层（lvm）' t_grub_abstraction
t_grub_fs() { grub_fixture btrfs; GRUB_FS=btrfs; reinstall_check_grub; }
expect_die 'grub: unsupported filesystem' '/boot/grub 文件系统不支持（当前 btrfs' t_grub_fs
t_grub_tool() {
  grub_fixture tool
  unset -f grub-mkrelpath
  mkdir -p "$work/empty-bin"
  # shellcheck disable=SC2123 # Hide any real GRUB tools on the runner.
  PATH="$work/empty-bin"
  reinstall_check_grub
}
expect_die 'grub: missing grub-mkrelpath' '无法重装：缺少 GRUB 工具：grub-mkrelpath' t_grub_tool

# Tampered downloads and an empty verified Release.
tamper_curl() {
  TAMPER_SUFFIX=$1
  curl() {
    local IFS=' ' url='' out=''
    while (( $# )); do case "$1" in -o) out=$2; shift 2 ;; https://*) url=$1; shift ;; *) shift ;; esac; done
    if [[ "$url" == *"$TAMPER_SUFFIX" ]]; then printf 'tampered\n' >"$out"; return 0; fi
    cp -- "$fix/mirror/${url#https://deb.debian.org/debian/}" "$out"
  }
}
t_tampered() {
  use_paths "$work/tamper-$2"
  use_host
  install_download_fakes
  tamper_curl "$1"
  reinstall_confirm() { :; }
  run_reinstall
}
expect_die 'tampered SHA256SUMS' 'installer SHA256SUMS SHA256 校验失败' t_tampered /images/SHA256SUMS sums
[[ ! -e "$work/tamper-sums/boot/404-reinstall.tmp" ]] || fail 'SHA256SUMS failure did not clean up'
expect_die 'tampered initrd.gz' 'netboot initrd.gz SHA256 校验失败' t_tampered /initrd.gz initrd
[[ ! -e "$work/tamper-initrd/boot/404-reinstall.tmp" && ! -e "$work/tamper-initrd/boot/404-reinstall" ]] || fail 'initrd failure did not clean up'
t_empty_release() {
  use_paths "$work/empty-release"
  use_host
  install_download_fakes
  : >"$work/empty-release-file"
  FAKE_RELEASE="$work/empty-release-file"
  reinstall_confirm() { :; }
  run_reinstall
}
expect_die 'empty Release.verified' 'gpgv 没有输出已验证的 Release 正文' t_empty_release
[[ ! -e "$work/empty-release/boot/404-reinstall.tmp" ]] || fail 'empty Release failure did not clean up'

# Hostname mismatch cancels with exit 0 before anything is installed or downloaded.
t_hostname_mismatch() {
  use_paths "$work/mismatch"
  use_host
  install_download_fakes
  REINSTALL_NEED_GPGV=true
  reinstall_generate_password() { :; }
  read_tty() { printf -v "$2" '%s' 'not-this-host'; }
  apt_get() { fail 'apt_get ran after a hostname mismatch'; }
  run_reinstall
  fail 'run continued after a hostname mismatch'
}
rm -f "$fix/curl.log"
expect_ok 'hostname mismatch cancels with exit 0' t_hostname_mismatch
grep -Fq '已取消，未做任何修改' "$work/last.out" || fail 'cancel message'
[[ ! -e "$fix/curl.log" ]] || fail 'download started after a hostname mismatch'
[[ "$(cd "$work/mismatch/boot" && find . -mindepth 1 | sort | tr '\n' ' ')" == './grub ' ]] || fail "mismatch changed /boot: $(cd "$work/mismatch/boot" && find . -mindepth 1)"

# GRUB mocks for the paths that write the one-shot entry.
grub_write_mocks() {
  grub-probe() { [[ "$1" == --target=fs_uuid ]] && echo 1111-2222; }
  grub-mkrelpath() { echo /404-reinstall; }
  grub-reboot() { printf 'next_entry=%s\n' "$1" >>"$FAKE_GRUBENV"; }
}

t_no_reboot() {
  use_paths "$work/noreboot"
  use_host
  install_download_fakes
  grub_write_mocks
  printf '# user entry\n' >"$REINSTALL_CUSTOM_CFG"
  printf 'saved_entry=0\n' >"$FAKE_GRUBENV"
  REINSTALL_TEST_MODE='no-reboot'
  reinstall_confirm() { :; }
  reboot() { fail 'no-reboot mode rebooted'; }
  sleep() { fail 'no-reboot mode counted down'; }
  run_reinstall
  [[ "$REINSTALL_ARMED" == false ]] || fail 'no-reboot stayed armed'
  [[ -s "$REINSTALL_BOOT_DIR/linux" && -s "$REINSTALL_BOOT_DIR/initrd.gz" ]] || fail 'no-reboot removed the installer files'
  grep -Fq '# user entry' "$REINSTALL_CUSTOM_CFG" || fail 'user custom.cfg content lost'
  grep -Fq 'search --no-floppy --fs-uuid --set=root 1111-2222' "$REINSTALL_CUSTOM_CFG" || fail 'menuentry search line'
  grep -Fq 'linux /404-reinstall/linux auto=true priority=critical' "$REINSTALL_CUSTOM_CFG" || fail 'menuentry linux line'
  [[ "$(cat "$REINSTALL_CUSTOM_BAK")" == '# user entry' ]] || fail 'custom.cfg backup'
  grep -Fxq 'next_entry=reinstall-debian13' "$FAKE_GRUBENV" || fail 'next_entry not set'
  reinstall_detect_leftover || fail 'no-reboot preparation not detectable as leftover'
}
expect_ok 'no-reboot keeps the prepared boot entry' t_no_reboot
for line in '准备就绪' 'ssh -p 22 root@203.0.113.10' 'ssh-keygen -R 203.0.113.10' 'no-reboot 测试模式'; do
  grep -Fq -- "$line" "$work/last.out" || fail "no-reboot output lacks [$line]"
done

t_reboot_fails() {
  use_paths "$work/reboot-fail"
  use_host
  install_download_fakes
  grub_write_mocks
  printf 'saved_entry=0\n' >"$FAKE_GRUBENV"
  reinstall_confirm() { :; }
  sleep() { :; }
  reboot() { return 1; }
  run_reinstall
}
expect_die 'reboot failure clears the boot entry' 'reboot 执行失败，已清除启动项，系统未改变；可重新运行 [9]' t_reboot_fails
[[ ! -e "$work/reboot-fail/boot/404-reinstall" && ! -e "$work/reboot-fail/boot/grub/custom.cfg" && ! -e "$work/reboot-fail/boot/grub/custom.cfg.404bak" ]] ||
  fail 'reboot failure left boot files'
[[ "$(cat "$work/reboot-fail/boot/grub/grubenv")" == 'saved_entry=0' ]] || fail 'reboot failure left next_entry'
grep -Fq '10...' "$work/last.out" || fail 'countdown not shown before reboot'

printf 'reinstall tests passed\n'
