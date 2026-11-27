#!/usr/bin/env bash
# shellcheck disable=SC2329,SC2034
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$repo/debian-init.sh"
trap - EXIT ERR HUP INT TERM
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

grub_cfg="$test_dir/grub.cfg"
cat >"$grub_cfg" <<'GRUB'
set default="${next_entry}"
set default="0"
### BEGIN /etc/grub.d/10_linux ###
menuentry 'Debian GNU/Linux' {
  linux /boot/vmlinuz-6.12.2-amd64 root=test
  initrd /boot/initrd.img-6.12.2-amd64
}
submenu 'Advanced options' {
}
### END /etc/grub.d/10_linux ###
GRUB
[[ "$(cleanup_parse_grub "$grub_cfg")" == 6.12.2-amd64 ]]
printf 'set default="saved"\n' >>"$grub_cfg"
if cleanup_parse_grub "$grub_cfg"; then fail 'accepted a custom GRUB default'; fi
printf '3 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.\n' >"$test_dir/unsafe-plan"
if cleanup_apt_plan "$(cat "$test_dir/unsafe-plan")"; then fail 'accepted package upgrades'; fi

# Debian 13 BIOS layout, with the firmware stanza emitted by trixie grub-common
# 2.12-9+deb13u4 (/etc/grub.d/30_uefi-firmware).
(
  root="$test_dir/trixie"
  boot="$root/boot"
  mkdir -p "$root/etc/default/grub.d" "$root/proc" "$boot/grub"
  sed "s|/etc/default/grub|$root/etc/default/grub|g; s|/proc/cmdline|$root/proc/cmdline|g; s|/sys/firmware/efi|$root/sys/firmware/efi|g" \
    "$repo/debian-init.sh" >"$root/installer"
  bash -s "$root" <<'TEST'
  set -Eeuo pipefail
  root=$1
  boot="$root/boot"
  # shellcheck disable=SC1091
  source "$root/installer"
  trap - EXIT ERR HUP INT TERM
  fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

  cat >"$root/etc/default/grub" <<'DEFAULTS'
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR=`( . /etc/os-release && echo ${NAME} )`
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0"
DEFAULTS
  printf 'BOOT_IMAGE=/boot/vmlinuz-6.12.118+deb13-amd64 root=UUID=fixture ro net.ifnames=0 biosdevname=0 quiet\n' >"$root/proc/cmdline"
  : >"$boot/grub/grubenv"
  cat >"$boot/grub/grub.cfg" <<'GRUB'
set default="${next_entry}"
set default="0"
### BEGIN /etc/grub.d/10_linux ###
menuentry 'Debian GNU/Linux' {
  linux /boot/vmlinuz-6.12.118+deb13-amd64 root=UUID=fixture ro net.ifnames=0 biosdevname=0 quiet
  initrd /boot/initrd.img-6.12.118+deb13-amd64
}
submenu 'Advanced options for Debian GNU/Linux' {
  menuentry 'Debian GNU/Linux, with Linux 6.12.117+deb13-amd64' {
    linux /boot/vmlinuz-6.12.117+deb13-amd64 root=UUID=fixture ro
    initrd /boot/initrd.img-6.12.117+deb13-amd64
  }
}
### END /etc/grub.d/10_linux ###
### BEGIN /etc/grub.d/30_uefi-firmware ###
if [ "$grub_platform" = "efi" ]; then
	fwsetup --is-supported
	if [ "$?" = 0 ]; then
		menuentry 'UEFI Firmware Settings' $menuentry_id_option 'uefi-firmware' {
			fwsetup
		}
	fi
fi
### END /etc/grub.d/30_uefi-firmware ###
### BEGIN /etc/grub.d/41_custom ###
if [ -f  ${config_directory}/custom.cfg ]; then
  source ${config_directory}/custom.cfg
elif [ -z "${config_directory}" -a -f  $prefix/custom.cfg ]; then
  source $prefix/custom.cfg
fi
### END /etc/grub.d/41_custom ###
GRUB
  eval "fixture_$(declare -f cleanup_old_kernel_candidates)"
  cleanup_old_kernel_candidates() { fixture_cleanup_old_kernel_candidates "$boot" "$root/modules"; }
  grub-script-check() { [[ "$1" == "$boot/grub/grub.cfg" ]]; }
  grub-editenv() { [[ "$1" == "$boot/grub/grubenv" && "$2" == list ]]; cat "$1"; }
  uname() { [[ "$1" == -r ]]; echo 6.12.118+deb13-amd64; }
  dpkg() {
    if [[ "$1" == --audit ]]; then return 0; fi
    [[ "$1" == --compare-versions && "$3" == gt ]] || fail "unexpected dpkg arguments: $*"
    [[ "$2" > "$4" ]]
  }
  apt-get() { fail 'unexpected APT call for an empty or unsafe kernel selection'; }
  dpkg-query() {
    case "$1:${3:-}" in
      -W:grub-pc) echo installed ;;
      -W:linux-image-\*) printf 'ii linux-image-%s\n' "${installed_releases[@]}" ;;
      *) [[ "$1" == -L ]] || fail "unexpected dpkg-query arguments: $*"
         printf '/boot/vmlinuz-%s\n' "${2#linux-image-}" ;;
    esac
  }
  for release in 6.12.{116,117,118}+deb13-amd64; do
    mkdir -p "$root/modules/$release/kernel"
    echo image >"$boot/vmlinuz-$release"
    echo initrd >"$boot/initrd.img-$release"
  done
  installed_releases=(6.12.{117,118}+deb13-amd64)
  cleanup_old_kernels
  [[ "$CLEANUP_RESULT" == '无需清理（仅保留当前、默认与备用内核）' ]] || fail "$CLEANUP_RESULT"
  installed_releases=(6.12.{116,117,118}+deb13-amd64)
  [[ "$(cleanup_old_kernel_candidates)" == linux-image-6.12.116+deb13-amd64 ]] || fail 'wrong oldest kernel'

  cp "$root/etc/default/grub" "$root/trixie-defaults"
  sed '/^GRUB_DISTRIBUTOR=/d' "$root/trixie-defaults" >"$root/etc/default/grub"
  printf '%s\n' '  GRUB_DISTRIBUTOR=`lsb_release -i -s 2> /dev/null || echo Debian`  ' >>"$root/etc/default/grub"
  [[ "$(cleanup_old_kernel_candidates)" == linux-image-6.12.116+deb13-amd64 ]] || fail 'stock Bookworm distributor was rejected'
  sed -i 's/lsb_release -i -s/echo custom/' "$root/etc/default/grub"
  cleanup_old_kernels
  [[ "$CLEANUP_RESULT" == '跳过（无法可靠确认当前、默认或备用内核）' ]] || fail 'accepted a custom GRUB distributor'
  cp "$root/trixie-defaults" "$root/etc/default/grub"

  cp "$boot/grub/grub.cfg" "$root/grub.cfg.orig"
  sed -i 's|/30_uefi-firmware |/30_unknown |g' "$boot/grub/grub.cfg"
  cleanup_old_kernels
  [[ "$CLEANUP_RESULT" == '跳过（无法可靠确认当前、默认或备用内核）' ]] || fail 'accepted a menuentry in a foreign stanza'
  {
    sed -n '/^### BEGIN .*\/30_uefi-firmware/,/^### END .*\/30_uefi-firmware/p' "$root/grub.cfg.orig"
    cat "$root/grub.cfg.orig"
  } >"$boot/grub/grub.cfg"
  if cleanup_old_kernel_candidates; then fail 'accepted firmware entry before 10_linux'; fi
