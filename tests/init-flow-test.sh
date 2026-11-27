#!/usr/bin/env bash
# shellcheck disable=SC2329,SC2034 # Mocks/state used through the sourced initializer.
set -Eeuo pipefail
# shellcheck source=tests/process-helper.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/process-helper.sh"
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
# Redirect menu presentation only; test doubles supply all terminal replies.
# Policy files the flow may read or write stay inside the work directory.
sed -e "s|/dev/tty|$work/tty|g" \
  -e "s|^readonly NETWORK_SYSCTL=.*|readonly NETWORK_SYSCTL='$work/network.conf'|" \
  -e "s|^readonly LEGACY_IPV6_SYSCTL=.*|readonly LEGACY_IPV6_SYSCTL='$work/legacy.conf'|" \
  -e "s|^readonly LEGACY_NETWORK_UNIT=.*|readonly LEGACY_NETWORK_UNIT='$work/legacy.service'|" \
  -e "s|^readonly IPV4_POLICY_HELPER=.*|readonly IPV4_POLICY_HELPER='$work/ipv4-helper'|" \
  -e "s|^readonly IPV4_POLICY_SERVICE=.*|readonly IPV4_POLICY_SERVICE='$work/ipv4.service'|" \
  -e "s|^readonly IPV4_POLICY_TIMER=.*|readonly IPV4_POLICY_TIMER='$work/ipv4.timer'|" \
  -e "s|^readonly IPV4_POLICY_IFUP=.*|readonly IPV4_POLICY_IFUP='$work/ipv4-ifup'|" \
  "$repo/debian-init.sh" >"$work/installer"
# shellcheck disable=SC1091
source "$work/installer"
trap - ERR HUP INT TERM
trap 'rm -rf -- "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
# Verify the process helper preserves errexit even when called by an `if`.
# shellcheck disable=SC2329 # Invoked in the isolated fixture.
errexit_probe() { echo 'errexit probe'; false; echo 'unexpected continuation'; }
expect_bash_failure 'errexit probe' errexit_probe

