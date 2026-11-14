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
    ask_yes_no() { [[ "$2" == false ]]; echo prompt >>"$trace"; [[ "$scenario" != no ]]; }
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

(
  trace="$test_dir/automatic"
  cleanup_preflight() { VERSION_ID=13; }
  preflight() { fail 'cleanup reached installer preflight'; }
  root_free_kib() { if [[ -s "$trace" ]]; then echo 1048577; else echo 665600; fi; }
  df() { printf 'header\n/dev/test 5138022 4000000 665600 90%% /\n'; }
  apt-get() { [[ "$1" == clean ]]; echo apt >>"$trace"; }
  journalctl() { [[ "$1" == --vacuum-size=50M ]]; echo journal >>"$trace"; return 1; }
  systemd-tmpfiles() { [[ "$1" == --clean && "$2" == --prefix=/tmp && "$3" == --prefix=/var/tmp ]]; echo tmpfiles >>"$trace"; }
  swapon() { [[ "$1" == --show=NAME,SIZE && "$2" == --bytes ]]; printf 'NAME SIZE\n/swapfile-vps-init 536866816\n'; }
  swapoff() { fail 'cleanup called swapoff'; }
  : >"$trace"
  # Set both optional operations aside in this reporting fixture, even when
  # the developer launches it from an interactive terminal.
  cleanup_orphan_packages() { CLEANUP_RESULT='测试跳过'; }
  cleanup_old_kernels() { CLEANUP_RESULT='测试跳过'; }
  main --cleanup-only >"$test_dir/report"
  [[ "$(cat "$trace")" == $'apt\njournal\ntmpfiles' ]]
  grep -Fxq '清理前可用：650MiB' "$test_dir/report"
  grep -Fxq '实际增加可用空间：374.0009765625MiB' "$test_dir/report"
  grep -Fxq '安装所需 2GiB 空间：FAIL，还需释放 1023.9990234375MiB' "$test_dir/report"
  grep -Fxq 'Journal：失败' "$test_dir/report"
  grep -Fxq '临时文件：完成' "$test_dir/report"
  grep -Fxq 'Swap：未修改' "$test_dir/report"
)

if [[ "$(uname -s)" == Linux ]] && command -v script >/dev/null; then
  for mode in quick custom exit smartdns singbox fail2ban cleanup; do
    case "$mode" in quick) option=1;; custom) option=2;; exit) option=3;; smartdns) option=4;; singbox) option=5;; fail2ban) option=6;; cleanup) option=7;; esac
    printf '%s\n' "$option" | script -qec "bash -c 'source \"$repo/debian-init.sh\"; select_install_mode; echo selected=\$INSTALL_MODE'" /dev/null >"$test_dir/menu" ||
      { cat "$test_dir/menu"; fail "menu option $option failed"; }
    grep -Fq '7. 系统清理' "$test_dir/menu" || fail 'cleanup menu label missing'
    if [[ "$mode" == exit ]]; then
      if grep -Fq 'selected=' "$test_dir/menu"; then fail 'exit continued to dispatch'; fi
    else
      grep -Fq "selected=$mode" "$test_dir/menu" || { cat "$test_dir/menu"; fail "unexpected dispatch for $mode"; }
    fi
  done
fi
echo 'PASS: Cleanup dispatch, disk accounting, optional removals and kernel protection'
