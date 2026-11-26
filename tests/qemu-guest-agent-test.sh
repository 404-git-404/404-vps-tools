#!/usr/bin/env bash
# shellcheck disable=SC2329,SC2034 # Mocks and state consumed by the sourced script.
set -Eeuo pipefail
# shellcheck source=tests/process-helper.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/process-helper.sh"
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if [[ ${1:-} == --package-manager ]]; then
  [[ -f /.dockerenv ]] || fail 'This test must run in a disposable Docker container.'
  # shellcheck disable=SC1091
  source "$repo/debian-init.sh"
  trap 'rm -rf -- "$work"' EXIT
  [[ $(qemu_guest_agent_status) == not-installed ]] || fail 'Container must start without qemu-guest-agent.'
  INSTALL_MODE=qemu-agent-remove
  preflight
  acquire_lock
  INSTALL_MODE=quick
  remove_qemu_guest_agent

  build_fixture() (
    local name=$1 depends=${2:-}
    umask 022
    mkdir -p "$work/$name/DEBIAN"
    {
      printf 'Package: %s\nVersion: 1\nArchitecture: all\nMaintainer: Test\nDescription: Test package\n' "$name"
      if [[ -n "$depends" ]]; then printf 'Depends: %s\n' "$depends"; fi
    } >"$work/$name/DEBIAN/control"
    dpkg-deb --build "$work/$name" "$work/$name.deb"
    dpkg --install "$work/$name.deb"
  )

  build_fixture qemu-guest-agent
  build_fixture qemu-agent-test-dependent qemu-guest-agent
  if run_in_bash 'remove_qemu_guest_agent' >"$work/blocked" 2>&1; then fail 'APT allowed removal of a reverse dependency'; fi
  grep -Fq '已阻止执行' "$work/blocked"
  [[ $(qemu_guest_agent_status) == installed ]]
  [[ $(dpkg-query -W -f='${db:Status-Status}' qemu-agent-test-dependent) == installed ]]
  dpkg --remove qemu-agent-test-dependent
  remove_qemu_guest_agent
  remove_qemu_guest_agent
  [[ $(qemu_guest_agent_status) == not-installed || $(qemu_guest_agent_status) == config-files ]]
  echo 'PASS: real APT dependency check and dpkg single-package removal'
  exit 0
fi

sed "s|/dev/tty|$work/tty|g" "$repo/debian-init.sh" >"$work/installer"
# shellcheck disable=SC1091
source "$work/installer"
trap - ERR HUP INT TERM
trap 'rm -rf -- "$work"' EXIT

for scenario in installed not-installed config-files repeat cancel extra simulation-failure removal-failure verification-failure query-failure; do
  trace="$work/$scenario.trace"
  output="$work/$scenario.output"
  : >"$trace"
  fixture_state=installed
  case "$scenario" in not-installed|config-files) fixture_state=$scenario ;; esac
  set +e
  (
    set -e
    preflight() { [[ "$INSTALL_MODE" == qemu-agent-remove ]]; echo preflight >>"$trace"; }
    acquire_lock() { echo lock >>"$trace"; }
    wait_for_package_manager() { :; }
    collect_initialization_config() { fail 'standalone initialized the system'; }
    run_system_update_only() { fail 'standalone updated the system'; }
    log() {
      if [[ "$1" == 'QEMU Guest Agent 卸载预览：' ]]; then echo preview >>"$trace"; fi
      printf '%s\n' "$*"
    }
    read_tty() {
      case "$1" in
        '请选择 [1-9]: ') printf -v "$2" 9 ;;
        '确认卸载 QEMU Guest Agent？ [y/N] ')
          echo confirm >>"$trace"
          if [[ "$scenario" == cancel ]]; then printf -v "$2" ''; else printf -v "$2" y; fi ;;
        *) fail "unexpected prompt: $1" ;;
      esac
    }
    dpkg-query() {
      [[ "$*" == "-W -f=\${db:Status-Status} -- qemu-guest-agent" ]] || fail "unexpected dpkg-query: $*"
      case "$scenario" in query-failure) return 2 ;; esac
      case "$fixture_state" in not-installed) return 1 ;; esac
      printf '%s' "$fixture_state"
    }
    apt_get() {
      [[ "$LC_ALL" == C && "$*" == '-s -o APT::Get::AutomaticRemove=false -o APT::Get::Purge=false remove -- qemu-guest-agent' ]] ||
        fail "unexpected APT command: $*"
      echo simulate >>"$trace"
      case "$scenario" in
        extra) printf '0 upgraded, 0 newly installed, 2 to remove and 0 not upgraded.\nRemv extra-package [1]\n' ;;
        simulation-failure) return 100 ;;
        *) printf '0 upgraded, 0 newly installed, 1 to remove and 0 not upgraded.\n' ;;
      esac
      printf 'Remv qemu-guest-agent [1]\n'
    }
    dpkg() {
      [[ "$*" == '--no-force-depends,depends-version --remove -- qemu-guest-agent' ]] || fail "unexpected dpkg: $*"
      echo remove >>"$trace"
      [[ "$scenario" != removal-failure ]] || return 1
      if [[ "$scenario" != verification-failure ]]; then fixture_state='config-files'; fi
    }
    IFS=' '
    main
    grep -Fxq '9. 卸载 QEMU Guest Agent' "$work/tty"
    if [[ "$scenario" == repeat ]]; then remove_qemu_guest_agent; fi
  ) >"$output" 2>&1
  result=$?
  set -e

  expected=$'preflight\nlock'
  case "$scenario" in
    installed|repeat) expected+=$'\nsimulate\npreview\nconfirm\nremove'; grep -Fq 'qemu-guest-agent 已卸载。' "$output" ;;
    not-installed|config-files) grep -Fq 'qemu-guest-agent 未安装，无需卸载。' "$output" ;;
    cancel) expected+=$'\nsimulate\npreview\nconfirm'; grep -Fq '已取消卸载' "$output" ;;
    extra) expected+=$'\nsimulate\npreview'; grep -Fq '已阻止执行' "$output" ;;
    simulation-failure) expected+=$'\nsimulate'; grep -Fq 'APT 模拟卸载 qemu-guest-agent 失败' "$output" ;;
    removal-failure) expected+=$'\nsimulate\npreview\nconfirm\nremove'; grep -Fq '卸载 qemu-guest-agent 失败' "$output" ;;
    verification-failure) expected+=$'\nsimulate\npreview\nconfirm\nremove'; grep -Fq '卸载后状态异常' "$output" ;;
    query-failure) grep -Fq '无法查询' "$output" ;;
  esac
  [[ $(cat "$trace") == "$expected" ]] || fail "$scenario called unexpected steps"
  case "$scenario" in
    extra|*-failure)
      (( result != 0 )) || fail "$scenario unexpectedly succeeded"
      if grep -Fq 'qemu-guest-agent 已卸载。' "$output"; then fail "$scenario reported success"; fi ;;
    *) (( result == 0 )) || fail "$scenario failed" ;;
  esac
done
grep -Fxq 'Remv qemu-guest-agent [1]' "$work/installed.output"
grep -Fq 'qemu-guest-agent 未安装，无需卸载。' "$work/repeat.output"
echo 'PASS: menu 9, preview, default cancel, installed, absent, repeat, dependency guard and failure reporting'