TEST
)

(
  uname() { [[ "$1" == -r ]]; echo 6.12.1-amd64; }
  cleanup_grub_kernel() { [[ "$2" == 6.12.1-amd64 ]]; echo 6.12.2-amd64; }
  dpkg() { [[ "$1" == --compare-versions ]]; [[ "$2" > "$4" ]]; }
  dpkg-query() {
    case "$1" in
      -W) printf 'ii linux-image-%s-amd64\n' 6.12.0 6.12.1 6.12.2 6.12.3 ;;
      -L) printf '/boot/vmlinuz-%s\n' "${2#linux-image-}" ;;
      *) return 1 ;;
    esac
  }
  for release in 6.12.{0,1,2,3}-amd64; do
    mkdir -p "$test_dir/boot" "$test_dir/modules/$release/kernel"
    echo image >"$test_dir/boot/vmlinuz-$release"
    echo initrd >"$test_dir/boot/initrd.img-$release"
  done
  [[ "$(cleanup_old_kernel_candidates "$test_dir/boot" "$test_dir/modules")" == linux-image-6.12.0-amd64 ]]
  cleanup_grub_kernel() { return 1; }
  if cleanup_old_kernel_candidates "$test_dir/boot" "$test_dir/modules"; then fail 'accepted unknown boot setup'; fi
)

