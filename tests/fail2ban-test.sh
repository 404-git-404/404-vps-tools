#!/usr/bin/env bash
# The sourced installer invokes the mocks and reads the test environment.
# shellcheck disable=SC2329,SC2034
set -Eeuo pipefail
# shellcheck source=tests/process-helper.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/process-helper.sh"

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$TEST_DIR/../debian-init.sh"
trap - ERR HUP INT TERM
IFS=$' \t\n'
TEST_TMP=$(mktemp -d)
trap 'rm -rf -- "$TEST_TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
record() { local IFS=' '; echo "$*" >>"$TRACE"; }

# Run the real menu, base APT step, Fail2ban setup and final report. Replace
# unrelated setup so the test can exercise these paths without changing SSH.
quick_fixture() {
  INSTALL_MODE=quick
  preflight() { :; }
  ensure_system_dns() { :; }
  acquire_lock() { :; }
  read_tty() {
    case "$1" in
      *'请选择 SSH 端口'*) printf -v "$2" '%s' "$menu_ssh" ;;
      '输入 SSH 端口: ') printf -v "$2" '%s' 43210 ;;
      *'请选择网络模式'*) printf -v "$2" '%s' "$menu_network" ;;
      '确认以上配置并开始自动安装？'*) printf -v "$2" y ;;
      *) fail "unexpected prompt: $1" ;;
    esac
  }
  ssh_port_available() { :; }
  collect_choices() {
    [[ "$SSH_PORT" == "$expected_port" && "$NETWORK_REQUEST" == "$expected_network" &&
      "$PRESERVE_SSH" == "$expected_preserve" ]] || fail 'wrong quick menu state'
  }
  install_early_dependencies() { :; }
  check_ssh_change_prerequisites() { :; }
  ensure_key_validation_dependency() { :; }
  collect_swap_choice() { :; }
  confirm_ssh_listener_change() { :; }
  ssh_listener_addresses() { :; }
  collect_public_key() { :; }
  install_authorized_key() { :; }
  configure_swap() { :; }
  ipv4_https_works() { :; }
  configure_chrony() { :; }
  configure_tcp_tuning() { :; }
  install_sing_box() { :; }
  backup_dns_state() { :; }
  apply_network_stack() { :; }
  cleanup_legacy_network_stack() { :; }
  detect_network_stack() { NETWORK_STACK=$NETWORK_REQUEST; }
  install_and_configure_smartdns() { :; }
  configure_system_dns() { DNS_TX=false; }
  configure_ssh() { :; }
  configure_ufw() { :; }
  configure_cf8443() { :; }
  persist_network_stack() { :; }
  run_safe_cleanup() { :; }
  verify_ipv4_policy() { :; }
}

assert_fail2ban_running() {
  [[ "$(dpkg-query -W -f='${Status}' fail2ban)" == 'install ok installed' ]]
  systemctl is-enabled --quiet fail2ban.service
  systemctl is-active --quiet fail2ban.service
  fail2ban-client ping | grep -F 'pong'
  fail2ban-client status sshd
  fail2ban-client status sshd-slow
}

if [[ "${1:-}" == --quick-integration ]]; then
  [[ -f /.dockerenv && "$TEST_DIR" == /repo/tests ]] || fail 'integration fixtures require the isolated CI container'
  while IFS=: read -r menu_ssh menu_network expected_port expected_network; do
    expected_preserve=false
    apt-get purge -y fail2ban
    if fail2ban_package_installed; then fail 'cold install fixture still has Fail2ban'; fi
    for run in first repeat; do
      printf 'Quick Fail2ban: SSH=%s network=%s run=%s\n' "$expected_port" "$expected_network" "$run"
      (
        quick_fixture
        trap cleanup EXIT
        BACKUP_DIR=$(mktemp -d "$TEST_TMP/backup.XXXXXXXX")
        TMP_DIR=$(mktemp -d "$TEST_TMP/run.XXXXXXXX")
        main --skip-upgrade
      )
      assert_fail2ban_running
    done
  done <<'MATRIX'
