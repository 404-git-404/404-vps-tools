#!/usr/bin/env bash
# shellcheck disable=SC2329,SC2034 # Mocks/state used by sourced installer functions.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
# shellcheck disable=SC1091
source "$repo/debian-init.sh"
trap - ERR HUP INT TERM
trap 'rm -rf -- "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

for scenario in default skip permanent-sing permanent-smart permanent-both absent unpacked upgrade-failure update-failure hold-failure restore-failure signal preserve; do
  mkdir "$work/$scenario"
  trace="$work/$scenario/trace" holds="$work/$scenario/holds"
  printf 'operator-package\n' >"$holds"
  case "$scenario" in
    permanent-sing) echo sing-box >>"$holds" ;;
    permanent-smart) echo smartdns >>"$holds" ;;
    permanent-both) printf 'sing-box\nsmartdns\n' >>"$holds" ;;
  esac
  cp "$holds" "$work/$scenario/original"
  : >"$trace"
  result=0
  set +e
  (
    set -Ee
    trap cleanup EXIT
    trap 'on_error $LINENO' ERR
    parse_args --update-only
    if [[ "$scenario" == skip ]]; then parse_args --skip-upgrade; fi
    if [[ "$scenario" == preserve ]]; then PRESERVE_SSH=true; fi
    wait_for_package_manager() { echo wait >>"$trace"; }
    apt-mark() {
      local IFS=' ' package
      printf 'mark %s\n' "$*" >>"$trace"
      case "$1" in
        showhold) cat "$holds" ;;
        hold)
          shift
          for package in "$@"; do echo "$package" >>"$holds"; done
          if [[ "$scenario" == hold-failure ]]; then return 1; fi ;;
        unhold)
          if [[ "$scenario" == restore-failure && ! -f "$work/retried" ]]; then touch "$work/retried"; return 1; fi
          shift
          for package in "$@"; do
            awk -v package="$package" '$0 != package' "$holds" >"$holds.new"
            mv "$holds.new" "$holds"
          done ;;
        *) fail 'unexpected apt-mark' ;;
      esac
    }
    dpkg-query() {
      if [[ "$scenario" == absent ]]; then return 1; fi
      if [[ "$scenario" == unpacked ]]; then echo unpacked; else echo installed; fi
    }
    apt_get() {
      local IFS=' '
      printf 'apt %s\n' "$*" >>"$trace"
      case "$1" in
        update) if [[ "$scenario" == update-failure ]]; then return 100; fi ;;
        full-upgrade)
          if [[ "$scenario" != absent && "$scenario" != unpacked ]]; then
            grep -Fxq sing-box "$holds" || fail 'sing-box not protected'
            grep -Fxq smartdns "$holds" || fail 'SmartDNS not protected'
          fi
          if [[ "$scenario" == upgrade-failure ]]; then return 100; fi
          if [[ "$scenario" == signal ]]; then on_signal TERM; fi ;;
        *) fail 'update-only installed tools or changed components' ;;
      esac
    }
    install_early_dependencies() { fail 'update-only dependencies'; }
    configure_ssh() { fail 'update-only SSH'; }
    configure_ufw() { fail 'update-only UFW'; }
    configure_swap() { fail 'update-only Swap'; }
    run_system_update_only
  ) >"$work/$scenario/output" 2>&1
  result=$?
  set -e
  case "$scenario" in
    *failure|signal) (( result != 0 )) || fail "$scenario was accepted" ;;
    *) if (( result )); then cat "$work/$scenario/output"; fail "$scenario failed"; fi ;;
  esac
  sort "$holds" >"$work/current"
  sort "$work/$scenario/original" >"$work/original"
  cmp "$work/current" "$work/original" || fail "$scenario changed permanent holds"
  grep -Fxq 'apt update' "$trace"
  case "$scenario" in
    skip|update-failure|hold-failure)
      if grep -Fq 'apt full-upgrade' "$trace"; then fail "$scenario ran upgrade"; fi ;;
    *) grep -Fxq 'apt full-upgrade -y' "$trace" ;;
  esac
done

# CLI compatibility and direct dispatch never enter initialization collection.
(
  parse_args --base-only --skip-upgrade --full-upgrade
  [[ "$BASE_ONLY" == true && "$INSTALL_MODE" == base && "$DO_FULL_UPGRADE" == true ]]
)
(
  preflight() { :; }
  acquire_lock() { :; }
  collect_initialization_config() { fail 'update dispatch entered initialization'; }
  run_system_update_only() { echo update-only >"$work/dispatch"; }
  main --update-only --skip-upgrade
  [[ "$DO_FULL_UPGRADE" == false ]]
)
grep -Fxq update-only "$work/dispatch"

# Exercise the actual apt wrapper's lock and noninteractive settings.
(
  apt-get() {
    local IFS=' '
    [[ "$NEEDRESTART_MODE" == a && "$DEBIAN_FRONTEND" == noninteractive && "$APT_LISTCHANGES_FRONTEND" == none ]]
    [[ "$*" == *'DPkg::Lock::Timeout='* && "$*" == *'--force-confold'* && "$*" == *'full-upgrade -y' ]]
  }
  apt_get full-upgrade -y
)
echo 'PASS: shared update, CLI, temporary/permanent holds, APT failures, signals and noninteractive locks'