for scenario in yes no kernel critical changed; do
  (
    trace="$test_dir/$scenario"
    : >"$trace"
    case "$scenario" in
      kernel) pkg=linux-image-6.12.1-amd64 ;;
      critical) pkg=openssh-server ;;
      *) pkg=libfixture ;;
    esac
    apt-get() {
      case "$2" in
        autoremove) printf 'Remv %s [1]\n' "$pkg" ;;
        remove)
          printf 'Remv %s [1]\n' "$pkg"
          if [[ "$scenario" == changed ]]; then printf 'Inst unexpected (1)\n'; fi ;;
        *) fail "unexpected apt arguments: $*" ;;
      esac
      printf '0 upgraded, 0 newly installed, 1 to remove and 0 not upgraded.\n'
    }
    apt-mark() { [[ "$1" == showauto ]]; printf '%s\n' "$pkg"; }
    dpkg-query() {
      case "$1:${2:-}" in
        -W:-f=*) printf 'installed|||optional|libs' ;;
        -W:--) printf '%s\t1\n' "$pkg" ;;
        -L:--) printf '/usr/lib/libfixture.so\n' ;;
        --control-list:*) printf 'md5sums\n' ;;
        *) return 1 ;;
      esac
    }
    dpkg() {
      if [[ "$1" == --audit ]]; then return 0; fi
      [[ "$1" == --remove && "$2" == -- && "$3" == libfixture && $# == 3 ]] || fail 'unsafe dpkg operation'
      echo removed >>"$trace"
    }
    ask_yes_no() { [[ "$2" == false ]] || fail 'package removal must default to N'; echo prompt >>"$trace"; [[ "$scenario" != no ]]; }
    cleanup_orphan_packages >"$test_dir/preview"
    grep -Fq "Remv $pkg [1]" "$test_dir/preview"
    case "$scenario" in
      yes) [[ "$CLEANUP_RESULT" == 已清理 ]]; grep -Fxq removed "$trace" ;;
      no) [[ "$CLEANUP_RESULT" == 用户跳过 ]]; [[ "$(cat "$trace")" == prompt ]] ;;
      kernel|critical) [[ "$CLEANUP_RESULT" == 跳过* && ! -s "$trace" ]] ;;
      changed) [[ "$CLEANUP_RESULT" == 失败* && "$(cat "$trace")" == prompt ]] ;;
    esac
  )
done

[[ "$(format_mib 511)" == '0 MiB' ]]
[[ "$(format_mib 512)" == '1 MiB' ]]
[[ "$(format_mib 1048575)" == '1024 MiB' ]]
[[ "$(format_mib 1048576)" == '1.0 GiB' ]]
[[ "$(format_mib 1310720)" == '1.3 GiB' ]]