:1:53651:auto
2:2:53651:ipv4
2:3:53651:dual
1:3:22:dual
3:1:43210:auto
MATRIX
  menu_ssh=2 menu_network=1 expected_port=53651 expected_network=auto expected_preserve=false
  override=/etc/fail2ban/jail.d/zz-test-disable-sshd-slow.local
  printf '[sshd-slow]\nenabled = false\n' >"$override"
  if run_in_bash 'quick_fixture; main --skip-upgrade' >"$TEST_TMP/missing-jail" 2>&1; then
    fail 'quick install accepted the operator override that disables a required jail'
  fi
  grep -F 'Fail2ban Jail 未运行：sshd-slow' "$TEST_TMP/missing-jail"
  rm -f -- "$override"
  menu_ssh=4 menu_network=1 expected_port=53651 expected_network=auto expected_preserve=true
  systemctl disable --now fail2ban.service
  sha256sum /etc/fail2ban/jail.d/vps-init-sshd.local >"$TEST_TMP/config"
  for _ in first repeat; do
    (quick_fixture; main --skip-upgrade) >"$TEST_TMP/preserve"
    grep -F '保留现状（已安装，服务状态 inactive）' "$TEST_TMP/preserve"
    if systemctl is-enabled --quiet fail2ban.service || systemctl is-active --quiet fail2ban.service; then
      fail 'preserve mode changed the service state'
    fi
    sha256sum -c "$TEST_TMP/config"
  done
  apt-get purge -y fail2ban
  (quick_fixture; main --skip-upgrade) >"$TEST_TMP/preserve" 2>&1
  grep -F '保留现状（未安装）' "$TEST_TMP/preserve"
  if fail2ban_package_installed; then fail 'preserve mode installed Fail2ban'; fi
  exit 0
fi

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
    ensure_system_dns() { record dns-precheck; }
    wait_for_package_manager() { record wait-apt; }
    apt_get() {
      record apt "$@"
      if [[ "$1" == install ]]; then touch "$TMP_DIR/packages-installed"; fi
    }
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
      if [[ "$scenario" == fresh && ! -f "$TMP_DIR/packages-installed" ]]; then return 1; fi
      case "$2" in
        "-f=\${Status}") printf 'install ok installed' ;;
        "-f=\${db:Status-Status}") printf 'installed' ;;
        *) fail 'unexpected dpkg query' ;;
      esac
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
        case "$scenario" in
          config-error) reason='Fail2ban 配置测试失败' ;;
          action-error) reason='Fail2ban 封禁动作验证失败' ;;
          no-backend) reason='UFW 未启用，nftables 也无法写入规则' ;;
        esac
        expect_bash_failure "$reason" 'trap rollback_fail2ban EXIT; main --fail2ban-only'
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
      # The system DNS check runs lazily, only when packages must be installed, and before APT.
      [[ "$(grep -nE '^(dns-precheck|wait-apt|apt update)' "$TRACE" | head -3 | cut -d: -f2 | paste -sd,)" == 'dns-precheck,wait-apt,apt update' ]]
      grep -Fxq 'systemctl mask --runtime fail2ban.service' "$TRACE"
      grep -Fxq 'systemctl unmask --runtime fail2ban.service' "$TRACE"
    elif grep -Eq '^(apt |dns-precheck)' "$TRACE"; then
      fail 'already-installed packages triggered APT or the DNS precheck'
    fi
    cmp "$TMP_DIR/jail.local" "$FAIL2BAN_DIR/jail.local"
    cmp "$TMP_DIR/local-owner.local" "$FAIL2BAN_DIR/jail.d/local-owner.local"
    [[ ! -e "$TMP_DIR/ban" ]] || fail 'test ban was left behind'
  )
done