for scenario in port22 default custom-port preserve reuse missing-keygen existing-swap no-swap low-memory multi multi-cancel ipv6-guard cancel custom-full custom-base custom-remove cli base ipv6-restore ipv6-keep; do
  trace="$work/$scenario.trace"
  : >"$trace"
  : >"$work/tty"
  set +e
  (
    set -Ee
    INSTALL_MODE=quick
    case "$scenario" in custom-full|custom-base|custom-remove) INSTALL_MODE=custom;; base) INSTALL_MODE='';; esac
    preflight() { :; }
    ensure_system_dns() { :; }
    acquire_lock() { :; }
    command() {
      if [[ "$1" == -v && "$2" == ss ]]; then return 0; fi
      if [[ "$1" == -v && "$2" == ssh-keygen ]]; then
        [[ "$scenario" != missing-keygen || -e "$work/keygen-installed" ]]; return
      fi
      builtin command "$@"
    }
    wait_for_package_manager() { :; }
    apt_get() {
      local IFS=' '
      case "$*" in
        update) echo minimal-update >>"$trace" ;;
        'install -y --no-install-recommends openssh-client') touch "$work/keygen-installed"; echo minimal-keygen >>"$trace" ;;
        *) fail 'unexpected APT before final confirmation' ;;
      esac
    }
    read_tty() {
      [[ "$CONFIG_CONFIRMED" == false ]] || fail "late prompt: $1"
      # The menu box printed just before this prompt; cleared so each prompt sees only its own menu.
      shown_menu=$(<"$work/tty")
      : >"$work/tty"
      printf 'prompt %s\n' "$1" >>"$trace"
      case "$1" in
        *'请选择 SSH 端口'*)
          case "$scenario" in port22) printf -v "$2" 1;; custom-port) printf -v "$2" 3;; preserve|ipv6-guard) printf -v "$2" 4;; *) printf -v "$2" 2;; esac ;;
        '输入 SSH 端口: '|'SSH 端口 '*) printf -v "$2" 43210 ;;
        '保留 SSH 22/tcp'*) printf -v "$2" n ;;
        *'恢复 IPv6'*) if [[ "$scenario" == ipv6-restore ]]; then printf -v "$2" 1; else printf -v "$2" ''; fi ;;
        *'请选择网络模式'*)
          case "$scenario" in ipv6-guard) printf -v "$2" 2;; custom-port) printf -v "$2" 3;; *) printf -v "$2" 1;; esac ;;
        'SSH key') printf -v "$2" fixture-key ;;
        '复用 key'*) printf -v "$2" y ;;
        '覆盖现有 SSH 分端口监听配置？'*)
          if [[ "$scenario" == multi-cancel ]]; then printf -v "$2" n; else printf -v "$2" y; fi ;;
        *'Swap'*'？'*) printf -v "$2" y ;;
        '请选择 [1-2]: ')
          if [[ "$scenario" == ipv6-* ]]; then
            [[ "$shown_menu" == *'重启后 IPv6'* && "$shown_menu" == *'恢复 IPv6'* ]] || fail 'missing IPv6 boot policy menu'
            printf 'prompt 恢复 IPv6\n' >>"$trace"
            if [[ "$scenario" == ipv6-restore ]]; then printf -v "$2" 1; else printf -v "$2" ''; fi
          elif [[ "$scenario" == custom-base ]]; then printf -v "$2" 2
          else printf -v "$2" 1; fi ;;
        '是否开启 Debian 自动安全更新？ [Y/n] ') printf -v "$2" '' ;;
        '确认以上配置并开始自动安装？'*)
          if grep -q '^execute ' "$trace"; then fail 'mutation before final confirmation'; fi
          [[ "$SSH_KEYS_TX" == false && "$SSH_TX" == false && "$UFW_TX" == false && "$DNS_TX" == false ]]
          if [[ "$scenario" == cancel ]]; then printf -v "$2" n; else printf -v "$2" ''; fi ;;
        *) fail "unexpected question: $1" ;;
      esac
    }
    # Hermetic by default. The ipv6-* scenarios model a boot-time disable_ipv6=1 that the
    # script's own override file (all = 0) beats, as systemd-sysctl would decide.
    ipv6_boot_state() {
      if [[ "$scenario" == ipv6-* ]]; then
        if [[ -f "$NETWORK_SYSCTL" ]] && grep -Fxq 'net.ipv6.conf.all.disable_ipv6 = 0' "$NETWORK_SYSCTL"; then echo on; else echo off; fi
      else
        echo on
      fi
    }
    ipv6_boot_disable_lines() { echo '/usr/lib/sysctl.d/50-fixture.conf: net.ipv6.conf.all.disable_ipv6 = 1'; }
    rm -f -- "$NETWORK_SYSCTL"
    ipv6_probe_keys() { :; }
    sysctl() { :; }
    sleep() { :; }
    tty_available() { return 0; }
    # Directory creation only (make_mutable backups); avoids host-specific chmod behavior.
    install() { [[ "$1" == -d ]] && mkdir -p -- "${@: -1}"; }
    lsattr() { :; }
    chattr() { :; }
    BACKUP_DIR="$work/backup-$scenario"
    TMP_DIR="$work/tmp-$scenario"
    mkdir -p "$BACKUP_DIR" "$TMP_DIR"
    ssh_port_available() { :; }
    check_ssh_change_prerequisites() { echo safety-check >>"$trace"; }
    ssh_listener_addresses() {
      if [[ "$scenario" == multi || "$scenario" == multi-cancel ]]; then
        printf '0.0.0.0:22\n[::]:53651\n'
      else echo '0.0.0.0:22'; fi
    }
    collect_public_key() {
      local candidate=''
      [[ "$CONFIG_CONFIRMED" == false && "$PRESERVE_SSH" == false ]]
      if [[ "$scenario" == reuse ]]; then
        ask_yes_no '复用 key' true
        REUSE_PUBLIC_KEY=true
      elif [[ -z "$PUBKEY_ARGUMENT" ]]; then
        read_tty 'SSH key' candidate
      fi
      echo key-validated >>"$trace"
    }
    recommend_swap() {
      SWAP_RECOMMENDED_MIB=0
      if [[ "$scenario" == low-memory ]]; then SWAP_RECOMMENDED_MIB=1024; fi
      echo swap-inspected >>"$trace"
    }
    mem_total_kib() { echo 524288; }
    swap_total_mib() { if [[ "$scenario" == existing-swap ]]; then echo 1024; else echo 0; fi; }
    execute() { [[ "$CONFIG_CONFIRMED" == true ]] || fail "early mutation $1"; echo "execute $1" >>"$trace"; }
    remove_qemu_guest_agent() { fail "initialization removed QGA"; }
    configure_security_updates() { execute security-updates; }
    record_trusted_keys() { execute trusted-keys; }
    check_boot_services() { execute boot-check; }
    create_swap() { [[ "$1" == 1024 ]]; execute swap; }
    install_early_dependencies() { execute dependencies; }
    install_authorized_key() { execute key; }
    update_system_and_tools() { execute "update-upgrade=$DO_FULL_UPGRADE"; }
    ipv4_https_works() { :; }
    configure_chrony() { execute chrony; }
    configure_tcp_tuning() { execute tuning; }
    install_sing_box() { execute singbox; }
    backup_dns_state() { execute backup-dns; }
    apply_network_stack() { execute network; }
    cleanup_legacy_network_stack() { :; }
    detect_network_stack() { NETWORK_STACK=ipv4; if [[ "$scenario" == ipv6-* ]]; then NETWORK_STACK=dual; fi; }
    install_and_configure_smartdns() { execute smartdns; }
    configure_system_dns() { execute dns; DNS_TX=false; }
    configure_ssh() { if [[ "$PRESERVE_SSH" == false ]]; then execute ssh; fi; }
    configure_ufw() { if [[ "$PRESERVE_SSH" == false ]]; then execute ufw; fi; }
    configure_cf8443() { :; }
    configure_fail2ban() { execute fail2ban; }
    remove_legacy_network_stack_state() { execute legacy-state; }
    run_safe_cleanup() { execute cleanup; }
    print_report() { execute report; }
    if [[ "$scenario" == ipv6-guard ]]; then SSH_CONNECTION='2001:db8::1 12345 2001:db8::2 22'; else unset SSH_CONNECTION; fi
    args=()
    case "$scenario" in
      cli) args=(--ssh-port 43210 --network-stack dual --pubkey fixture --skip-upgrade) ;;
      base) args=(--base-only --skip-upgrade) ;;
    esac
    main "${args[@]}"
    case "$scenario" in
      port22) [[ "$SSH_PORT" == 22 ]] ;;
      default) [[ "$SSH_PORT" == 53651 && "$KEEP_SSH_22" == false ]] ;;
      custom-port|cli) [[ "$SSH_PORT" == 43210 && "$NETWORK_REQUEST" == dual ]] ;;
      preserve) [[ "$PRESERVE_SSH" == true ]]; if grep -Eq 'key-validated|execute (ssh|ufw|key|fail2ban)$' "$trace"; then fail 'preserve mode changed access'; fi ;;
      reuse) [[ "$REUSE_PUBLIC_KEY" == true ]] ;;
      low-memory) grep -Fxq 'execute swap' "$trace" ;;
      ipv6-restore)
        [[ "$NETWORK_STACK" == dual ]]
        grep -Fxq 'net.ipv6.conf.all.disable_ipv6 = 0' "$NETWORK_SYSCTL"
        grep -Fxq 'net.ipv6.conf.default.disable_ipv6 = 0' "$NETWORK_SYSCTL"
        [[ "$IPV6_BOOT_RESULT" == 已恢复 && "$IPV6_PROBE_RESULT" == dual ]] ;;
      ipv6-keep)
        [[ "$NETWORK_STACK" == ipv4 ]]
        [[ ! -e "$NETWORK_SYSCTL" ]]
        [[ "$IPV6_BOOT_RESULT" == 仍禁用 && "$IPV6_PROBE_RESULT" == dual ]] ;;
    esac
  ) >"$work/$scenario.output" 2>&1
  result=$?
  set -e
  case "$scenario" in
    multi-cancel|ipv6-guard|cancel)
      (( result != 0 )) || fail "$scenario accepted"
      if grep -q '^execute ' "$trace"; then fail "$scenario modified system"; fi ;;
    *)
      if (( result )); then cat "$work/$scenario.output"; fail "$scenario failed"; fi
      case "$scenario" in
        cli|base) grep -Fxq 'execute update-upgrade=false' "$trace" ;;
        *) grep -Fxq 'execute update-upgrade=true' "$trace" ;;
      esac ;;
  esac
  if [[ "$scenario" == custom-base || "$scenario" == base ]]; then
    if grep -Eq '^execute (ssh|ufw|key|network|smartdns|singbox|cleanup|legacy-state)$' "$trace"; then fail 'base-only changed components'; fi
  fi
  case "$scenario" in
    base|custom-base|multi-cancel|ipv6-guard|cancel) ;;
    *)
      grep -Fxq 'execute cleanup' "$trace"
      [[ "$(tail -n 4 "$trace")" == $'execute legacy-state\nexecute cleanup\nexecute boot-check\nexecute report' ]] || fail 'legacy-state, cleanup, boot check, report order'
      ;;
  esac
  if grep -Fq 'prompt 是否卸载 QEMU Guest Agent？' "$trace"; then fail "$scenario asked about QGA"; fi
  if grep -Fxq 'execute remove-qemu-agent' "$trace"; then fail "$scenario removed QGA"; fi
