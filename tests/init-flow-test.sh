#!/usr/bin/env bash
# shellcheck disable=SC2329,SC2034 # Mocks/state used through the sourced initializer.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
# Redirect menu presentation only; test doubles supply all terminal replies.
sed "s|/dev/tty|$work/tty|g" "$repo/debian-init.sh" >"$work/installer"
# shellcheck disable=SC1091
source "$work/installer"
trap - ERR HUP INT TERM
trap 'rm -rf -- "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

for scenario in port22 default custom-port preserve reuse missing-keygen existing-swap no-swap low-memory multi multi-cancel ipv6-guard cancel custom-full custom-base custom-remove cli base stray-comment stray-keep; do
  trace="$work/$scenario.trace"
  : >"$trace"
  set +e
  (
    set -Ee
    INSTALL_MODE=quick
    case "$scenario" in custom-full|custom-base|custom-remove) INSTALL_MODE=custom;; base) INSTALL_MODE='';; esac
    preflight() { :; }
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
      printf 'prompt %s\n' "$1" >>"$trace"
      case "$1" in
        *'请选择 SSH 端口'*)
          case "$scenario" in port22) printf -v "$2" 1;; custom-port) printf -v "$2" 3;; preserve|ipv6-guard) printf -v "$2" 4;; *) printf -v "$2" 2;; esac ;;
        '输入 SSH 端口: '|'SSH 端口 '*) printf -v "$2" 43210 ;;
        '保留 SSH 22/tcp'*) printf -v "$2" n ;;
        *'仅注释上述行'*) if [[ "$scenario" == stray-comment ]]; then printf -v "$2" 1; else printf -v "$2" ''; fi ;;
        *'请选择网络模式'*)
          case "$scenario" in ipv6-guard) printf -v "$2" 2;; custom-port) printf -v "$2" 3;; *) printf -v "$2" 1;; esac ;;
        'SSH key') printf -v "$2" fixture-key ;;
        '复用 key'*) printf -v "$2" y ;;
        '覆盖现有 SSH 分端口监听配置？'*)
          if [[ "$scenario" == multi-cancel ]]; then printf -v "$2" n; else printf -v "$2" y; fi ;;
        *'Swap'*'？'*) printf -v "$2" y ;;
        '请选择 [1-2]: ')
          if [[ "$scenario" == custom-base ]]; then printf -v "$2" 2; else printf -v "$2" 1; fi ;;
        '是否卸载 QEMU Guest Agent？ [y/N] ')
          if [[ "$scenario" == custom-remove ]]; then printf -v "$2" Y; else printf -v "$2" ''; fi ;;
        '确认以上配置并开始自动安装？'*)
          if grep -q '^execute ' "$trace"; then fail 'mutation before final confirmation'; fi
          [[ "$SSH_KEYS_TX" == false && "$SSH_TX" == false && "$UFW_TX" == false && "$DNS_TX" == false ]]
          if [[ "$scenario" == cancel ]]; then printf -v "$2" n; else printf -v "$2" y; fi ;;
        *) fail "unexpected question: $1" ;;
      esac
    }
    # Hermetic by default; the stray-* scenarios expose one unmanaged disable_ipv6 file.
    stray_file="$work/stray-$scenario.conf"
    printf '# vendor
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.all.accept_ra = 2
' >"$stray_file"
    sysctl_policy_files() { if [[ "$scenario" == stray-* ]]; then printf '%s
' "$stray_file"; fi; }
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
    remove_qemu_guest_agent() { execute remove-qemu-agent; }
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
    detect_network_stack() { NETWORK_STACK=ipv4; if [[ "$scenario" == stray-* ]]; then NETWORK_STACK=dual; fi; }
    install_and_configure_smartdns() { execute smartdns; }
    configure_system_dns() { execute dns; DNS_TX=false; }
    configure_ssh() { if [[ "$PRESERVE_SSH" == false ]]; then execute ssh; fi; }
    configure_ufw() { if [[ "$PRESERVE_SSH" == false ]]; then execute ufw; fi; }
    configure_cf8443() { :; }
    configure_fail2ban() { execute fail2ban; }
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
      stray-comment)
        [[ "$NETWORK_STACK" == dual ]]
        [[ "$(sed -n 2p "$stray_file")" == '# Disabled by vps-init.sh: net.ipv6.conf.all.disable_ipv6 = 1' ]]
        grep -Fxq 'net.ipv6.conf.all.disable_ipv6 = 1' "$BACKUP_DIR/files$stray_file" ;;
      stray-keep)
        [[ "$NETWORK_STACK" == ipv4 ]]
        grep -Fxq 'net.ipv6.conf.all.disable_ipv6 = 1' "$stray_file" ;;
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
    if grep -Eq '^execute (ssh|ufw|key|network|smartdns|singbox)$' "$trace"; then fail 'base-only changed components'; fi
  fi
  case "$scenario" in
    custom-full|custom-base|custom-remove)
      grep -Fxq 'prompt 是否卸载 QEMU Guest Agent？ [y/N] ' "$trace"
      ;;
    *)
      if grep -Fq 'prompt 是否卸载 QEMU Guest Agent？' "$trace"; then fail "$scenario asked about QEMU Guest Agent"; fi
      ;;
  esac
  case "$scenario" in
    custom-full|custom-base|base|multi-cancel|ipv6-guard|cancel)
      if grep -Fxq 'execute remove-qemu-agent' "$trace"; then fail "$scenario removed QEMU Guest Agent"; fi
      ;;
    *)
      grep -Fxq 'execute remove-qemu-agent' "$trace"
      grep -Fxq 'QEMU Guest Agent：已安装则卸载' "$work/$scenario.output"
      ;;
  esac
done
grep -Fxq 'QEMU Guest Agent：保留' "$work/custom-full.output"
for scenario in stray-comment stray-keep; do
  grep -Fq '重启后 IPv6：发现 1 行' "$work/$scenario.output" || fail "$scenario summary lacks the reboot-state line"
  grep -Fq 'disable_ipv6 = 1' "$work/$scenario.output" || fail "$scenario did not list the offending line"
  # The choice is asked after the network menu and before the single confirmation.
  awk '/请选择网络模式/ {n=NR} /仅注释上述行/ {s=NR} /确认以上配置/ {c=NR} END {exit !(n && s && c && n < s && s < c)}' "$work/$scenario.trace" ||
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
if (CONFIG_CONFIRMED=true; read_tty 'unexpected' response); then fail 'accepted execution-stage prompt'; fi
echo 'PASS: early configuration, SSH menus, key reuse/dependency, safety, Swap, confirmation, custom and CLI'