(
  trace="$test_dir/automatic"
  cleanup_preflight() { VERSION_ID=13; }
  preflight() { fail 'cleanup reached installer preflight'; }
  root_free_kib() { if [[ -s "$trace" ]]; then echo "$after_cleanup"; else echo 665600; fi; }
  df() { printf 'header\n/dev/test 5138022 4000000 665600 90%% /\n'; }
  apt-get() { [[ "$1" == clean ]]; echo apt >>"$trace"; }
  journalctl() { [[ "$1" == --vacuum-size=50M ]]; echo journal >>"$trace"; return 1; }
  TMP_DIR="$test_dir/tmp"
  BACKUP_DIR="$test_dir/backup"
  mkdir -p "$TMP_DIR" "$BACKUP_DIR"
  systemd-tmpfiles() {
    [[ "$1" == --clean && "$2" == --prefix=/tmp && "$3" == --prefix=/var/tmp ]]
    local arg
    for arg in "$TMP_DIR" "$BACKUP_DIR" /tmp/smartdns /tmp/sing-box /tmp/fail2ban /var/tmp/smartdns /var/tmp/sing-box /var/tmp/fail2ban; do
      printf '%s\n' "$@" | grep -Fxq -- "--exclude-prefix=$arg" || fail "missing cleanup exclusion: $arg"
    done
    echo tmpfiles >>"$trace"
  }
  swapon() { [[ "$1" == --show=NAME,SIZE && "$2" == --bytes ]]; printf 'NAME SIZE\n/swapfile-vps-init 536866816\n'; }
  swapoff() { fail 'cleanup called swapoff'; }
  : >"$trace"
  # Set both optional operations aside in this reporting fixture, even when
  # the developer launches it from an interactive terminal.
  cleanup_orphan_packages() { CLEANUP_RESULT='测试跳过'; }
  cleanup_old_kernels() { CLEANUP_RESULT='测试跳过'; }
  after_cleanup=1048577
  main --cleanup-only >"$test_dir/report"
  [[ "$(cat "$trace")" == $'apt\njournal\ntmpfiles' ]]
  grep -Fq '系统清理报告' "$test_dir/report"
  for line in '系统：Debian 13' '清理前可用：650 MiB' '清理后可用：1.0 GiB' \
    '实际增加可用空间：374 MiB' '安装所需 2GiB 空间：FAIL，还需释放 1024 MiB' \
    'APT 缓存：完成' 'Journal：失败' '临时文件：完成' '无用软件包：' '旧内核：' 'Swap：未修改'; do
    grep -Eq "^(│|\|) $line.*(│|\|)$" "$test_dir/report" || fail "missing cleanup report row: $line"
  done
  for after_cleanup in 665600 663552 2097152; do
    : >"$trace"
    run_system_cleanup >"$test_dir/report"
    if (( after_cleanup < MIN_ROOT_FREE_KIB )); then
      grep -Fq '实际增加可用空间：约 0（清理期间有其他写入）' "$test_dir/report"
    else
      grep -Fq '安装所需 2GiB 空间：PASS' "$test_dir/report"
    fi
  done
)

(
  apt-get() { return 1; }
  journalctl() { return 1; }
  systemd-tmpfiles() { return 1; }
  run_safe_cleanup 2>"$test_dir/warning"
  [[ "$SAFE_CLEANUP_APT" == 失败 && "$SAFE_CLEANUP_JOURNAL" == 失败 && "$SAFE_CLEANUP_TMPFILES" == 失败 ]]
  grep -Fq '安全清理未全部完成' "$test_dir/warning"
  PRESERVE_SSH=true NETWORK_REQUEST=auto
  ssh_listener_addresses() { :; }
  fail2ban_package_installed() { return 1; }
  ufw() { echo unavailable; }
  smartdns() { echo fixture; }
  sing-box() { echo fixture; }
  print_report >"$test_dir/init-report" 2>/dev/null
  grep -Fq "安全清理      : $SAFE_CLEANUP_RESULT" "$test_dir/init-report"
  grep -Eq '^(│|\|) 重启后可运行 \[7\] 清理旧内核和无用包 +(│|\|)$' "$test_dir/init-report"
)