done

for scenario in ipv6-restore ipv6-keep; do
  grep -Fq '重启后 IPv6：将被现有配置关闭' "$work/$scenario.output" || fail "$scenario summary lacks the reboot-state line"
  grep -Fq '50-fixture.conf: net.ipv6.conf.all.disable_ipv6 = 1' "$work/$scenario.output" || fail "$scenario did not list the offending line"
  # The choice is asked after the network menu and before the single confirmation.
  awk '/请选择网络模式/ {n=NR} /恢复 IPv6/ {s=NR} /确认以上配置/ {c=NR} END {exit !(n && s && c && n < s && s < c)}' "$work/$scenario.trace" ||
    fail "$scenario prompt order"
done
grep -Fxq minimal-keygen "$work/missing-keygen.trace"
if (
  check_ssh_change_prerequisites() { :; }
  ssh_listener_addresses() { echo '0.0.0.0:45670'; }
  backup_ssh_state() { fail 'changed listeners reached SSH mutation'; }
  SSH_LISTENERS_CONFIRMED=true SSH_CONFIRMED_LISTENERS='0.0.0.0:22'
  configure_ssh
); then fail 'accepted listeners changed after confirmation'; fi
# Enter at the split-listener prompt has no default: it asks again, and only n cancels.
# shellcheck disable=SC2016 # Evaluated inside the isolated fixture.
expect_bash_failure '已取消 SSH 切换' 'ssh_listener_addresses() { printf "0.0.0.0:22\n[::]:2222\n"; }; asks=0; read_tty() { [[ "$1" == *" [y/n] " ]] || fail "not [y/n]: $1"; asks=$((asks + 1)); if (( asks == 1 )); then printf -v "$2" ""; else grep -Fq "请输入 y 确认，或 n 跳过/取消（Ctrl+C 退出）" "$work/tty" || fail "no re-ask hint"; printf -v "$2" n; fi; }; confirm_ssh_listener_change'

