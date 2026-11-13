#!/usr/bin/env bash
# The sourced installer invokes the mocks and reads the test environment.
# shellcheck disable=SC2329,SC2034
set -Eeuo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$TEST_DIR/../debian-init.sh"
trap - ERR HUP INT TERM
IFS=$' \t\n'
TEST_TMP=$(mktemp -d)
trap 'rm -rf -- "$TEST_TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
record() { local IFS=' '; echo "$*" >>"$TRACE"; }

for scenario in fresh repeat reality config-error action-error no-backend; do
  (
    FAIL2BAN_DIR="$TEST_TMP/$scenario/etc"
    BACKUP_DIR="$TEST_TMP/$scenario/backup"
    TMP_DIR="$TEST_TMP/$scenario/tmp"
    TRACE="$TEST_TMP/$scenario/trace"
    mkdir -p "$FAIL2BAN_DIR/jail.d" "$FAIL2BAN_DIR/filter.d" "$BACKUP_DIR" "$TMP_DIR"
    printf '[custom]\nenabled = true\n' >"$FAIL2BAN_DIR/jail.local"
    printf '[custom]\nmaxretry = 9\n' >"$FAIL2BAN_DIR/jail.d/local-owner.local"
    cp "$FAIL2BAN_DIR/jail.local" "$TMP_DIR/jail.local"
    cp "$FAIL2BAN_DIR/jail.d/local-owner.local" "$TMP_DIR/local-owner.local"
    if [[ "$scenario" == config-error || "$scenario" == action-error ]]; then
      echo 'old managed defaults' >"$FAIL2BAN_DIR/jail.d/00-vps-init-defaults.local"
      echo 'old managed sshd' >"$FAIL2BAN_DIR/jail.d/vps-init-sshd.local"
    fi
    SSH_CONNECTION='203.0.113.10 56789 203.0.113.20 22'
    : >"$TRACE"
    preflight() { record preflight; }
    acquire_lock() { record lock; }
    collect_choices() { fail 'full initialization was reached'; }
    detect_network_stack() { fail 'system networking was reached'; }
    backup_dns_state() { fail 'SmartDNS was reached'; }
    install_sing_box() { fail 'sing-box installation was reached'; }
    configure_ssh() { fail 'SSH configuration was reached'; }
    configure_ufw() { fail 'UFW configuration was reached'; }
    wait_for_package_manager() { record wait-apt; }
    apt_get() { record apt "$@"; }
    make_mutable() { :; }
    install() {
      case "$1" in
        -d) shift 3; mkdir -p "$@" ;;
        -m) shift 2; cp -- "$@" ;;
        *) fail 'unexpected install invocation' ;;
      esac
    }
    fail2ban_default_ignoreip() { echo 203.0.113.0/28; }
    sleep() { :; }
    dpkg-query() {
      if [[ "$scenario" == fresh ]]; then return 1; fi
      printf 'install ok installed'
    }
    command() {
      if [[ "${1:-} ${2:-}" == '-v ufw' ]]; then return 0; fi
      builtin command "$@"
    }
    ufw() {
      [[ "$*" == status ]] || fail 'unexpected UFW mutation'
      if [[ "$scenario" == reality ]]; then echo 'Status: active'; else echo 'Status: inactive'; fi
      [[ ! -f "$TMP_DIR/ban" ]] || cat "$TMP_DIR/ban"
    }
    nft() {
      case "$*" in
        '--check add table inet vps_init_fail2ban_check') [[ "$scenario" != no-backend ]] ;;
        '-n list ruleset') [[ ! -f "$TMP_DIR/ban" ]] || cat "$TMP_DIR/ban" ;;
        *) fail 'unexpected nftables mutation' ;;
      esac
    }
    systemctl() {
      record systemctl "$@"
      case "$*" in
        'is-active --quiet sing-box.service') [[ "$scenario" == reality ]] ;;
        'is-active --quiet fail2ban.service'|'is-enabled --quiet fail2ban.service')
          [[ "$scenario" != fresh || -f "$TMP_DIR/running" ]] ;;
        'is-enabled fail2ban.service') return 1 ;;
        'reload-or-restart fail2ban.service') touch "$TMP_DIR/running" ;;
        'enable fail2ban.service'|'disable fail2ban.service'|'mask --runtime fail2ban.service'|'unmask --runtime fail2ban.service') : ;;
        *) fail 'unexpected service mutation' ;;
      esac
    }
    journalctl() {
      [[ "$*" == '-u sing-box.service -b --no-pager -o cat -n 500' ]] || fail 'unexpected journal query'
      echo 'inbound/vless[test]: TLS handshake: REALITY: processed invalid connection'
    }
    fail2ban-client() {
      record fail2ban-client "$@"
      case "$*" in
        -t) [[ "$scenario" != config-error ]] ;;
        ping|status|'status sshd'|'status sshd-slow') : ;;
        'status sing-box-reality'|'status sing-box-reality-slow') [[ "$scenario" == reality ]] ;;
        'get '*' actions')
          if [[ "$scenario" == reality ]]; then echo ufw; else echo nftables; fi ;;
        'get '*' banip') : ;;
        'set '*' banip 192.0.2.254')
          if [[ "$scenario" != action-error ]]; then echo 192.0.2.254 >"$TMP_DIR/ban"; fi
          echo 1 ;;
        'set '*' unbanip 192.0.2.254') rm -f "$TMP_DIR/ban" ;;
        *) fail 'unexpected Fail2ban command' ;;
      esac
    }

    case "$scenario" in
      config-error|action-error|no-backend)
        if (trap rollback_fail2ban EXIT; main --fail2ban-only); then fail "$scenario returned success"; fi
        if [[ "$scenario" != no-backend ]]; then
          grep -Fxq 'old managed defaults' "$FAIL2BAN_DIR/jail.d/00-vps-init-defaults.local"
          grep -Fxq 'old managed sshd' "$FAIL2BAN_DIR/jail.d/vps-init-sshd.local"
        fi
        if [[ "$scenario" != action-error ]] && grep -Fq 'systemctl reload-or-restart' "$TRACE"; then
          fail 'service was touched before successful validation'
        fi
        ;;
      *)
        main --fail2ban-only
        if [[ "$scenario" == repeat ]]; then
          cp "$FAIL2BAN_DIR/jail.d/vps-init-sshd.local" "$TMP_DIR/first-sshd.local"
          INSTALL_MODE=''
          main --fail2ban-only
          cmp "$TMP_DIR/first-sshd.local" "$FAIL2BAN_DIR/jail.d/vps-init-sshd.local"
        fi
        grep -Fxq 'maxretry = 5' "$FAIL2BAN_DIR/jail.d/vps-init-sshd.local"
        grep -Fxq 'maxretry = 20' "$FAIL2BAN_DIR/jail.d/vps-init-sshd.local"
        grep -Fq '203.0.113.10' "$FAIL2BAN_DIR/jail.d/vps-init-sshd.local"
        if [[ "$scenario" == reality ]]; then
          grep -Fxq 'banaction = ufw[blocktype=deny]' "$FAIL2BAN_DIR/jail.d/vps-init-sshd.local"
          grep -Fxq 'bantime = 28d' "$FAIL2BAN_DIR/jail.d/vps-init-sing-box-reality.local"
        else
          grep -Fxq 'banaction = nftables[type=allports]' "$FAIL2BAN_DIR/jail.d/vps-init-sshd.local"
          [[ ! -e "$FAIL2BAN_DIR/jail.d/vps-init-sing-box-reality.local" ]] || fail 'unexpected REALITY Jail'
        fi
        ;;
    esac
    if [[ "$scenario" == fresh ]]; then
      grep -Fxq 'apt install -y --no-install-recommends --no-upgrade fail2ban python3-systemd nftables' "$TRACE"
      grep -Fxq 'systemctl mask --runtime fail2ban.service' "$TRACE"
      grep -Fxq 'systemctl unmask --runtime fail2ban.service' "$TRACE"
    elif grep -q '^apt ' "$TRACE"; then
      fail 'already-installed packages were sent to APT'
    fi
    cmp "$TMP_DIR/jail.local" "$FAIL2BAN_DIR/jail.local"
    cmp "$TMP_DIR/local-owner.local" "$FAIL2BAN_DIR/jail.d/local-owner.local"
    [[ ! -e "$TMP_DIR/ban" ]] || fail 'test ban was left behind'
  )
done

if (parse_args --fail2ban-only --smartdns-only); then fail 'conflicting modes accepted'; fi
help_output=$(bash "$TEST_DIR/../debian-init.sh" --help)
[[ "$help_output" == *--fail2ban-only* ]] || fail 'missing CLI help'

# A PTY exercises the real interactive menu on Linux CI.
if [[ "$(uname -s)" == Linux ]] && command -v script >/dev/null; then
  printf '6\n' | script -qec "bash -c 'source \"$TEST_DIR/../debian-init.sh\"; select_install_mode; echo \"selected=\$INSTALL_MODE\"'" /dev/null >"$TEST_TMP/menu"
  grep -Fq '6. 仅安装/更新 Fail2ban' "$TEST_TMP/menu"
  grep -Fq 'selected=fail2ban' "$TEST_TMP/menu"
fi
echo 'PASS: Fail2ban independent install, backends, custom jails, rollback and entry points'
