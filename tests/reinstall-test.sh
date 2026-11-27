#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031,SC2317,SC2329,SC2034,SC2016,SC1003 # Subshell isolation, mocks and literal fixtures are intentional.
set -Eeuo pipefail

# Offline tests for menu option 9 (reinstall to official Debian 13). Nothing here touches the
# host's /boot, GRUB or network: every path is redirected into a temporary tree and every
# external command the flow needs is replaced by a function.

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

declare -A FAKE_ADDR4=() FAKE_ADDR6=()
FAKE_V4_ROUTE='' FAKE_V6_ROUTE='' FAKE_V6_GET=''
FAKE_GRUBENV="$work/grubenv"

load() {
  # shellcheck disable=SC1091
  source "$repo/debian-init.sh"
  trap - EXIT ERR HUP INT TERM
}

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
  REINSTALL_HOST='vps-test' REINSTALL_DISK='vda' REINSTALL_DISK_SECTORS=83886080 REINSTALL_DISK_SIZE='40G'
  REINSTALL_GRUB_FS='ext2'
  REINSTALL_V4_MODE='static' REINSTALL_V4_IFACE='eth0' REINSTALL_V4_ADDR='203.0.113.10' REINSTALL_V4_PREFIX='32'
  REINSTALL_V4_NETMASK='255.255.255.255' REINSTALL_V4_GW='198.51.100.1' REINSTALL_V4_MAC='02:00:00:00:00:01'
  REINSTALL_V6_MODE='static' REINSTALL_V6_IFACE='eth1' REINSTALL_V6_ADDR='2001:db8:1::a/64'
  REINSTALL_V6_GW='2001:db8:ff::1' REINSTALL_V6_EXTRA='' REINSTALL_V6_MAC='02:00:00:00:00:02'
  REINSTALL_KEYS=('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureFixtureFixtureFixtureFixtureFixture test')
  REINSTALL_ROOT_HASH='$6$fixture$hash'
  REINSTALL_ROOT_PASS='FixturePassword12345'
}

# expect_ok <name> <fn>: run fn in a fresh subshell with the script loaded; it must succeed.
expect_ok() {
  local name=$1 out rc
  shift
  set +e
  out=$( (load; install_fakes; "$@") 2>&1 )
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
  out=$( (load; install_fakes; "$@") 2>&1 )
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
  # Someone else's next_entry is not ours: neither a leftover nor touched by cleanup.
  printf 'next_entry=1\n' >"$FAKE_GRUBENV"
  if reinstall_detect_leftover; then fail 'foreign next_entry counted as leftover'; fi
  reinstall_cleanup
  [[ "$(cat "$FAKE_GRUBENV")" == 'next_entry=1' ]] || fail 'cleanup touched a foreign next_entry'
}
expect_ok 'leftover detection recognises all four signals' t_leftover_signals

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
  reinstall_confirm() { :; }
  run_reinstall
  [[ ! -e "$REINSTALL_BOOT_DIR" && ! -e "$REINSTALL_BOOT_TMP_DIR" ]] || fail 'dry-run left files in /boot'
  [[ "$(cat "$REINSTALL_CUSTOM_CFG")" == '# user custom' && ! -e "$REINSTALL_CUSTOM_BAK" ]] || fail 'dry-run touched custom.cfg'
  [[ "$(cat "$FAKE_GRUBENV")" == 'saved_entry=0' ]] || fail 'dry-run touched grubenv'
  [[ "$REINSTALL_ARMED" == false ]] || fail 'dry-run stayed armed'
}
rm -f "$fix/curl.log"
expect_ok 'dry-run downloads, prints and cleans up' t_dry_run
for line in 'd-i pkgsel/upgrade select safe-upgrade' "IPV4_ADDR='203.0.113.10'" 'auto eth1' 'dry-run 完成'; do
  grep -Fq -- "$line" "$work/last.out" || fail "dry-run output lacks [$line]"
done
[[ "$(grep -c '' "$fix/curl.log")" == 4 ]] || fail 'dry-run did not make exactly four downloads'
while IFS= read -r line; do
  [[ "$line" == "--proto =https --tlsv1.2 -fsSL --retry 3 --connect-timeout 15 https://deb.debian.org/debian/dists/trixie/"*' -o '* ]] ||
    fail "curl options: $line"
done <"$fix/curl.log"

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
grep -Fxq 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureFixtureFixtureFixtureFixtureFixture test' "$x/404/authorized_keys" || fail 'authorized_keys content'

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

printf 'reinstall tests passed\n'