# A leftover network-stack state file from older versions is removed (with a backup); a symlink,
# a directory or a missing file is left alone.
sed "s|^readonly LEGACY_NETWORK_STACK_STATE=.*|readonly LEGACY_NETWORK_STACK_STATE='$test_dir/state/network-stack'|" "$repo/debian-init.sh" >"$test_dir/installer"
bash -Eeuo pipefail -s "$test_dir" <<'TEST'
source "$1/installer"
trap - EXIT ERR HUP INT TERM
BACKUP_DIR="$1/backups"
mkdir -p "$BACKUP_DIR" "$(dirname "$LEGACY_NETWORK_STACK_STATE")"
remove_legacy_network_stack_state
printf 'dual\n' >"$LEGACY_NETWORK_STACK_STATE"
remove_legacy_network_stack_state 2>"$BACKUP_DIR/log"
[[ ! -e "$LEGACY_NETWORK_STACK_STATE" ]]
[[ "$(cat "$BACKUP_DIR/files$LEGACY_NETWORK_STACK_STATE")" == dual ]]
[[ -d "$(dirname "$LEGACY_NETWORK_STACK_STATE")" ]]
printf 'keep\n' >"$BACKUP_DIR/elsewhere"
ln -s "$BACKUP_DIR/elsewhere" "$LEGACY_NETWORK_STACK_STATE"
remove_legacy_network_stack_state
[[ -L "$LEGACY_NETWORK_STACK_STATE" && "$(cat "$BACKUP_DIR/elsewhere")" == keep ]]
rm -f "$LEGACY_NETWORK_STACK_STATE"
mkdir "$LEGACY_NETWORK_STACK_STATE"
remove_legacy_network_stack_state
[[ -d "$LEGACY_NETWORK_STACK_STATE" ]]
# A file that cannot be made mutable or backed up is only reported: the run (and its report) goes on.
rmdir "$LEGACY_NETWORK_STACK_STATE"
printf 'dual\n' >"$LEGACY_NETWORK_STACK_STATE"
lsattr() { echo '----i---------e------- x'; }
chattr() { return 1; }
make_mutable() { echo 'make_mutable must not be used' >&2; return 1; }
remove_legacy_network_stack_state 2>"$BACKUP_DIR/warn"
[[ -f "$LEGACY_NETWORK_STACK_STATE" ]]
grep -Fq '保留' "$BACKUP_DIR/warn"
unset -f lsattr chattr
BACKUP_DIR=/dev/null/none
remove_legacy_network_stack_state 2>"$1/warn2"
[[ -f "$LEGACY_NETWORK_STACK_STATE" ]]
grep -Fq '无法备份' "$1/warn2"
echo report-still-printed >"$1/report"
TEST

if [[ "$(uname -s)" == Linux ]] && command -v script >/dev/null; then
  for mode in quick custom exit smartdns singbox fail2ban cleanup update; do
    case "$mode" in quick) option=1;; custom) option=2;; exit) option=0;; smartdns) option=3;; singbox) option=4;; fail2ban) option=5;; cleanup) option=7;; update) option=6;; esac
    printf '%s\n' "$option" | script -qec "bash -c 'source \"$repo/debian-init.sh\"; select_install_mode; echo selected=\$INSTALL_MODE'" /dev/null >"$test_dir/menu" ||
      { cat "$test_dir/menu"; fail "menu option $option failed"; }
    sed $'s/\033\\[[0-9;]*[A-Za-z]//g' "$test_dir/menu" >"$test_dir/menu.plain"
    grep -Fq '7. 系统清理' "$test_dir/menu.plain" || fail 'cleanup menu label missing'
    grep -Fq '6. 仅更新系统' "$test_dir/menu.plain" || fail 'update menu label missing'
    grep -Fq '4. 安装/升级 sing-box' "$test_dir/menu.plain" || fail 'sing-box menu label missing'
    if [[ "$mode" == exit ]]; then
      if grep -Fq 'selected=' "$test_dir/menu.plain"; then fail 'exit continued to dispatch'; fi
    else
      grep -Fq "selected=$mode" "$test_dir/menu.plain" || { cat "$test_dir/menu"; fail "unexpected dispatch for $mode"; }
    fi
  done
fi
echo 'PASS: Cleanup dispatch, disk accounting, optional removals and kernel protection'