# ask_yes_no default=false: Enter, blanks and other words ask again; y/yes/n/no in any case answer.
# shellcheck disable=SC2016 # Evaluated inside the isolated fixture.
yes_no_case() {
  local expected=$1 replies=$2
  run_in_bash "
    replies=($replies) asks=0
    read_tty() { printf -v \"\$2\" '%s' \"\${replies[asks]}\"; asks=\$((asks + 1)); printf '%s\n' \"\$1\" >>\"\$work/yes-no.prompts\"; }
    : >\"\$work/yes-no.prompts\"
    if ask_yes_no '确认删除 fixture？' false; then rc=0; else rc=1; fi
    [[ \$rc == $expected ]] || fail \"ask_yes_no [$replies] returned \$rc\"
    [[ \$asks == \${#replies[@]} ]] || fail \"ask_yes_no [$replies] asked \$asks times\"
    [[ \$(sort -u \"\$work/yes-no.prompts\") == '确认删除 fixture？ [y/n] ' ]] || fail 'prompt text'
  " || fail "yes/no case [$replies]"
}
yes_no_case 1 "'' n"
yes_no_case 0 "'' y"
yes_no_case 0 "'   ' maybe ' YES '"
yes_no_case 1 "'是' 'N '"
yes_no_case 1 "No"
# The re-ask hint goes to the terminal after a non-answer.
: >"$work/tty"
yes_no_case 1 "'' n"
grep -Fxq '请输入 y 确认，或 n 跳过/取消（Ctrl+C 退出）' "$work/tty" || fail 'default=false re-ask hint'
# default=true is unchanged: Enter means yes.
# shellcheck disable=SC2016 # Evaluated inside the isolated fixture.
run_in_bash 'read_tty() { [[ "$1" == "保留？ [Y/n] " ]] || fail "prompt: $1"; printf -v "$2" ""; }; ask_yes_no "保留？" true' || fail '[Y/n] Enter is not yes'
# default=true also compares without surrounding blanks: blanks only mean yes.
yes_no_true_case() {
  local expected=$1 replies=$2
  run_in_bash "
    replies=($replies) asks=0
    read_tty() { printf -v \"\$2\" '%s' \"\${replies[asks]}\"; asks=\$((asks + 1)); }
    if ask_yes_no '保留？' true; then rc=0; else rc=1; fi
    [[ \$rc == $expected && \$asks == \${#replies[@]} ]] || fail \"[Y/n] [$replies] returned \$rc after \$asks asks\"
  " || fail "[Y/n] case [$replies]"
}
yes_no_true_case 0 "'   '"
yes_no_true_case 1 "' n '"
yes_no_true_case 0 "' YES '"
yes_no_true_case 1 "maybe ' No '"
# End of input dies instead of asking forever: the real read_tty reads the (exhausted) terminal file.
# shellcheck disable=SC2016 # Evaluated inside the isolated fixture.
expect_bash_failure '读取交互输入失败' ': >"$work/tty"; CONFIG_CONFIRMED=false; ask_yes_no "确认删除 fixture？" false'
# shellcheck disable=SC2016 # Evaluated inside the isolated fixture.
expect_bash_failure '需要交互输入，但当前没有可用' 'rm -f -- "$work/tty"; CONFIG_CONFIRMED=false; ask_yes_no "确认删除 fixture？" false'
: >"$work/tty"
expect_bash_failure '执行阶段出现未预收集的交互' 'CONFIG_CONFIRMED=true; read_tty unexpected response'
# shellcheck disable=SC2016 # Evaluated inside the isolated fixture.
expect_bash_failure '需要交互输入，但当前没有可用' 'rm -f -- "$work/tty"; CONFIG_CONFIRMED=false; ask_yes_no "确认以上配置并开始自动安装？" true'
echo 'PASS: early configuration, SSH menus, key reuse/dependency, safety, Swap, confirmation, custom and CLI'