for scenario in quick-ok missing-package apt-error inactive disabled no-pong missing-jail preserve absent-cli; do
  (
    quick_fixture
    menu_ssh=2 menu_network=2 expected_port=53651 expected_network=ipv4 expected_preserve=false
    args=(--skip-upgrade)
    if [[ "$scenario" == quick-ok ]]; then args=(); fi
    if [[ "$scenario" == preserve ]]; then
      menu_ssh=4 expected_preserve=true
    elif [[ "$scenario" == absent-cli ]]; then
      args+=(--preserve-ssh)
      expected_preserve=true
    fi
    FAIL2BAN_DIR="$TEST_TMP/quick-$scenario"
    TRACE="$TEST_TMP/$scenario.trace"
    out="$TEST_TMP/$scenario.out"
    : >"$TRACE"
    ss() { :; }
    curl() { :; }
    sshd() { :; }
    ufw() { :; }
    sleep() { :; }
    wait_for_package_manager() { :; }
    make_mutable() { :; }
    apt-mark() { :; }
    dpkg-query() {
      [[ "${*: -1}" == fail2ban ]] || return 1
      case "$scenario" in missing-package|preserve|absent-cli) return 1 ;; esac
      printf 'installed'
    }
    apt_get() {
      record apt "$@"
      if [[ "$scenario" == apt-error && "$1" == install ]]; then
        # The real wrapper exits nonzero and the install must stop.
        return 100
      fi
    }
    systemctl() {
      record systemctl "$@"
      case "$*" in
        'is-active --quiet fail2ban.service') [[ "$scenario" != inactive ]] ;;
        'is-enabled --quiet fail2ban.service') [[ "$scenario" != disabled ]] ;;
        'enable fail2ban.service'|'restart fail2ban.service') : ;;
        *) fail 'unexpected service operation' ;;
      esac
    }
    fail2ban-client() {
      record fail2ban-client "$@"
      case "$*" in
        -t|'status sshd') : ;;
        ping) [[ "$scenario" != no-pong ]] ;;
        'status sshd-slow') [[ "$scenario" != missing-jail ]] ;;
        status) printf 'Jail list: sshd, sshd-slow\n' ;;
        *) fail 'unexpected client operation' ;;
      esac
    }
    expected=''
    case "$scenario" in
      missing-package) expected='dpkg 未确认 Fail2ban 已安装' ;;
      apt-error) expected='退出码 100' ;;
      inactive) expected='Fail2ban 服务未运行' ;;
      disabled) expected='Fail2ban 未设置为开机自启' ;;
      no-pong) expected='Fail2ban 未响应 fail2ban-client ping' ;;
      missing-jail) expected='Fail2ban Jail 未运行：sshd-slow' ;;
    esac
    result=0
    # Run the child as an ordinary command so Bash's ERR trap and errexit apply.
    set +e
    (set -Eeuo pipefail; trap 'on_error $LINENO' ERR; main "${args[@]}") >"$out" 2>&1
    result=$?
    set -e
    if [[ -n "$expected" ]]; then
      (( result != 0 )) || fail "$scenario unexpectedly succeeded"
      grep -Fq "$expected" "$out" || { cat "$out" >&2; fail "$scenario diagnostic missing"; }
      if grep -Fq 'VPS 初始化完成' "$out"; then fail 'failed run printed a successful final report'; fi
    else
      (( result == 0 )) || { cat "$out" >&2; fail "$scenario failed"; }
    fi
    if [[ "$expected_preserve" == true ]]; then
      grep -Fq '保留现状（未安装）' "$out"
      if grep -Eq '(^apt install .*[[:space:]]fail2ban[[:space:]]|^systemctl |^fail2ban-client )' "$TRACE"; then
        fail 'preserve mode attempted to install or configure Fail2ban'
      fi
    else
      grep -Eq '^apt install .*[[:space:]]fail2ban[[:space:]]' "$TRACE"
      if [[ "$scenario" == quick-ok ]]; then
        grep -Fxq 'apt full-upgrade -y' "$TRACE"
        grep -Fq 'sshd 和 sshd-slow 已验证' "$out"
      elif grep -Fq 'apt full-upgrade' "$TRACE"; then
        fail '--skip-upgrade ran full-upgrade'
      fi
    fi
  )
done

expect_bash_failure '只能选择一种独立运行模式' 'parse_args --fail2ban-only --smartdns-only'
help_output=$(bash "$TEST_DIR/../debian-init.sh" --help)
[[ "$help_output" == *--fail2ban-only* ]] || fail 'missing CLI help'

# A PTY exercises the real interactive menu on Linux CI.
if [[ "$(uname -s)" == Linux ]] && command -v script >/dev/null; then
  printf '6\n' | script -qec "bash -c 'source \"$TEST_DIR/../debian-init.sh\"; select_install_mode; echo \"selected=\$INSTALL_MODE\"'" /dev/null >"$TEST_TMP/menu"
  grep -Fq '6. 仅安装/更新 Fail2ban' "$TEST_TMP/menu"
  grep -Fq 'selected=fail2ban' "$TEST_TMP/menu"
fi
echo 'PASS: Fail2ban quick install, preserve mode, standalone backends, custom jails and rollback'
