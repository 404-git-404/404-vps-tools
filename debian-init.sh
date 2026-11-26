#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export LC_ALL=C

readonly DEFAULT_SSH_PORT='53651'
readonly APT_WAIT_MAX="${VPS_INIT_APT_WAIT:-1800}"
readonly LOCK_FILE='/run/lock/vps-init.lock'
readonly BACKUP_ROOT='/root/vps-init-backups'
readonly SSH_MAIN='/etc/ssh/sshd_config'
readonly SSH_DIR='/etc/ssh/sshd_config.d'
readonly SSH_DROPIN='/etc/ssh/sshd_config.d/00-vps-init.conf'
readonly AUTHORIZED_KEYS='/root/.ssh/authorized_keys'
readonly UFW_DEFAULT='/etc/default/ufw'
readonly UFW_RULES='/etc/ufw/user.rules'
readonly UFW_RULES6='/etc/ufw/user6.rules'
readonly NETWORK_SYSCTL='/etc/sysctl.d/99-vps-init-network.conf'
readonly IPV4_POLICY_HELPER='/usr/local/libexec/vps-init-ipv4-only'
readonly IPV4_POLICY_SERVICE='/etc/systemd/system/vps-init-ipv4-only.service'
readonly IPV4_POLICY_TIMER='/etc/systemd/system/vps-init-ipv4-only.timer'
readonly IPV4_POLICY_IFUP='/etc/network/if-pre-up.d/vps-init-ipv4-only'
readonly -a IPV4_POLICY_FILES=("$IPV4_POLICY_HELPER" "$IPV4_POLICY_SERVICE" "$IPV4_POLICY_TIMER" "$IPV4_POLICY_IFUP")
readonly TCP_SYSCTL='/etc/sysctl.d/99-vps-init-tcp.conf'
readonly NETWORK_STACK_STATE='/var/lib/404-vps-tools/network-stack'
readonly BBR_MODULES='/etc/modules-load.d/vps-init-bbr.conf'
readonly TRUSTED_KEYS_STATE='/var/lib/404-vps-tools/trusted-key-fingerprints'
readonly SECURITY_APT_CONF='/etc/apt/apt.conf.d/zzzz-404-security'
AUTO_SECURITY=true
BOOT_REPORT='未检查'
declare -a AUDIT_FINDINGS=()
HARDENING_KEY_DELETED=false
HARDENING_MAIL_PURGED=false
AUDIT_SESSION_KEY=''
AUDIT_APT_SOURCES=''
readonly SMARTDNS_CONF='/etc/smartdns/smartdns.conf'
readonly SMARTDNS_CACHE='/var/cache/smartdns/smartdns.cache'
readonly SMARTDNS_APT_PIN='/etc/apt/preferences.d/vps-init-smartdns'
readonly SMARTDNS_RELEASE='Release48.4'
readonly SMARTDNS_VERSION='1.2026.08.05-0921'
readonly SMARTDNS_DEB_VERSION='2026.08.05-0921'
FAIL2BAN_DIR='/etc/fail2ban'
readonly SAGER_KEY_FINGERPRINT='2C317FBD5D886B4E89BAE8DA6D9152172A2B2F0C'
readonly SINGBOX_CONFIG='/etc/sing-box/config.json'
readonly SINGBOX_DROPIN_DIR='/etc/systemd/system/sing-box.service.d'
readonly SINGBOX_DROPIN='/etc/systemd/system/sing-box.service.d/10-vps-init-config-gate.conf'
readonly SINGBOX_MANAGED_MARKER='/var/lib/vps-init/sing-box-managed'
readonly CF_TOOL='/usr/local/sbin/vps-init-cloudflare-8443'
readonly CF_SERVICE='/etc/systemd/system/vps-init-cloudflare-8443.service'
readonly CF_TIMER='/etc/systemd/system/vps-init-cloudflare-8443.timer'
readonly SWAPFILE='/swapfile-vps-init'
readonly SWAP_FSTAB='/etc/fstab'
readonly SWAP_RESERVE_KIB=$((1024 * 1024))
readonly MIN_ROOT_FREE_KIB=$((2 * 1024 * 1024))
readonly LEGACY_NETWORK_UNIT='/etc/systemd/system/404-network-stack.service'
readonly LEGACY_NETWORK_HELPER='/usr/local/libexec/404-network-stack'
readonly LEGACY_IPV6_SYSCTL='/etc/sysctl.d/99-disable-ipv6.conf'
readonly FALLBACK_DNS='1.1.1.1'
readonly DNS_PROBE_HOST='deb.debian.org'
# Second line of the network sysctl file written when the user chooses to restore IPv6.
readonly AUTO_RESTORE_MARK='# IPv6 restored by Auto: overrides unmanaged disable_ipv6 settings'

CURRENT_STEP='启动'
TMP_DIR=''
BACKUP_DIR=''
SSH_PORT="$DEFAULT_SSH_PORT"
KEEP_SSH_22=true
DO_FULL_UPGRADE=true
SSH_PORT_SET=false
KEEP_SSH_22_SET=false
PRESERVE_SSH=false
declare -a SSH_TEMP_HOLDS=()
declare -a UPDATE_TEMP_HOLDS=()
CONFIG_CONFIRMED=false
SWAP_CHOICE_COLLECTED=false
SWAP_CONFIRMED_MIB=0
SSH_LISTENERS_CONFIRMED=false
SSH_CONFIRMED_LISTENERS=''
REUSED_KEY_FINGERPRINTS=''
SSH_KEYS_TX=false
SSH_KEY_DIR_STATE=''
BASE_ONLY=false
INSTALL_MODE=''
SINGBOX_RUNTIME_MASK=false
NETWORK_REQUEST='auto'
NETWORK_REQUEST_SET=false
NETWORK_STACK='unknown'
SAFE_CLEANUP_RESULT='未执行'
IPV6_BOOT_STATE='unknown'
IPV6_RESTORE_CHOICE=''
IPV6_BOOT_RESULT=''
IPV6_RESTORED=false
IPV6_WRITTEN_UNVERIFIED=false
IPV6_FORCE_IPV4=false
IPV6_PROBE_RESULT=''
IPV6_OLD_ALL=''
SING_BOX_VERSION=''
PUBKEY_ARGUMENT=''
PUBKEY_FILE=''
PUBLIC_KEY=''
REUSE_PUBLIC_KEY=false
CF8443_MODE='auto' # auto = fresh install off; existing managed install preserved
CONTAINER_KIND='none'
SSH_TX=false
SSH_RELOAD_ATTEMPTED=false
DNS_TX=false
UFW_TX=false
FAIL2BAN_TX=false
FAIL2BAN_SERVICE_CHANGED=false
FAIL2BAN_RUNTIME_MASK=false
FAIL2BAN_OLD_ACTIVE=false
FAIL2BAN_OLD_ENABLED=false
FAIL2BAN_PROBE_JAIL=''
FAIL2BAN_PROBE_IP=''
UFW_OLD_ACTIVE=false
SMARTDNS_OLD_ACTIVE=false
SMARTDNS_OLD_ENABLED=false
SMARTDNS_DID_INSTALL=false
SMARTDNS_TRANSPORT='unknown'
RESOLVED_OLD_ACTIVE=false
RESOLVED_OLD_ENABLED=false
SINGBOX_WAS_INSTALLED=false
SINGBOX_CONFIG_PREEXISTED=false
SINGBOX_WAS_MANAGED=false
SWAP_RECOMMENDED_MIB=0
SWAP_REUSE_FILE=false
SWAPFILE_SNAPSHOT=''
PERSIST_RESOLV_IMMUTABLE=false
RESOLV_WRITTEN_SHA=''
EARLY_DNS_FIXED=false
EARLY_DNS_BACKUP=''
IPV6_OLD_DEFAULT=''
declare -A IPV6_OLD_INTERFACES=()
NETWORK_POLICY_CHANGED=false
IPV4_TIMER_WAS_ENABLED=false
IPV4_TIMER_WAS_ACTIVE=false
IPV4_POLICY_STATUS='未核验'
LEGACY_NETWORK_CHANGED=false
LEGACY_NETWORK_WAS_ACTIVE=false
LEGACY_NETWORK_WAS_ENABLED=false

# Files whose i/a attributes were temporarily cleared. Values are original lsattr flags.
declare -A ORIGINAL_ATTRS=()
declare -a IPV6_PROBE_CHANGED=()
declare -a IPV6_BOOT_LINES=()
declare -a FAIL2BAN_MANAGED_FILES=(
  jail.d/00-vps-init-defaults.local
  jail.d/vps-init-sshd.local
  filter.d/vps-init-sing-box-reality.conf
  jail.d/vps-init-sing-box-reality.local
)

log()  { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
用法：
  bash debian-init.sh
  bash debian-init.sh [选项]

交互菜单：1 快速初始化、2 自定义初始化、3 SmartDNS、4 sing-box 节点、5 Fail2ban、6 系统更新、7 清理、8 安全加固、0 退出（9 预留）。
仅部署 sing-box 独立运行节点配置向导；完整初始化只安装 sing-box，不创建节点。

默认流程：
  - Debian 12/13 amd64/arm64
  - 开始前收集 SSH、网络、公钥、安全确认和 Swap，显示摘要并统一确认
  - 快速/自定义安装默认 apt update 和 full-upgrade -y；--skip-upgrade 可跳过升级
  - SSH 公钥提示可直接回车，查看指纹并确认复用已有公钥
  - 低内存且无合适 Swap 时才询问是否创建推荐 Swap
  - 快速安装默认只监听 SSH 53651，可改选 22 或自定义单端口
  - Auto 探测当前 IPv6 连通性，只得出 ipv4 或 dual，永远不主动禁用 IPv6
  - Auto 在确认前用 systemd-sysctl 计算重启后 IPv6 是否被关闭；可写入脚本自己的覆盖文件恢复，或保留并按 ipv4 处理
  - 仅显式选择 ipv4 才持久禁用 IPv6，dual 则显式启用
  - SmartDNS 仅监听 127.0.0.1:53（UDP+TCP）；优先 DoH（H2），失败自动回退 UDP/TCP 53
  - /etc/resolv.conf 使用 127.0.0.1，备用 1.1.1.1，SmartDNS 异常时系统仍可解析
  - 443/tcp + 443/udp 默认开放
  - Cloudflare 8443 默认不启用，使用 --cloudflare-8443 显式启用

选项：
  --pubkey "KEY"             预先提供 SSH 公钥，跳过复用询问
  --pubkey-file FILE         从文件读取 SSH 公钥，跳过复用询问
  --ssh-port PORT            指定 SSH 端口并跳过端口菜单（默认 53651）
  --keep-22                  兼容旧部署，为非 22 的 SSH 端口保留 22 备用
  --close-22                 仅使用所选 SSH 端口（快速安装默认）
  --preserve-ssh             保留现有 SSH 监听、认证及 UFW，跳过公钥和端口配置
  --full-upgrade             执行 full-upgrade（默认）
  --skip-upgrade             仅 apt update，不执行 full-upgrade
  --sing-box-version VER     指定 sing-box 版本；未指定时已安装版本不会被重跑升级
  --network-stack MODE       auto、ipv4、dual（默认 auto），显式参数跳过网络菜单
                             ipv4 持久禁用各接口 IPv6，保留原始网络配置
  --cloudflare-8443          启用 Cloudflare-only 8443/tcp + 每日刷新
  --no-cloudflare-8443       删除本脚本管理的 Cloudflare 8443 规则/定时器
  --base-only                只完成系统更新和基础工具安装
  --smartdns-only            仅安装/更新 SmartDNS 并验证系统 DNS
  --sing-box-only            仅安装 sing-box 并进入节点配置向导
  --fail2ban-only            仅安装/更新 Fail2ban 并验证 Jail
  --cleanup-only             系统清理，删除软件包和旧内核需分别确认
  --update-only              仅系统更新，保留 sing-box/SmartDNS hold，不安装初始化工具
  --audit                    只读体检，完整报告输出到终端，不创建备份、锁或临时文件
  --help                     显示帮助
EOF
}

read_tty() {
  local prompt=$1 var=$2
  [[ "$CONFIG_CONFIRMED" == false ]] || die "执行阶段出现未预收集的交互：$prompt"
  [[ -r /dev/tty && -w /dev/tty ]] || die '需要交互输入，但当前没有可用 /dev/tty。'
  printf '%s' "$prompt" >/dev/tty
  IFS= read -r "${var?}" </dev/tty || die '读取交互输入失败。'
}

ask_yes_no() {
  local prompt=$1 default=$2 answer=''
  while true; do
    if [[ "$default" == true ]]; then
      read_tty "$prompt [Y/n] " answer
      answer=${answer:-Y}
    else
      read_tty "$prompt [y/N] " answer
      answer=${answer:-N}
    fi
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) printf '请输入 y 或 n。\n' >/dev/tty ;;
    esac
  done
}

restore_attrs() {
  local path flags
  for path in "${!ORIGINAL_ATTRS[@]}"; do
    [[ -e "$path" || -L "$path" ]] || continue
    if [[ "$path" == /etc/resolv.conf && "$PERSIST_RESOLV_IMMUTABLE" == true && "$DNS_TX" == false ]]; then
      continue
    fi
    flags=${ORIGINAL_ATTRS[$path]}
    command -v chattr >/dev/null 2>&1 || continue
    chattr -i -a -- "$path" 2>/dev/null || true
    if [[ "$flags" == *i* ]]; then chattr +i -- "$path" 2>/dev/null || true; fi
    if [[ "$flags" == *a* ]]; then chattr +a -- "$path" 2>/dev/null || true; fi
  done
}

reject_symlink() {
  local path=$1
  [[ ! -L "$path" ]] || die "$path 不能是符号链接。"
}

# Create a missing directory (and missing parents) as 0755 despite the 077 umask.
# Existing directories are left exactly as they are.
ensure_dir() {
  local dir=$1 parent
  [[ ! -d "$dir" ]] || return 0
  parent=${dir%/*}
  if [[ -n "$parent" && "$parent" != "$dir" ]]; then ensure_dir "$parent"; fi
  install -d -m 0755 -- "$dir"
}

make_mutable() {
  local path=$1 out flags
  [[ -e "$path" && ! -L "$path" ]] || return 0
  if [[ -n "$BACKUP_DIR" ]]; then
    local backup="$BACKUP_DIR/files$path"
    if [[ ! -e "$backup" && ! -L "$backup" ]]; then
      install -d -m 0700 "$(dirname "$backup")"
      cp -a -- "$path" "$backup"
    fi
  fi
  command -v lsattr >/dev/null 2>&1 || return 0
  command -v chattr >/dev/null 2>&1 || return 0
  out=$(lsattr -d -- "$path" 2>/dev/null || true)
  flags=${out%% *}
  if [[ -z "${ORIGINAL_ATTRS[$path]+x}" ]]; then
    ORIGINAL_ATTRS["$path"]=$flags
  fi
  if [[ "$flags" == *i* || "$flags" == *a* ]]; then
    log "临时解除文件属性 i/a：$path"
    chattr -i -a -- "$path" || die "无法解除 $path 的 immutable/append-only 属性。"
  fi
}

cleanup() {
  local rc=$?
  set +e
  restore_update_package_holds
  restore_ssh_package_holds
  restore_ipv6_probe_state || true
  rollback_fail2ban || true
  if [[ "$SINGBOX_RUNTIME_MASK" == true ]]; then
    if [[ "$SINGBOX_WAS_INSTALLED" == false ]]; then
      systemctl disable sing-box.service >/dev/null 2>&1 || true
      systemctl stop sing-box.service >/dev/null 2>&1 || true
    fi
    systemctl unmask --runtime sing-box.service >/dev/null 2>&1 || true
  fi
  restore_attrs
  [[ -z "$TMP_DIR" || ! -d "$TMP_DIR" ]] || rm -rf -- "$TMP_DIR"
  trap - EXIT
  exit "$rc"
}

rollback_ssh() {
  rollback_ssh_keys
  [[ "$SSH_TX" == true ]] || return 0
  SSH_TX=false
  warn '正在回滚 SSH 配置。'
  make_mutable "$SSH_MAIN"
  make_mutable "$SSH_DIR"
  if [[ -d "$BACKUP_DIR/ssh/sshd_config.d" ]]; then
    rm -rf -- "$SSH_DIR"
    cp -a -- "$BACKUP_DIR/ssh/sshd_config.d" "$SSH_DIR"
  elif [[ -e "$BACKUP_DIR/ssh/no-sshd_config.d" ]]; then
    rm -rf -- "$SSH_DIR"
  fi
  if [[ -e "$BACKUP_DIR/ssh/sshd_config" ]]; then
    cp -a -- "$BACKUP_DIR/ssh/sshd_config" "$SSH_MAIN"
  fi
  if [[ "$SSH_RELOAD_ATTEMPTED" == true ]]; then
    if ! sshd -t || ! systemctl reload ssh.service; then
      warn "无法重新加载恢复后的 SSH 配置；备份位于 $BACKUP_DIR/ssh"
    fi
  fi
}

rollback_dns() {
  [[ "$DNS_TX" == true ]] || return 0
  DNS_TX=false
  PERSIST_RESOLV_IMMUTABLE=false
  warn '正在回滚 SmartDNS / resolv.conf。'
  make_mutable "$SMARTDNS_CONF"
  make_mutable /etc/resolv.conf
  if [[ -e "$BACKUP_DIR/dns/smartdns.conf" ]]; then
    install -D -m 0644 "$BACKUP_DIR/dns/smartdns.conf" "$SMARTDNS_CONF" 2>/dev/null || true
  elif [[ -e "$BACKUP_DIR/dns/no-smartdns-conf" ]]; then
    rm -f -- "$SMARTDNS_CONF"
  fi
  if [[ "$NETWORK_POLICY_CHANGED" == true ]]; then
    rollback_legacy_network_stack
    rollback_network_policy
  fi
  if [[ -L "$BACKUP_DIR/dns/resolv.conf.symlink" ]]; then
    rm -f /etc/resolv.conf
    ln -s "$(readlink "$BACKUP_DIR/dns/resolv.conf.symlink")" /etc/resolv.conf 2>/dev/null || true
  elif [[ -e "$BACKUP_DIR/dns/no-resolv-conf" ]]; then
    # resolv.conf did not exist before this run. Remove only what this run wrote and that
    # is still byte-identical; anything a user or another service created since stays.
    if [[ -n "$RESOLV_WRITTEN_SHA" && -f /etc/resolv.conf && ! -L /etc/resolv.conf ]] &&
      [[ "$(sha256sum /etc/resolv.conf | awk '{print $1}')" == "$RESOLV_WRITTEN_SHA" ]]; then
      rm -f -- /etc/resolv.conf
    elif [[ -e /etc/resolv.conf || -L /etc/resolv.conf ]]; then
      warn '/etc/resolv.conf 原本不存在，但现在的内容不是本脚本写入的，已保留。'
    fi
  elif [[ -e "$BACKUP_DIR/dns/resolv.conf" ]]; then
    if mountpoint -q /etc/resolv.conf 2>/dev/null; then
      cat "$BACKUP_DIR/dns/resolv.conf" >/etc/resolv.conf || true
    else
      rm -f /etc/resolv.conf
      cp -a "$BACKUP_DIR/dns/resolv.conf" /etc/resolv.conf 2>/dev/null || true
    fi
  fi
  if [[ "$RESOLVED_OLD_ENABLED" == true ]]; then
    systemctl enable systemd-resolved.service >/dev/null 2>&1 || true
  else
    systemctl disable systemd-resolved.service >/dev/null 2>&1 || true
  fi
  if [[ "$RESOLVED_OLD_ACTIVE" == true ]]; then
    systemctl start systemd-resolved.service >/dev/null 2>&1 || true
  else
    systemctl stop systemd-resolved.service >/dev/null 2>&1 || true
  fi
  if [[ "$SMARTDNS_OLD_ENABLED" == true ]]; then
    systemctl enable smartdns.service >/dev/null 2>&1 || true
  else
    systemctl disable smartdns.service >/dev/null 2>&1 || true
  fi
  if [[ "$SMARTDNS_OLD_ACTIVE" == true ]]; then
    systemctl restart smartdns.service >/dev/null 2>&1 || true
  else
    systemctl stop smartdns.service >/dev/null 2>&1 || true
  fi
}

rollback_ufw() {
  [[ "$UFW_TX" == true ]] || return 0
  UFW_TX=false
  warn '正在回滚 UFW 配置文件。'
  if [[ -d "$BACKUP_DIR/ufw/etc-ufw" ]]; then
    rm -rf /etc/ufw
    cp -a "$BACKUP_DIR/ufw/etc-ufw" /etc/ufw
  fi
  [[ ! -e "$BACKUP_DIR/ufw/default-ufw" ]] || cp -a "$BACKUP_DIR/ufw/default-ufw" /etc/default/ufw
  if [[ "$UFW_OLD_ACTIVE" == true ]]; then
    if ! ufw reload >/dev/null 2>&1; then
      ufw --force enable >/dev/null 2>&1 || warn "无法恢复 UFW；备份位于 $BACKUP_DIR/ufw"
    fi
  else
    ufw --force disable >/dev/null 2>&1 || true
  fi
}

on_error() {
  local rc=$? line=$1
  trap - ERR
  rollback_ufw || true
  rollback_ssh || true
  rollback_dns || true
  printf '[ERROR] 步骤“%s”第 %s 行失败（退出码 %s）。\n' "$CURRENT_STEP" "$line" "$rc" >&2
  exit "$rc"
}

on_signal() {
  local sig=$1
  trap - ERR HUP INT TERM
  restore_ipv6_probe_state || true
  rollback_ufw || true
  rollback_ssh || true
  rollback_dns || true
  warn "收到 $sig，中止执行。"
  exit 130
}

die() {
  rollback_ufw || true
  rollback_ssh || true
  rollback_dns || true
  printf '[ERROR] 步骤“%s”：%s\n' "$CURRENT_STEP" "$*" >&2
  exit 1
}

trap 'on_error $LINENO' ERR
trap cleanup EXIT
trap 'on_signal HUP' HUP
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

validate_port() {
  local p=$1
  [[ "$p" =~ ^[1-9][0-9]{0,4}$ ]] || return 1
  (( 10#$p >= 1 && 10#$p <= 65535 )) || return 1
  case "$p" in 53|80|443|8443) return 1 ;; esac
}

parse_args() {
  while (( $# )); do
    case "$1" in
      --pubkey) [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die '--pubkey 需要非空公钥。'; PUBKEY_ARGUMENT=$2; shift 2 ;;
      --pubkey-file) [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die '--pubkey-file 需要非空文件路径。'; PUBKEY_FILE=$2; shift 2 ;;
      --ssh-port) [[ $# -ge 2 ]] || die '--ssh-port 缺少参数。'; SSH_PORT=$2; SSH_PORT_SET=true; shift 2 ;;
      --keep-22) KEEP_SSH_22=true; KEEP_SSH_22_SET=true; shift ;;
      --close-22) KEEP_SSH_22=false; KEEP_SSH_22_SET=true; shift ;;
      --preserve-ssh) PRESERVE_SSH=true; shift ;;
      --full-upgrade) DO_FULL_UPGRADE=true; shift ;;
      --skip-upgrade) DO_FULL_UPGRADE=false; shift ;;
      --sing-box-version) [[ $# -ge 2 ]] || die '--sing-box-version 缺少参数。'; SING_BOX_VERSION=${2#v}; shift 2 ;;
      --network-stack) [[ $# -ge 2 ]] || die '--network-stack 缺少参数。'; NETWORK_REQUEST=$2; NETWORK_REQUEST_SET=true; shift 2 ;;
      --cloudflare-8443) CF8443_MODE='enable'; shift ;;
      --no-cloudflare-8443) CF8443_MODE='disable'; shift ;;
      --base-only|--smartdns-only|--sing-box-only|--fail2ban-only|--cleanup-only|--update-only|--audit)
        [[ -z "$INSTALL_MODE" ]] || die '只能选择一种独立运行模式。'
        case "$1" in
          --base-only) BASE_ONLY=true; INSTALL_MODE=base ;;
          --smartdns-only) INSTALL_MODE=smartdns ;;
          --sing-box-only) INSTALL_MODE=singbox ;;
          --fail2ban-only) INSTALL_MODE=fail2ban ;;
          --cleanup-only) INSTALL_MODE=cleanup ;;
          --update-only) INSTALL_MODE=update ;;
          --audit) INSTALL_MODE=audit ;;
        esac
        shift ;;
      --help|-h) usage; exit 0 ;;
      *) die "未知参数：$1" ;;
    esac
  done
  [[ -z "$PUBKEY_ARGUMENT" || -z "$PUBKEY_FILE" ]] || die '--pubkey 与 --pubkey-file 只能指定一个。'
  if [[ "$PRESERVE_SSH" == true ]]; then
    if [[ "$SSH_PORT_SET" == true || "$KEEP_SSH_22_SET" == true || -n "$PUBKEY_ARGUMENT$PUBKEY_FILE" ]]; then
      die '--preserve-ssh 不能与 SSH 端口、备用端口或公钥参数同时使用。'
    fi
    [[ "$CF8443_MODE" == auto ]] || die '--preserve-ssh 保留 UFW，不能同时调整 Cloudflare 8443 规则。'
  fi
  validate_port "$SSH_PORT" || die "SSH 端口无效：$SSH_PORT（保留端口为 53/80/443/8443）。"
  case "$NETWORK_REQUEST" in auto|ipv4|dual) ;; *) die '--network-stack 仅支持 auto、ipv4、dual。' ;; esac
  if [[ -n "$SING_BOX_VERSION" ]]; then
    [[ "$SING_BOX_VERSION" =~ ^[0-9A-Za-z.+:~_-]+$ ]] || die 'sing-box 版本格式无效。'
  fi
}

acquire_lock() {
  install -d -m 0755 /run/lock
  exec 9>"$LOCK_FILE"
  flock -n 9 || die '已有另一个 vps-init.sh 正在运行。'
}

preflight() {
  CURRENT_STEP='环境预检'
  (( EUID == 0 )) || die '必须使用 root 运行。'
  if [[ ! "$APT_WAIT_MAX" =~ ^[0-9]+$ ]] || (( APT_WAIT_MAX < 60 )); then die 'VPS_INIT_APT_WAIT 必须是 >=60 的整数秒。'; fi
  [[ -r /etc/os-release ]] || die '无法读取 /etc/os-release。'
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == debian && "${VERSION_ID:-}" =~ ^(12|13)$ ]] || die '仅支持 Debian 12/13。'
  if [[ "$INSTALL_MODE" == qemu-agent-remove || "$INSTALL_MODE" == hardening ]]; then return 0; fi
  if [[ ! -d /run/systemd/system ]] || ! command -v systemctl >/dev/null 2>&1; then
    die '需要正在运行的 systemd。'
  fi
  command -v dpkg >/dev/null 2>&1 || die '缺少 dpkg。'
  local arch audit
  arch=$(dpkg --print-architecture)
  [[ "$arch" == amd64 || "$arch" == arm64 ]] || die "仅支持 amd64/arm64，当前：$arch。"
  check_root_space
  audit=$(dpkg --audit 2>&1 || true)
  [[ -z "$audit" ]] || die "dpkg 当前存在未完成/损坏状态：$audit"
  if [[ "$INSTALL_MODE" == quick || "$INSTALL_MODE" == custom ]]; then
    if [[ "$PRESERVE_SSH" == false ]]; then
      systemctl is-active --quiet ssh.service || systemctl is-active --quiet ssh.socket ||
        die 'ssh.service 和 ssh.socket 均未运行。'
    fi
    [[ -r /dev/tty && -w /dev/tty ]] || die '完整初始化需要交互式 /dev/tty。'
  fi
  CONTAINER_KIND=$(systemd-detect-virt --container 2>/dev/null || true)
  [[ -n "$CONTAINER_KIND" && "$CONTAINER_KIND" != none ]] || CONTAINER_KIND='none'
  install -d -m 0700 "$BACKUP_ROOT"
  BACKUP_DIR="$BACKUP_ROOT/$(date -u '+%Y%m%dT%H%M%SZ')-$$"
  install -d -m 0700 "$BACKUP_DIR"
  TMP_DIR=$(mktemp -d /root/vps-init-tmp.XXXXXXXX)
  log "系统：${PRETTY_NAME:-Debian} / $arch；容器：$CONTAINER_KIND"
  log "资源：RAM=$(awk '/MemTotal:/{printf "%.0fMiB",$2/1024}' /proc/meminfo)，Swap=$(awk '/SwapTotal:/{printf "%.0fMiB",$2/1024}' /proc/meminfo)，RootFree=$(df -Ph / | awk 'NR==2{print $4}')"
  log "地址：$(ip -brief address show scope global 2>/dev/null | tr '\n' '; ' || true)"
  log "默认路由：$({ ip -4 route show default 2>/dev/null; ip -6 route show default 2>/dev/null; } | tr '\n' '; ' || true)"
  log "本轮备份：$BACKUP_DIR"
}

apt_get() {
  local lock_timeout=$APT_WAIT_MAX
  local NEEDRESTART_MODE=${NEEDRESTART_MODE:-a}
  if [[ "$PRESERVE_SSH" == true ]]; then NEEDRESTART_MODE=l; fi
  export NEEDRESTART_MODE
  apt-get \
    -o "DPkg::Lock::Timeout=$lock_timeout" \
    -o Dpkg::Options::='--force-confdef' \
    -o Dpkg::Options::='--force-confold' \
    "$@"
}

show_apt_holders() {
  command -v lslocks >/dev/null 2>&1 || return 0
  lslocks -n -o PID,COMMAND,PATH 2>/dev/null | awk '
    $3=="/var/lib/dpkg/lock" || $3=="/var/lib/dpkg/lock-frontend" ||
    $3=="/var/cache/apt/archives/lock" || $3=="/var/lib/apt/lists/lock" {print}
  ' || true
}

wait_for_package_manager() {
  CURRENT_STEP='等待 apt/dpkg'
  local start=$SECONDS holders elapsed
  while true; do
    holders=$(show_apt_holders)
    [[ -n "$holders" ]] || return 0
    elapsed=$((SECONDS - start))
    if (( elapsed >= APT_WAIT_MAX )); then
      printf '%s\n' "$holders" >&2
      die "apt/dpkg 仍被正常进程占用超过 ${APT_WAIT_MAX}s；未强拆锁。可用 VPS_INIT_APT_WAIT 调整等待上限。"
    fi
    if (( elapsed % 30 < 5 )); then
      warn "apt/dpkg 正在被其他进程使用，继续等待（${elapsed}s/${APT_WAIT_MAX}s）：$(echo "$holders" | tr '\n' '; ')"
    fi
    sleep 5
  done
}

install_early_dependencies() {
  CURRENT_STEP='安装初始化依赖'
  wait_for_package_manager
  apt_get update
  local -a ssh_packages=()
  if [[ "$PRESERVE_SSH" == false ]]; then ssh_packages+=(openssh-client); fi
  apt_get install -y util-linux e2fsprogs ca-certificates curl gnupg "${ssh_packages[@]}"
}

root_free_kib() {
  df -Pk / | awk 'NR == 2 && $4 ~ /^[0-9]+$/ { print $4; found=1 } END { exit !found }'
}

format_mib() {
  awk -v kib="$1" 'BEGIN { value=sprintf("%.10f", kib/1024); sub(/0+$/, "", value); sub(/\.$/, "", value); print value "MiB" }'
}

check_root_space() {
  local free_kib
  free_kib=$(root_free_kib) || die '无法读取根分区可用空间。'
  if (( free_kib < MIN_ROOT_FREE_KIB )); then
    die "$(printf '根分区可用：%s\n最低要求：%s\n还需释放：%s' \
      "$(format_mib "$free_kib")" "$(format_mib "$MIN_ROOT_FREE_KIB")" \
      "$(format_mib "$((MIN_ROOT_FREE_KIB - free_kib))")")"
  fi
}

mem_total_kib() { awk '/MemTotal:/ {print $2}' /proc/meminfo; }
swap_total_mib() { awk '/SwapTotal:/ {print int($2/1024)}' /proc/meminfo; }

swapfile_is_active() {
  grep -Fxq -- "$SWAPFILE" <<<"$1"
}

inactive_swapfile_bytes() {
  [[ ! -L "$SWAPFILE" ]] || return 1
  if [[ ! -e "$SWAPFILE" ]]; then printf '0\n'; return 0; fi
  [[ -f "$SWAPFILE" ]] || return 1
  local owner mode links bytes
  IFS=' ' read -r owner mode links bytes < <(stat -c '%u %a %h %s' -- "$SWAPFILE") || return 1
  [[ "$owner" == 0 && "$mode" == 600 && "$links" == 1 ]] || return 1
  [[ "$(blkid -p -s TYPE -o value -- "$SWAPFILE" 2>/dev/null)" == swap ]] || return 1
  printf '%s\n' "$bytes"
}

swapfile_snapshot() {
  if [[ -e "$SWAPFILE" || -L "$SWAPFILE" ]]; then
    stat -c '%d:%i:%s:%y:%z' -- "$SWAPFILE"
  fi
}

select_swap_capacity() {
  local maximum=$1 free_kib=$2 old_bytes=$3 candidate
  SWAP_RECOMMENDED_MIB=0
  SWAP_REUSE_FILE=false
  for candidate in 2048 1024 512; do
    (( candidate <= maximum )) || continue
    if (( old_bytes == candidate * 1024 * 1024 && free_kib >= SWAP_RESERVE_KIB )); then
      SWAP_RECOMMENDED_MIB=$candidate
      SWAP_REUSE_FILE=true
      return 0
    fi
    if (( candidate == 2048 && free_kib < 4 * 1024 * 1024 )); then continue; fi
    if (( free_kib >= candidate * 1024 + SWAP_RESERVE_KIB )); then
      SWAP_RECOMMENDED_MIB=$candidate
      return 0
    fi
  done
}

recommend_swap() {
  local mem_kib swap maximum free_kib active old_bytes reason
  SWAP_RECOMMENDED_MIB=0
  if [[ "$CONTAINER_KIND" != none ]]; then
    log '容器环境：跳过自动 Swap 文件建议。'
    return 0
  fi
  swap=$(swap_total_mib)
  (( swap < 512 )) || return 0
  mem_kib=$(mem_total_kib)
  if (( mem_kib <= 1024 * 1024 )); then
    maximum=2048
  elif (( mem_kib <= 2048 * 1024 )); then
    maximum=1024
  else
    return 0
  fi
  active=$(swapon --show=NAME --noheadings --raw) || { warn '无法检查已启用的 Swap，跳过。'; return 0; }
  if swapfile_is_active "$active"; then log "$SWAPFILE 已启用，跳过创建。"; return 0; fi
  old_bytes=$(inactive_swapfile_bytes) || { warn "$SWAPFILE 的类型、归属、权限或 Swap 签名无法验证，跳过。"; return 0; }
  SWAPFILE_SNAPSHOT=$(swapfile_snapshot) || { warn '无法确认旧 Swap 文件状态，跳过。'; return 0; }
  free_kib=$(root_free_kib) || { warn '无法检查根分区可用空间，跳过 Swap。'; return 0; }
  select_swap_capacity "$maximum" "$free_kib" "$old_bytes"
  reason='保留根分区安全空间'
  if [[ "$SWAP_REUSE_FILE" == true ]]; then
    reason='复用现有未启用的 Swap 文件，无需重新分配空间'
  elif (( SWAP_RECOMMENDED_MIB == 0 )); then
    reason='没有可在保留 1024MiB 后安全创建的容量，跳过'
  fi
  log "$(printf 'RAM：%s\n当前 Swap：%sMiB\n磁盘可用：%s\n原始推荐：%sMiB\n调整推荐：%sMiB\n原因：%s' \
    "$(format_mib "$mem_kib")" "$swap" "$(format_mib "$free_kib")" "$maximum" "$SWAP_RECOMMENDED_MIB" "$reason")"
}

create_swap() (
  local confirmed=$1 free_kib active old_bytes target current fstab_before
  local swap_work='' fstab_stage='' publishing=false activating=false committed=false
  ORIGINAL_ATTRS=()
  # Keep the old inode until both activation and the atomic fstab update succeed.
  trap '
    set +e
    if [[ -n "$fstab_stage" ]]; then rm -f -- "$fstab_stage"; fi
    if [[ "$committed" == false ]]; then
      if [[ "$activating" == true ]]; then
        if ! active=$(swapon --show=NAME --noheadings --raw) ||
          { swapfile_is_active "$active" && ! swapoff "$SWAPFILE"; }; then
          warn "无法安全撤销 $SWAPFILE；保留文件及恢复目录：$swap_work"
          restore_attrs
          exit 1
        fi
      fi
      if [[ "$publishing" == true && ! -e "$swap_work/new" ]]; then rm -f -- "$SWAPFILE"; fi
      if [[ -n "$swap_work" && -e "$swap_work/old" ]]; then
        mv -T -- "$swap_work/old" "$SWAPFILE" || {
          warn "无法恢复原 Swap 文件；备份保留在 $swap_work/old"
          restore_attrs
          exit 1
        }
      fi
    fi
    restore_attrs
    if [[ -n "$swap_work" ]]; then rm -f -- "$swap_work/new" "$swap_work/old"; rmdir -- "$swap_work"; fi
  ' EXIT
  trap 'exit 1' HUP INT TERM

  active=$(swapon --show=NAME --noheadings --raw) || return 1
  if swapfile_is_active "$active" || (( $(swap_total_mib) >= 512 )); then return 0; fi
  current=$(swapfile_snapshot) || return 1
  if [[ "$current" != "$SWAPFILE_SNAPSHOT" ]]; then warn 'Swap 文件自确认后已变化，跳过。'; return 0; fi
  old_bytes=$(inactive_swapfile_bytes) || { warn "$SWAPFILE 的状态已变化，跳过。"; return 0; }
  free_kib=$(root_free_kib) || return 1
  select_swap_capacity "$confirmed" "$free_kib" "$old_bytes"
  target=$SWAP_RECOMMENDED_MIB
  if (( target == 0 )); then warn '磁盘空间变化，已跳过 Swap。'; return 0; fi
  if (( target < confirmed )); then warn "磁盘空间变化，Swap 调整为 ${target}MiB。"; fi
  [[ -f "$SWAP_FSTAB" && ! -L "$SWAP_FSTAB" ]] || return 1
  fstab_before="$BACKUP_DIR/swap/fstab"
  install -d -m 0700 "$BACKUP_DIR/swap" || return 1
  cp -a -- "$SWAP_FSTAB" "$fstab_before" || return 1
  fstab_stage=$(mktemp "${SWAP_FSTAB}.vps-init.XXXXXXXX") || return 1
  cp --preserve=mode,ownership -- "$fstab_before" "$fstab_stage" || return 1
  awk -v path="$SWAPFILE" '
    $1 == path { if ($3 != "swap") exit 1; next }
    { print }
    END { print path " none swap sw 0 0" }
  ' "$fstab_before" >"$fstab_stage" || return 1

  if [[ "$SWAP_REUSE_FILE" == false ]]; then
    swap_work=$(mktemp -d "${SWAPFILE}.vps-init.XXXXXXXX") || return 1
    if ! dd if=/dev/zero of="$swap_work/new" bs=1M count="$target" conv=fsync status=none; then
      warn 'Swap 文件分配失败，保留现有文件并跳过。'
      return 0
    fi
    chmod 0600 "$swap_work/new" || return 1
    mkswap "$swap_work/new" >/dev/null || return 1
    current=$(swapfile_snapshot) || return 1
    active=$(swapon --show=NAME --noheadings --raw) || return 1
    if [[ "$current" != "$SWAPFILE_SNAPSHOT" ]] || swapfile_is_active "$active"; then
      warn 'Swap 文件或启用状态已变化，跳过。'
      return 0
    fi
    if (( old_bytes > 0 )); then mv -T -- "$SWAPFILE" "$swap_work/old" || return 1; fi
    publishing=true
    mv -T -- "$swap_work/new" "$SWAPFILE" || return 1
  fi
  free_kib=$(root_free_kib) || return 1
  if (( free_kib < SWAP_RESERVE_KIB )); then warn '磁盘可用空间已低于安全余量，已跳过 Swap。'; return 0; fi
  activating=true
  swapon "$SWAPFILE" || return 1
  active=$(swapon --show=NAME --noheadings --raw) && swapfile_is_active "$active" || return 1
  if ! cmp -s -- "$fstab_before" "$SWAP_FSTAB"; then warn 'fstab 在配置过程中已变化。'; return 1; fi
  if ! cmp -s -- "$fstab_stage" "$SWAP_FSTAB"; then
    make_mutable "$SWAP_FSTAB"
    # Defer signals across the atomic commit and rollback flag update.
    trap '' HUP INT TERM
    mv -T -- "$fstab_stage" "$SWAP_FSTAB" || return 1
  fi
  committed=true
  log "已启用 ${target}MiB Swap：$SWAPFILE"
)

collect_swap_choice() {
  SWAP_CHOICE_COLLECTED=true
  SWAP_CONFIRMED_MIB=0
  recommend_swap
  (( SWAP_RECOMMENDED_MIB > 0 )) || return 0
  local action='创建' question='创建？'
  if [[ "$SWAP_REUSE_FILE" == true ]]; then
    action='复用并启用'
    question='启用？'
  elif [[ -e "$SWAPFILE" ]]; then
    action='替换未启用的旧文件并创建'
    question='替换并创建？'
  fi
  if ask_yes_no "$(printf '检测到 %s RAM、当前 Swap %sMiB\n当前磁盘空间推荐%s %sMiB Swap\n%s' \
    "$(format_mib "$(mem_total_kib)")" "$(swap_total_mib)" "$action" "$SWAP_RECOMMENDED_MIB" "$question")" true; then
    SWAP_CONFIRMED_MIB=$SWAP_RECOMMENDED_MIB
  fi
}

configure_swap() {
  if [[ "$SWAP_CHOICE_COLLECTED" == false ]]; then collect_swap_choice; fi
  (( SWAP_CONFIRMED_MIB > 0 )) || return 0
  if ! create_swap "$SWAP_CONFIRMED_MIB"; then warn 'Swap 配置未完成，继续初始化。'; fi
}

collect_choices() {
  [[ "$BASE_ONLY" == true ]] && return 0
  local answer=''
  if [[ "$PRESERVE_SSH" == false && "$SSH_PORT_SET" == false ]]; then
    read_tty "SSH 端口 [$DEFAULT_SSH_PORT]: " answer
    [[ -z "$answer" ]] || SSH_PORT=$answer
  fi
  validate_port "$SSH_PORT" || die "SSH 端口无效：$SSH_PORT。"
  if [[ "$PRESERVE_SSH" == false && "$KEEP_SSH_22_SET" == false ]]; then
    if ask_yes_no '保留 SSH 22/tcp 作为备用？' true; then KEEP_SSH_22=true; else KEEP_SSH_22=false; fi
  fi
}

ssh_port_available() {
  local listeners
  listeners=$(ss -H -ltnp "sport = :$1") || return 1
  awk '
    NF {
      if (!/users:\(\("(sshd|sshd-session)",/) busy=1
      sub(/^.*users:/, "")
      gsub(/\("(sshd|sshd-session)",/, "")
      if (/\("/) busy=1
    }
    END { exit busy }
  ' <<<"$listeners"
}

collect_quick_choices() {
  local choice='' port=''
  if [[ "$KEEP_SSH_22_SET" == false ]]; then KEEP_SSH_22=false; fi
  if [[ "$PRESERVE_SSH" == false && "$SSH_PORT_SET" == false ]]; then
    while true; do
      read_tty $'\n1. 22 only\n2. 53651 only（默认）\n3. 自定义端口 only\n4. 保留现有 SSH 配置\n请选择 SSH 端口 [1-4]: ' choice
      case "${choice:-2}" in
        1) port=22 ;;
        2) port=$DEFAULT_SSH_PORT ;;
        3) read_tty '输入 SSH 端口: ' port ;;
        4)
          [[ "$KEEP_SSH_22_SET" == false && -z "$PUBKEY_ARGUMENT$PUBKEY_FILE" && "$CF8443_MODE" == auto ]] ||
            die '保留 SSH 模式不能与备用端口、公钥参数或 Cloudflare 8443 修改同时使用。'
          PRESERVE_SSH=true
          break ;;
        *) warn '无效选择。'; continue ;;
      esac
      if validate_port "$port"; then ensure_port_validation_dependency; fi
      if validate_port "$port" && ssh_port_available "$port"; then
        SSH_PORT=$port
        KEEP_SSH_22=false
        break
      fi
      warn "端口无效、已占用或无法检查：$port"
    done
  fi
  collect_network_choice
  SSH_PORT_SET=true
  KEEP_SSH_22_SET=true
}

collect_network_choice() {
  local choice=''
  if [[ "$NETWORK_REQUEST_SET" == false ]]; then
    while true; do
      read_tty $'\n1. Auto（默认）\n2. IPv4-only\n3. Dual-Stack\n请选择网络模式 [1-3]: ' choice
      case "${choice:-1}" in
        1) NETWORK_REQUEST=auto; break ;;
        2) NETWORK_REQUEST=ipv4; break ;;
        3) NETWORK_REQUEST=dual; break ;;
        *) warn '无效选择。' ;;
      esac
    done
  fi
}

restore_ssh_package_holds() {
  (( ${#SSH_TEMP_HOLDS[@]} )) || return 0
  if apt-mark unhold "${SSH_TEMP_HOLDS[@]}" >/dev/null; then
    SSH_TEMP_HOLDS=()
  else
    warn "无法恢复临时包 hold：${SSH_TEMP_HOLDS[*]}"
    return 1
  fi
}

restore_update_package_holds() {
  (( ${#UPDATE_TEMP_HOLDS[@]} )) || return 0
  if apt-mark unhold "${UPDATE_TEMP_HOLDS[@]}" >/dev/null; then
    UPDATE_TEMP_HOLDS=()
  else
    warn "无法恢复临时包 hold：${UPDATE_TEMP_HOLDS[*]}"
    return 1
  fi
}

update_system() {
  CURRENT_STEP='系统更新'
  local package held installed
  local upgrade_rc=0
  wait_for_package_manager
  held=$(apt-mark showhold) || die '无法读取原有 APT hold 状态。'
  if [[ "$PRESERVE_SSH" == true ]]; then
    for package in openssh-server openssh-client openssh-sftp-server ufw fail2ban; do
      installed=$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)
      if [[ "$installed" == installed ]] && ! grep -Fxq "$package" <<<"$held"; then
        SSH_TEMP_HOLDS+=("$package")
        apt-mark hold "$package" >/dev/null
      fi
    done
  fi
  apt_get update
  if [[ "$DO_FULL_UPGRADE" == true ]]; then
    for package in sing-box smartdns; do
      installed=$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)
      if [[ "$installed" == installed ]] && ! grep -Fxq "$package" <<<"$held"; then
        # Track before mutation so ERR/signal/EXIT can always restore the hold.
        UPDATE_TEMP_HOLDS+=("$package")
        apt-mark hold "$package" >/dev/null
        log "full-upgrade 前临时 hold $package，避免非预期升级。"
      fi
    done
    if apt_get full-upgrade -y; then upgrade_rc=0; else upgrade_rc=$?; fi
    restore_update_package_holds || die '系统更新结束，但临时 hold 恢复失败。'
    (( upgrade_rc == 0 )) || die "apt full-upgrade 失败（退出码 $upgrade_rc）。"
  fi
  log "系统更新完成；full-upgrade=$DO_FULL_UPGRADE。"
}

run_system_update_only() {
  update_system
  restore_ssh_package_holds
  local boot_kernel=''
  if [[ -e /vmlinuz ]]; then boot_kernel=$(readlink -f /vmlinuz); boot_kernel=${boot_kernel##*/vmlinuz-}; fi
  if [[ -e /run/reboot-required || -e /var/run/reboot-required ]] ||
    [[ -n "$boot_kernel" && "$boot_kernel" != "$(uname -r)" ]]; then
    log '系统报告需要重启；请安排重启。'
  else
    log '系统未报告需要重启（/run/reboot-required）；内核升级后请核对运行版本。'
  fi
}

update_system_and_tools() {
  update_system
  CURRENT_STEP='安装基础工具'
  local -a access_packages=(openssh-server ufw fail2ban)
  if [[ "$PRESERVE_SSH" == true ]]; then access_packages=(); fi
  apt_get install -y \
    ca-certificates curl wget git rsync tar unzip xz-utils jq nano gnupg openssl socat cron \
    "${access_packages[@]}" dnsutils iproute2 iputils-ping netcat-openbsd mtr-tiny traceroute tcpdump \
    procps lsof htop chrony vnstat python3 python3-systemd util-linux file sudo e2fsprogs psmisc \
    kmod
  restore_ssh_package_holds
  if ! command -v curl >/dev/null; then
    die '基础工具验证失败。'
  fi
  if [[ "$PRESERVE_SSH" == false ]] && { ! command -v sshd >/dev/null || ! command -v ufw >/dev/null; }; then
    die '基础工具验证失败。'
  fi
  if [[ "$PRESERVE_SSH" == false ]] && ! fail2ban_package_installed; then
    die 'APT 基础工具安装已结束，但 dpkg 未确认 Fail2ban 已安装。'
  fi
}

ssh_public_key_fingerprints() {
  # ssh-keygen also accepts known_hosts and private keys. Pass only public
  # records after checking the optional authorized_keys prefix.
  awk '
    function strip_options(line,    name, option, i, ch) {
      for (;;) {
        if (!match(line, /^[A-Za-z-]+/)) return ""
        name = tolower(substr(line, 1, RLENGTH))
        line = substr(line, RLENGTH + 1)
        if (name ~ /^(command|environment|expiry-time|from|permitlisten|permitopen|principals|tunnel)$/) {
          if (substr(line, 1, 2) != "=\"") return ""
          option = substr(line, 3)
          for (i = 1; i <= length(option); i++) {
            ch = substr(option, i, 1)
            if (ch == "\\" && substr(option, i + 1, 1) == "\"") i++
            else if (ch == "\"") break
          }
          if (i > length(option)) return ""
          line = substr(option, i + 1)
        } else if (name !~ /^(restrict|cert-authority|(no-)?(agent-forwarding|port-forwarding|pty|user-rc|x11-forwarding|touch-required|verify-required))$/) {
          return ""
        }
        if (line ~ /^[ \t]/) {
          sub(/^[ \t]+/, "", line)
          return line
        }
        if (substr(line, 1, 1) != ",") return ""
        line = substr(line, 2)
      }
    }
    {
      sub(/\r$/, "")
      if (/[\r\x00]/) next
      sub(/^[ \t]+/, "")
      if ($0 == "" || /^#/ || length($0) > 8192) next
      if ($1 !~ /^(ssh-|ecdsa-|sk-)/) $0 = strip_options($0)
      if ($1 ~ /^(ssh-|ecdsa-|sk-)/ && $2 ~ /^[A-Za-z0-9+\/=]+$/) print $1, $2
    }
  ' "$@" | ssh-keygen -l -E sha256 -f - 2>/dev/null | awk '$2 ~ /^SHA256:/ { print $2 }'
}

check_authorized_keys_path() {
  local directory=${AUTHORIZED_KEYS%/*}
  reject_symlink "$directory"
  reject_symlink "$AUTHORIZED_KEYS"
  [[ ! -e "$directory" || -d "$directory" ]] || die "$directory 必须是目录。"
  [[ ! -e "$AUTHORIZED_KEYS" || -f "$AUTHORIZED_KEYS" ]] || die "$AUTHORIZED_KEYS 必须是普通文件。"
}

check_reused_key_permissions() {
  local path owner mode
  for path in "${AUTHORIZED_KEYS%/*}" "$AUTHORIZED_KEYS"; do
    IFS=' ' read -r owner mode < <(stat -c '%u %a' -- "$path") || die "无法检查 $path 的权限。"
    if [[ "$owner" != 0 ]] || (( 8#$mode & 022 )); then
      die "$path 必须归 root 所有，且不能允许组或其他用户写入。"
    fi
  done
}

collect_public_key() {
  CURRENT_STEP='验证 SSH 公钥'
  local fingerprints='' candidate=''
  local -a keys=()
  command -v ssh-keygen >/dev/null || die '缺少 ssh-keygen，无法验证 SSH 公钥。'
  REUSE_PUBLIC_KEY=false
  PUBLIC_KEY=''
  check_authorized_keys_path
  if [[ -n "$PUBKEY_FILE" ]]; then
    [[ -f "$PUBKEY_FILE" && -r "$PUBKEY_FILE" ]] || die "无法读取公钥文件：$PUBKEY_FILE"
    candidate=$(awk 'NF && $1 !~ /^#/ {sub(/\r$/, ""); print; exit}' <"$PUBKEY_FILE")
  elif [[ -n "$PUBKEY_ARGUMENT" ]]; then
    candidate=$PUBKEY_ARGUMENT
  else
    read_tty 'SSH 公钥（直接回车检测已有密钥）: ' candidate
    if [[ -z "$candidate" ]]; then
      if [[ -f "$AUTHORIZED_KEYS" ]]; then
        fingerprints=$(ssh_public_key_fingerprints "$AUTHORIZED_KEYS" || true)
      fi
      if [[ -n "$fingerprints" ]]; then
        mapfile -t keys <<<"$fingerprints"
        printf '检测到 %s 个有效 SSH 公钥\n%s\n' "${#keys[@]}" "$fingerprints"
        if ask_yes_no '是否复用已有公钥？' true; then
          check_reused_key_permissions
          REUSE_PUBLIC_KEY=true
          REUSED_KEY_FINGERPRINTS=$fingerprints
          return 0
        fi
      else
        log '未检测到有效 SSH 公钥。'
      fi
      read_tty '请输入新的 SSH 公钥: ' candidate
    fi
  fi
  while [[ "$candidate" == *$'\n'* ]] || ! ssh_public_key_fingerprints <<<"$candidate" >/dev/null; do
    if [[ -n "$PUBKEY_ARGUMENT" || -n "$PUBKEY_FILE" ]]; then
      die '显式提供的 SSH 公钥为空或无效。'
    fi
    warn 'SSH 公钥为空或无效，请重试。'
    read_tty '请输入新的 SSH 公钥: ' candidate
  done
  PUBLIC_KEY=${candidate%$'\r'}
}

install_authorized_key() {
  CURRENT_STEP='安装 SSH 公钥'
  if [[ "$REUSE_PUBLIC_KEY" == true ]]; then
    check_authorized_keys_path
    check_reused_key_permissions
    [[ -n "$REUSED_KEY_FINGERPRINTS" && "$(ssh_public_key_fingerprints "$AUTHORIZED_KEYS")" == "$REUSED_KEY_FINGERPRINTS" ]] ||
      die '已确认复用的 SSH 公钥发生变化，请重新运行配置。'
    return 0
  fi
  local fingerprint existing='' last_byte
  fingerprint=$(ssh_public_key_fingerprints <<<"$PUBLIC_KEY") || die 'SSH 公钥无法通过 ssh-keygen 校验。'
  check_authorized_keys_path
  if [[ -f "$AUTHORIZED_KEYS" ]]; then
    install -d -m 0700 "$BACKUP_DIR/ssh"
    cp -a -- "$AUTHORIZED_KEYS" "$BACKUP_DIR/ssh/authorized_keys"
    existing=$(ssh_public_key_fingerprints "$AUTHORIZED_KEYS" || true)
  fi
  if [[ -d "${AUTHORIZED_KEYS%/*}" ]]; then SSH_KEY_DIR_STATE=$(stat -c '%u:%g %a' -- "${AUTHORIZED_KEYS%/*}"); fi
  SSH_KEYS_TX=true
  install -d -o root -g root -m 0700 "${AUTHORIZED_KEYS%/*}"
  make_mutable "$AUTHORIZED_KEYS"
  touch "$AUTHORIZED_KEYS"
  chown root:root "$AUTHORIZED_KEYS"
  chmod 0600 "$AUTHORIZED_KEYS"
  if grep -Fqx "$fingerprint" <<<"$existing"; then
    log 'authorized_keys 已有相同公钥。'
  else
    last_byte=$(tail -c 1 -- "$AUTHORIZED_KEYS" | od -An -t u1)
    {
      if [[ -n "$last_byte" && ! "$last_byte" =~ ^[[:space:]]*10$ ]]; then printf '\n'; fi
      printf '%s\n' "$PUBLIC_KEY"
    } >>"$AUTHORIZED_KEYS"
    log "SSH 公钥已添加：$fingerprint"
  fi
}

rollback_ssh_keys() {
  [[ "$SSH_KEYS_TX" == true ]] || return 0
  SSH_KEYS_TX=false
  local mode owner directory="${AUTHORIZED_KEYS%/*}"
  make_mutable "$AUTHORIZED_KEYS"
  if [[ -f "$BACKUP_DIR/ssh/authorized_keys" ]]; then
    cp -a -- "$BACKUP_DIR/ssh/authorized_keys" "$AUTHORIZED_KEYS" || warn '无法恢复 authorized_keys。'
  else
    rm -f -- "$AUTHORIZED_KEYS" || warn '无法移除本次新建的 authorized_keys。'
  fi
  if [[ -n "$SSH_KEY_DIR_STATE" ]]; then
    IFS=' ' read -r owner mode <<<"$SSH_KEY_DIR_STATE"
    if ! chown "$owner" "$directory" || ! chmod "$mode" "$directory"; then warn '无法恢复 .ssh 权限。'; fi
  else
    rmdir -- "$directory" 2>/dev/null || true
  fi
}

ipv4_https_probe() {
  local provider=$1 host=$2 address=$3 result rc
  # Fixed IPs keep this probe independent of the system resolver. Disable curlrc and proxies,
  # keep the hostname in the URL for SNI and certificate checks. Any HTTP response proves the
  # HTTPS connection, including 400 from a bare DoH request.
  if result=$(curl --disable -4 --noproxy '*' --resolve "$host:443:$address" \
    --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 4 --max-time 6 "https://$host/dns-query" 2>&1); then
    if [[ "$result" =~ ^[1-5][0-9][0-9]$ ]]; then
      log "IPv4 HTTPS $provider: PASS (HTTP $result)"
      return 0
    fi
    warn "IPv4 HTTPS $provider: FAIL (no HTTP response: $result)"
  else
    rc=$?
    warn "IPv4 HTTPS $provider: FAIL (curl $rc: $result)"
  fi
  return 1
}

ipv4_https_works() {
  ipv4_https_probe Cloudflare cloudflare-dns.com 1.1.1.1 ||
    ipv4_https_probe Google dns.google 8.8.8.8
}

# Plain TCP check for a system that does not have curl yet (it cannot be installed without DNS).
ipv4_tcp_probe() {
  local provider=$1 address=$2
  # shellcheck disable=SC2016 # $1 is expanded by the inner bash on purpose.
  if timeout 6 bash -c 'exec 3<>"/dev/tcp/$1/443"' _ "$address" 2>/dev/null; then
    log "IPv4 TCP 443 $provider: PASS"
    return 0
  fi
  warn "IPv4 TCP 443 $provider: FAIL"
  return 1
}

ipv4_direct_reachable() {
  if command -v curl >/dev/null 2>&1; then
    ipv4_https_works
  else
    ipv4_tcp_probe Cloudflare 1.1.1.1 || ipv4_tcp_probe Google 8.8.8.8
  fi
}

system_dns_works() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 20 getent ahostsv4 "$DNS_PROBE_HOST" >/dev/null 2>&1
  else
    getent ahostsv4 "$DNS_PROBE_HOST" >/dev/null 2>&1
  fi
}

dns_prompt_available() {
  ( : </dev/tty ) 2>/dev/null && ( : >/dev/tty ) 2>/dev/null
}

# lsattr flags of a regular file; empty for anything else or when lsattr is missing.
early_dns_flags() {
  local out
  [[ -f "$1" && ! -L "$1" ]] || return 0
  command -v lsattr >/dev/null 2>&1 || return 0
  out=$(lsattr -d -- "$1" 2>/dev/null) || return 0
  printf '%s\n' "${out%% *}"
}

# Put /etc/resolv.conf back exactly as backed up: content, existence, symlink and the
# i/a attributes. Returns non-zero (and says why) when anything could not be restored.
restore_early_dns_original() {
  local target=/etc/resolv.conf backup=$1 flags=$2 dir tmp want flag now ok=true
  dir=${target%/*}
  tmp="$dir/.resolv.conf.vps-init-restore.$$"
  if command -v chattr >/dev/null 2>&1; then chattr -i -a -- "$target" 2>/dev/null || true; fi
  if [[ -L "$backup/resolv.conf.symlink" ]]; then
    want=$(readlink "$backup/resolv.conf.symlink") || ok=false
    if [[ ! -L "$target" || "$(readlink "$target")" != "$want" ]]; then
      rm -f -- "$tmp" || ok=false
      if ln -s -- "$want" "$tmp" && mv -f -T -- "$tmp" "$target"; then :; else rm -f -- "$tmp"; ok=false; fi
    fi
    [[ -L "$target" && "$(readlink "$target")" == "$want" ]] || ok=false
  elif [[ -f "$backup/resolv.conf" ]]; then
    if mountpoint -q "$target" 2>/dev/null; then
      cat "$backup/resolv.conf" >"$target" || ok=false
    elif [[ -L "$target" || ! -f "$target" ]] || ! cmp -s -- "$backup/resolv.conf" "$target"; then
      if cp -a -- "$backup/resolv.conf" "$tmp" && mv -f -- "$tmp" "$target"; then :; else rm -f -- "$tmp"; ok=false; fi
    fi
    if [[ -L "$target" ]] || ! cmp -s -- "$backup/resolv.conf" "$target"; then ok=false; fi
  elif [[ -e "$backup/no-resolv-conf" ]]; then
    rm -f -- "$target" || ok=false
    if [[ -e "$target" || -L "$target" ]]; then ok=false; fi
  else
    ok=false
  fi
  for flag in i a; do
    if [[ "$flags" == *"$flag"* ]]; then
      if ! command -v chattr >/dev/null 2>&1 || ! chattr "+$flag" -- "$target" 2>/dev/null; then ok=false; fi
    fi
  done
  if [[ -n "$flags" ]]; then
    now=$(early_dns_flags "$target")
    for flag in i a; do
      if [[ "$flags" == *"$flag"* && "$now" != *"$flag"* ]]; then ok=false; fi
    done
  fi
  if [[ "$ok" != true ]]; then warn "未能完整恢复 $target（内容、链接或属性），请手动核对。"; fi
  [[ "$ok" == true ]]
}

# Write the new resolv.conf. Every step is checked explicitly (the caller runs this inside
# a condition, where errexit does not apply). A regular file is replaced by renaming a
# complete temporary file from the same directory, so a failed write never leaves an empty
# or missing resolv.conf.
early_dns_apply() {
  local target=$1 content=$2 flags=$3 tmp
  if [[ "$flags" == *i* || "$flags" == *a* ]]; then
    log "临时解除文件属性 i/a：$target"
    command -v chattr >/dev/null 2>&1 || return 1
    chattr -i -a -- "$target" || return 1
  fi
  if mountpoint -q "$target" 2>/dev/null; then
    cat "$content" >"$target" || return 1
    return 0
  fi
  tmp=$(mktemp "${target%/*}/.resolv.conf.vps-init.XXXXXXXX") || return 1
  if ! cat "$content" >"$tmp" || ! chmod 0644 "$tmp" || ! mv -f -- "$tmp" "$target"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Independent early repair: once it has succeeded it is deliberately not part of any
# rollback transaction, so a later failure never puts the broken resolver configuration
# back. Until it has succeeded, any failure restores the original and then exits.
early_repair_system_dns() {
  local target=/etc/resolv.conf staged="$TMP_DIR/resolv.conf.early" backup="$BACKUP_DIR/dns-precheck"
  local flags='' saved
  install -d -m 0700 "$backup"
  if [[ -L "$target" ]]; then
    saved="$backup/resolv.conf.symlink"
    ln -s -- "$(readlink "$target")" "$saved"
  elif [[ -e "$target" ]]; then
    saved="$backup/resolv.conf"
    cp -a -- "$target" "$saved"
  else
    saved="$backup/no-resolv-conf"
    : >"$saved"
  fi
  printf 'nameserver 127.0.0.1\nnameserver %s\noptions timeout:2 attempts:2\n' "$FALLBACK_DNS" >"$staged"
  flags=$(early_dns_flags "$target")
  if ! early_dns_apply "$target" "$staged" "$flags"; then
    if restore_early_dns_original "$backup" "$flags"; then
      die "无法写入备用 DNS；已恢复原 $target；备份在 $saved"
    fi
    die "无法写入备用 DNS，且未能完整恢复原 $target；原文件备份在 $saved"
  fi
  if ! system_dns_works; then
    if restore_early_dns_original "$backup" "$flags"; then
      die "已写入备用 DNS $FALLBACK_DNS，但仍无法解析 $DNS_PROBE_HOST（可能拦截了 UDP 53）。已恢复原 $target；备份在 $saved"
    fi
    die "已写入备用 DNS $FALLBACK_DNS，但仍无法解析 $DNS_PROBE_HOST，且未能完整恢复原 $target；原文件备份在 $saved"
  fi
  EARLY_DNS_FIXED=true
  EARLY_DNS_BACKUP=$saved
  log "已提前修复系统 DNS：写入 127.0.0.1 / $FALLBACK_DNS；原文件备份在 $saved"
}

# Runs after the lock is held and before the first apt or network use. A broken system resolver must not stop the
# installer, but a dead IPv4 network must be reported as such.
ensure_system_dns() {
  CURRENT_STEP='检查系统 DNS'
  system_dns_works && return 0
  warn "系统 DNS 无法解析 $DNS_PROBE_HOST，后续 apt 与下载都会失败。"
  if ! ipv4_direct_reachable; then
    die 'IPv4 网络不可用：不经过 DNS 直连 1.1.1.1 / 8.8.8.8 的 443 端口也不通。请检查服务器网络、网关和防火墙。'
  fi
  warn "IPv4 直连正常，故障在系统 DNS（resolv.conf 的 DNS 不应答，或只剩不可用的 127.0.0.1）。"
  warn "将先备份 /etc/resolv.conf，再写入 127.0.0.1 / $FALLBACK_DNS / options timeout:2 attempts:2（与初始化最终写入的内容相同），此修复不随后续回滚撤销。"
  if dns_prompt_available; then
    ask_yes_no '临时写入备用 DNS 以继续？' true ||
      die '已取消：系统 DNS 不可用，无法继续。未做任何修改。'
  else
    warn '没有可用的交互终端，自动写入备用 DNS 以继续。'
  fi
  early_repair_system_dns
}

ipv6_global_present() {
  ip -6 addr show scope global |
    awk '$1 == "inet6" && $2 ~ /^[23]/ && !/ (tentative|dadfailed|deprecated)( |$)/ { found=1 } END { exit !found }'
}

ipv6_route_present() {
  ip -6 route show table all default |
    awk '$1 == "default" && !/ (linkdown|dead)( |$)/ { found=1 } END { exit !found }'
}

ipv6_https_probe() {
  local provider=$1 host=$2 address=$3 result rc
  # Disable curlrc and proxies. Keep the hostname in the URL for SNI and certificate checks.
  # Any HTTP response proves the HTTPS connection, including 400 from a bare DoH request.
  if result=$(curl --disable -6 --noproxy '*' --resolve "$host:443:[$address]" \
    --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 4 --max-time 6 "https://$host/dns-query" 2>&1); then
    if [[ "$result" =~ ^[1-5][0-9][0-9]$ ]]; then
      log "IPv6 HTTPS $provider: PASS (HTTP $result)"
      return 0
    fi
    warn "IPv6 HTTPS $provider: FAIL (no HTTP response: $result)"
  else
    rc=$?
    warn "IPv6 HTTPS $provider: FAIL (curl $rc: $result)"
  fi
  return 1
}

ipv6_https_works() {
  local reachable=false
  ipv6_https_probe Cloudflare cloudflare-dns.com 2606:4700:4700::1111 && reachable=true
  ipv6_https_probe Google dns.google 2001:4860:4860::8888 && reachable=true
  [[ "$reachable" == true ]]
}

detect_ipv6_stack() {
  local address=false route=false detail
  NETWORK_STACK=ipv4
  if detail=$(ipv6_global_present 2>&1); then
    address=true
    log 'IPv6 Global Address: PASS'
  else
    warn "IPv6 Global Address: FAIL (${detail:-no usable global unicast address})"
  fi
  if detail=$(ipv6_route_present 2>&1); then
    route=true
    log 'IPv6 Default Route: PASS'
  else
    warn "IPv6 Default Route: FAIL (${detail:-no usable default route})"
  fi
  if [[ "$address" == true && "$route" == true ]]; then
    if ipv6_https_works; then NETWORK_STACK=dual; fi
  else
    warn 'IPv6 HTTPS Cloudflare: FAIL (skipped: address or default route unavailable)'
    warn 'IPv6 HTTPS Google: FAIL (skipped: address or default route unavailable)'
  fi
}

ipv6_probe_keys() {
  local path
  # Writing conf/all affects every interface. Touch only disabled interfaces so
  # the original per-interface state can be restored without disturbing live links.
  for path in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
    [[ -e "$path" && "$path" != */all/* && "$path" != */default/* ]] || continue
    printf '%s\n' "${path#/proc/sys/}"
  done
}

enable_ipv6_for_probe() {
  local key value
  while IFS= read -r key; do
    if value=$(sysctl -n "$key" 2>/dev/null) && [[ "$value" == 1 ]]; then
      # Register before the write so a signal between commands still restores it.
      IPV6_PROBE_CHANGED+=("$key")
      if ! sysctl -q -w "$key=0"; then warn "IPv6 probe could not enable $key"; fi
    fi
  done < <(ipv6_probe_keys)
  if (( ${#IPV6_PROBE_CHANGED[@]} )); then sleep 3; fi
}

restore_ipv6_probe_state() {
  local key
  local -a failed=()
  for key in "${IPV6_PROBE_CHANGED[@]}"; do
    if [[ "$(sysctl -n "$key" 2>/dev/null)" != 1 ]] && ! sysctl -q -w "$key=1"; then
      warn "IPv6 probe could not restore $key"
      failed+=("$key")
    fi
  done
  IPV6_PROBE_CHANGED=("${failed[@]}")
  (( ${#failed[@]} == 0 ))
}

ssh_session_uses_ipv6() {
  local local_addr=''
  [[ -n "${SSH_CONNECTION:-}" ]] || return 1
  local_addr=$(awk '{print $3}' <<<"$SSH_CONNECTION")
  # A dual-stack socket can represent an IPv4 session as an IPv4-mapped address.
  [[ "$local_addr" == *:* && "${local_addr,,}" != ::ffff:*.* ]]
}

detect_network_stack() {
  CURRENT_STEP='检测网络栈'
  case "$NETWORK_REQUEST" in
    ipv4) NETWORK_STACK='ipv4' ;;
    dual) NETWORK_STACK='dual' ;;
    auto)
      if [[ "$NETWORK_POLICY_CHANGED" == false && "$CONTAINER_KIND" == none ]] &&
        ! ssh_session_uses_ipv6 && ! ipv6_global_present 2>/dev/null &&
        { managed_ipv6_policy "$NETWORK_SYSCTL" || legacy_ipv6_unit_managed || legacy_ipv6_sysctl_managed; }; then
        enable_ipv6_for_probe
      fi
      detect_ipv6_stack
      restore_ipv6_probe_state || die '无法恢复 IPv6 探测前的接口状态。'
      log "Selected Network Stack: $NETWORK_STACK"
      ;;
  esac
  if [[ "$NETWORK_REQUEST" == ipv4 ]] && ssh_session_uses_ipv6; then
    die '当前 SSH 会话正在通过 IPv6；为避免断线，拒绝关闭 IPv6。请先用 IPv4 SSH 登录后重跑。'
  fi
  log "网络模式：$NETWORK_STACK（请求：$NETWORK_REQUEST）"
}

tty_available() {
  [[ -r /dev/tty && -w /dev/tty ]]
}

systemd_sysctl_path() {
  local path
  for path in /usr/lib/systemd/systemd-sysctl /lib/systemd/systemd-sysctl; do
    if [[ -x "$path" ]]; then printf '%s\n' "$path"; return 0; fi
  done
  return 1
}

ipv6_kernel_present() {
  [[ -d /proc/sys/net/ipv6 ]]
}

# What would a reboot leave in net.ipv6.conf.{all,default}.disable_ipv6?
# systemd-sysctl itself evaluates the real configuration (all search paths,
# masking, wildcards, ordering) inside a throw-away network namespace, so the
# host is never touched. Prints on, off, kernel-off or unknown.
# Interface-specific keys have no device in the namespace and cannot be judged;
# lo is irrelevant because nothing here depends on ::1.
ipv6_boot_state() {
  local tool out inner
  # shellcheck disable=SC2016 # Evaluated by sh inside the namespace, not here.
  inner='
base=/proc/sys/net/ipv6/conf
for k in all default; do
  echo 0 >"$base/$k/disable_ipv6" || exit 3
  [ "$(cat "$base/$k/disable_ipv6")" = 0 ] || exit 3
done
"$1" --prefix=net.ipv6.conf >/dev/null 2>&1 || exit 4
printf "all=%s default=%s\n" "$(cat "$base/all/disable_ipv6")" "$(cat "$base/default/disable_ipv6")"
'
  if ! ipv6_kernel_present; then printf 'kernel-off\n'; return 0; fi
  if ! command -v unshare >/dev/null 2>&1 || ! tool=$(systemd_sysctl_path); then printf 'unknown\n'; return 0; fi
  if ! out=$(unshare --net -- sh -c "$inner" _ "$tool" 2>/dev/null); then printf 'unknown\n'; return 0; fi
  if [[ "$out" =~ ^all=([01])\ default=([01])$ ]]; then
    if [[ "${BASH_REMATCH[1]}${BASH_REMATCH[2]}" == 00 ]]; then printf 'on\n'; else printf 'off\n'; fi
  else
    printf 'unknown\n'
  fi
}

# Display only: the settings systemd-sysctl would apply, as "file: line". Never used for decisions.
ipv6_boot_disable_lines() {
  local tool
  tool=$(systemd_sysctl_path) || return 0
  "$tool" --cat-config 2>/dev/null | awk '
    /^# \// { file = substr($0, 3); next }
    /^[[:space:]]*[#;]/ { next }
    /disable_ipv6[[:space:]]*=[[:space:]]*1/ { printf "%s: %s\n", file, $0 }
  ' || true
}

auto_restore_policy_file() {
  managed_ipv6_policy "$1" && grep -Fxq "$AUTO_RESTORE_MARK" "$1"
}

# Policy files that Auto removes while migrating this script's older versions.
# The file written for "restore IPv6" must survive later Auto runs.
migratable_ipv6_policy() {
  managed_ipv6_policy "$1" || return 1
  if [[ "$NETWORK_REQUEST" == auto ]] && auto_restore_policy_file "$1"; then return 1; fi
  return 0
}

# Older managed settings that Auto removes later also show up in the boot state,
# so a check made before that migration cannot be trusted.
auto_will_migrate_ipv6_policy() {
  if migratable_ipv6_policy "$NETWORK_SYSCTL" && grep -Eq 'disable_ipv6[[:space:]]*=[[:space:]]*1' "$NETWORK_SYSCTL"; then return 0; fi
  legacy_ipv6_sysctl_managed
}

# Runs while choices are collected so the answer is part of the single confirmation.
collect_ipv6_boot_policy() {
  local line choice=''
  IPV6_BOOT_STATE='unknown'
  IPV6_RESTORE_CHOICE=''
  IPV6_BOOT_LINES=()
  [[ "$NETWORK_REQUEST" == auto && "$BASE_ONLY" == false ]] || return 0
  if auto_will_migrate_ipv6_policy; then
    IPV6_BOOT_STATE='pending'
    return 0
  fi
  IPV6_BOOT_STATE=$(ipv6_boot_state)
  case "$IPV6_BOOT_STATE" in
    on) return 0 ;;
    unknown)
      warn '无法判断重启后的 IPv6 状态（缺少 unshare/systemd-sysctl 或运行受限）；按探测结果继续。'
      return 0 ;;
    kernel-off)
      warn '内核层面已禁用 IPv6（/proc/sys/net/ipv6 不存在）；按 ipv4 处理。'
      return 0 ;;
  esac
  warn '重启后 IPv6 会被现有 sysctl 配置关闭（只判断 all/default；具体网卡名的设置无法判断）。相关配置（不一定都是最终生效值）：'
  while IFS= read -r line; do
    IPV6_BOOT_LINES+=("$line")
    printf '  %s\n' "$line" >&2
  done < <(ipv6_boot_disable_lines)
  if [[ -e "$NETWORK_SYSCTL" || -L "$NETWORK_SYSCTL" ]] && ! managed_ipv6_policy "$NETWORK_SYSCTL"; then
    IPV6_RESTORE_CHOICE=keep
    warn "$NETWORK_SYSCTL 不是脚本管理的文件，无法用脚本覆盖；保留，Auto 按 IPv4 处理。"
    return 0
  fi
  if [[ "$NETWORK_REQUEST_SET" == false ]] && tty_available; then
    while true; do
      read_tty $'\n1. 恢复 IPv6：写入脚本管理的 /etc/sysctl.d/99-vps-init-network.conf 覆盖上述设置（不修改原有文件）\n2. 保留，Auto 按 IPv4 处理（默认）\n请选择 [1-2]: ' choice
      case "${choice:-2}" in
        1) IPV6_RESTORE_CHOICE=restore; break ;;
        2) IPV6_RESTORE_CHOICE=keep; break ;;
        *) warn '无效选择。' ;;
      esac
    done
  else
    IPV6_RESTORE_CHOICE=keep
    warn '无交互选择：默认保留这些设置，Auto 按 IPv4 处理。'
  fi
}

restore_ipv6_runtime() {
  local key value
  if [[ "$IPV6_OLD_ALL" =~ ^[01]$ ]]; then
    sysctl -q -w "net.ipv6.conf.all.disable_ipv6=$IPV6_OLD_ALL" >/dev/null 2>&1 || warn '无法恢复 net.ipv6.conf.all.disable_ipv6'
  fi
  if [[ "$IPV6_OLD_DEFAULT" =~ ^[01]$ ]]; then
    sysctl -q -w "net.ipv6.conf.default.disable_ipv6=$IPV6_OLD_DEFAULT" >/dev/null 2>&1 || true
  fi
  for key in "${!IPV6_OLD_INTERFACES[@]}"; do
    value=${IPV6_OLD_INTERFACES[$key]}
    if [[ "$(sysctl -n "$key" 2>/dev/null)" != "$value" ]]; then
      sysctl -q -w "$key=$value" >/dev/null 2>&1 || warn "无法恢复 $key"
    fi
  done
}

write_ipv6_restore_policy() {
  # Debian 13 ships its sysctl defaults under /usr/lib; /etc/sysctl.d may not exist yet.
  ensure_dir "${NETWORK_SYSCTL%/*}"
  cat >"$NETWORK_SYSCTL" <<EOF
# Managed by vps-init.sh
$AUTO_RESTORE_MARK
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
EOF
  chmod 0644 "$NETWORK_SYSCTL"
}

# Writes the script's own override and proves with systemd-sysctl that it wins.
restore_ipv6_boot_policy() {
  local scope out state line before=''
  if [[ -e "$NETWORK_SYSCTL" || -L "$NETWORK_SYSCTL" ]] && ! managed_ipv6_policy "$NETWORK_SYSCTL"; then
    warn "$NETWORK_SYSCTL 已变为非脚本管理的文件，不覆盖；保留，按 ipv4 处理。"
    IPV6_BOOT_RESULT='仍禁用'
    IPV6_FORCE_IPV4=true
    return 0
  fi
  if [[ "$NETWORK_POLICY_CHANGED" != true ]]; then backup_network_policy; fi
  IPV6_OLD_ALL=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || true)
  # A file left by an earlier run must survive a failed attempt: keep a copy before writing.
  if [[ -f "$NETWORK_SYSCTL" ]]; then
    before="$BACKUP_DIR/dns/network-sysctl.before-restore"
    install -d -m 0700 "$BACKUP_DIR/dns"
    cp -a -- "$NETWORK_SYSCTL" "$before"
  fi
  make_mutable "$NETWORK_SYSCTL"
  write_ipv6_restore_policy
  for scope in all default lo; do
    if ! out=$(sysctl -w "net.ipv6.conf.$scope.disable_ipv6=0" 2>&1); then
      warn "恢复 IPv6 运行时开关失败（$scope）：$out"
    fi
  done
  sleep 3
  state=$(ipv6_boot_state)
  case "$state" in
    on)
      IPV6_BOOT_RESULT='已恢复'
      IPV6_RESTORED=true
      log "已写入 $NETWORK_SYSCTL；重启后 IPv6 不再被关闭，原有文件未修改。" ;;
    unknown)
      IPV6_BOOT_RESULT='已写入、未验证'
      IPV6_WRITTEN_UNVERIFIED=true
      warn "已写入 $NETWORK_SYSCTL，但无法用 systemd-sysctl 验证效果；不能确认 IPv6 已恢复，重启后请核对。" ;;
    *)
      # A later file still wins: undo our change and fall back to ipv4.
      # Restore what was there before; only a file created by this attempt is removed.
      if [[ -n "$before" ]]; then
        cat "$before" >"$NETWORK_SYSCTL"
      else
        rm -f -- "$NETWORK_SYSCTL"
      fi
      restore_ipv6_runtime
      IPV6_BOOT_RESULT='仍禁用'
      IPV6_FORCE_IPV4=true
      warn '脚本的覆盖文件没有生效（有排序更靠后的配置覆盖了它），已撤销；相关配置（不一定都是最终生效值），均未被修改：'
      while IFS= read -r line; do printf '  %s\n' "$line" >&2; done < <(ipv6_boot_disable_lines)
      warn '保留，按 ipv4 处理。' ;;
  esac
}

# After migrating this script's older policy files: look again, never change files silently.
apply_ipv6_boot_policy() {
  CURRENT_STEP='复查重启后 IPv6'
  local state
  IPV6_FORCE_IPV4=false
  IPV6_RESTORED=false
  IPV6_WRITTEN_UNVERIFIED=false
  IPV6_BOOT_RESULT=''
  [[ "$NETWORK_REQUEST" == auto ]] || return 0
  if [[ "$IPV6_RESTORE_CHOICE" == restore ]]; then
    restore_ipv6_boot_policy
    return 0
  fi
  state=$(ipv6_boot_state)
  case "$state" in
    on) IPV6_BOOT_RESULT='无需处理' ;;
    unknown) IPV6_BOOT_RESULT='无法判断' ;;
    kernel-off)
      IPV6_BOOT_RESULT='仍禁用（内核已禁用）'
      IPV6_FORCE_IPV4=true ;;
    *)
      IPV6_BOOT_RESULT='仍禁用'
      IPV6_FORCE_IPV4=true
      warn '重启后 IPv6 会被现有 sysctl 配置关闭；未选择恢复，不改动任何文件，按 ipv4 处理。' ;;
  esac
}

# After the connectivity probe: configuration and probing are reported separately.
finalize_ipv6_stack() {
  [[ "$NETWORK_REQUEST" == auto ]] || return 0
  IPV6_PROBE_RESULT=$NETWORK_STACK
  if [[ "$IPV6_RESTORED" == true && "$NETWORK_STACK" == ipv4 ]]; then
    warn 'IPv6 已恢复但当前探测未通过：本次按 ipv4 处理；IPv6 地址可能要等网络服务重新初始化或重启后才出现。'
  elif [[ "$IPV6_WRITTEN_UNVERIFIED" == true && "$NETWORK_STACK" == ipv4 ]]; then
    warn 'IPv6 覆盖文件已写入但未验证，且当前探测未通过：本次按 ipv4 处理；重启后请核对 IPv6 状态。'
  fi
  if [[ "$IPV6_FORCE_IPV4" == true && "$NETWORK_STACK" == dual ]]; then
    NETWORK_STACK=ipv4
    warn '重启后 IPv6 仍会被关闭，网络栈按 ipv4 处理。'
  fi
}

ipv6_report_lines() {
  local line
  [[ -n "$IPV6_BOOT_RESULT" ]] || return 0
  printf '重启后 IPv6 : %s\n当前探测     : %s\n' "$IPV6_BOOT_RESULT" "${IPV6_PROBE_RESULT:-未探测}"
  if [[ "$IPV6_WRITTEN_UNVERIFIED" == true ]]; then
    printf '覆盖文件     : 已写入 %s，效果未验证\n' "$NETWORK_SYSCTL"
  fi
  if [[ "$IPV6_RESTORED" == true && ${#IPV6_BOOT_LINES[@]} -gt 0 ]]; then
    printf '已被脚本配置覆盖（%s）。相关配置（不一定都是最终生效值），原文件未修改：\n' "$NETWORK_SYSCTL"
    for line in "${IPV6_BOOT_LINES[@]}"; do printf '  %s\n' "$line"; done
  fi
}

managed_ipv6_policy() {
  [[ -f "$1" && ! -L "$1" ]] || return 1
  awk '
    NR == 1 && /^# Managed by (vps-init\.sh|404-vps-tools|404notfound)/ { managed=1 }
    /^[[:space:]]*($|#)/ { next }
    /^[[:space:]]*net\.ipv6\.conf\.(all|default|lo)\.disable_ipv6[[:space:]]*=[[:space:]]*[01][[:space:]]*$/ { next }
    { invalid=1 }
    END { exit !(managed && !invalid) }
  ' "$1"
}

legacy_ipv6_unit_managed() {
  [[ -f "$LEGACY_NETWORK_UNIT" && ! -L "$LEGACY_NETWORK_UNIT" ]] &&
    grep -Eq '^Description=Apply (404-vps-tools|404notfound) IPv4-only network stack$' "$LEGACY_NETWORK_UNIT"
}

managed_ipv4_policy_file() {
  [[ -f "$1" && ! -L "$1" ]] &&
    grep -Fxq '# Managed by vps-init.sh: IPv4-only policy' "$1"
}

install_ipv4_policy() {
  local path staged
  for path in "${IPV4_POLICY_FILES[@]}"; do
    ensure_dir "${path%/*}"
    make_mutable "$path"
  done
  staged=$(mktemp -d "$TMP_DIR/ipv4-policy.XXXXXXXX")
  cat >"$staged/helper" <<'IPV4_HELPER'
#!/bin/bash
# Managed by vps-init.sh: IPv4-only policy
set -Eeuo pipefail
export LC_ALL=C

# Keep ifupdown's inet6 static and DHCPv6 methods working. They need IPv6
# temporarily for the original configuration to complete.
if [[ "${1:-}" == --ifup ]]; then
  [[ "${ADDRFAM:-}" == inet6 && -n "${IFACE:-}" && "$IFACE" != */* ]] || exit 0
  exec 9>/run/lock/vps-init-ipv4-only.lock
  flock -w 5 9 || exit 0
  key="net/ipv6/conf/$IFACE/disable_ipv6"
  if [[ "$(sysctl -n "$key" 2>/dev/null)" == 1 ]]; then
    sysctl -q -w "$key=0" || :
  fi
  exit 0
fi

status=0
if [[ "${1:-}" != --check ]]; then
  exec 9>/run/lock/vps-init-ipv4-only.lock
  flock 9
  # A timer can fire during a hotplug ifup, not just during boot.
  if pgrep -x ifup >/dev/null; then
    printf 'IPv4-only deferred while ifupdown configures interfaces.\n' >&2
    exit 0
  fi
  # A device created during the scan inherits the policy from default.
  for scope in default all; do
    key="net/ipv6/conf/$scope/disable_ipv6"
    if [[ "$(sysctl -n "$key" 2>/dev/null)" != 1 ]]; then
      sysctl -q -w "$key=1" || status=1
    fi
  done
  for node in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
    [[ -e "$node" && "$node" != */all/* && "$node" != */default/* ]] || continue
    key=${node#/proc/sys/}
    if [[ "$(sysctl -n "$key" 2>/dev/null)" != 1 ]]; then
      sysctl -q -w "$key=1" || { [[ ! -e "$node" ]] || status=1; }
    fi
  done
fi

nodes=(/proc/sys/net/ipv6/conf/{all,default,lo}/disable_ipv6)
for node in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
  [[ -e "$node" && "$node" != */all/* && "$node" != */default/* && "$node" != */lo/* ]] || continue
  nodes+=("$node")
done
for node in "${nodes[@]}"; do
  key=${node#/proc/sys/}
  if ! value=$(sysctl -n "$key" 2>&1) || [[ "$value" != 1 ]]; then
    printf '%s: expected disable_ipv6=1, got %s\n' "${key%/disable_ipv6}" "${value:-unknown}" >&2
    status=1
  fi
done
for check in address route; do
  if [[ "$check" == address ]]; then
    args=(address show)
  else
    args=(route show table all exact ::/0)
  fi
  if ! out=$(ip -o -6 "${args[@]}" 2>&1); then
    printf 'Cannot check IPv6 %s: %s\n' "$check" "$out" >&2
    status=1
    continue
  fi
  # Nexthop-backed RA defaults can survive disable_ipv6, and "ip route
  # flush" can fail to replay their attributes as a delete request. Delete
  # by route selectors instead of replaying nexthop or gateway attributes.
  if [[ "$check" == route && -n "$out" && "${1:-}" != --check ]] && (( status == 0 )); then
    while IFS= read -r route; do
      read -r -a fields <<<"$route"
      selectors=()
      for ((i=0; i+1<${#fields[@]}; i++)); do
        case "${fields[i]}" in
          table|from|metric) selectors+=("${fields[i]}" "${fields[i+1]}"); ((i+=1)) ;;
          dev|via|proto|nhid|expires|pref) ((i+=1)) ;;
          nexthop) break ;;
        esac
      done
      ip -6 route del default "${selectors[@]}" || status=1
    done <<<"$out"
    if ! out=$(ip -o -6 "${args[@]}" 2>&1); then
      printf 'Cannot recheck IPv6 routes: %s\n' "$out" >&2
      status=1
      continue
    fi
  fi
  if [[ -n "$out" ]]; then
    printf 'IPv6 %s still present:\n%s\n' "$check" "$out" >&2
    status=1
  fi
done
exit "$status"
IPV4_HELPER
  cat >"$staged/service" <<EOF
# Managed by vps-init.sh: IPv4-only policy
[Unit]
Description=Enforce IPv4-only on network interfaces
After=systemd-sysctl.service network.target networking.service systemd-networkd.service NetworkManager.service
ConditionPathIsReadWrite=/proc/sys/net/ipv6/conf/default/disable_ipv6
ConditionCapability=CAP_NET_ADMIN

[Service]
Type=oneshot
TimeoutStartSec=10s
ExecStart=$IPV4_POLICY_HELPER
EOF
  cat >"$staged/timer" <<'EOF'
# Managed by vps-init.sh: IPv4-only policy
[Unit]
Description=Reapply IPv4-only after network interfaces are configured

[Timer]
OnActiveSec=1s
OnUnitInactiveSec=1h
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF
  install -m 0755 -- "$staged/helper" "$IPV4_POLICY_HELPER"
  install -m 0644 -- "$staged/service" "$IPV4_POLICY_SERVICE"
  install -m 0644 -- "$staged/timer" "$IPV4_POLICY_TIMER"
  printf '#!/bin/bash\n# Managed by vps-init.sh: IPv4-only policy\nset -Eeuo pipefail\nexec %q --ifup\n' "$IPV4_POLICY_HELPER" >"$staged/ifup"
  install -m 0755 -- "$staged/ifup" "$IPV4_POLICY_IFUP"
  systemctl daemon-reload
}

verify_ipv4_policy() {
  local out
  if out=$("$IPV4_POLICY_HELPER" --check 2>&1); then
    IPV4_POLICY_STATUS='PASS（逐接口已禁用，无 IPv6 地址或默认路由）'
  else
    IPV4_POLICY_STATUS='FAIL（内核 IPv6 未完全禁用，SmartDNS 仍为 A only）'
    warn "$out"
  fi
  log "IPv4-only 内核核验：$IPV4_POLICY_STATUS"
}

backup_network_policy() {
  local key value path
  if [[ -e "$NETWORK_SYSCTL" || -L "$NETWORK_SYSCTL" ]]; then cp -a "$NETWORK_SYSCTL" "$BACKUP_DIR/dns/network-sysctl"; fi
  for path in "${IPV4_POLICY_FILES[@]}"; do
    if managed_ipv4_policy_file "$path"; then cp -a -- "$path" "$BACKUP_DIR/dns/${path##*/}"; fi
  done
  if [[ -f "$IPV4_POLICY_TIMER" ]]; then
    if systemctl is-enabled --quiet "${IPV4_POLICY_TIMER##*/}"; then IPV4_TIMER_WAS_ENABLED=true; fi
    if systemctl is-active --quiet "${IPV4_POLICY_TIMER##*/}"; then IPV4_TIMER_WAS_ACTIVE=true; fi
  fi
  IPV6_OLD_DEFAULT=$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || true)
  while IFS= read -r key; do
    if value=$(sysctl -n "$key" 2>/dev/null) && [[ "$value" =~ ^[01]$ ]]; then
      IPV6_OLD_INTERFACES["$key"]=$value
    fi
  done < <(ipv6_probe_keys)
  NETWORK_POLICY_CHANGED=true
}

rollback_network_policy() {
  local path saved reload=false
  if managed_ipv4_policy_file "$IPV4_POLICY_TIMER"; then
    systemctl disable --now "${IPV4_POLICY_TIMER##*/}" || warn "无法停止 $IPV4_POLICY_TIMER"
    systemctl stop "${IPV4_POLICY_SERVICE##*/}" || warn "无法停止 $IPV4_POLICY_SERVICE"
  fi
  for path in "${IPV4_POLICY_FILES[@]}"; do
    saved="$BACKUP_DIR/dns/${path##*/}"
    if [[ -f "$saved" ]]; then
      cp -a -- "$saved" "$path" || warn "无法恢复 $path"
      reload=true
    elif managed_ipv4_policy_file "$path"; then
      rm -f -- "$path" || warn "无法移除 $path"
      reload=true
    fi
  done
  if [[ -L "$BACKUP_DIR/dns/network-sysctl" ]]; then
    : # Auto did not modify this provider-owned link.
  elif [[ -f "$BACKUP_DIR/dns/network-sysctl" ]]; then
    cp -a -- "$BACKUP_DIR/dns/network-sysctl" "$NETWORK_SYSCTL" || warn "无法恢复 $NETWORK_SYSCTL"
  else
    rm -f -- "$NETWORK_SYSCTL" || warn "无法移除 $NETWORK_SYSCTL"
  fi
  restore_ipv6_runtime
  if [[ "$reload" == true ]]; then
    systemctl daemon-reload || warn '无法重载 systemd 配置。'
    if [[ "$IPV4_TIMER_WAS_ENABLED" == true ]]; then systemctl enable "${IPV4_POLICY_TIMER##*/}" || warn "无法启用 $IPV4_POLICY_TIMER"; fi
    if [[ "$IPV4_TIMER_WAS_ACTIVE" == true ]]; then systemctl start "${IPV4_POLICY_TIMER##*/}" || warn "无法启动 $IPV4_POLICY_TIMER"; fi
  fi
  NETWORK_POLICY_CHANGED=false
}

apply_network_stack() {
  CURRENT_STEP='应用网络栈'
  local scope out path had_policy=false restore_runtime=false
  local -a policy_files=()
  if [[ "$NETWORK_REQUEST" == ipv4 ]] && ssh_session_uses_ipv6; then
    die '当前 SSH 会话正在通过 IPv6；为避免断线，拒绝关闭 IPv6。'
  fi
  for path in "${IPV4_POLICY_FILES[@]}"; do
    [[ -e "$path" || -L "$path" ]] || continue
    managed_ipv4_policy_file "$path" || die "$path 不是脚本管理的 IPv4-only 配置。"
    policy_files+=("$path")
    had_policy=true
  done
  if [[ -e "$NETWORK_SYSCTL" || -L "$NETWORK_SYSCTL" ]] && ! managed_ipv6_policy "$NETWORK_SYSCTL"; then
    if [[ "$NETWORK_REQUEST" != auto ]]; then die "$NETWORK_SYSCTL 不是脚本管理的配置。"; fi
    warn "保留非脚本管理的 $NETWORK_SYSCTL"
  fi
  if [[ "$NETWORK_REQUEST" == auto ]]; then
    [[ "$had_policy" == true ]] || migratable_ipv6_policy "$NETWORK_SYSCTL" ||
      legacy_ipv6_unit_managed || legacy_ipv6_sysctl_managed || return 0
  fi
  backup_network_policy
  if [[ "$had_policy" == true ]] || legacy_ipv6_unit_managed || legacy_ipv6_sysctl_managed; then
    restore_runtime=true
  fi
  if managed_ipv4_policy_file "$IPV4_POLICY_TIMER"; then
    systemctl disable --now "${IPV4_POLICY_TIMER##*/}"
  fi
  if managed_ipv4_policy_file "$IPV4_POLICY_SERVICE"; then
    systemctl stop "${IPV4_POLICY_SERVICE##*/}"
  fi
  if migratable_ipv6_policy "$NETWORK_SYSCTL"; then
    if grep -Eq 'disable_ipv6[[:space:]]*=[[:space:]]*1[[:space:]]*$' "$NETWORK_SYSCTL"; then restore_runtime=true; fi
    make_mutable "$NETWORK_SYSCTL"
    rm -f -- "$NETWORK_SYSCTL"
  fi
  if [[ "$NETWORK_REQUEST" == ipv4 ]]; then
    install_ipv4_policy
    if ! out=$("$IPV4_POLICY_HELPER" 2>&1); then warn "$out"; fi
    systemctl enable --now "${IPV4_POLICY_TIMER##*/}"
    return 0
  fi
  if [[ "$had_policy" == true ]]; then
    for path in "${policy_files[@]}"; do make_mutable "$path"; done
    rm -f -- "${policy_files[@]}"
    systemctl daemon-reload
  fi
  if [[ "$NETWORK_REQUEST" == auto ]]; then
    log "Auto 正在迁移脚本管理的 IPv6 策略；备份=$BACKUP_DIR"
    [[ "$restore_runtime" == true ]] || return 0
  else
    ensure_dir "${NETWORK_SYSCTL%/*}"
    cat >"$NETWORK_SYSCTL" <<EOF
# Managed by vps-init.sh
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
EOF
  fi
  for scope in all default lo; do
    if ! out=$(sysctl -w "net.ipv6.conf.$scope.disable_ipv6=0" 2>&1); then
      warn "恢复 IPv6 能力失败（$scope）：$out"
    fi
  done
  if [[ "$restore_runtime" == true ]] && ! ipv6_global_present; then
    warn '原始 IPv6 配置已保留；静态地址和 DHCPv6 可能需等到网络服务下次初始化或计划重启后恢复。'
  fi
}

legacy_ipv6_sysctl_managed() {
  managed_ipv6_policy "$LEGACY_IPV6_SYSCTL" ||
    { [[ -f "$LEGACY_IPV6_SYSCTL" && ! -L "$LEGACY_IPV6_SYSCTL" ]] && legacy_ipv6_unit_managed &&
      awk '
        /^[[:space:]]*($|#)/ { next }
        /^[[:space:]]*net\.ipv6\.conf\.(all|default|lo)\.disable_ipv6[[:space:]]*=[[:space:]]*1[[:space:]]*$/ { found=1; next }
        { invalid=1 }
        END { exit !(found && !invalid) }
      ' "$LEGACY_IPV6_SYSCTL"; }
}

configure_chrony() {
  CURRENT_STEP='配置 Chrony'
  systemctl enable chrony.service >/dev/null 2>&1 || true
  if ! systemctl restart chrony.service; then
    if [[ "$CONTAINER_KIND" != none ]]; then
      warn "容器（$CONTAINER_KIND）内 Chrony 启动失败；继续安装。"
    else
      die 'Chrony 启动失败。'
    fi
  fi
}

sysctl_try() {
  local key=$1 value=$2 out=''
  if out=$(sysctl -w "$key=$value" 2>&1); then return 0; fi
  if grep -Eqi 'permission denied|operation not permitted|read-only|unknown key|cannot stat' <<<"$out"; then
    warn "$key 无法应用：$out"
    return 1
  fi
  die "sysctl $key 失败：$out"
}

configure_tcp_tuning() {
  CURRENT_STEP='配置 TCP/BBR'
  local available bbr=false
  if command -v tcpfit >/dev/null 2>&1; then
    tcpfit rollback || die 'tcpfit rollback 失败；为避免叠加未知旧调优，停止继续。'
  fi
  reject_symlink "$TCP_SYSCTL"
  reject_symlink "$BBR_MODULES"
  # Minimal Debian 13 installs may not have /etc/sysctl.d yet.
  ensure_dir "${TCP_SYSCTL%/*}"
  make_mutable "$TCP_SYSCTL"
  make_mutable "$BBR_MODULES"
  available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
  if [[ " $available " != *' bbr '* ]]; then
    modprobe tcp_bbr >/dev/null 2>&1 || true
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
  fi
  [[ " $available " == *' bbr '* ]] && bbr=true
  {
    echo '# Managed by vps-init.sh'
    cat <<'EOF'
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_moderate_rcvbuf = 1
EOF
  } >"$TCP_SYSCTL"
  chmod 0644 "$TCP_SYSCTL"
  sysctl_try net.core.rmem_max 33554432 || true
  sysctl_try net.core.wmem_max 33554432 || true
  sysctl_try net.ipv4.tcp_rmem '4096 131072 33554432' || true
  sysctl_try net.ipv4.tcp_wmem '4096 16384 33554432' || true
  sysctl_try net.ipv4.tcp_window_scaling 1 || true
  sysctl_try net.ipv4.tcp_moderate_rcvbuf 1 || true
  if [[ "$bbr" == true ]]; then
    local out
    if out=$(sysctl -w net.core.default_qdisc=fq 2>&1); then
      printf 'net.core.default_qdisc = fq\n' >>"$TCP_SYSCTL"
    else
      warn "默认 qdisc 无法设为 fq：$out"
    fi
    if out=$(sysctl -w net.ipv4.tcp_congestion_control=bbr 2>&1); then
      ensure_dir "${BBR_MODULES%/*}"
      printf 'tcp_bbr\n' >"$BBR_MODULES"
      printf 'net.ipv4.tcp_congestion_control = bbr\n' >>"$TCP_SYSCTL"
    else
      rm -f -- "$BBR_MODULES"
      warn "当前环境无法启用 BBR：$out"
    fi
  else
    rm -f "$BBR_MODULES"
    warn '当前内核未报告 BBR 可用；TCP 参数的应用结果见上方日志。'
  fi
  log "TCP 实际拥塞算法：$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unavailable) / 默认 qdisc：$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unavailable)"
}

configure_sagernet_repo() {
  CURRENT_STEP='配置 SagerNet 仓库'
  local key="$TMP_DIR/sagernet.asc" gh="$TMP_DIR/gnupg" primary='' pub_count=0
  curl -fsSL --retry 3 https://sing-box.app/gpg.key -o "$key"
  install -d -m 0700 "$gh"
  gpg --batch --homedir "$gh" --import "$key" >/dev/null 2>&1 || die 'SagerNet GPG key 导入失败。'
  pub_count=$(gpg --batch --homedir "$gh" --with-colons --list-keys | awk -F: '$1=="pub"{c++} END{print c+0}')
  primary=$(gpg --batch --homedir "$gh" --with-colons --list-keys | awk -F: '$1=="pub"{want=1;next} want&&$1=="fpr"{print $10; exit}')
  [[ "$pub_count" -eq 1 && "$primary" == "$SAGER_KEY_FINGERPRINT" ]] || die "SagerNet key 不满足唯一主密钥指纹要求：$primary / count=$pub_count。"
  ensure_dir /etc/apt/keyrings
  ensure_dir /etc/apt/sources.list.d
  reject_symlink /etc/apt/keyrings/sagernet.gpg
  reject_symlink /etc/apt/sources.list.d/sagernet.sources
  make_mutable /etc/apt/keyrings/sagernet.gpg
  make_mutable /etc/apt/sources.list.d/sagernet.sources
  gpg --batch --homedir "$gh" --export "$SAGER_KEY_FINGERPRINT" >"$TMP_DIR/sagernet.gpg"
  install -m 0644 "$TMP_DIR/sagernet.gpg" /etc/apt/keyrings/sagernet.gpg
  cat >/etc/apt/sources.list.d/sagernet.sources <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.gpg
EOF
}

capture_singbox_state() {
  if [[ -e "$SINGBOX_CONFIG" || -L "$SINGBOX_CONFIG" ]]; then
    SINGBOX_CONFIG_PREEXISTED=true
  else
    SINGBOX_CONFIG_PREEXISTED=false
  fi

  if [[ -e "$SINGBOX_MANAGED_MARKER" || -e "$SINGBOX_DROPIN" ]]; then
    SINGBOX_WAS_MANAGED=true
  else
    SINGBOX_WAS_MANAGED=false
  fi

  if dpkg-query -W sing-box >/dev/null 2>&1; then
    SINGBOX_WAS_INSTALLED=true
  else
    SINGBOX_WAS_INSTALLED=false
  fi
}

configure_singbox_boot_gate() {
  CURRENT_STEP='配置 sing-box 启动条件'
  install -d -m 0755 "$SINGBOX_DROPIN_DIR"
  reject_symlink "$SINGBOX_DROPIN"
  make_mutable "$SINGBOX_DROPIN"
  cat >"$TMP_DIR/sing-box-config-gate.conf" <<'EOF'
[Unit]
ConditionPathExists=/etc/sing-box/config.json
EOF
  install -m 0644 "$TMP_DIR/sing-box-config-gate.conf" "$SINGBOX_DROPIN"
  systemctl daemon-reload
}

mark_singbox_managed() {
  install -d -m 0755 "$(dirname "$SINGBOX_MANAGED_MARKER")"
  printf 'managed-by-vps-init\n' >"$SINGBOX_MANAGED_MARKER"
}

remove_fresh_singbox_default_config() {
  if [[ "$SINGBOX_WAS_INSTALLED" == false && "$SINGBOX_CONFIG_PREEXISTED" == false && -e "$SINGBOX_CONFIG" ]]; then
    [[ ! -L "$SINGBOX_CONFIG" ]] || die "拒绝删除符号链接形式的 sing-box 默认配置：$SINGBOX_CONFIG"
    make_mutable "$SINGBOX_CONFIG"
    rm -f -- "$SINGBOX_CONFIG"
    log "已删除官方包附带的默认配置：$SINGBOX_CONFIG；等待用户写入正式配置。"
  fi
}

restore_singbox_state() {
  if [[ "$SINGBOX_WAS_INSTALLED" == false ]]; then
    systemctl stop sing-box.service >/dev/null 2>&1 || true
  fi
  # The gate must exist before enabling. Never start/restart during initialization.
  configure_singbox_boot_gate
  systemctl enable sing-box.service
  systemctl is-enabled --quiet sing-box.service || die 'sing-box 开机自启验证失败。'
}

install_sing_box() {
  CURRENT_STEP='安装 sing-box'
  capture_singbox_state
  configure_sagernet_repo
  apt_get update

  if [[ "$SINGBOX_WAS_INSTALLED" == true && -z "$SING_BOX_VERSION" ]]; then
    restore_singbox_state
    if [[ "$SINGBOX_WAS_MANAGED" == true ]]; then
      configure_singbox_boot_gate
      mark_singbox_managed
      if [[ ! -e "$SINGBOX_CONFIG" ]]; then
        systemctl stop sing-box.service >/dev/null 2>&1 || true
      fi
      log "sing-box 重跑不升级；已启用开机自启，未启动：$(sing-box version 2>/dev/null | head -1 || true)"
    else
      log "已有 sing-box 未升级，已添加启动条件并设为开机自启，未启动：$(sing-box version 2>/dev/null | head -1 || true)"
    fi
    return 0
  fi

  [[ ! -e /run/systemd/system/sing-box.service && ! -L /run/systemd/system/sing-box.service ]] ||
    die 'sing-box 已有 runtime service 覆盖或 mask，请先检查。'
  systemctl mask --runtime sing-box.service
  SINGBOX_RUNTIME_MASK=true

  if [[ -n "$SING_BOX_VERSION" ]]; then
    apt-cache madison sing-box | awk '{print $3}' | grep -Fqx "$SING_BOX_VERSION" || die "仓库中找不到 sing-box=$SING_BOX_VERSION。"
    apt_get install -y --allow-downgrades "sing-box=$SING_BOX_VERSION"
  else
    apt_get install -y sing-box
  fi

  command -v sing-box >/dev/null 2>&1 || die '安装后找不到 sing-box。'
  install -d -m 0755 /etc/sing-box

  if [[ "$SINGBOX_WAS_INSTALLED" == false || "$SINGBOX_WAS_MANAGED" == true ]]; then
    configure_singbox_boot_gate
    remove_fresh_singbox_default_config
    mark_singbox_managed
  fi

  if [[ "$SINGBOX_RUNTIME_MASK" == true ]]; then
    systemctl unmask --runtime sing-box.service
    SINGBOX_RUNTIME_MASK=false
  fi
  restore_singbox_state
  log "sing-box：$(sing-box version 2>/dev/null | head -1)；状态=$(systemctl is-active sing-box.service 2>/dev/null || true)/$(systemctl is-enabled sing-box.service 2>/dev/null || true)"
}

smartdns_pkg_values() {
  local arch
  arch=$(dpkg --print-architecture)
  case "$arch" in
    amd64)
      SMARTDNS_PKG='smartdns.1.2026.08.05-0921.x86_64-debian-all.deb'
      SMARTDNS_SHA='4cc1b8f9db10110e1212d981cfee7eb89a3c80f5766760e3b5f7541c8da8b546'
      ;;
    arm64)
      SMARTDNS_PKG='smartdns.1.2026.08.05-0921.aarch64-debian-all.deb'
      SMARTDNS_SHA='2effd18abaa7b8a5e30a66bb087b8429ceb87cf1ee37b06571362cdc17dab229'
      ;;
    *) die "SmartDNS 不支持架构：$arch" ;;
  esac
  SMARTDNS_URL="https://github.com/pymumu/smartdns/releases/download/$SMARTDNS_RELEASE/$SMARTDNS_PKG"
}

backup_dns_state() {
  install -d -m 0700 "$BACKUP_DIR/dns"
  if [[ -f "$SMARTDNS_CONF" ]]; then cp -a "$SMARTDNS_CONF" "$BACKUP_DIR/dns/smartdns.conf"; else touch "$BACKUP_DIR/dns/no-smartdns-conf"; fi
  if [[ -L /etc/resolv.conf ]]; then
    ln -s "$(readlink /etc/resolv.conf)" "$BACKUP_DIR/dns/resolv.conf.symlink"
  elif [[ -e /etc/resolv.conf ]]; then
    cp -a /etc/resolv.conf "$BACKUP_DIR/dns/resolv.conf"
  else
    touch "$BACKUP_DIR/dns/no-resolv-conf"
  fi
  systemctl is-active --quiet smartdns.service 2>/dev/null && SMARTDNS_OLD_ACTIVE=true || SMARTDNS_OLD_ACTIVE=false
  systemctl is-enabled --quiet smartdns.service 2>/dev/null && SMARTDNS_OLD_ENABLED=true || SMARTDNS_OLD_ENABLED=false
  systemctl is-active --quiet systemd-resolved.service 2>/dev/null && RESOLVED_OLD_ACTIVE=true || RESOLVED_OLD_ACTIVE=false
  systemctl is-enabled --quiet systemd-resolved.service 2>/dev/null && RESOLVED_OLD_ENABLED=true || RESOLVED_OLD_ENABLED=false
}

write_smartdns_config() {
  local out=$1 transport=${2:-h2} aaaa_soa=no
  # Listen on IPv4 loopback only: it exists regardless of any later disable_ipv6 policy.
  if [[ "$NETWORK_REQUEST" == ipv4 ]]; then aaaa_soa=yes; fi
  {
    cat <<EOF
bind 127.0.0.1:53
bind-tcp 127.0.0.1:53

cache-persist yes
cache-file /var/cache/smartdns/smartdns.cache
cache-checkpoint-time 86400

serve-expired yes
serve-expired-ttl 259200
serve-expired-reply-ttl 3
serve-expired-prefetch-time 21600
prefetch-domain yes

speed-check-mode tcp:443,ping
response-mode first-ping

dualstack-ip-selection no
force-AAAA-SOA $aaaa_soa

log-level warn
log-console no
log-syslog yes
audit-enable no

ca-file /etc/ssl/certs/ca-certificates.crt
EOF
  } >"$out" || return 1

  case "$transport" in
    h2)
      cat >>"$out" <<'EOF'

# Preferred upstream: Cloudflare + Google DNS-over-HTTPS (HTTP/2 over IPv4).
server-https https://cloudflare-dns.com/dns-query -host-ip 1.1.1.1
server-https https://dns.google/dns-query -host-ip 8.8.8.8
EOF
      ;;
    dns53)
      cat >>"$out" <<'EOF'

# Automatic fallback when the DoH health check fails.
# Use both UDP/53 and TCP/53 over IPv4 transport; AAAA answers remain available in dual-stack mode.
server 1.1.1.1
server 8.8.8.8
server-tcp 1.1.1.1
server-tcp 8.8.8.8
EOF
      ;;
    *)
      die "未知 SmartDNS 上游模式：$transport"
      ;;
  esac
}

smartdns_health_check() {
  local a='' aaaa='' tcp_a='' upstream=''
  # Use a fresh name so persistent or expired cache entries cannot pass the upstream check.
  upstream=$(dig @127.0.0.1 "_smartdns-check-$RANDOM-$RANDOM-$RANDOM.google.com." TXT +noall +comments +time=6 +tries=2 2>/dev/null) || return 1
  [[ "$upstream" == *'status: NXDOMAIN,'* ]] || return 1

  tcp_a=$(dig @127.0.0.1 google.com A +tcp +short +time=6 +tries=2 2>/dev/null || true)
  grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' <<<"$tcp_a" || return 1
  a=$(dig @127.0.0.1 google.com A +short +time=6 +tries=2 2>/dev/null || true)
  grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' <<<"$a" || return 1

  aaaa=$(dig @127.0.0.1 google.com AAAA +short +time=6 +tries=2 2>/dev/null || true)
  if [[ "$NETWORK_REQUEST" == ipv4 ]]; then
    [[ -z "$aaaa" ]]
  else
    grep -Eq '^[0-9a-fA-F:]*:[0-9a-fA-F:]+$' <<<"$aaaa"
  fi
}

smartdns_try_transport() {
  local transport=$1 staged=$2
  write_smartdns_config "$staged" "$transport" || return 1
  make_mutable "$SMARTDNS_CONF"
  install -m 0644 "$staged" "$SMARTDNS_CONF" || return 1

  systemctl restart smartdns.service >/dev/null 2>&1 || return 1
  sleep 2
  systemctl is-active --quiet smartdns.service || return 1
  smartdns_health_check
}

install_smartdns_package() {
  local current='' current_text='' deb="$TMP_DIR/$SMARTDNS_PKG" actual=''
  SMARTDNS_DID_INSTALL=false
  if command -v smartdns >/dev/null 2>&1; then
    current_text=$(smartdns -v 2>/dev/null | awk 'NF{print; exit}' || true)
    current=$(awk '{print $2}' <<<"$current_text")
  fi
  apt-mark unhold smartdns >/dev/null 2>&1 || true
  if [[ "$current" == "$SMARTDNS_VERSION" ]]; then
    log "SmartDNS 已是目标版本：$current；跳过安装。"
    return 0
  fi
  # Release40/46 的 Debian 包使用 40/46.x 版本号，不能和新的 1.YYYY.MM.DD 版本直接做 dpkg 大小比较。
  # 只有同属日期版本格式时，才把更高版本视为真正的 newer build。
  if [[ "$current" =~ ^1\.[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9]+$ ]] &&
     dpkg --compare-versions "$current" gt "$SMARTDNS_VERSION"; then
    log "SmartDNS 已是更新日期版本：$current；不降级。"
    return 0
  fi
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 180 "$SMARTDNS_URL" -o "$deb"
  actual=$(sha256sum "$deb" | awk '{print $1}')
  [[ "$actual" == "$SMARTDNS_SHA" ]] || die "SmartDNS SHA256 不匹配：$actual"
  [[ "$(dpkg-deb --field "$deb" Package)" == smartdns ]] || die 'SmartDNS 包名验证失败。'
  local package_arch
  package_arch=$(dpkg-deb --field "$deb" Architecture)
  # Upstream marks these architecture-specific, SHA256-pinned assets as "all".
  [[ "$package_arch" == all || "$package_arch" == "$(dpkg --print-architecture)" ]] || die 'SmartDNS 包架构验证失败。'
  local deb_version
  deb_version=$(dpkg-deb --field "$deb" Version 2>/dev/null || true)
  [[ "$deb_version" == "$SMARTDNS_DEB_VERSION" ]] || die "SmartDNS 包版本验证失败：期望 $SMARTDNS_DEB_VERSION，实际 ${deb_version:-unknown}。"
  apt_get install -y --allow-downgrades "$deb"
  current_text=$(smartdns -v 2>/dev/null | awk 'NF{print; exit}' || true)
  grep -Fq "$SMARTDNS_VERSION" <<<"$current_text" || die "SmartDNS 安装后程序版本验证失败：${current_text:-unknown}"
  SMARTDNS_DID_INSTALL=true
}

configure_smartdns_apt_policy() {
  local installed_version
  installed_version=$(dpkg-query -W -f='${Version}' smartdns 2>/dev/null || true)
  [[ -n "$installed_version" ]] || die '无法读取已安装 SmartDNS Debian 包版本。'
  install -d -m 0755 /etc/apt/preferences.d
  reject_symlink "$SMARTDNS_APT_PIN"
  make_mutable "$SMARTDNS_APT_PIN"
  cat >"$SMARTDNS_APT_PIN" <<'EOF'
# Managed by vps-init.sh
# SmartDNS is installed from the verified upstream GitHub .deb.
# Prevent Debian archive versions (e.g. 40/46.x) from replacing the verified
# upstream package. Upstream's .deb metadata uses YYYY.MM.DD-HHMM (binary prints 1.YYYY.MM.DD-HHMM).
Package: smartdns
Pin: release o=Debian
Pin-Priority: -1
EOF
  apt-mark unhold smartdns >/dev/null 2>&1 || true
  log "SmartDNS APT policy 已设置：当前 $installed_version；不使用永久 apt-mark hold。"
}

install_and_configure_smartdns() {
  CURRENT_STEP='安装并配置 SmartDNS'
  local staged="$TMP_DIR/smartdns.conf" user group
  smartdns_pkg_values
  [[ ! -L /etc/smartdns ]] || die '/etc/smartdns 不能是符号链接。'
  [[ ! -L "$SMARTDNS_CONF" ]] || die "$SMARTDNS_CONF 不能是符号链接。"
  install_smartdns_package
  command -v smartdns >/dev/null 2>&1 || die '安装后找不到 smartdns。'
  configure_smartdns_apt_policy
  user=$(systemctl show smartdns.service -p User --value 2>/dev/null || true); [[ -n "$user" ]] || user=root
  if id "$user" >/dev/null 2>&1; then group=$(id -gn "$user"); else user=root; group=root; fi
  install -d -m 0755 /etc/smartdns
  install -d -o "$user" -g "$group" -m 0750 /var/cache/smartdns
  if [[ "$SMARTDNS_DID_INSTALL" == true && -f "$SMARTDNS_CACHE" ]]; then
    systemctl stop smartdns.service >/dev/null 2>&1 || true
    mv "$SMARTDNS_CACHE" "$BACKUP_DIR/dns/smartdns.cache.before-$SMARTDNS_RELEASE"
    log 'SmartDNS 升级后已隔离旧持久化缓存。'
  fi

  systemctl disable --now systemd-resolved.service >/dev/null 2>&1 || true
  systemctl daemon-reload
  systemctl enable smartdns.service >/dev/null

  SMARTDNS_TRANSPORT='unknown'
  if smartdns_try_transport h2 "$staged"; then
    SMARTDNS_TRANSPORT='DoH (H2 优先)'
    log 'SmartDNS DoH（H2 优先）健康检查通过。'
  else
    warn 'SmartDNS DoH（H2 优先）健康检查失败，自动回退到 Cloudflare/Google UDP+TCP 53。'
    if smartdns_try_transport dns53 "$staged"; then
      SMARTDNS_TRANSPORT='DNS53'
      log 'SmartDNS UDP/TCP 53 回退健康检查通过。'
    else
      journalctl -u smartdns -n 60 --no-pager >&2 || true
      die 'SmartDNS DoH 与 UDP/TCP 53 上游均未通过健康检查。'
    fi
  fi

  log "SmartDNS 健康检查通过：$(smartdns -v 2>/dev/null | head -1)；上游=$SMARTDNS_TRANSPORT"
}

cleanup_legacy_network_stack() {
  CURRENT_STEP='迁移旧网络栈组件'
  local path backup="$BACKUP_DIR/legacy-404-network"
  local -a files=()
  if legacy_ipv6_sysctl_managed; then
    files+=("$LEGACY_IPV6_SYSCTL")
  fi
  if legacy_ipv6_unit_managed; then
    files+=("$LEGACY_NETWORK_UNIT")
    if [[ -e "$LEGACY_NETWORK_HELPER" || -L "$LEGACY_NETWORK_HELPER" ]]; then files+=("$LEGACY_NETWORK_HELPER"); fi
    if systemctl is-active --quiet 404-network-stack.service; then LEGACY_NETWORK_WAS_ACTIVE=true; fi
    if systemctl is-enabled --quiet 404-network-stack.service; then LEGACY_NETWORK_WAS_ENABLED=true; fi
  fi
  (( ${#files[@]} )) || return 0
  install -d -m 0700 "$backup"
  for path in "${files[@]}"; do
    cp -a -- "$path" "$backup/"
    make_mutable "$path"
  done
  LEGACY_NETWORK_CHANGED=true
  if [[ -f "$backup/${LEGACY_NETWORK_UNIT##*/}" ]]; then
    systemctl disable --now 404-network-stack.service
  fi
  rm -f -- "${files[@]}"
  systemctl daemon-reload
  log "已迁移旧 IPv6 持久化组件；备份=$backup"
}

rollback_legacy_network_stack() {
  [[ "$LEGACY_NETWORK_CHANGED" == true ]] || return 0
  local path backup="$BACKUP_DIR/legacy-404-network"
  for path in "$LEGACY_NETWORK_UNIT" "$LEGACY_NETWORK_HELPER" "$LEGACY_IPV6_SYSCTL"; do
    if [[ -e "$backup/${path##*/}" || -L "$backup/${path##*/}" ]]; then
      cp -a -- "$backup/${path##*/}" "$path" || warn "无法恢复 $path"
    fi
  done
  if [[ -f "$backup/${LEGACY_NETWORK_UNIT##*/}" ]]; then
    systemctl daemon-reload || true
    if [[ "$LEGACY_NETWORK_WAS_ENABLED" == true ]]; then systemctl enable 404-network-stack.service || true; fi
    if [[ "$LEGACY_NETWORK_WAS_ACTIVE" == true ]]; then systemctl start 404-network-stack.service || true; fi
  fi
  LEGACY_NETWORK_CHANGED=false
}

configure_system_dns() {
  CURRENT_STEP='固定系统 DNS'
  local staged="$TMP_DIR/resolv.conf"
  # SmartDNS first; the fallback keeps the host resolvable if SmartDNS stops.
  printf 'nameserver 127.0.0.1\nnameserver %s\noptions timeout:2 attempts:2\n' "$FALLBACK_DNS" >"$staged"
  make_mutable /etc/resolv.conf
  if mountpoint -q /etc/resolv.conf 2>/dev/null; then
    if cp "$staged" /etc/resolv.conf 2>/dev/null; then
      warn '/etc/resolv.conf 是挂载点，已原地写入；运行时可能在重启后重新生成。'
    else
      die '/etc/resolv.conf 是不可写挂载点，无法安全接管系统 DNS。'
    fi
  else
    rm -f /etc/resolv.conf
    install -m 0644 "$staged" /etc/resolv.conf
    RESOLV_WRITTEN_SHA=$(sha256sum "$staged" | awk '{print $1}')
    if command -v chattr >/dev/null 2>&1; then
      if chattr +i /etc/resolv.conf 2>/dev/null; then
        PERSIST_RESOLV_IMMUTABLE=true
      else
        warn '无法将 /etc/resolv.conf 设为 immutable；DHCP/cloud-init 未来可能覆盖它。'
      fi
    fi
  fi
  getent ahostsv4 debian.org >/dev/null 2>&1 || die '切换到本机 SmartDNS 后系统解析失败。'
  DNS_TX=false
}

backup_ssh_state() {
  install -d -m 0700 "$BACKUP_DIR/ssh"
  [[ ! -e "$SSH_MAIN" ]] || cp -a "$SSH_MAIN" "$BACKUP_DIR/ssh/sshd_config"
  if [[ -d "$SSH_DIR" ]]; then cp -a "$SSH_DIR" "$BACKUP_DIR/ssh/sshd_config.d"; else touch "$BACKUP_DIR/ssh/no-sshd_config.d"; fi
}

neutralize_ssh_file() {
  local f=$1 staged="$TMP_DIR/ssh.$RANDOM.$RANDOM"
  [[ -f "$f" && ! -L "$f" ]] || return 0
  make_mutable "$f"
  awk '
    BEGIN {
      global=1
      split("port listenaddress permitrootlogin pubkeyauthentication authenticationmethods passwordauthentication kbdinteractiveauthentication challengeresponseauthentication permitemptypasswords usepam x11forwarding authorizedkeysfile authorizedkeyscommand authorizedkeyscommanduser allowusers allowgroups denyusers denygroups", a, " ")
      for (i in a) blocked[a[i]]=1
    }
    {
      t=$0; sub(/^[[:space:]]+/, "", t); split(t, f, /[[:space:]=]+/); k=tolower(f[1])
      if (k=="match") global=0
      if (global && blocked[k] && t !~ /^#/) { print "# Disabled by vps-init.sh: " $0; next }
      print
    }
  ' "$f" >"$staged"
  if ! cmp -s "$f" "$staged"; then install -m 0644 "$staged" "$f"; fi
}

ensure_ssh_include() {
  local staged="$TMP_DIR/sshd-main"
  make_mutable "$SSH_MAIN"
  if grep -Eqi '^[[:space:]]*Include[[:space:]=]+/etc/ssh/sshd_config\.d/\*\.conf([[:space:]]|$)' "$SSH_MAIN"; then return 0; fi
  { echo 'Include /etc/ssh/sshd_config.d/*.conf'; cat "$SSH_MAIN"; } >"$staged"
  install -m 0644 "$staged" "$SSH_MAIN"
}

write_ssh_dropin() {
  install -d -m 0755 "$SSH_DIR"
  make_mutable "$SSH_DROPIN"
  {
    echo '# Managed by vps-init.sh'
    if ssh_has_backup_port; then echo 'Port 22'; fi
    cat <<EOF
Port $SSH_PORT
PermitRootLogin prohibit-password
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
AuthorizedKeysCommand none
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitEmptyPasswords no
UsePAM yes
X11Forwarding no
EOF
  } >"$SSH_DROPIN"
  chmod 0644 "$SSH_DROPIN"
}

ssh_has_backup_port() {
  [[ "$KEEP_SSH_22" == true && "$SSH_PORT" != 22 ]]
}

ufw_allow_port() {
  # prepend does not retag an existing rule with the same match.
  ufw prepend allow "$1/tcp" comment "$2" >/dev/null
}

preauthorize_ufw_ssh() {
  if ufw_is_active; then
    ufw_allow_port "$SSH_PORT" vps-init-ssh
    if ssh_has_backup_port; then ufw_allow_port 22 vps-init-ssh-backup; fi
  fi
}

validate_sshd_effective() {
  local context=${1:-user=root,host=localhost,addr=127.0.0.1} eff ports authfile authcmd
  eff=$(sshd -T -C "$context" 2>/dev/null) || return 1
  ports=$(awk '$1=="port"{print $2}' <<<"$eff" | sort -u)
  if ssh_has_backup_port; then
    [[ "$ports" == "22"$'\n'"$SSH_PORT" || "$ports" == "$SSH_PORT"$'\n22' ]] || return 1
  else
    [[ "$ports" == "$SSH_PORT" ]] || return 1
  fi
  awk -v selected="$SSH_PORT" -v backup="$KEEP_SSH_22" '
    $1 == "listenaddress" && $2 !~ (":" selected "$") && !(backup == "true" && $2 ~ /:22$/) { exit 1 }
  ' <<<"$eff" || return 1
  grep -Eq '^permitrootlogin (prohibit-password|without-password)$' <<<"$eff" || return 1
  grep -Eq '^pubkeyauthentication yes$' <<<"$eff" || return 1
  grep -Eq '^passwordauthentication no$' <<<"$eff" || return 1
  grep -Eq '^kbdinteractiveauthentication no$' <<<"$eff" || return 1
  grep -Fxq 'authenticationmethods publickey' <<<"$eff" || return 1
  authfile=$(awk '$1=="authorizedkeysfile"{$1=""; sub(/^ /,""); print; exit}' <<<"$eff")
  grep -Eq '(^|[[:space:]])\.ssh/authorized_keys([[:space:]]|$)|/root/\.ssh/authorized_keys' <<<"$authfile" || return 1
  authcmd=$(awk '$1=="authorizedkeyscommand"{print $2; exit}' <<<"$eff")
  [[ "$authcmd" == none ]] || return 1
}

validate_ssh_listeners() {
  local listeners ports
  listeners=$(ss -H -ltnp) || return 1
  ports=$(awk '/users:\(\("(sshd|sshd-session)",/ { sub(/^.*:/, "", $4); print $4 }' <<<"$listeners" | sort -u)
  if ssh_has_backup_port; then
    [[ "$ports" == "22"$'\n'"$SSH_PORT" || "$ports" == "$SSH_PORT"$'\n22' ]]
  else
    [[ "$ports" == "$SSH_PORT" ]]
  fi
}

validate_ssh_policy() {
  local peer='' _ local_addr=''
  validate_sshd_effective || return 1
  IFS=' ' read -r peer _ local_addr _ <<<"${SSH_CONNECTION:-}"
  if [[ -n "$peer" && -n "$local_addr" ]]; then
    validate_sshd_effective "user=root,host=$peer,addr=$peer,laddr=$local_addr,lport=$SSH_PORT"
  fi
}

ssh_listener_addresses() {
  local entries unit
  entries=$(ss -H -ltnp) || return 1
  awk '/users:.*\("(sshd|sshd-session)",/ { print $4 }' <<<"$entries"
  if systemctl is-active --quiet ssh.socket; then
    unit=$(systemctl show ssh.socket -p Listen --value) || return 1
    awk '{for (i=2; i<=NF; i++) if ($i=="(Stream)") print $(i-1)}' <<<"$unit"
  fi
}

confirm_ssh_listener_change() {
  local addresses ports
  addresses=$(ssh_listener_addresses) || die '无法读取现有 SSH 监听。'
  SSH_CONFIRMED_LISTENERS=$(sort -u <<<"$addresses")
  SSH_LISTENERS_CONFIRMED=true
  ports=$(awk 'NF { sub(/^.*:/, ""); print }' <<<"$addresses" | sort -u)
  if [[ "$ports" != *$'\n'* ]]; then return 0; fi
  warn "现有 SSH 监听多个端口，切换到端口 $SSH_PORT 可能改变 IPv4/IPv6 或 NAT 的访问路径。"
  printf '%s\n' "$addresses"
  if ! ask_yes_no '覆盖现有 SSH 分端口监听配置？' false; then
    die '已取消 SSH 切换。可用 --preserve-ssh 保留现有配置并继续初始化。'
  fi
}

configure_ssh() {
  CURRENT_STEP='配置 SSH'
  if [[ "$PRESERVE_SSH" == true ]]; then
    log '保留 SSH 监听、认证和服务。'
    return 0
  fi
  check_ssh_change_prerequisites
  if [[ "$SSH_LISTENERS_CONFIRMED" == true ]]; then
    [[ "$(ssh_listener_addresses | sort -u)" == "$SSH_CONFIRMED_LISTENERS" ]] ||
      die 'SSH 监听自确认后发生变化，拒绝覆盖；请重新运行配置。'
  fi
  backup_ssh_state
  backup_ufw_state
  SSH_TX=true
  UFW_TX=true
  preauthorize_ufw_ssh
  make_mutable "$SSH_MAIN"
  make_mutable "$SSH_DIR"
  local mf
  shopt -s nullglob
  for mf in "$SSH_DIR"/*; do make_mutable "$mf"; done
  shopt -u nullglob
  ensure_ssh_include
  neutralize_ssh_file "$SSH_MAIN"
  local f
  shopt -s nullglob
  for f in "$SSH_DIR"/*.conf; do [[ "$f" == "$SSH_DROPIN" ]] || neutralize_ssh_file "$f"; done
  shopt -u nullglob
  write_ssh_dropin
  sshd -t || die 'sshd -t 失败。'
  validate_ssh_policy || die 'sshd -T 最终监听或认证策略不符合目标。'
  SSH_RELOAD_ATTEMPTED=true
  systemctl reload ssh.service || die 'reload ssh.service 失败。'
  local attempt
  for ((attempt=0; attempt<10; attempt++)); do validate_ssh_listeners && break; sleep 1; done
  validate_ssh_listeners || die 'SSH 实际监听端口与目标不一致。'
  validate_ssh_policy || die 'reload 后 SSH 策略验证失败。'
  log "SSH 配置完成：$SSH_PORT/tcp；保留 22=$KEEP_SSH_22。"
}

backup_ufw_state() {
  install -d -m 0700 "$BACKUP_DIR/ufw"
  ufw_is_active && UFW_OLD_ACTIVE=true || UFW_OLD_ACTIVE=false
  [[ ! -d /etc/ufw ]] || cp -a /etc/ufw "$BACKUP_DIR/ufw/etc-ufw"
  [[ ! -e /etc/default/ufw ]] || cp -a /etc/default/ufw "$BACKUP_DIR/ufw/default-ufw"
}

ufw_is_active() {
  local status
  status=$(ufw status 2>/dev/null) || return 1
  grep -q '^Status: active$' <<<"$status"
}

ufw_delete_comment_rules() {
  local comment=$1 keep=${2:-} nums n
  while true; do
    nums=$(ufw status numbered | awk -v c="$comment" -v keep="$keep" '
      { line=$0; if (sub(/^.*[[:space:]]#[[:space:]]+/, "") && $0 == c) {
          n=line; sub(/^\[[[:space:]]*/,"",n); sub(/\].*/,"",n)
          sub(/^\[[^]]*\][[:space:]]*/,"",line); split(line, fields, /[[:space:]]+/)
          if (n~/^[0-9]+$/ && (keep == "" || fields[1] != keep)) print n
        }
      }
    ' | sort -rn) || return 1
    [[ -n "$nums" ]] || break
    while IFS= read -r n; do ufw --force delete "$n" >/dev/null || return 1; done <<<"$nums"
  done
}

set_ufw_ipv6() {
  [[ -f "$UFW_DEFAULT" && ! -L "$UFW_DEFAULT" ]] || die "$UFW_DEFAULT 必须是普通文件。"
  make_mutable "$UFW_DEFAULT"
  if grep -q '^IPV6=' "$UFW_DEFAULT"; then
    sed -i -E "s/^IPV6=.*/IPV6=$1/" "$UFW_DEFAULT"
  else
    printf '\nIPV6=%s\n' "$1" >>"$UFW_DEFAULT"
  fi
}

ufw_generic_ipv6_number() {
  local body=${1#'### tuple ### '} target source='Anywhere (v6)' action
  local -a parts=()
  body=${body%' comment='*}
  IFS=' ' read -r -a parts <<<"$body"
  (( ${#parts[@]} == 7 )) || return 0
  [[ "${parts[3]}" == ::/0 && "${parts[4]}" == any && "${parts[5]}" == ::/0 ]] || return 0
  case "${parts[6]}" in in|out) ;; *) return 0 ;; esac
  action=${parts[0]%%_*}
  target=${parts[2]}
  if [[ "$target" == any ]]; then
    target=Anywhere
    if [[ "${parts[1]}" != any ]]; then source="Anywhere/${parts[1]} (v6)"; fi
  fi
  if [[ "${parts[1]}" != any ]]; then target+="/${parts[1]}"; fi
  target+=" (v6) ${action^^} ${parts[6]^^} $source"
  ufw status numbered | awk -v target="$target" '
    /^\[[[:space:]]*[0-9]+\]/ {
      n=$0; sub(/^\[[[:space:]]*/,"",n); sub(/\].*/,"",n)
      sub(/^\[[^]]*\][[:space:]]*/,""); sub(/[[:space:]]+#.*/,"")
      sub(/ \((log|log-all|out)[^)]*\)$/,""); gsub(/[[:space:]]+/," "); sub(/ $/,"")
      if ($0==target) print n
    }'
}

ufw_sync_generic_ipv6() {
  # Read UFW's persisted tuples, including inactive rules. Never eval show-added
  # output or replay a generic command: that could change IPv4 actions/comments.
  local line body comment hex action protocol port destination source_port source direction reason existing match
  local i j anchor position
  local -a fields=() command_args=() originals=()
  [[ -r "$UFW_RULES" && -r "$UFW_RULES6" ]] || die '无法读取 UFW 规则文件。'
  mapfile -t originals <"$UFW_RULES"
  for ((i=0; i<${#originals[@]}; i++)); do
    line=${originals[i]}
    [[ "$line" == '### tuple ### '* ]] || continue
    body=${line#'### tuple ### '}
    comment=''
    hex=''
    if [[ "$body" == *' comment='* ]]; then
      hex=${body##*' comment='}
      body=${body%' comment='*}
    fi
    IFS=' ' read -r -a fields <<<"$body"
    reason=''
    if (( ${#fields[@]} != 7 )); then
      reason='应用配置或未知 tuple 格式'
    else
      action=${fields[0]} protocol=${fields[1]} port=${fields[2]} destination=${fields[3]}
      source_port=${fields[4]} source=${fields[5]} direction=${fields[6]}
      case "$action" in allow|deny|reject|allow_log|deny_log|reject_log|allow_log-all|deny_log-all|reject_log-all) ;; *) reason='LIMIT、路由或未知动作' ;; esac
      case "$protocol" in tcp|udp|any) ;; *) reason='无法安全映射的协议' ;; esac
      case "$direction" in in|out) ;; *) reason='接口限定或未知方向' ;; esac
      if [[ "$destination" != 0.0.0.0/0 || "$source" != 0.0.0.0/0 || "$source_port" != any ]]; then
        reason='源/目标地址、CIDR 或源端口限制'
      fi
      if [[ "$port" != any && ! "$port" =~ ^[0-9]+([,:][0-9]+)*$ ]]; then reason='未知端口格式'; fi
      if [[ -n "$hex" ]]; then
        if [[ "$hex" =~ ^([[:xdigit:]]{2})+$ && ! "$hex" =~ ^(..)*(00|0[aAdD]) ]]; then
          # shellcheck disable=SC2001 # Decode each hex byte, not a substring replacement.
          comment=$(printf '%b' "$(sed 's/../\\x&/g' <<<"$hex")")
        else
          reason='无法安全保留的注释编码'
        fi
      fi
    fi
    if [[ -n "$reason" ]]; then warn "跳过 IPv4 UFW 同步（$reason）：$line"; continue; fi
    match="$protocol $port ::/0 any ::/0 $direction"
    existing=$(awk -v key="$match" '
      /^### tuple ### / { line=$0; sub(/^### tuple ### /,"",line); sub(/ comment=.*/,"",line)
        sub(/^[^ ]+ /,"",line); if(line==key) print $0 }
    ' "$UFW_RULES6")
    if [[ -n "$existing" ]]; then
      # UFW may replace an existing action/comment on append. Preserve ownership
      # and policy, even when the operator's IPv6 action differs from IPv4.
      if [[ "$existing" != "### tuple ### $action $match"* ]]; then warn "保留冲突的 IPv6 UFW 规则，未覆盖：$existing"; fi
      continue
    fi
    command_args=("${action%%_*}" "$direction")
    if [[ "$action" == *_* ]]; then command_args+=("${action#*_}"); fi
    if [[ "$protocol" != any ]]; then command_args+=(proto "$protocol"); fi
    command_args+=(from ::/0 to ::/0)
    if [[ "$port" != any ]]; then command_args+=(port "$port"); fi
    if [[ -n "$comment" ]]; then command_args+=(comment "$comment"); fi
    # Insert before the next existing counterpart, preserving IPv4 rule order
    # (e.g. DENY an exception before a broader ALLOW) without moving user IPv6 rules.
    for ((j=i+1; j<${#originals[@]}; j++)); do
      anchor=${originals[j]//0.0.0.0\/0/::\/0}
      [[ "$anchor" == '### tuple ### '* ]] || continue
      grep -Fq -- "${anchor%' comment='*}" "$UFW_RULES6" || continue
      position=$(ufw_generic_ipv6_number "$anchor")
      if [[ "$position" =~ ^[0-9]+$ ]]; then command_args=(insert "$position" "${command_args[@]}"); break; fi
    done
    ufw "${command_args[@]}" >/dev/null
    grep -Fq "### tuple ### $action $match" "$UFW_RULES6" || die 'IPv6 UFW 规则写入验证失败。'
    log "已补充 IPv6 UFW：$action $direction $port/$protocol"
  done
  # The synchronizer must never rewrite an IPv4 rule, including its comment.
  cmp -s "$UFW_RULES" <(printf '%s\n' "${originals[@]}") || die '同步期间 IPv4 UFW 规则发生变化。'
}

ufw_ipv6_rule_numbers() {
  # Use UFW's own parser: specific IPv6 endpoints have no '(v6)' marker, while
  # an IPv4 comment may contain that text. It also groups app tuples
  # into the exact same numbers as `ufw status numbered` and `ufw delete NUM`.
  /usr/bin/python3 - <<'UFW_NUMBERS'
import gettext
import sys
gettext.install('ufw')
from ufw.frontend import UFWFrontend

# UFW validates its launcher and parent ownership, including sys.argv[0].
# Python stdin uses '-', so point that check at the actual packaged launcher.
sys.argv[0] = '/usr/sbin/ufw'
backend = UFWFrontend(False).backend
if not backend.use_ipv6():
    raise RuntimeError('IPV6=yes is required before enumerating IPv6 rules')
total = backend.get_rules_count(False) + backend.get_rules_count(True)
numbers = []
for number in range(total, 0, -1):
    rule = backend.get_rule_by_number(number)
    if rule is None:
        raise RuntimeError('Unrecognized UFW rule number')
    if rule.v6:
        numbers.append(number)
print('\n'.join(map(str, numbers)))
UFW_NUMBERS
}

ufw_remove_ipv6_rules() {
  local nums n before original_v4
  original_v4=$(sha256sum "$UFW_RULES") || return 1
  # The UFW parser also works while inactive. Re-read after every batch; app
  # profiles can expand to several tuples behind one visible rule number.
  while true; do
    nums=$(ufw_ipv6_rule_numbers) || return 1
    [[ -n "$nums" ]] || break
    before=$nums
    while IFS= read -r n; do
      [[ "$n" =~ ^[0-9]+$ ]] || return 1
      ufw --force delete "$n" >/dev/null || return 1
    done <<<"$nums"
    nums=$(ufw_ipv6_rule_numbers) || return 1
    [[ "$nums" != "$before" ]] || return 1
  done
  ! grep -q '^### tuple ### ' "$UFW_RULES6" || return 1
  [[ "$(sha256sum "$UFW_RULES")" == "$original_v4" ]]
}

configure_ufw() {
  CURRENT_STEP='配置 UFW'
  local ipv6_was_enabled=false status
  if [[ "$PRESERVE_SSH" == true ]]; then
    log '保留现有 UFW 状态与放行规则。'
    return 0
  fi
  if [[ "$UFW_TX" == false ]]; then
    backup_ufw_state
    UFW_TX=true
  fi
  if [[ "$NETWORK_REQUEST" != auto || "$NETWORK_STACK" == dual ]]; then
    if grep -Eiq "^IPV6=['\"]?yes['\"]?$" "$UFW_DEFAULT"; then ipv6_was_enabled=true; fi
    # Expose hidden user6.rules before numbered deletion. Load both families
    # with SSH protection in place before touching existing IPv6 rules.
    set_ufw_ipv6 yes
    if [[ "$ipv6_was_enabled" == false && "$UFW_OLD_ACTIVE" == true ]]; then
      # Rule commands reload user6.rules too. The IPv6 base chains must exist
      # first when moving from IPV6=no, or ip6tables-restore can fail mid-command.
      ufw reload >/dev/null
    fi
  fi
  if [[ "$NETWORK_REQUEST" == ipv4 ]]; then
    ufw_remove_ipv6_rules || die '清理 IPv6 UFW 失败，拒绝关闭 IPv6 支持。'
    set_ufw_ipv6 no
  fi
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw_allow_port "$SSH_PORT" vps-init-ssh
  if ssh_has_backup_port; then ufw_allow_port 22 vps-init-ssh-backup; fi
  ufw prepend allow 443/tcp comment 'vps-init-443-tcp' >/dev/null
  ufw prepend allow 443/udp comment 'vps-init-443-udp' >/dev/null
  if [[ "$UFW_OLD_ACTIVE" == true ]]; then
    # Apply the updated IPv6 setting without disabling the active firewall.
    ufw reload >/dev/null
  else
    ufw --force enable >/dev/null
  fi
  ufw_is_active || die 'UFW 未成功启用。'
  if [[ "$NETWORK_REQUEST" == dual || ( "$NETWORK_REQUEST" == auto && "$NETWORK_STACK" == dual ) ]]; then
    ufw_sync_generic_ipv6
    ufw reload >/dev/null
  fi
  ufw_delete_comment_rules vps-init-ssh "$SSH_PORT/tcp"
  if ssh_has_backup_port; then
    ufw_delete_comment_rules vps-init-ssh-backup 22/tcp
  else
    # A previous backup rule may have the same match as the new primary rule.
    ufw_delete_comment_rules vps-init-ssh-backup
    ufw_allow_port "$SSH_PORT" vps-init-ssh
  fi
  status=$(ufw status) || die '无法验证 UFW 最终状态。'
  grep -q '^Status: active$' <<<"$status" || die 'UFW 未成功启用。'
  grep -Eq "^${SSH_PORT}/tcp[[:space:]]+ALLOW" <<<"$status" || die 'UFW 未放行新 SSH 端口。'
  if ssh_has_backup_port; then
    grep -Eq '^22/tcp[[:space:]]+ALLOW' <<<"$status" || die 'UFW 未放行 SSH 备用端口。'
  fi
  UFW_TX=false
  SSH_TX=false
  SSH_KEYS_TX=false
}

write_cf_tool() {
  local path
  for path in "$CF_TOOL" "$CF_SERVICE" "$CF_TIMER"; do
    reject_symlink "$path"
    ensure_dir "${path%/*}"
    make_mutable "$path"
  done
  cat >"$CF_TOOL" <<'CFEOF'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
readonly COMMENT='vps-init-cf8443'
TMP=$(mktemp -d /root/vps-init-cf.XXXXXXXX)
trap 'rm -rf "$TMP"' EXIT
[[ $EUID -eq 0 ]] || { echo 'root required' >&2; exit 1; }
ufw status | grep -q '^Status: active$' || { echo 'UFW inactive' >&2; exit 1; }
curl -fsSL --retry 3 https://www.cloudflare.com/ips-v4 -o "$TMP/v4"
curl -fsSL --retry 3 https://www.cloudflare.com/ips-v6 -o "$TMP/v6"
python3 - "$TMP/v4" "$TMP/v6" <<'PY'
import ipaddress,sys
for p in sys.argv[1:]:
    with open(p) as f:
        vals=[x.strip() for x in f if x.strip()]
    if not vals: raise SystemExit(f'empty: {p}')
    for v in vals: ipaddress.ip_network(v, strict=False)
PY
# Refuse to pretend 8443 is Cloudflare-only when an unmanaged global allow exists.
if ufw status | grep -E '^8443/tcp[[:space:]]+ALLOW[[:space:]]+(Anywhere|Anywhere \(v6\))' | grep -vq "# $COMMENT"; then
  echo 'Unmanaged global 8443/tcp ALLOW exists; refusing to modify it.' >&2
  exit 1
fi
# Remove only rules owned by this tool, then install the current official list.
while :; do
  nums=$(ufw status numbered | awk -v c="# $COMMENT" 'index($0,c){n=$0;sub(/^\[[[:space:]]*/,"",n);sub(/\].*/,"",n);gsub(/[[:space:]]/,"",n);if(n~/^[0-9]+$/)print n}' | sort -rn)
  [[ -n "$nums" ]] || break
  while IFS= read -r n; do [[ -n "$n" ]] && ufw --force delete "$n" >/dev/null; done <<<"$nums"
done
while IFS= read -r cidr; do [[ -n "$cidr" ]] && ufw allow proto tcp from "$cidr" to any port 8443 comment "$COMMENT" >/dev/null; done <"$TMP/v4"
if grep -Eq '^IPV6=yes' /etc/default/ufw 2>/dev/null; then
  while IFS= read -r cidr; do [[ -n "$cidr" ]] && ufw allow proto tcp from "$cidr" to any port 8443 comment "$COMMENT" >/dev/null; done <"$TMP/v6"
fi
ufw status | grep -Fq "# $COMMENT" || { echo 'No managed rules installed' >&2; exit 1; }
CFEOF
  chmod 0755 "$CF_TOOL"
  cat >"$CF_SERVICE" <<EOF
[Unit]
Description=Refresh Cloudflare-only 8443 UFW rules
After=network-online.target ufw.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$CF_TOOL
EOF
  cat >"$CF_TIMER" <<'EOF'
[Unit]
Description=Daily Cloudflare UFW refresh

[Timer]
OnBootSec=10min
OnUnitActiveSec=1d
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

configure_cf8443() {
  CURRENT_STEP='配置 Cloudflare 8443'
  [[ "$PRESERVE_SSH" == false ]] || return 0
  local currently=false
  [[ -x "$CF_TOOL" || -e "$CF_TIMER" ]] && currently=true
  if ufw status 2>/dev/null | grep -Fq '# vps-init-cf8443'; then currently=true || true; fi
  if [[ "$CF8443_MODE" == auto ]]; then
    [[ "$currently" == true ]] || { log 'Cloudflare 8443：默认关闭。'; return 0; }
    CF8443_MODE=enable
  fi
  if [[ "$CF8443_MODE" == enable ]]; then
    write_cf_tool
    systemctl daemon-reload
    "$CF_TOOL"
    systemctl enable --now vps-init-cloudflare-8443.timer >/dev/null
    log 'Cloudflare-only 8443 已启用，并设置每日刷新。'
  else
    ufw_delete_comment_rules 'vps-init-cf8443'
    systemctl disable --now vps-init-cloudflare-8443.timer >/dev/null 2>&1 || true
    rm -f "$CF_SERVICE" "$CF_TIMER" "$CF_TOOL"
    systemctl daemon-reload
    log '已删除本脚本管理的 Cloudflare 8443 配置。'
  fi
}

rollback_fail2ban() {
  local path saved
  clear_fail2ban_probe || warn '无法撤销 Fail2ban 测试封禁。'
  if [[ "$FAIL2BAN_TX" == true ]]; then
    FAIL2BAN_TX=false
    warn '正在回滚 Fail2ban 管理的配置。'
    for path in "${FAIL2BAN_MANAGED_FILES[@]}"; do
      saved="$BACKUP_DIR/fail2ban/$path"
      if [[ -f "$saved" ]]; then
        cp -a -- "$saved" "$FAIL2BAN_DIR/$path" || warn "无法恢复 $FAIL2BAN_DIR/$path"
      else
        rm -f -- "$FAIL2BAN_DIR/$path" || warn "无法移除 $FAIL2BAN_DIR/$path"
      fi
    done
    if [[ "$FAIL2BAN_SERVICE_CHANGED" == true ]]; then
      if [[ "$FAIL2BAN_OLD_ACTIVE" == true ]]; then
        systemctl reload-or-restart fail2ban.service || warn '无法恢复 Fail2ban 服务。'
      else
        systemctl stop fail2ban.service || warn '无法停止 Fail2ban 服务。'
      fi
      if [[ "$FAIL2BAN_OLD_ENABLED" == false ]]; then
        systemctl disable fail2ban.service || warn '无法恢复 Fail2ban 开机自启状态。'
      fi
    fi
  fi
  if [[ "$FAIL2BAN_RUNTIME_MASK" == true ]]; then
    systemctl disable fail2ban.service >/dev/null 2>&1 || true
    systemctl unmask --runtime fail2ban.service || warn '无法移除本次安装的 Fail2ban 临时 mask。'
  fi
}

fail2ban_ufw_active() {
  local status
  command -v ufw >/dev/null 2>&1 || return 1
  status=$(ufw status) || die '无法读取 UFW 状态。'
  [[ "$status" == 'Status: active'* ]]
}

fail2ban_reality_available() {
  local logs
  systemctl is-active --quiet sing-box.service || return 1
  logs=$(journalctl -u sing-box.service -b --no-pager -o cat -n 500) || return 1
  grep -Eq 'inbound/vless\[[^]]+\].*REALITY:' <<<"$logs" && return 0
  grep -Eq 'inbound/vless\[[^]]+\]' <<<"$logs" || return 1
  python3 - "$SINGBOX_CONFIG" <<'PY'
import json
import sys

try:
    with open(sys.argv[1]) as config:
        inbounds = json.load(config).get("inbounds", [])
    sys.exit(not any(
        inbound.get("type") == "vless"
        and inbound.get("tls", {}).get("enabled") is True
        and inbound["tls"].get("reality", {}).get("enabled") is True
        for inbound in inbounds
    ))
except (OSError, ValueError, AttributeError, TypeError):
    sys.exit(1)
PY
}

fail2ban_default_ignoreip() {
  /usr/bin/python3 - "$FAIL2BAN_DIR" <<'PY'
import sys
from fail2ban.client.configreader import ConfigReader

reader = ConfigReader()
reader.setBaseDir(sys.argv[1])
reader.read("jail")
if reader.has_option("DEFAULT", "ignoreip"):
    print(" ".join(reader.get("DEFAULT", "ignoreip").split()))
PY
}

verify_fail2ban_action() {
  local jail=$1 expected=$2 actions
  actions=$(fail2ban-client get "$jail" actions) || return 1
  # Avoid exercising additional custom actions such as mail/webhook notifications.
  [[ "${actions##*$'\n'}" == "$expected" ]] || return 1
  # Force action initialization using an unused documentation address. Verify
  # the kernel-side result because Fail2ban can queue a ban before the action runs.
  local address=192.0.2.254 attempt ok=false firewall banned
  local peer=${SSH_CONNECTION:-}
  peer=${peer%% *}
  [[ "$address" != "$peer" ]] || address=198.51.100.254
  firewall=$(fail2ban_firewall_state "$expected") || return 1
  banned=$(fail2ban-client get "$jail" banip) || return 1
  if grep -Fqw "$address" <<<"$firewall"$'\n'"$banned"; then
    warn "Fail2ban 探测地址 $address 已存在于防火墙规则。"
    return 1
  fi
  FAIL2BAN_PROBE_JAIL=$jail
  FAIL2BAN_PROBE_IP=$address
  local added
  added=$(fail2ban-client set "$jail" banip "$address") || return 1
  if [[ "$added" != 1 ]]; then
    FAIL2BAN_PROBE_IP=''
    return 1
  fi
  for ((attempt=0; attempt<10; attempt++)); do
    if firewall=$(fail2ban_firewall_state "$expected") && grep -Fqw "$address" <<<"$firewall"; then
      ok=true
      break
    fi
    sleep 1
  done
  clear_fail2ban_probe || return 1
  for ((attempt=0; attempt<10; attempt++)); do
    firewall=$(fail2ban_firewall_state "$expected") || return 1
    if ! grep -Fqw "$address" <<<"$firewall"; then
      [[ "$ok" == true ]]
      return
    fi
    sleep 1
  done
  return 1
}

fail2ban_firewall_state() {
  if [[ "$1" == ufw ]]; then ufw status; else nft -n list ruleset; fi
}

clear_fail2ban_probe() {
  [[ -n "$FAIL2BAN_PROBE_IP" ]] || return 0
  fail2ban-client set "$FAIL2BAN_PROBE_JAIL" unbanip "$FAIL2BAN_PROBE_IP" >/dev/null || return 1
  FAIL2BAN_PROBE_IP=''
}

fail2ban_package_installed() {
  local status
  status=$(dpkg-query -W -f='${db:Status-Status}' fail2ban 2>/dev/null) && [[ "$status" == installed ]]
}

configure_fail2ban() {
  CURRENT_STEP='配置 Fail2ban'
  fail2ban_package_installed || die 'Fail2ban 软件包未安装或尚未完成配置。'
  local action=${1:-ufw} reality=true action_config='ufw[blocktype=deny]' path peer=''
  local -a jails=(sshd sshd-slow)
  if [[ "$INSTALL_MODE" == fail2ban ]]; then
    if ! fail2ban_reality_available; then reality=false; fi
    if [[ "$action" == nftables ]]; then action_config='nftables[type=allports]'; fi
    peer=${SSH_CONNECTION:-}
    peer=${peer%% *}
    # Only literal SSH peer addresses may be written to jail config.
    [[ "$peer" =~ ^[0-9A-Fa-f:.]+$ ]] || peer=''
    if systemctl is-active --quiet fail2ban.service; then
      FAIL2BAN_OLD_ACTIVE=true
      fail2ban-client status
    fi
    if systemctl is-enabled --quiet fail2ban.service; then FAIL2BAN_OLD_ENABLED=true; fi
    reject_symlink "$FAIL2BAN_DIR"
    reject_symlink "$FAIL2BAN_DIR/jail.d"
    reject_symlink "$FAIL2BAN_DIR/filter.d"
    install -d -m 0700 "$BACKUP_DIR/fail2ban/jail.d" "$BACKUP_DIR/fail2ban/filter.d"
  fi
  install -d -m 0755 "$FAIL2BAN_DIR/jail.d" "$FAIL2BAN_DIR/filter.d"
  for path in "${FAIL2BAN_MANAGED_FILES[@]}"; do
    reject_symlink "$FAIL2BAN_DIR/$path"
    if [[ "$INSTALL_MODE" == fail2ban && -f "$FAIL2BAN_DIR/$path" ]]; then
      cp -a -- "$FAIL2BAN_DIR/$path" "$BACKUP_DIR/fail2ban/$path"
    fi
    make_mutable "$FAIL2BAN_DIR/$path"
  done
  if [[ "$INSTALL_MODE" == fail2ban ]]; then
    FAIL2BAN_TX=true
    # Replace our legacy global defaults with jail-scoped settings below.
    rm -f -- "$FAIL2BAN_DIR/jail.d/00-vps-init-defaults.local"
  else
    cat >"$FAIL2BAN_DIR/jail.d/00-vps-init-defaults.local" <<'EOF'
[DEFAULT]
backend = systemd
banaction = ufw[blocktype=deny]
ignoreip = 127.0.0.1/8 ::1
EOF
  fi
  cat >"$FAIL2BAN_DIR/jail.d/vps-init-sshd.local" <<'EOF'
[sshd]
enabled = true
filter = sshd
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1d

[sshd-slow]
enabled = true
filter = sshd
backend = systemd
maxretry = 20
findtime = 24h
bantime = 7d
EOF
  if [[ "$reality" == true ]]; then
    if [[ "$INSTALL_MODE" == fail2ban ]]; then jails+=(sing-box-reality sing-box-reality-slow); fi
    cat >"$FAIL2BAN_DIR/filter.d/vps-init-sing-box-reality.conf" <<'EOF'
[Definition]
failregex = ^.*inbound/vless\[[^]]+\]: process connection from \[?<HOST>\]?:\d+: TLS handshake: REALITY: processed invalid connection$
ignoreregex =
journalmatch = _SYSTEMD_UNIT=sing-box.service
EOF
    cat >"$FAIL2BAN_DIR/jail.d/vps-init-sing-box-reality.local" <<'EOF'
[sing-box-reality]
enabled = true
filter = vps-init-sing-box-reality
backend = systemd
maxretry = 300
findtime = 10m
bantime = 7d

[sing-box-reality-slow]
enabled = true
filter = vps-init-sing-box-reality
backend = systemd
maxretry = 500
findtime = 7d
bantime = 28d
EOF
  else
    # Keep the filter available for custom jails that reference it.
    rm -f -- "$FAIL2BAN_DIR/jail.d/vps-init-sing-box-reality.local"
  fi
  if [[ "$INSTALL_MODE" == fail2ban ]]; then
    local ignore_defaults
    ignore_defaults=$(fail2ban_default_ignoreip)
    for path in "$FAIL2BAN_DIR/jail.d/vps-init-sshd.local" "$FAIL2BAN_DIR/jail.d/vps-init-sing-box-reality.local"; do
      [[ -f "$path" ]] || continue
      awk -v action="$action_config" -v ignore="$ignore_defaults 127.0.0.1/8 ::1 $peer" '
        { print }
        /^backend = systemd$/ { print "banaction = " action; print "ignoreip = " ignore }
      ' "$path" >"$TMP_DIR/fail2ban-jail.local"
      install -m 0600 "$TMP_DIR/fail2ban-jail.local" "$path"
    done
  fi
  fail2ban-client -t >/dev/null || die 'Fail2ban 配置测试失败。'
  if [[ "$INSTALL_MODE" == fail2ban ]]; then
    FAIL2BAN_SERVICE_CHANGED=true
    systemctl reload-or-restart fail2ban.service
  else
    systemctl enable fail2ban.service >/dev/null
    systemctl restart fail2ban.service
  fi
  systemctl is-active --quiet fail2ban.service || die 'Fail2ban 服务未运行。'
  local attempt jail
  for ((attempt=0; attempt<15; attempt++)); do fail2ban-client ping >/dev/null 2>&1 && break; sleep 1; done
  fail2ban-client ping >/dev/null 2>&1 || die 'Fail2ban 未响应 fail2ban-client ping。'
  for jail in "${jails[@]}"; do
    fail2ban-client status "$jail" >/dev/null || die "Fail2ban Jail 未运行：$jail"
    if [[ "$INSTALL_MODE" == fail2ban ]]; then
      verify_fail2ban_action "$jail" "$action" || die "Fail2ban 封禁动作验证失败：$jail ($action)"
    fi
  done
  if [[ "$INSTALL_MODE" == fail2ban ]]; then
    systemctl enable fail2ban.service >/dev/null
  fi
  systemctl is-enabled --quiet fail2ban.service || die 'Fail2ban 未设置为开机自启。'
  if [[ "$INSTALL_MODE" == fail2ban ]]; then
    FAIL2BAN_TX=false
    log "Fail2ban 封禁后端=$action；REALITY=$reality；备份=$BACKUP_DIR/fail2ban"
  fi
  log "Fail2ban jails：$(fail2ban-client status | sed -n 's/.*Jail list:[[:space:]]*//p')"
}

# No files, locks, APT refreshes or temporary files are created by audit helpers.
# This prefix is empty in production; offline tests replace the constant in a copy.
readonly AUDIT_ROOT=''

hardening_backup() {
  local path=$1 dest="$BACKUP_DIR/files$1"
  [[ -n "$BACKUP_DIR" ]] || die '缺少备份目录，拒绝修改。'
  reject_symlink "$path"
  if [[ -e "$path" && ! -e "$dest" ]]; then
    install -d -m 0700 "${dest%/*}"
    cp -a -- "$path" "$dest"
  fi
}

record_trusted_keys() {
  local fingerprints
  if [[ "$REUSE_PUBLIC_KEY" == true ]]; then fingerprints=$REUSED_KEY_FINGERPRINTS
  else fingerprints=$(ssh_public_key_fingerprints <<<"$PUBLIC_KEY"); fi
  [[ -n "$fingerprints" ]] || die '没有已确认的公钥指纹。'
  reject_symlink "${TRUSTED_KEYS_STATE%/*}"
  reject_symlink "$TRUSTED_KEYS_STATE"
  hardening_backup "$TRUSTED_KEYS_STATE"
  install -d -o root -g root -m 0700 "${TRUSTED_KEYS_STATE%/*}"
  # Replace this account's record only; keep decisions for other accounts.
  { if [[ -f "$TRUSTED_KEYS_STATE" ]]; then awk -F '\t' -v p="$AUTHORIZED_KEYS" '$1 != p' "$TRUSTED_KEYS_STATE"; fi
    while IFS= read -r fp; do printf '%s\t%s\n' "$AUTHORIZED_KEYS" "$fp"; done <<<"$fingerprints"
  } >"$TMP_DIR/trusted-keys"
  install -o root -g root -m 0600 "$TMP_DIR/trusted-keys" "$TRUSTED_KEYS_STATE"
  cmp -s "$TMP_DIR/trusted-keys" "$TRUSTED_KEYS_STATE" || die '公钥指纹记录验证失败。'
}

write_security_update_policy() {
  cat <<'EOF'
// Managed by 404-vps-tools. Preserve dpkg holds and exclude external packages.
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
  "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};
Unattended-Upgrade::Package-Blacklist { "^sing-box$"; "^smartdns$"; };
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Mail "";
APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
}

security_updates_enabled() {
  local config
  config=$(apt-config dump 2>/dev/null) || return 1
  grep -Fxq 'APT::Periodic::Unattended-Upgrade "1";' <<<"$config" &&
    grep -Fxq 'APT::Periodic::Enable "1";' <<<"$config" &&
    systemctl is-enabled --quiet apt-daily.timer && systemctl is-enabled --quiet apt-daily-upgrade.timer
}

configure_security_updates() {
  [[ "$AUTO_SECURITY" == true ]] || { log '未选择自动安全更新，保留现状。'; return 0; }
  ensure_dir "${SECURITY_APT_CONF%/*}"
  hardening_backup "$SECURITY_APT_CONF"
  write_security_update_policy >"$TMP_DIR/security-policy"
  install -m 0644 "$TMP_DIR/security-policy" "$SECURITY_APT_CONF"
  # Install only after the restrictive policy is in place.
  apt_get install -y unattended-upgrades
  local effective origins
  effective=$(apt-config dump)
  origins=$(awk '/^Unattended-Upgrade::(Origins-Pattern|Allowed-Origins):: /' <<<"$effective")
  # shellcheck disable=SC2016 # APT expands this placeholder at upgrade time.
  [[ "$origins" == 'Unattended-Upgrade::Origins-Pattern:: "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";' ]] ||
    die '自动安全更新来源验证失败，请检查其他 APT 配置。'
  grep -Fxq 'Unattended-Upgrade::Automatic-Reboot "false";' <<<"$effective" || die '禁止自动重启的配置未生效。'
  grep -Fxq 'Unattended-Upgrade::Mail "";' <<<"$effective" || die '禁止邮件的配置未生效。'
  systemctl enable apt-daily.timer apt-daily-upgrade.timer
  security_updates_enabled || die '自动安全更新开机自启验证失败。'
}

check_boot_services() {
  local unit result enabled active extra before
  local -a units=(ssh.service ufw.service smartdns.service fail2ban.service chrony.service cron.service vnstat.service sing-box.service)
  [[ ! -f "$CF_TIMER" ]] || units+=(vps-init-cloudflare-8443.timer)
  units+=(apt-daily.timer apt-daily-upgrade.timer)
  BOOT_REPORT=''
  for unit in "${units[@]}"; do
    before=$(systemctl is-enabled "$unit" 2>/dev/null || true)
    enabled=$before
    result=''
    if [[ "$PRESERVE_SSH" == true && "$unit" =~ ^(ssh|ufw|fail2ban)\.service$ ]]; then
      result='保留 SSH：只报告'
    elif [[ "$unit" == ssh.service ]] && systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
      result='检测到 ssh.socket 自启：只报告，避免冲突'
    else
      if [[ "$unit" == sing-box.service ]]; then configure_singbox_boot_gate; fi
      if [[ "$before" != enabled ]]; then
        printf '%s\t%s\n' "$unit" "$before" >>"$BACKUP_DIR/boot-before.tsv"
        if ! systemctl enable "$unit"; then result='启用失败，请检查'; fi
      fi
      enabled=$(systemctl is-enabled "$unit" 2>/dev/null || true)
      [[ "$enabled" == enabled ]] || result="${result}；未获得持久自启状态"
    fi
    active=$(systemctl is-active "$unit" 2>/dev/null || true)
    extra=''
    if [[ "$unit" == ufw.service ]]; then
      extra="；$(ufw status 2>/dev/null | head -1 || true)"
      if [[ "$PRESERVE_SSH" == false && "$extra" != *'Status: active'* ]]; then result="${result}；ufw 状态不是 active，请检查"; fi
    fi
    if [[ "$unit" == sing-box.service && "$enabled" == enabled && ! -e "$SINGBOX_CONFIG" ]]; then extra='；已启用，等待配置'; fi
    BOOT_REPORT+="$unit: ${enabled:-未知} / ${active:-未知}${extra} ${result}"$'\n'
  done
}

audit_add() {
  local target=$3 detail=$4
  target=${target//$'\t'/ }; target=${target//$'\n'/ }; target=${target//$'\r'/ }; target=${target//$'\e'/ }
  detail=${detail//$'\t'/ }; detail=${detail//$'\n'/ }; detail=${detail//$'\r'/ }; detail=${detail//$'\e'/ }
  AUDIT_FINDINGS+=("$1"$'\t'"$2"$'\t'"$target"$'\t'"$detail")
}

# Owner package of a path. Debian 12 dpkg does not resolve the merged-/usr aliases, so a
# package that registered /usr/lib/... is not found through /lib/... (and vice versa);
# try the alias before concluding that nothing owns the path.
audit_package_owner() {
  local candidate record package
  local -a candidates=("$1")
  case "$1" in
    /lib/*|/bin/*|/sbin/*) candidates+=("/usr$1") ;;
    /usr/lib/*|/usr/bin/*|/usr/sbin/*) candidates+=("${1#/usr}") ;;
  esac
  for candidate in "${candidates[@]}"; do
    record=$(dpkg-query -S -- "$candidate" 2>/dev/null | head -1) || continue
    [[ "$record" == *': '* ]] || continue
    package=${record%%: *}
    printf '%s\n' "${package%%,*}"
    return 0
  done
  return 1
}

# FragmentPath of a unit. systemd cannot show template units such as getty@.service, so
# fall back to the standard unit directories.
audit_unit_fragment() {
  local unit=$1 path dir
  path=$(systemctl show -p FragmentPath --value "$unit" 2>/dev/null || true)
  if [[ -z "$path" ]]; then
    for dir in /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system; do
      if [[ -f "$AUDIT_ROOT$dir/$unit" ]]; then path="$dir/$unit"; break; fi
    done
  fi
  printf '%s\n' "$path"
}

audit_debian_package() {
  # Require the *installed version* to have an official origin in the local APT cache.
  # No network access. Unknown/obsolete versions are intentionally reported for review.
  local version policy sources
  version=$(dpkg-query -W -f='${Version}' -- "$1" 2>/dev/null) || return 1
  policy=$(apt-cache policy -- "$1" 2>/dev/null) || return 1
  sources=$(awk '
    /^[ ]*[0-9]+ / {source=$0; sub(/^[ ]*[0-9]+ /,"",source)}
    /release / && /(^|[, ])o=Debian([, ]|$)/ {print source}
  ' <<<"$AUDIT_APT_SOURCES")
  awk -v version="$version" -v sources="$sources" '
    BEGIN {n=split(sources,s,"\n"); for(i=1;i<=n;i++) official[s[i]]=1}
    $1=="***" {v=$2; next}
    NF==2 && $2 ~ /^[0-9]+$/ {v=$1; next}
    v==version && $1 ~ /^[0-9]+$/ {line=$0; sub(/^[ ]*[0-9]+ /,"",line); if(official[line]) ok=1}
    END {exit !ok}' <<<"$policy"
}

audit_session_key() {
  local ip port server serverport pid=$PPID parent comm since logs fp found=''
  IFS=' ' read -r ip port server serverport <<<"${SSH_CONNECTION:-}"
  [[ -n "$ip" && "$port" =~ ^[0-9]+$ && -n "$server" && "$serverport" =~ ^[0-9]+$ ]] || return 1
  # Bind the log to a live sshd ancestor and its start time, not an arbitrary old login.
  while [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 )); do
    comm=$(ps -o comm= -p "$pid") || return 1
    if [[ "$comm" == sshd || "$comm" == sshd-session ]]; then
      since=$(ps -o lstart= -p "$pid") || return 1
      since=$(date -d "$since" '+%Y-%m-%d %H:%M:%S') || return 1
      logs=$(journalctl -b --since "$since" --no-pager -o cat "_PID=$pid" 2>/dev/null) || return 1
      fp=$(awk -v ip="$ip" -v port="$port" '
        $1 == "Accepted" && $2 == "publickey" && $5 == "from" && $6 == ip && $7 == "port" && $8 == port {
          for(i=9;i<=NF;i++) if($i ~ /^SHA256:[A-Za-z0-9+\/]+$/) print $i
        }' <<<"$logs" | sort -u)
      if [[ -n "$fp" ]]; then found+="$fp"$'\n'; fi
    fi
    parent=$(ps -o ppid= -p "$pid") || return 1
    pid=${parent//[[:space:]]/}
  done
  found=$(printf '%s' "$found" | sed '/^$/d' | sort -u)
  [[ -n "$found" && "$found" != *$'\n'* ]] || return 1
  printf '%s\n' "$found"
}

audit_regular_key_path() {
  local path=$1 parent=$1
  [[ -f "$path" && ! -L "$path" ]] || return 1
  while [[ "$parent" != / && -n "$parent" ]]; do
    [[ ! -L "$parent" ]] || return 1
    parent=${parent%/*}
  done
}

audit_keys() {
  local file line fp comment recorded count owner mode
  for file in "$AUDIT_ROOT"/root/.ssh/authorized_keys "$AUDIT_ROOT"/home/*/.ssh/authorized_keys; do
    [[ -e "$file" || -L "$file" ]] || continue
    if ! audit_regular_key_path "$file"; then audit_add B keys "$file" '路径不是普通文件或含软链接，只报告'; continue; fi
    recorded=''
    if audit_regular_key_path "$TRUSTED_KEYS_STATE"; then
      IFS=' ' read -r owner mode < <(stat -c '%u %a' "$TRUSTED_KEYS_STATE")
      if [[ "$owner" == 0 ]] && (( !(8#$mode & 022) )); then
        recorded=$(awk -F '\t' -v p="$file" '$1 == p {print $2}' "$TRUSTED_KEYS_STATE")
      fi
    fi
    count=$(ssh_public_key_fingerprints "$file" | sort -u | wc -l) || count=0
    # shellcheck disable=SC2094 # audit_add only appends an in-memory finding.
    while IFS= read -r line || [[ -n "$line" ]]; do
      fp=$(ssh_public_key_fingerprints <<<"$line") || continue
      [[ -n "$fp" ]] || continue
      comment=$(ssh-keygen -l -f /dev/stdin <<<"$line" 2>/dev/null || printf '%s' "$line")
      if [[ -n "$recorded" ]] && grep -Fxq "$fp" <<<"$recorded"; then continue; fi
      audit_add A key "$file" "$fp；$([[ -n "$recorded" ]] && echo '不是你提供的' || echo '没有归属记录，请选择保留哪些')；$comment；共 $count 把；当前会话=$([[ "$fp" == "$AUDIT_SESSION_KEY" ]] && echo 是 || echo 未匹配)"
    done <"$file"
  done
}

readonly CLOUD_DISABLED_FLAG='/etc/cloud/cloud-init.disabled'
readonly CLOUD_STATIC_HINT='如果商家迁移机器、更换 IP，需要用 VNC 修改网络配置，或删除 /etc/cloud/cloud-init.disabled 重新启用 cloud-init。'
CLOUD_NET_KIND=''
CLOUD_NET_STATIC=false
CLOUD_NET_REASON=''

# True when any cloud-init configuration lists the plain "boot" event under
# updates: network: when: (network is regenerated on every boot). Block lists, inline
# lists and one-line flow mappings are understood; boot-new-instance is not "boot".
audit_cloud_boot_regenerates() {
  local file
  for file in "$AUDIT_ROOT"/etc/cloud/cloud.cfg "$AUDIT_ROOT"/etc/cloud/cloud.cfg.d/*.cfg; do
    [[ -f "$file" ]] || continue
    if awk '
      function indent(s) { match(s, /^ */); return RLENGTH }
      function scan(s,    n, t, k) {
        n = split(s, t, /[^A-Za-z0-9_-]+/)
        for (k = 1; k <= n; k++) if (t[k] == "boot") bad = 1
      }
      { sub(/\r$/, "") }
      /^[[:space:]]*(#|$)/ { next }
      { i = indent($0) }
      inupd && i <= ui { inupd = 0; innet = 0; inwhen = 0 }
      innet && i <= ni { innet = 0; inwhen = 0 }
      inwhen && i <= wi && $0 !~ /^[[:space:]]*-/ { inwhen = 0 }
      /^[[:space:]]*updates:[[:space:]]*(#.*)?$/ { inupd = 1; ui = i; next }
      /^[[:space:]]*updates:.*when:/ { r = $0; sub(/.*when:/, "", r); scan(r); next }
      inupd && /^[[:space:]]*network:[[:space:]]*(#.*)?$/ { innet = 1; ni = i; next }
      inupd && /^[[:space:]]*network:.*when:/ { r = $0; sub(/.*when:/, "", r); scan(r); next }
      innet && /^[[:space:]]*when:/ { inwhen = 1; wi = i; r = $0; sub(/^[^:]*:/, "", r); scan(r); next }
      inwhen { scan($0) }
      END { exit !bad }' "$file"; then return 0; fi
  done
  return 1
}

audit_network_regular_file() {
  [[ -f "$1" && ! -L "$1" && -s "$1" ]]
}

# R4: cloud-init may be switched off only when the network configuration already lives in
# regular files under /etc (ifupdown, netplan or systemd-networkd) and cloud-init is not
# told to regenerate it on every boot. DHCP, SLAAC and static addresses are all fine.
# Returns 0 when safe; always sets CLOUD_NET_KIND / CLOUD_NET_STATIC / CLOUD_NET_REASON.
audit_cloud_network_classify() {
  local file kinds='' static=false methods
  CLOUD_NET_KIND='' CLOUD_NET_STATIC=false CLOUD_NET_REASON=''
  if audit_cloud_boot_regenerates; then
    CLOUD_NET_REASON='cloud-init 配置了每次开机重新生成网络（updates: network: when 含 boot）'
    return 1
  fi
  local -a ifupdown_files=("$AUDIT_ROOT/etc/network/interfaces")
  if grep -Eqs '^[[:space:]]*source(-directory)?[[:space:]]+/etc/network/interfaces\.d(/\*)?[[:space:]]*$' "$AUDIT_ROOT/etc/network/interfaces"; then
    ifupdown_files+=("$AUDIT_ROOT"/etc/network/interfaces.d/*)
  fi
  for file in "${ifupdown_files[@]}"; do
    audit_network_regular_file "$file" || continue
    methods=$(awk '/^[[:space:]]*#/ {next}
      $1 == "iface" && $2 != "lo" && $3 ~ /^inet6?$/ && $4 ~ /^(dhcp|static|auto)$/ {print $4}' "$file")
    [[ -n "$methods" ]] || continue
    kinds+=' ifupdown'
    if grep -Fxq static <<<"$methods"; then static=true; fi
  done
  for file in "$AUDIT_ROOT"/etc/netplan/*.yaml; do
    audit_network_regular_file "$file" || continue
    grep -Eq '^[[:space:]]*(ethernets|bonds|bridges|vlans|wifis):' "$file" || continue
    kinds+=' netplan'
    # nameservers: addresses: are DNS servers, not interface addresses.
    if awk '
      function indent(s) { match(s, /^ */); return RLENGTH }
      /^[[:space:]]*(#|$)/ { next }
      { i = indent($0); if (ns && i <= nsi) ns = 0 }
      /^[[:space:]]*nameservers:/ { ns = 1; nsi = i; next }
      !ns && /^[[:space:]]*(addresses|gateway4|gateway6):/ { found = 1 }
      END { exit !found }' "$file"; then static=true; fi
  done
  for file in "$AUDIT_ROOT"/etc/systemd/network/*.network; do
    audit_network_regular_file "$file" || continue
    grep -Eq '^[[:space:]]*(DHCP|Address|Gateway|IPv6AcceptRA)=' "$file" || continue
    kinds+=' systemd-networkd'
    if grep -Eq '^[[:space:]]*(Address|Gateway)=' "$file"; then static=true; fi
  done
  if [[ -z "$kinds" ]]; then
    CLOUD_NET_REASON='/etc 下没有 ifupdown、netplan 或 systemd-networkd 的普通网络配置文件，网络配置可能只存在于 /run'
    return 1
  fi
  CLOUD_NET_KIND=${kinds# }
  CLOUD_NET_STATIC=$static
  return 0
}

audit_cloud_init_present() {
  [[ "$(dpkg-query -W -f='${db:Status-Status}' -- cloud-init 2>/dev/null || true)" == installed || -f "$AUDIT_ROOT/etc/cloud/cloud.cfg" ]]
}

# R5 vendor agent names, matched case-insensitively against process names, service
# names and install paths (any path component).
readonly -a VENDOR_AGENT_NAMES=(
  aliyun-service assist_daemon AliYunDun AliYunDunUpdate aegis argusagent cloudmonitor
  YDService YDLive barad_agent sgagent tat_agent
  hostguard uniagent telescope
  amazon-ssm-agent google-guest-agent walinuxagent waagent oracle-cloud-agent
)

audit_agent_name_for() {
  local text=${1,,} name lname
  [[ -n "$text" ]] || return 1
  for name in "${VENDOR_AGENT_NAMES[@]}"; do
    lname=${name,,}
    if [[ "$text" == "$lname" || "/$text/" == *"/$lname/"* ]]; then printf '%s\n' "$name"; return 0; fi
  done
  return 1
}

# ps truncates process names to 15 characters.
audit_agent_comm_prefix() {
  local comm=${1,,} name
  (( ${#comm} == 15 )) || return 1
  for name in "${VENDOR_AGENT_NAMES[@]}"; do
    if [[ "${name,,}" == "$comm"* ]]; then printf '%s\n' "$name"; return 0; fi
  done
  return 1
}

audit_agents() {
  local pid comm exe name unit frag exec prefix path kind package status owner seen=$'\n' key
  local -a evidence=() units=()
  while IFS=' ' read -r pid comm; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    exe=$(readlink -f "$AUDIT_ROOT/proc/$pid/exe" 2>/dev/null || true)
    name=$(audit_agent_name_for "$comm" || audit_agent_comm_prefix "$comm" || audit_agent_name_for "$exe" || true)
    [[ -z "$name" ]] || evidence+=("$name"$'\t'process$'\t'"${exe:-$comm}")
  done < <(ps -eo pid=,comm= 2>/dev/null || true)
  # systemctl show rejects template units (getty@.service) and then prints nothing for the
  # whole call, so templates are matched by name only.
  mapfile -t units < <(systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null | awk 'NF && $1 !~ /@\.service$/ {print $1}' || true)
  while IFS= read -r unit; do
    name=$(audit_agent_name_for "${unit%.service}" || true)
    [[ -z "$name" ]] || evidence+=("$name"$'	'service$'	'"$(audit_unit_fragment "$unit")")
  done < <(systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null | awk 'NF && $1 ~ /@\.service$/ {print $1}' || true)
  if (( ${#units[@]} > 0 )); then
    while IFS=$'\t' read -r unit frag exec; do
      name=$(audit_agent_name_for "${unit%.service}" || audit_agent_name_for "$frag" || audit_agent_name_for "$exec" || true)
      [[ -z "$name" ]] || evidence+=("$name"$'\t'service$'\t'"${frag:-$unit}")
    done < <(systemctl show -p Id,FragmentPath,ExecStart --no-pager -- "${units[@]}" 2>/dev/null | awk '
      function flush() { if (id != "") printf "%s\t%s\t%s\n", id, frag, ex; id = frag = ex = "" }
      /^$/ { flush() }
      /^Id=/ { id = substr($0, 4) }
      /^FragmentPath=/ { frag = substr($0, 14) }
      /^ExecStart=/ { if (match($0, /path=[^ ;]+/)) ex = substr($0, RSTART + 5, RLENGTH - 5) }
      END { flush() }' || true)
  fi
  while IFS=$'\t' read -r package status; do
    [[ "$status" == installed ]] || continue
    name=$(audit_agent_name_for "${package%%:*}" || true)
    [[ -z "$name" ]] || evidence+=("$name"$'\t'package$'\t'"$package")
  done < <(dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' 2>/dev/null || true)
  for prefix in /usr/local /usr/local/share /usr/local/qcloud /opt /usr/sbin /usr/bin /usr/local/sbin /usr/local/bin; do
    for name in "${VENDOR_AGENT_NAMES[@]}"; do
      for path in "$prefix/$name" "$prefix/${name,,}"; do
        if [[ -e "$AUDIT_ROOT$path" ]]; then evidence+=("$name"$'\t'path$'\t'"$path"); break; fi
      done
    done
  done
  for key in "${evidence[@]}"; do
    IFS=$'\t' read -r name kind path <<<"$key"
    if [[ "$kind" == package ]]; then owner=${path%%:*}; else owner=$(audit_package_owner "$path" || true); fi
    if [[ -n "$owner" ]]; then
      # Same-name packages from the official Debian archive are not vendor agents.
      if audit_debian_package "$owner"; then continue; fi
      [[ "$seen" != *$'\n'"pkg:$owner"$'\n'* ]] || continue
      seen+="pkg:$owner"$'\n'
      audit_add A agent "$owner" "商家 agent「$name」由软件包 $owner 安装，该包不是 Debian 官方源；可预览 purge 后确认。卸载后该商家的监控、重置密码等面板功能可能失效"
    else
      [[ "$seen" != *$'\n'"file:$name"$'\n'* ]] || continue
      seen+="file:$name"$'\n'
      audit_add B agent "$name" "商家 agent（$kind：$path）不是软件包安装的，只报告；请按商家文档手动卸载（例如官方卸载脚本），拿不准就联系商家或用官方系统重装"
    fi
  done
}

collect_security_audit() {
  AUDIT_FINDINGS=()
  AUDIT_SESSION_KEY=$(audit_session_key) || AUDIT_SESSION_KEY=''
  AUDIT_APT_SOURCES=$(apt-cache policy 2>/dev/null || true)
  local file package status unit path uid user effective command keys listener pid exe cloud_detail exim4_found=false key_ok=true key_path
  local -a key_paths=()
  audit_keys
  [[ -n "$AUDIT_SESSION_KEY" ]] || audit_add B keys session '无法确定当前 SSH 公钥，禁止删除任何公钥'
  if audit_cloud_init_present && [[ ! -e "$CLOUD_DISABLED_FLAG" ]]; then
    if audit_cloud_network_classify; then
      cloud_detail="网络配置已写在 /etc 的普通文件里（$CLOUD_NET_KIND），关闭后网络不受影响；关闭方式：创建 /etc/cloud/cloud-init.disabled；恢复：删除这个文件"
      [[ "$CLOUD_NET_STATIC" != true ]] || cloud_detail+="；使用静态地址：$CLOUD_STATIC_HINT"
      audit_add A cloud cloud-init "$cloud_detail"
    else
      audit_add B cloud-skip cloud-init "不关闭 cloud-init：$CLOUD_NET_REASON；只跳过这一项，其他项照常进行"
    fi
  fi
  [[ $(qemu_guest_agent_status) != installed ]] || audit_add A qga qemu-guest-agent '面板通信助手，可复用现有安全卸载流程'
  audit_agents
  while IFS=$'\t' read -r package status; do
    [[ "$status" == installed ]] || continue
    case "${package%%:*}" in exim4|exim4-*) exim4_found=true ;; esac
    if ! audit_debian_package "$package"; then audit_add B package "$package" '本地缓存不能证明已安装版本来自 Debian 官方源（包括缓存缺失或旧版本），请核实'; fi
  done < <(dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' 2>/dev/null || true)
  if [[ "$exim4_found" == true ]]; then
    audit_add A mail exim4 'Debian 邮件服务，VPS 上一般用不上；卸载后 cron 任务的输出邮件将无法投递。先模拟 purge，连带删除其他包时还需额外确认'
  fi
  while IFS=' ' read -r unit _; do
    [[ -n "$unit" ]] || continue
    path=$(audit_unit_fragment "$unit")
    if [[ -z "$path" ]] || ! audit_package_owner "$path" >/dev/null; then audit_add B service "$unit" "已启用但服务文件不属于软件包：${path:-找不到服务文件}"; fi
    # Drop-ins can change an otherwise official service's executable. The sing-box start
    # condition written by this installer is its own file and expected.
    for path in $(systemctl show -p DropInPaths --value "$unit" 2>/dev/null | tr ' ' '\n' || true); do
      if [[ "$unit" == sing-box.service && "$path" == "$SINGBOX_DROPIN" ]]; then continue; fi
      if ! audit_package_owner "$path" >/dev/null; then audit_add B service "$unit" "额外的服务覆盖文件：$path"; fi
    done
  done < <(systemctl list-unit-files --state=enabled --type=service --no-legend --no-pager 2>/dev/null || true)
  for file in "$AUDIT_ROOT"/etc/crontab "$AUDIT_ROOT"/etc/cron.d/* "$AUDIT_ROOT"/etc/cron.{hourly,daily,weekly,monthly}/* "$AUDIT_ROOT"/var/spool/cron/crontabs/*; do
    [[ -f "$file" ]] || continue
    if ! audit_package_owner "$file" >/dev/null; then audit_add B cron "$file" '计划任务文件不属于软件包，请看一眼其中的命令'; fi
  done
  for file in "$AUDIT_ROOT"/etc/sudoers.d/*; do
    [[ -s "$file" && "$file" != */README ]] || continue
    audit_add B sudo "$file" '额外的提权规则，请确认谁可以获得 root 权限'
  done
  while IFS= read -r listener; do
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      exe=$(readlink -f "$AUDIT_ROOT/proc/$pid/exe" 2>/dev/null || true)
      package=$(audit_package_owner "$exe" || true)
      if [[ -z "$package" ]] || ! audit_debian_package "$package"; then audit_add B port "$pid" "$listener；程序=$exe；来源=${package:-不属于软件包}"; fi
    done < <(grep -oE 'pid=[0-9]+' <<<"$listener" | cut -d= -f2 | sort -u)
  done < <(ss -H -lntup 2>/dev/null || true)
  [[ ! -s "$AUDIT_ROOT/etc/ld.so.preload" ]] || audit_add C preload /etc/ld.so.preload '存在全局预加载，可能影响每个程序；建议用官方镜像重装'
  while IFS=: read -r user _ uid _; do
    [[ "$uid" != 0 || "$user" == root ]] || audit_add C uid "$user" '除 root 外还有 UID 0 用户；建议用官方镜像重装'
  done <"$AUDIT_ROOT/etc/passwd"
  if effective=$(sshd -T 2>/dev/null); then
    command=$(awk '$1=="authorizedkeyscommand" {$1=""; sub(/^ /, ""); print}' <<<"$effective")
    keys=$(awk '$1=="authorizedkeysfile" {$1=""; sub(/^ /, ""); print}' <<<"$effective")
    [[ "$command" == none ]] || audit_add C ssh AuthorizedKeysCommand "公钥通过额外命令获取：$command；只报告，不改 sshd，建议官方重装"
    # Defaults are .ssh/authorized_keys (+ .ssh/authorized_keys2 on older OpenSSH); the
    # installer itself pins .ssh/authorized_keys. Anything else is reported.
    IFS=' ' read -ra key_paths <<<"$keys"
    for key_path in "${key_paths[@]}"; do
      case "$key_path" in .ssh/authorized_keys|.ssh/authorized_keys2) ;; *) key_ok=false ;; esac
    done
    [[ "$keys" == *.ssh/authorized_keys* && "$key_ok" == true ]] || audit_add C ssh AuthorizedKeysFile "公钥文件位置不是 Debian 默认值：$keys；只报告，不改 sshd，建议官方重装"
  else audit_add B ssh sshd 'sshd -T 无法读取有效配置，未能完成 SSH 配置检查'; fi
}

audit_type_label() {
  case "$1" in
    key|keys) printf '登录公钥' ;;
    cloud) printf 'cloud-init' ;;
    cloud-skip) printf 'cloud-init（已跳过）' ;;
    qga) printf 'QEMU Guest Agent' ;;
    agent) printf '商家 agent' ;;
    mail) printf '邮件服务 exim4' ;;
    package) printf '非 Debian 官方源软件包' ;;
    service) printf '非软件包服务' ;;
    cron) printf '非软件包计划任务' ;;
    sudo) printf '额外 sudo 规则' ;;
    port) printf '监听端口' ;;
    preload) printf '全局预加载' ;;
    uid) printf '额外 UID 0 用户' ;;
    ssh) printf 'SSH 公钥配置' ;;
    *) printf '%s' "$1" ;;
  esac
}

# One plain-language sentence per category, printed once under each level.
audit_type_help() {
  case "$1" in
    key|keys) printf '能用来登录这台服务器的钥匙；不是你提供的钥匙等于别人手里有备用钥匙。' ;;
    cloud) printf '商家镜像里的开机配置程序，每次开机可能改网络、改密码；网络已固定在 /etc 里时可以关掉。' ;;
    cloud-skip) printf '这台机器网络可能依赖 cloud-init，关掉有失联风险，所以只跳过它这一项。' ;;
    qga) printf '商家面板和虚拟机之间的通信助手，面板的重置密码等功能要靠它。' ;;
    agent) printf '云厂商装的监控、安全或管理客户端，常驻后台。' ;;
    mail) printf '本机邮件服务，VPS 一般用不上；卸载后 cron 的邮件通知无法投递。' ;;
    package) printf '不是从 Debian 官方源装的软件，可能是你自己装的，请确认来源。' ;;
    service) printf '开机自动运行、但不属于任何软件包的服务，请确认是你装的。' ;;
    cron) printf '定时任务文件不属于任何软件包，请看一眼里面执行什么。' ;;
    sudo) printf '额外授予的 root 提权规则，请确认谁拥有。' ;;
    port) printf '由非官方软件监听的网络端口，请确认你知道它是什么。' ;;
    preload) printf '系统层面强制给所有程序加载的库，正常系统里应该是空的。' ;;
    uid) printf 'root 之外还有拥有 root 权限的账号。' ;;
    ssh) printf 'SSH 获取登录公钥的方式被改过，可能存在你看不到的后门入口。' ;;
  esac
}

print_security_audit() {
  local mode=${1:-summary} level title row count type target detail seen
  for level in A B C; do
    case "$level" in
      A) title='A 建议删除：这些是登录钥匙或商家助手；确认不需要再处理，默认保留。' ;;
      B) title='B 需要你看一眼：这些有额外权限或后台行为；可能是你装的，只报告。' ;;
      C) title='C 严重异常：这些会改变系统或登录信任；只报告，建议用官方系统重装。' ;;
    esac
    count=0
    for row in "${AUDIT_FINDINGS[@]}"; do [[ "$row" != "$level"$'\t'* ]] || count=$((count + 1)); done
    printf '\n[%s]（%s 项）\n' "$title" "$count"
    if [[ "$mode" == full ]]; then
      seen=$'\n'
      for row in "${AUDIT_FINDINGS[@]}"; do
        [[ "$row" == "$level"$'\t'* ]] || continue
        IFS=$'\t' read -r _ type target detail <<<"$row"
        if [[ "$seen" != *$'\n'"$type"$'\n'* ]]; then
          seen+="$type"$'\n'
          printf '  ▸ %s：%s\n' "$(audit_type_label "$type")" "$(audit_type_help "$type")"
        fi
        printf '      - %s — %s\n' "$target" "$detail"
      done
    fi
  done
  printf '\n当前会话公钥：%s\n' "${AUDIT_SESSION_KEY:-无法确定，禁止删除公钥}"
}

hardening_delete_key() {
  HARDENING_KEY_DELETED=false
  local file=$1 remove=$2 session before after line fp stage="$TMP_DIR/authorized-keys" original count
  session=$(audit_session_key) || { warn '无法确定当前会话公钥，只报告，禁止删除。'; return 0; }
  [[ "$remove" != "$session" ]] || { warn '不能删除当前 SSH 会话的公钥。'; return 0; }
  audit_regular_key_path "$file" || { warn '公钥路径不安全，跳过。'; return 0; }
  original=$(sha256sum -- "$file")
  before=$(ssh_public_key_fingerprints "$file" | sort -u) || { warn '无法完整解析公钥，跳过。'; return 0; }
  count=$(wc -l <<<"$before")
  (( count > 1 )) || { warn '至少保留一把公钥，跳过。'; return 0; }
  : >"$stage"
  while IFS= read -r line || [[ -n "$line" ]]; do
    fp=$(ssh_public_key_fingerprints <<<"$line" || true)
    [[ "$fp" == "$remove" ]] || printf '%s\n' "$line" >>"$stage"
  done <"$file"
  after=$(ssh_public_key_fingerprints "$stage" | sort -u) || { warn '删除后的公钥校验失败，跳过。'; return 0; }
  [[ -n "$after" ]] || { warn '至少保留一把有效公钥。'; return 0; }
  if grep -Fxq "$session" <<<"$before"; then grep -Fxq "$session" <<<"$after" || die '当前会话公钥保护失败。'; fi
  [[ "$(sha256sum -- "$file")" == "$original" && "$(audit_session_key || true)" == "$session" ]] || { warn '公钥或当前会话发生变化，跳过。'; return 0; }
  command -v python3 >/dev/null || { warn '缺少 python3，无法安全原子替换公钥，只报告。'; return 0; }
  # Open every parent with O_NOFOLLOW and pin it by fd: a user's writable home
  # must never let a rename/symlink race redirect root's writes elsewhere.
  # The stage stays in root's private temp dir; cross-filesystem moves safely fail.
  if ! python3 - "$file" "$stage" "${original%% *}" "$BACKUP_DIR" <<'KEY_REPLACE'
import hashlib
import os
import stat
import sys

path, stage, digest, backup = sys.argv[1:]
directory = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
try:
    parts = path.split('/')[1:]
    if not parts or any(p in ('', '.', '..') for p in parts):
        raise ValueError('unsafe path')
    for part in parts[:-1]:
        child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
        os.close(directory)
        directory = child
    source = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
    try:
        attrs = os.fstat(source)
        if not stat.S_ISREG(attrs.st_mode) or attrs.st_nlink != 1:
            raise ValueError('not a single regular file')
        with os.fdopen(os.dup(source), 'rb') as stream:
            data = stream.read()
        if hashlib.sha256(data).hexdigest() != digest:
            raise ValueError('authorized_keys changed')
        destination = backup + '/files' + path
        os.makedirs(os.path.dirname(destination), mode=0o700, exist_ok=True)
        if not os.path.lexists(destination):
            with open(destination, 'xb') as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            os.chown(destination, attrs.st_uid, attrs.st_gid)
            os.chmod(destination, stat.S_IMODE(attrs.st_mode))
        os.chown(stage, attrs.st_uid, attrs.st_gid)
        os.chmod(stage, stat.S_IMODE(attrs.st_mode))
        for name in os.listxattr(source):
            os.setxattr(stage, name, os.getxattr(source, name))
        # Reject a replacement of the original inode during verification/backup.
        latest = os.stat(parts[-1], dir_fd=directory, follow_symlinks=False)
        if (latest.st_ino, latest.st_dev, latest.st_mtime_ns, latest.st_size) != (attrs.st_ino, attrs.st_dev, attrs.st_mtime_ns, attrs.st_size):
            raise ValueError('authorized_keys changed during backup')
        os.replace(stage, parts[-1], dst_dir_fd=directory)
        os.fsync(directory)
    finally:
        os.close(source)
finally:
    os.close(directory)
KEY_REPLACE
  then warn '公钥原子替换未完成，已停止删除，请检查备份与文件系统。'; return 0; fi
  HARDENING_KEY_DELETED=true
  log "已删除 $file 中的 $remove；保留 $(wc -l <<<"$after") 把有效公钥。"
}

hardening_purge_plan() {
  local plan=$1
  plan=${plan/#Purg /Remv }
  cleanup_apt_plan "${plan//$'\n'Purg /$'\n'Remv }"
}

hardening_purge_exim4() {
  HARDENING_MAIL_PURGED=false
  local plan planned current versions observed_versions package status path rc found=false
  local -a packages=() extra=()
  CURRENT_STEP='模拟卸载 exim4 邮件服务'
  wait_for_package_manager
  # Quote the wildcard: APT must simulate the entire exim4 family, not shell matches.
  plan=$(apt_get -s -o APT::Get::AutomaticRemove=false purge -- 'exim4*') || return 1
  planned=$(hardening_purge_plan "$plan" | sort) || { warn '无法安全解析 exim4 purge 计划，已停止。'; return 1; }
  [[ -n "$planned" ]] || { log '没有需要清除的 exim4 软件包。'; return 0; }
  mapfile -t packages <<<"$planned"
  for package in "${packages[@]}"; do
    case "${package%%:*}" in
      exim4|exim4-*) found=true ;;
      openssh-server) warn '计划涉及 openssh-server，可能修改 sshd 配置，已停止加固。'; return 1 ;;
      *) extra+=("$package") ;;
    esac
  done
  [[ "$found" == true ]] || { warn '计划中没有 exim4 系列，拒绝仅删除其他软件包。'; return 1; }
  versions=$(dpkg-query -W -- "${packages[@]}") || return 1
  printf 'exim4 完整卸载预览：\n%s\n' "$plan"
  warn '卸载 exim4 后，cron 任务的输出邮件将无法投递；仍需要邮件通知时请保留。'
  if (( ${#extra[@]} > 0 )); then
    printf '除 exim4 系列外，还会连带删除以下软件包：\n'
    printf '  %s\n' "${extra[@]}"
  fi
  ask_yes_no '确认卸载 exim4 邮件服务（cron 输出邮件将无法投递）？' false || return 0
  if (( ${#extra[@]} > 0 )); then
    ask_yes_no '额外确认：也删除上面列出的非 exim4 软件包？' false || return 0
  fi
  wait_for_package_manager
  # Recheck after both confirmations. Never widen an already approved removal list.
  plan=$(apt_get -s -o APT::Get::AutomaticRemove=false purge -- 'exim4*') || return 1
  current=$(hardening_purge_plan "$plan" | sort) || return 1
  observed_versions=$(dpkg-query -W -- "${packages[@]}") || return 1
  if [[ "$current" != "$planned" || "$observed_versions" != "$versions" ]]; then
    warn 'exim4 删除计划或包版本发生变化，已停止；请重新体检和确认。'
    return 1
  fi
  [[ -n "$BACKUP_DIR" ]] || die '缺少备份目录，拒绝卸载 exim4。'
  printf '%s\n' "$plan" >"$BACKUP_DIR/exim4-purge-plan.txt"
  printf '%s\n' "$versions" >"$BACKUP_DIR/exim4-purge-versions.txt"
  # Include local Exim configuration as well as conffiles of every approved package.
  hardening_backup /etc/exim4
  for package in "${packages[@]}"; do
    dpkg-query -L -- "$package" >"$BACKUP_DIR/$package.files"
    while IFS= read -r path; do
      if [[ "$path" == /etc/* && -f "$path" && ! -L "$path" ]]; then hardening_backup "$path"; fi
    done <"$BACKUP_DIR/$package.files"
  done
  # Purge exactly the reviewed list. dpkg enforces dependencies under its own lock;
  # a new dependency may stop removal, but cannot silently add another package.
  CURRENT_STEP='清除已确认的 exim4 邮件服务软件包'
  dpkg --no-force-depends,depends-version --purge -- "${packages[@]}" || return 1
  for package in "${packages[@]}"; do
    if status=$(dpkg-query -W -f='${db:Status-Status}' -- "$package" 2>/dev/null); then
      [[ "$status" == not-installed ]] || { warn "$package 未完成 purge：$status"; return 1; }
    else
      rc=$?
      (( rc == 1 )) || { warn "无法验证 $package 的卸载状态。"; return 1; }
    fi
  done
  HARDENING_MAIL_PURGED=true
  log 'exim4 及已额外确认的软件包已清除；cron 输出邮件将无法投递。'
}

hardening_purge_agent() {
  local package=$1 plan actual
  wait_for_package_manager
  plan=$(apt_get -s -o APT::Get::AutomaticRemove=false purge -- "$package") || return 1
  actual=$(hardening_purge_plan "$plan") || return 1
  [[ "$actual" == "$package" ]] || { warn '卸载会影响其他软件包，已跳过。'; return 0; }
  printf '%s\n' "$plan"
  ask_yes_no "确认这个 purge 预览（$package）？" false || return 0
  dpkg-query -L "$package" >"$BACKUP_DIR/$package.files"
  # Preserve package-owned configuration and the simulated plan before apt runs.
  printf '%s\n' "$plan" >"$BACKUP_DIR/$package.purge-plan"
  local path
  while IFS= read -r path; do
    if [[ "$path" == /etc/* && -f "$path" && ! -L "$path" ]]; then hardening_backup "$path"; fi
  done <"$BACKUP_DIR/$package.files"
  # Hold the native package-manager lock across the final dependency check and purge.
  # dpkg will refuse any removal that breaks dependencies; never force dependencies.
  dpkg --no-force-depends,depends-version --purge -- "$package"
  [[ $(dpkg-query -W -f='${db:Status-Status}' -- "$package" 2>/dev/null || true) != installed ]] || return 1
}

readonly HARDENING_RISK_NOTICE='关闭 cloud-init 和 Guest Agent 后，面板上的重置密码等功能可能失效。请确认你在面板上能看到 root 密码，或者自己知道 root 密码。'
declare -a HARDENING_ACTIONS=()

# Flow (R3): read-only audit -> three levels -> risk notice and confirmation -> per-item
# confirmation (default N) -> backup first, then act -> report. Nothing is written (no
# backup directory either) until the risk notice is confirmed, and an unused backup
# directory is removed again when no item was executed.
run_security_hardening() {
  local row level type target detail fp actionable=0
  HARDENING_ACTIONS=()
  collect_security_audit
  print_security_audit full
  for row in "${AUDIT_FINDINGS[@]}"; do
    if [[ "$row" == A$'\t'* ]]; then actionable=$((actionable + 1)); fi
  done
  if (( actionable == 0 )); then
    log '没有 A 级建议项：未做任何修改，也没有创建备份。'
    return 0
  fi
  printf '\n%s\n' "$HARDENING_RISK_NOTICE"
  ask_yes_no '已了解上述风险，并确认知道 root 密码，继续逐项确认？' false || { log '已取消，未做任何修改。'; return 0; }
  install -d -m 0700 "$BACKUP_ROOT"
  BACKUP_DIR=$(mktemp -d "$BACKUP_ROOT/hardening-XXXXXXXX")
  TMP_DIR=$(mktemp -d /root/vps-hardening-XXXXXXXX)
  print_security_audit full >"$BACKUP_DIR/audit-before.txt"
  for row in "${AUDIT_FINDINGS[@]}"; do
    IFS=$'\t' read -r level type target detail <<<"$row"
    [[ "$level" == A ]] || continue
    printf '\n%s：%s\n' "$target" "$detail"
    case "$type" in
      key)
        fp=${detail%%；*}
        if [[ -z "$AUDIT_SESSION_KEY" || "$fp" == "$AUDIT_SESSION_KEY" ]]; then log '当前会话的钥匙或会话无法确定，禁止删除。'; continue; fi
        if ask_yes_no "保留 $target 的 $fp？" true; then continue; fi
        ask_yes_no "确认删除 $fp（默认不删除）？" false || continue
        HARDENING_KEY_DELETED=false
        hardening_delete_key "$target" "$fp"
        if [[ "$HARDENING_KEY_DELETED" == true ]]; then
          HARDENING_ACTIONS+=("已从 $target 删除公钥 $fp；恢复：用 $BACKUP_DIR/files$target 覆盖回原文件")
        fi ;;
      cloud)
        ask_yes_no '关闭 cloud-init？' false || continue
        # Re-check right before acting; a skip only affects this item.
        if ! audit_cloud_network_classify; then warn "网络检查结果变化，跳过 cloud-init：$CLOUD_NET_REASON"; continue; fi
        reject_symlink "${CLOUD_DISABLED_FLAG%/*}"
        hardening_backup "${CLOUD_DISABLED_FLAG%/*}"
        hardening_backup /etc/network/interfaces
        hardening_backup /etc/network/interfaces.d
        hardening_backup /etc/netplan
        hardening_backup /etc/systemd/network
        install -m 0644 /dev/null "$CLOUD_DISABLED_FLAG"
        [[ -f "$CLOUD_DISABLED_FLAG" ]] || die 'cloud-init 关闭标记验证失败。'
        log "cloud-init 已关闭（下次开机生效）；恢复：删除 $CLOUD_DISABLED_FLAG"
        if [[ "$CLOUD_NET_STATIC" == true ]]; then warn "$CLOUD_STATIC_HINT"; fi
        HARDENING_ACTIONS+=("已关闭 cloud-init（创建 /etc/cloud/cloud-init.disabled）；恢复：删除这个文件即可重新启用") ;;
      qga)
        ask_yes_no '卸载 QEMU Guest Agent？' false || continue
        hardening_backup /etc/qemu
        remove_qemu_guest_agent
        if [[ $(qemu_guest_agent_status || true) != installed ]]; then
          HARDENING_ACTIONS+=("已卸载 QEMU Guest Agent；恢复：apt-get install qemu-guest-agent；备份：$BACKUP_DIR/files/etc/qemu")
        fi ;;
      agent)
        ask_yes_no "卸载商家 agent 软件包 $target？" false || continue
        hardening_purge_agent "$target" || warn "商家 agent $target 未能卸载，已跳过。"
        if [[ $(dpkg-query -W -f='${db:Status-Status}' -- "$target" 2>/dev/null || true) != installed ]]; then
          HARDENING_ACTIONS+=("已 purge 商家 agent 软件包 $target；配置备份：$BACKUP_DIR/files；需要时从商家渠道重新安装")
        fi ;;
      mail)
        HARDENING_MAIL_PURGED=false
        hardening_purge_exim4 || warn 'exim4 未完成卸载，已跳过；系统状态以 dpkg 为准。'
        if [[ "$HARDENING_MAIL_PURGED" == true ]]; then
          HARDENING_ACTIONS+=("已 purge exim4 邮件服务；cron 输出邮件将无法投递；恢复：apt-get install exim4；配置备份：$BACKUP_DIR/files/etc/exim4")
        fi ;;
    esac
  done > >(tee "$BACKUP_DIR/actions.txt") 2>&1
  if (( ${#HARDENING_ACTIONS[@]} == 0 )); then
    rm -rf -- "$BACKUP_DIR"
    log '没有执行任何修改，已删除未使用的备份目录。'
    BACKUP_DIR=''
    return 0
  fi
  collect_security_audit
  print_security_audit full >"$BACKUP_DIR/audit-after.txt"
  print_security_audit full
  printf '\n加固报告：\n'
  printf '  - %s\n' "${HARDENING_ACTIONS[@]}"
  log "备份与体检报告：$BACKUP_DIR（audit-before.txt、audit-after.txt、actions.txt）"
}

print_report() {
  local ssh_listeners fail2ban_status='已安装、自启并运行；sshd 和 sshd-slow 已验证'
  ssh_listeners=$(ssh_listener_addresses | sort -u | paste -sd ' ' -) || ssh_listeners=''
  if [[ "$NETWORK_REQUEST" == ipv4 ]]; then verify_ipv4_policy; fi
  if [[ "$PRESERVE_SSH" == true ]]; then
    if fail2ban_package_installed; then
      fail2ban_status="保留现状（已安装，服务状态 $(systemctl is-active fail2ban.service 2>/dev/null || true)）"
    else
      fail2ban_status='保留现状（未安装）'
      warn 'Fail2ban 未安装，保留 SSH 模式已跳过安装与配置。'
    fi
  fi
  cat <<EOF

============================================================
VPS 初始化完成
============================================================
系统          : ${PRETTY_NAME:-Debian}
网络栈        : $NETWORK_STACK（策略 $NETWORK_REQUEST）
$(if [[ "$NETWORK_REQUEST" == ipv4 ]]; then printf '内核 IPv6     : %s\n' "$IPV4_POLICY_STATUS"; fi)
SSH 实际监听  : ${ssh_listeners:-未检测到}$(if [[ "$PRESERVE_SSH" == true ]]; then printf '（保留现有配置）'; fi)
UFW           : $(ufw status 2>/dev/null | sed -n '1p' || echo unavailable)
SmartDNS      : $(smartdns -v 2>/dev/null | head -1 || echo unavailable)
SmartDNS 模式 : $([[ "$NETWORK_REQUEST" == ipv4 ]] && echo 'A only' || echo 'A + AAAA') / $SMARTDNS_TRANSPORT
SmartDNS 监听 : 127.0.0.1:53（UDP+TCP）
备用 DNS      : $FALLBACK_DNS（resolv.conf 第二个 nameserver）
$(ipv6_report_lines)
sing-box      : $(sing-box version 2>/dev/null | head -1 || echo unavailable)
Fail2ban      : $fail2ban_status
TCP / qdisc   : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unavailable) / $(sysctl -n net.core.default_qdisc 2>/dev/null || echo unavailable)
Swap          : $(awk '/SwapTotal:/ {printf "%.0f MiB", $2/1024}' /proc/meminfo)
系统 DNS      : $(if [[ "$EARLY_DNS_FIXED" == true ]]; then printf '已提前修复系统 DNS，原文件备份在 %s' "$EARLY_DNS_BACKUP"; else printf '未提前修复（系统 DNS 原本可用）'; fi)
备份目录      : $BACKUP_DIR
自动安全更新  : $(if security_updates_enabled; then echo 已启用; else echo 未启用; fi)
需要重启      : $([[ -e /run/reboot-required ]] && echo yes || echo no)
安全清理      : $SAFE_CLEANUP_RESULT
重启后可运行 [7] 清理旧内核和无用包
开机自启检查（不额外启动）：
$BOOT_REPORT
============================================================
请保持当前 SSH 会话，并从另一终端验证所需的 SSH 监听地址和端口。
EOF
}

select_install_mode() {
  [[ -z "$INSTALL_MODE" ]] || return 0
  local choice=''
  while true; do
    printf '\n1. 快速初始化\n2. 自定义初始化\n3. 仅安装/更新 SmartDNS\n4. 仅部署 sing-box 节点\n5. 仅安装/更新 Fail2ban\n6. 仅更新系统\n7. 系统清理\n8. 安全加固（体检 → 建议 → 确认后执行）\n0. 退出\n' >/dev/tty
    read_tty '请选择 [0-8]: ' choice
    case "$choice" in
      1) INSTALL_MODE=quick; return 0 ;;
      2) INSTALL_MODE=custom; return 0 ;;
      0) exit 0 ;;
      3) INSTALL_MODE=smartdns; return 0 ;;
      4) INSTALL_MODE=singbox; return 0 ;;
      5) INSTALL_MODE=fail2ban; return 0 ;;
      6) INSTALL_MODE=update; return 0 ;;
      7) INSTALL_MODE=cleanup; return 0 ;;
      8) INSTALL_MODE=hardening; return 0 ;;
      *) printf '无效选择。\n' >/dev/tty ;;
    esac
  done
}

collect_custom_phase_choice() {
  local choice=''
  while true; do
    printf '\n选择基础工具安装后的流程：\n1. 继续完整初始化\n2. 完成基础工具后退出，用于测试 IP、线路和基础环境\n' >/dev/tty
    read_tty '请选择 [1-2]: ' choice
    case "$choice" in
      1) return 0 ;;
      2) BASE_ONLY=true; return 0 ;;
      *) printf '无效选择。\n' >/dev/tty ;;
    esac
  done
}

ensure_key_validation_dependency() {
  command -v ssh-keygen >/dev/null 2>&1 && return 0
  CURRENT_STEP='安装公钥验证所需的最小依赖'
  wait_for_package_manager
  apt_get update
  apt_get install -y --no-install-recommends openssh-client
  command -v ssh-keygen >/dev/null || die '安装后仍缺少 ssh-keygen。'
}

ensure_port_validation_dependency() {
  command -v ss >/dev/null 2>&1 && return 0
  wait_for_package_manager
  apt_get update
  apt_get install -y --no-install-recommends iproute2
  command -v ss >/dev/null || die '缺少 ss，无法检查 SSH 端口。'
}

check_ssh_change_prerequisites() {
  systemctl is-active --quiet ssh.service || die 'ssh.service 未运行。'
  [[ -f "$SSH_MAIN" && ! -L "$SSH_MAIN" ]] || die "$SSH_MAIN 必须是普通文件。"
  [[ ! -L "$SSH_DIR" ]] || die "$SSH_DIR 不能是符号链接。"
  reject_symlink "$SSH_DROPIN"
  if systemctl is-active --quiet ssh.socket 2>/dev/null; then die '检测到 ssh.socket 激活；为避免锁死，请先转换为 ssh.service 后再运行。'; fi
  ssh_port_available "$SSH_PORT" || die "$SSH_PORT/tcp 已被占用或无法检查。"
}

collect_initialization_config() {
  CURRENT_STEP='收集初始化配置'
  case "$INSTALL_MODE" in
    quick) collect_quick_choices; collect_choices ;;
    custom)
      collect_custom_phase_choice
      collect_choices
      if [[ "$BASE_ONLY" == false ]]; then collect_network_choice; fi
      if ask_yes_no '是否开启 Debian 自动安全更新？' true; then AUTO_SECURITY=true; else AUTO_SECURITY=false; fi
      ;;
  esac
  if [[ "$BASE_ONLY" == false ]]; then
    if [[ "$NETWORK_REQUEST" == ipv4 ]] && ssh_session_uses_ipv6; then
      die '当前 SSH 会话正在通过 IPv6；请用 IPv4 SSH 登录后再关闭 IPv6。'
    fi
    if [[ "$PRESERVE_SSH" == false ]]; then
      ensure_port_validation_dependency
      ensure_key_validation_dependency
      collect_public_key
      check_ssh_change_prerequisites
      confirm_ssh_listener_change
    fi
    collect_ipv6_boot_policy
  fi
  collect_swap_choice
  print_initialization_summary
  # --base-only historically supports automation without a terminal confirmation.
  if [[ "$INSTALL_MODE" != base ]]; then
    ask_yes_no '确认以上配置并开始自动安装？' true || die '用户取消，未开始初始化。'
  fi
  CONFIG_CONFIRMED=true
}

print_initialization_summary() {
  local ssh="端口 $SSH_PORT/tcp；备用 22=$KEEP_SSH_22" key='使用已验证的新公钥' network=$NETWORK_REQUEST
  if [[ "$REUSE_PUBLIC_KEY" == true ]]; then key='复用已确认的公钥'; fi
  if [[ "$PRESERVE_SSH" == true ]]; then ssh='保留原有监听、认证及 UFW'; key='保留原有公钥'; fi
  if [[ "$BASE_ONLY" == true ]]; then ssh='不配置'; key='不配置'; network='不修改'; fi
  printf '\n本次执行配置：\n模式：%s；仅基础工具：%s\nSSH：%s\n公钥：%s\n网络：%s\nfull-upgrade：%s；Swap：%sMiB（0 表示不创建）\n' \
    "$INSTALL_MODE" "$BASE_ONLY" "$ssh" "$key" "$network" "$DO_FULL_UPGRADE" "$SWAP_CONFIRMED_MIB"
  printf '自动安全更新：%s\n' "$AUTO_SECURITY"
  if [[ "$NETWORK_REQUEST" == auto && "$BASE_ONLY" == false ]]; then
    case "$IPV6_BOOT_STATE:$IPV6_RESTORE_CHOICE" in
      off:restore) printf '重启后 IPv6：将被现有配置关闭；选择恢复，写入 %s 覆盖，不改原文件\n' "$NETWORK_SYSCTL" ;;
      off:keep) printf '重启后 IPv6：将被现有配置关闭；保留，Auto 按 ipv4 处理\n' ;;
      kernel-off:*) printf '重启后 IPv6：内核已禁用，按 ipv4 处理\n' ;;
      pending:*) printf '重启后 IPv6：迁移脚本旧策略后复查\n' ;;
    esac
  fi
  if [[ "$BASE_ONLY" == false ]]; then
    printf 'DNS：SmartDNS 仅监听 127.0.0.1:53；resolv.conf 备用 %s\n' "$FALLBACK_DNS"
  fi
}

install_component_dependencies() {
  CURRENT_STEP='安装组件依赖'
  wait_for_package_manager
  apt_get update
  case "$INSTALL_MODE" in
    smartdns) apt_get install -y ca-certificates curl dnsutils iproute2 util-linux e2fsprogs ;;
    singbox) apt_get install -y ca-certificates curl gnupg jq util-linux e2fsprogs ;;
  esac
}

run_smartdns_only() {
  install_component_dependencies
  # Only select the DNS answer/upstream family; do not toggle the host IPv6 stack.
  case "$NETWORK_REQUEST" in
    ipv4) NETWORK_STACK=ipv4 ;;
    dual) NETWORK_STACK=dual ;;
    auto) detect_ipv6_stack; log "Selected Network Stack: $NETWORK_STACK" ;;
  esac
  backup_dns_state
  DNS_TX=true
  install_and_configure_smartdns
  configure_system_dns
  log "SmartDNS 完成：网络=$NETWORK_STACK（策略 $NETWORK_REQUEST）；上游=$SMARTDNS_TRANSPORT；备份=$BACKUP_DIR"
  if [[ "$EARLY_DNS_FIXED" == true ]]; then log "已提前修复系统 DNS，原文件备份在 $EARLY_DNS_BACKUP"; fi
}

run_singbox_only() {
  [[ -r /dev/tty && -w /dev/tty ]] || die '节点配置向导需要交互式 /dev/tty。'
  install_component_dependencies
  install_sing_box
  run_node_config_wizard </dev/tty
}

run_fail2ban_only() {
  CURRENT_STEP='安装 Fail2ban 依赖'
  local action=nftables package installed fresh=false
  local -a packages=(fail2ban python3-systemd) missing=()
  if fail2ban_ufw_active; then action=ufw; else packages+=(nftables); fi
  for package in "${packages[@]}"; do
    installed=$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null) || installed=''
    if [[ "$installed" != 'install ok installed' && "$installed" != 'hold ok installed' ]]; then
      missing+=("$package")
      if [[ "$package" == fail2ban ]]; then fresh=true; fi
    fi
  done
  if (( ${#missing[@]} )); then
    ensure_system_dns
    CURRENT_STEP='安装 Fail2ban 依赖'
    wait_for_package_manager
    if [[ "$fresh" == true ]]; then
      if [[ "$(systemctl is-enabled fail2ban.service 2>/dev/null || true)" == masked* ]]; then
        die 'Fail2ban 已被管理员 mask，请先确认服务策略。'
      fi
      FAIL2BAN_RUNTIME_MASK=true
      systemctl mask --runtime fail2ban.service
    fi
    apt_get update
    apt_get install -y --no-install-recommends --no-upgrade "${missing[@]}"
    if [[ "$FAIL2BAN_RUNTIME_MASK" == true ]]; then
      systemctl disable fail2ban.service >/dev/null
      systemctl unmask --runtime fail2ban.service
      FAIL2BAN_RUNTIME_MASK=false
    fi
  fi
  if [[ "$action" == nftables ]]; then
    # Check permission and kernel support without committing firewall changes.
    nft --check add table inet vps_init_fail2ban_check || die 'UFW 未启用，nftables 也无法写入规则。'
  fi
  configure_fail2ban "$action"
}

qemu_guest_agent_status() {
  local status
  if status=$(dpkg-query -W -f='${db:Status-Status}' -- qemu-guest-agent 2>/dev/null); then
    printf '%s\n' "$status"
  elif [[ $? == 1 ]]; then
    printf '%s\n' 'not-installed'
  else
    return 1
  fi
}

remove_qemu_guest_agent() {
  local status plan packages
  CURRENT_STEP='检查 QEMU Guest Agent 安装状态'
  status=$(qemu_guest_agent_status) || die '无法查询 qemu-guest-agent 安装状态。'
  case "$status" in
    not-installed|config-files) log 'qemu-guest-agent 未安装，无需卸载。'; return 0 ;;
    installed) ;;
    *) die "qemu-guest-agent 状态异常（$status），无法卸载。" ;;
  esac

  wait_for_package_manager
  CURRENT_STEP='模拟卸载 QEMU Guest Agent'
  plan=$(LC_ALL=C apt_get -s -o APT::Get::AutomaticRemove=false -o APT::Get::Purge=false remove -- qemu-guest-agent) ||
    die 'APT 模拟卸载 qemu-guest-agent 失败。'
  if [[ "$INSTALL_MODE" == qemu-agent-remove || "$INSTALL_MODE" == hardening ]]; then
    log 'QEMU Guest Agent 卸载预览：'
    printf '%s\n' "$plan"
  fi
  if ! packages=$(cleanup_apt_plan "$plan") || [[ ! "$packages" =~ ^qemu-guest-agent(:[a-z0-9-]+)?$ ]]; then
    die 'APT 模拟结果并非仅卸载 qemu-guest-agent，已阻止执行。'
  fi
  if [[ "$INSTALL_MODE" == qemu-agent-remove || "$INSTALL_MODE" == hardening ]]; then
    if ! ask_yes_no '确认卸载 QEMU Guest Agent？' false; then
      log '已取消卸载 QEMU Guest Agent。'
      return 0
    fi
    wait_for_package_manager
  fi

  CURRENT_STEP='卸载 QEMU Guest Agent'
  # dpkg checks dependencies under its own lock and only removes the specified
  # package, even if package state changes after the APT simulation.
  dpkg --no-force-depends,depends-version --remove -- "$packages" ||
    die '卸载 qemu-guest-agent 失败（dpkg 返回错误）。'
  status=$(qemu_guest_agent_status) || die '无法验证 qemu-guest-agent 卸载结果。'
  [[ "$status" == not-installed || "$status" == config-files ]] ||
    die "qemu-guest-agent 卸载后状态异常（$status）。"
  log 'qemu-guest-agent 已卸载。'
}

cleanup_preflight() {
  CURRENT_STEP='清理预检'
  (( EUID == 0 )) || die '必须使用 root 运行。'
  [[ -r /etc/os-release && -d /run/lock ]] || die '缺少系统版本信息或锁目录。'
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == debian && "${VERSION_ID:-}" =~ ^(12|13)$ ]] || die '仅支持 Debian 12/13。'
  local tool
  for tool in df awk flock; do command -v "$tool" >/dev/null || die "缺少 $tool。"; done
  exec 9>"$LOCK_FILE"
  flock -n 9 || die '已有另一个 vps-init.sh 正在运行。'
}

cleanup_apt_plan() {
  local plan=$1
  awk '
    /^(Inst|Conf|Purg)[[:space:]]/ { invalid=1 }
    /^Remv[[:space:]]/ {
      if ($2 !~ /^[a-z0-9][a-z0-9+.-]*(:[a-z0-9-]+)?$/ || seen[$2]++) invalid=1
      print $2
    }
    /^[0-9]+ upgraded, [0-9]+ newly installed, [0-9]+ to remove/ {
      summary++; if ($1 != 0 || $3 != 0) invalid=1
      removals=$6
    }
    END { exit (invalid || summary != 1 || removals != length(seen)) }
  ' <<<"$plan"
}

cleanup_autoremove_safe() {
  local package=$1 metadata files scripts
  # Limit automatic orphan removal to optional libraries and development
  # packages. Treat unknown metadata, critical paths and maintainer hooks as unsafe.
  metadata=$(dpkg-query -W -f='${db:Status-Status}|${Essential}|${Protected}|${Priority}|${Section}' -- "$package") || return 1
  [[ "$metadata" =~ ^installed\|(no)?\|(no)?\|(optional|extra)\|([^|]+/)?(libs|oldlibs|libdevel)$ ]] || return 1
  case "${package%%:*}" in
    linux-*|kernel-*|kmod|grub*|*initramfs*|*systemd*|*pam*|*nss*|*ssh*|*smartdns*|*sing-box*|*fail2ban*|*nft*|*iptables*|*ufw*) return 1 ;;
  esac
  files=$(dpkg-query -L -- "$package") || return 1
  if grep -Eq '^/(boot|etc|var|root|home|sbin|usr/sbin)(/|$)|^/(usr/)?lib/(systemd|modules|udev|firmware)/' <<<"$files"; then return 1; fi
  scripts=$(dpkg-query --control-list "$package") || return 1
  ! grep -Exq 'prerm|postrm|triggers' <<<"$scripts"
}

cleanup_remove_packages() {
  local kind=$1 preview=$2 planned current plan package
  shift 2
  local -a packages=("$@")
  if ! ask_yes_no "删除上述$kind？" false; then
    CLEANUP_RESULT='用户跳过'
    return
  fi
  # Recheck dependencies after confirmation. dpkg removes only these exact
  # packages and enforces dependencies under its own locks.
  if ! plan=$(apt-get -s remove -- "${packages[@]}") || ! current=$(cleanup_apt_plan "$plan"); then
    CLEANUP_RESULT='失败（无法重新验证删除计划）'
    return
  fi
  planned=$(printf '%s\n' "${packages[@]}" | sort)
  if [[ "$(sort <<<"$current")" != "$planned" ]] || ! cmp -s <(dpkg-query -W -- "${packages[@]}") <(printf '%s\n' "$preview"); then
    CLEANUP_RESULT='跳过（删除计划或包版本已变化）'
    return
  fi
  if [[ "$kind" == 旧内核 ]]; then
    current=$(cleanup_old_kernel_candidates) || current=''
    for package in "${packages[@]}"; do
      if ! grep -Fxq -- "$package" <<<"$current"; then
        CLEANUP_RESULT='跳过（启动保护状态已变化）'
        return
      fi
    done
  else
    local auto
    auto=$(apt-mark showauto) || { CLEANUP_RESULT='跳过（无法复核自动安装状态）'; return; }
    for package in "${packages[@]}"; do
      if ! grep -Fxq -- "$package" <<<"$auto" || ! cleanup_autoremove_safe "$package"; then
        CLEANUP_RESULT='跳过（软件包保护状态已变化）'
        return
      fi
    done
  fi
  if dpkg --remove -- "${packages[@]}"; then CLEANUP_RESULT='已清理'; else CLEANUP_RESULT='失败（包管理器返回错误）'; fi
}

cleanup_orphan_packages() {
  local plan candidates package versions audit
  local -a packages
  CLEANUP_RESULT='跳过（缺少 APT 或 dpkg 工具）'
  command -v apt-get >/dev/null && command -v apt-mark >/dev/null && command -v dpkg >/dev/null && command -v dpkg-query >/dev/null || return 0
  audit=$(dpkg --audit) && [[ -z "$audit" ]] || { CLEANUP_RESULT='跳过（dpkg 状态异常）'; return; }
  CLEANUP_RESULT='失败（无法预览 APT 删除计划）'
  plan=$(apt-get -s autoremove) || return 0
  printf '\nAPT autoremove 完整预览\n%s\n' "$plan"
  candidates=$(cleanup_apt_plan "$plan") || return 0
  if [[ -z "$candidates" ]]; then CLEANUP_RESULT='无候选'; return; fi
  mapfile -t packages <<<"$candidates"
  for package in "${packages[@]}"; do
    if ! cleanup_autoremove_safe "$package"; then
      CLEANUP_RESULT="跳过（计划含受保护或无法安全确认的包 $package）"
      return
    fi
  done
  versions=$(dpkg-query -W -- "${packages[@]}") || return 0
  cleanup_remove_packages 无用软件包 "$versions" "${packages[@]}"
}

cleanup_grub_kernel() {
  local boot=$1 running=$2 file config environment
  # Only the stock GRUB first-entry layout can be resolved conservatively.
  command -v grub-script-check >/dev/null && command -v grub-editenv >/dev/null || return 1
  [[ -f "$boot/grub/grub.cfg" && -r "$boot/grub/grubenv" ]] || return 1
  # The kernel post-removal hook regenerates GRUB. The source defaults must
  # also select the first entry; never source local shell configuration.
  [[ -f /etc/default/grub ]] || return 1
  for file in /etc/default/grub.d/*.cfg; do [[ ! -e "$file" ]] || return 1; done
  awk '
    /^[[:space:]]*($|#)/ { next }
    /^GRUB_DEFAULT=(0|"0"|\0470\047)[[:space:]]*$/ { defaults++; next }
    /^GRUB_[A-Z0-9_]+=/ && !/^GRUB_DEFAULT=/ && !/[`$;&|]/ { next }
    { unsafe=1 }
    END { exit (unsafe || defaults > 1) }
  ' /etc/default/grub || return 1
  grub-script-check "$boot/grub/grub.cfg" >/dev/null || return 1
  environment=$(grub-editenv "$boot/grub/grubenv" list) || return 1
  if grep -Eq '^(next_entry|saved_entry|prev_saved_entry)=' <<<"$environment"; then return 1; fi
  # A BOOT_IMAGE for the running kernel and a GRUB installation are both
  # required. With UEFI, confirm firmware is booting Debian's GRUB/shim.
  file=$(awk '{ for (i=1; i<=NF; i++) if ($i ~ /^BOOT_IMAGE=([^[:space:]]*\/)?vmlinuz-/) {
    sub(/^BOOT_IMAGE=([^[:space:]]*\/)?vmlinuz-/, "", $i); print $i
  }}' /proc/cmdline)
  [[ "$file" == "$running" ]] || return 1
  if [[ -d /sys/firmware/efi ]]; then
    command -v efibootmgr >/dev/null || return 1
    config=$(efibootmgr -v) || return 1
    awk '
      /^BootCurrent:/ { current=$2 }
      /^BootNext:/ { uncertain=1 }
      /^BootOrder:/ { split($2, order, ","); first=order[1] }
      /^Boot[0-9A-Fa-f]/ && tolower($0) ~ /\\efi\\debian\\(grub|shim)(x64|aa64)\.efi/ { debian[substr($1,5,4)]=1 }
      END { exit (uncertain || current == "" || first != current || !debian[current]) }
    ' <<<"$config" || return 1
  else
    dpkg-query -W -f='${db:Status-Status}' grub-pc 2>/dev/null | grep -Fxq installed || return 1
  fi
  cleanup_parse_grub "$boot/grub/grub.cfg"
}

cleanup_parse_grub() {
  awk '
    /^### BEGIN .*\/10_linux ###$/ { standard=1; next }
    /^### END .*\/10_linux ###$/ { standard=0 }
    /^[[:space:]]*source[[:space:]]/ && $0 !~ /^[[:space:]]*source[[:space:]]+\$\{?(prefix|config_directory)\}?\/custom\.cfg[[:space:]]*$/ { unsafe=1 }
    /^[[:space:]]*(configfile|chainloader|blscfg)([[:space:]]|$)/ { unsafe=1 }
    /^[[:space:]]*set default=/ && $0 !~ /^[[:space:]]*set default="(0|\$\{next_entry\})"[[:space:]]*$/ { unsafe=1 }
    /^[[:space:]]*set default="0"[[:space:]]*$/ { fallback=1 }
    /^[[:space:]]*(menuentry|submenu)[[:space:]]/ {
      if (!standard || (!entries && $1 != "menuentry")) unsafe=1
      entries++
    }
    /^[[:space:]]*linux[[:space:]]/ && entries == 1 && standard {
      if ($2 !~ /^\/(boot\/)?vmlinuz-[a-zA-Z0-9.+~-]+$/ || kernel != "") unsafe=1
      kernel=$2; sub(/^.*\/vmlinuz-/, "", kernel)
    }
    END { if (unsafe || !fallback || kernel == "") exit 1; print kernel }
  ' "$1"
}

cleanup_old_kernel_candidates() {
  local boot=${1:-/boot} modules=${2:-/lib/modules} running default package release output files backup='' abi='' state
  local -a eligible=() releases=()
  running=$(uname -r) || return 1
  [[ ! -e "$boot/grub/custom.cfg" && ! -L "$boot/grub/custom.cfg" ]] || return 1
  default=$(cleanup_grub_kernel "$boot" "$running") || return 1
  output=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-image-*') || return 1
  while IFS=' ' read -r state package; do
    [[ "$state" == ii && "$package" =~ ^linux-image-[0-9][a-zA-Z0-9.+~-]+$ ]] || continue
    release=${package#linux-image-}
    release=${release%-unsigned}
    [[ -s "$boot/vmlinuz-$release" && -s "$boot/initrd.img-$release" && -d "$modules/$release/kernel" ]] || continue
    files=$(dpkg-query -L "$package") || continue
    awk -v release="$release" '
      $0 == "/boot/vmlinuz-" release { image=1 }
      /^\/boot\// && substr($0,length($0)-length(release)) != "-" release { unsafe=1 }
      /^\/(usr\/)?lib\/modules\// {
        sub(/^\/(usr\/)?lib\/modules\//, "")
        split($0, part, "/")
        if (part[1] != release) unsafe=1
      }
      END { exit (!image || unsafe) }
    ' <<<"$files" || continue
    eligible+=("$package")
    releases+=("$release")
    if [[ "$release" != "$running" ]] && { [[ -z "$backup" ]] || dpkg --compare-versions "$release" gt "$backup"; }; then
      backup=$release
    fi
  done <<<"$output"
  [[ -n "$backup" ]] && printf '%s\n' "${releases[@]}" | grep -Fx "$running" >/dev/null || return 1
  printf '%s\n' "${releases[@]}" | grep -Fx "$default" >/dev/null || return 1
  for package in "${eligible[@]}"; do
    release=${package#linux-image-}; release=${release%-unsigned}
    [[ "$release" != "$running" && "$release" != "$default" && "$release" != "$backup" ]] || continue
    # Protect a boot-related alias pointing to this kernel or initramfs.
    for abi in /vmlinuz /initrd.img /vmlinuz.old /initrd.img.old "$boot/vmlinuz" "$boot/initrd.img" "$boot/vmlinuz.old" "$boot/initrd.img.old"; do
      [[ -L "$abi" ]] || continue
      case "$(readlink -f -- "$abi")" in */vmlinuz-"$release"|*/initrd.img-"$release") continue 2 ;; esac
    done
    printf '%s\n' "$package"
  done
  return 0
}

cleanup_old_kernels() {
  local candidates plan actual versions audit size
  local -a packages
  CLEANUP_RESULT='跳过（无法可靠确认当前、默认或备用内核）'
  command -v apt-get >/dev/null && command -v dpkg >/dev/null && command -v dpkg-query >/dev/null || return 0
  audit=$(dpkg --audit) && [[ -z "$audit" ]] || { CLEANUP_RESULT='跳过（dpkg 状态异常）'; return; }
  candidates=$(cleanup_old_kernel_candidates) || return 0
  if [[ -z "$candidates" ]]; then CLEANUP_RESULT='无安全候选'; return; fi
  mapfile -t packages <<<"$candidates"
  CLEANUP_RESULT='跳过（内核删除计划涉及额外操作或无法预览）'
  plan=$(apt-get -s remove -- "${packages[@]}") && actual=$(cleanup_apt_plan "$plan") || return 0
  printf '\n旧内核完整删除预览\n%s\n' "$plan"
  [[ "$(sort <<<"$actual")" == "$(sort <<<"$candidates")" ]] || return 0
  size=$(dpkg-query -W -f='${Installed-Size}\n' -- "${packages[@]}" | awk '{ total += $1 } END { print total+0 }') || return 0
  printf '候选包的预计已安装大小：%s\n' "$(format_mib "$size")"
  versions=$(dpkg-query -W -- "${packages[@]}") || return 0
  cleanup_remove_packages 旧内核 "$versions" "${packages[@]}"
}

run_safe_cleanup() {
  SAFE_CLEANUP_APT='跳过（缺少 apt-get）'
  SAFE_CLEANUP_JOURNAL='跳过（缺少 journalctl）'
  SAFE_CLEANUP_TMPFILES='跳过（缺少 systemd-tmpfiles）'
  local -a exclusions=()
  if [[ -n "$TMP_DIR" ]]; then exclusions+=("--exclude-prefix=$TMP_DIR"); fi
  if [[ -n "$BACKUP_DIR" ]]; then exclusions+=("--exclude-prefix=$BACKUP_DIR"); fi
  if command -v apt-get >/dev/null; then
    if apt-get clean; then SAFE_CLEANUP_APT='完成'; else SAFE_CLEANUP_APT='失败'; fi
  fi
  if command -v journalctl >/dev/null; then
    if journalctl --vacuum-size=50M; then SAFE_CLEANUP_JOURNAL='完成（归档日志，目标 50MiB）'; else SAFE_CLEANUP_JOURNAL='失败'; fi
  fi
  if command -v systemd-tmpfiles >/dev/null; then
    if systemd-tmpfiles --clean --prefix=/tmp --prefix=/var/tmp \
      --exclude-prefix=/tmp/smartdns --exclude-prefix=/tmp/sing-box --exclude-prefix=/tmp/fail2ban \
      --exclude-prefix=/var/tmp/smartdns --exclude-prefix=/var/tmp/sing-box --exclude-prefix=/var/tmp/fail2ban "${exclusions[@]}"; then
      SAFE_CLEANUP_TMPFILES='完成'
    else
      SAFE_CLEANUP_TMPFILES='失败'
    fi
  fi
  SAFE_CLEANUP_RESULT="APT 缓存：$SAFE_CLEANUP_APT；Journal：$SAFE_CLEANUP_JOURNAL；临时文件：$SAFE_CLEANUP_TMPFILES"
  if [[ "$SAFE_CLEANUP_RESULT" == *失败* || "$SAFE_CLEANUP_RESULT" == *跳过* ]]; then
    warn "安全清理未全部完成：$SAFE_CLEANUP_RESULT"
  fi
}

run_system_cleanup() {
  CURRENT_STEP='系统清理'
  local before after total used orphans kernels swaps=''
  local CLEANUP_RESULT
  before=$(root_free_kib) || die '无法读取清理前的根分区空间。'
  IFS=' ' read -r total used < <(df -Pk / | awk 'NR == 2 { print $2, $3 }') || die '无法读取根分区容量。'
  printf '磁盘总容量：%s\n已用空间：%s\n可用空间：%s\n' "$(format_mib "$total")" "$(format_mib "$used")" "$(format_mib "$before")"
  if command -v swapon >/dev/null && swaps=$(swapon --show=NAME,SIZE --bytes); then
    printf '活动 Swap（容量以字节显示）\n%s\n' "${swaps:-无}"
  else
    warn '无法读取活动 Swap。'
  fi
  if [[ -e "$SWAPFILE" || -L "$SWAPFILE" ]]; then log "检测到脚本 Swap 路径：$SWAPFILE"; fi
  run_safe_cleanup
  if ( : </dev/tty ) 2>/dev/null; then
    cleanup_orphan_packages; orphans=$CLEANUP_RESULT
    cleanup_old_kernels; kernels=$CLEANUP_RESULT
  else
    orphans='跳过（无交互终端）'; kernels=$orphans
  fi
  printf '\nVPS 系统清理完成\n系统：Debian %s\n清理前可用：%s\n' "$VERSION_ID" "$(format_mib "$before")"
  if after=$(root_free_kib); then
    printf '清理后可用：%s\n实际增加可用空间：%s\n' "$(format_mib "$after")" "$(format_mib "$((after - before))")"
    if (( after >= MIN_ROOT_FREE_KIB )); then
      printf '安装所需 2GiB 空间：PASS\n'
    else
      printf '安装所需 2GiB 空间：FAIL，还需释放 %s\n' "$(format_mib "$((MIN_ROOT_FREE_KIB - after))")"
    fi
  else
    warn '无法读取清理后的根分区空间。'
  fi
  printf 'APT 缓存：%s\nJournal：%s\n临时文件：%s\n无用软件包：%s\n旧内核：%s\nSwap：未修改\n' \
    "$SAFE_CLEANUP_APT" "$SAFE_CLEANUP_JOURNAL" "$SAFE_CLEANUP_TMPFILES" "$orphans" "$kernels"
}

# Best-effort bookkeeping that runs after every system change: a failure only warns, so the final
# report (with the new SSH port) is never lost. The sing-box wizard falls back to a local probe.
persist_network_stack() {
  local dir=${NETWORK_STACK_STATE%/*}
  case "$NETWORK_STACK" in ipv4|dual) ;; *) warn "无法保存网络栈：$NETWORK_STACK"; return 1 ;; esac
  if [[ -L "$dir" || -L "$NETWORK_STACK_STATE" ]]; then warn "$NETWORK_STACK_STATE 或其目录是符号链接，未保存网络栈。"; return 1; fi
  if ensure_dir "$dir" && make_mutable "$NETWORK_STACK_STATE" &&
    printf '%s\n' "$NETWORK_STACK" >"$NETWORK_STACK_STATE" && chmod 0644 "$NETWORK_STACK_STATE" &&
    [[ "$(cat "$NETWORK_STACK_STATE")" == "$NETWORK_STACK" ]]; then
    return 0
  fi
  warn "网络栈状态保存失败：$NETWORK_STACK_STATE"
  return 1
}

main() {
  parse_args "$@"
  select_install_mode
  if [[ "$INSTALL_MODE" == audit ]]; then
    (( EUID == 0 )) || die '完整只读体检需要 root。'
    collect_security_audit
    print_security_audit full
    return 0
  fi
  if [[ "$INSTALL_MODE" == hardening ]]; then
    preflight
    acquire_lock
    run_security_hardening
    return 0
  fi
  if [[ "$INSTALL_MODE" == cleanup ]]; then
    cleanup_preflight
    run_system_cleanup
    return
  fi
  preflight
  acquire_lock
  # The DNS repair rewrites /etc/resolv.conf, so it only runs once the lock is held. Modes that
  # never touch the network skip it; Fail2ban-only checks lazily, when packages must be installed.
  case "$INSTALL_MODE" in
    fail2ban|qemu-agent-remove) ;;
    *) ensure_system_dns ;;
  esac
  case "$INSTALL_MODE" in
    smartdns) run_smartdns_only; return 0 ;;
    singbox) run_singbox_only; return 0 ;;
    fail2ban) run_fail2ban_only; return 0 ;;
    update) run_system_update_only; return 0 ;;
    qemu-agent-remove) remove_qemu_guest_agent; return 0 ;;
  esac
  collect_initialization_config
  install_early_dependencies
  if [[ "$BASE_ONLY" == false && "$PRESERVE_SSH" == false ]]; then
    install_authorized_key
  fi
  configure_swap
  update_system_and_tools
  configure_security_updates
  if [[ "$BASE_ONLY" == true ]]; then
    log '已按 --base-only 完成系统更新与基础工具安装。'
    return 0
  fi
  # Establish IPv4 connectivity before tuning or changing the kernel.
  CURRENT_STEP='检测网络栈'
  ipv4_https_works || die '未检测到可用 IPv4 HTTPS 出站。'
  configure_chrony
  configure_tcp_tuning
  install_sing_box
  backup_dns_state
  DNS_TX=true
  apply_network_stack
  cleanup_legacy_network_stack
  apply_ipv6_boot_policy
  detect_network_stack
  finalize_ipv6_stack
  install_and_configure_smartdns
  configure_system_dns
  configure_ssh
  configure_ufw
  if [[ "$PRESERVE_SSH" == false ]]; then record_trusted_keys; fi
  configure_cf8443
  if [[ "$PRESERVE_SSH" == true ]]; then
    log '保留现有 Fail2ban 状态，避免重启时变更 SSH 封禁规则。'
  else
    configure_fail2ban
  fi
  persist_network_stack || warn '网络栈状态未保存；sing-box 向导将按本地 IPv6 检测给出默认值。'
  run_safe_cleanup
  check_boot_services
  print_report
}

# The wizard runs in a separate Bash process so its traps, globals and functions
# cannot replace the initialization transaction or cleanup handlers.
run_node_config_wizard() {
  bash /dev/fd/3 3<<'SINGBOX_WIZARD'
#!/usr/bin/env bash
set -Eeuo pipefail

readonly CONFIG_PATH='/etc/sing-box/config.json'
readonly CONFIG_DIR='/etc/sing-box'
readonly NETWORK_STACK_STATE='/var/lib/404-vps-tools/network-stack'
readonly MODULE_CANCEL_STATUS=20

TEMP_CONFIG=''
LOG_JSON='{}'
INBOUNDS_JSON='[]'
OUTBOUNDS_JSON='[]'
ROUTE_JSON='{}'
BUILT_ITEM=''
WORKING_CONFIG_JSON=''
OUTBOUND_TAGS=()
MODULE_INPUT_ACTIVE=false
NETWORK_STACK='ipv4'
VIRTUALIZATION='unknown'
CONTAINER_VIRTUALIZATION='none'
ENVIRONMENT_LABEL='Unknown environment'
KERNEL_ENFORCEMENT='unavailable'
APPLICATION_ENFORCEMENT='enabled'
NETWORK_RESULT='SUCCESS'

RED=''
GREEN=''
YELLOW=''
CYAN=''
RESET=''

init_colors() {
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        RED=$'\033[31m'
        GREEN=$'\033[32m'
        YELLOW=$'\033[33m'
        CYAN=$'\033[36m'
        RESET=$'\033[0m'
    fi
}

info() {
    printf '%s%s%s\n' "$CYAN" "$*" "$RESET"
}

success() {
    printf '%s%s%s\n' "$GREEN" "$*" "$RESET"
}

warn() {
    printf '%s%s%s\n' "$YELLOW" "$*" "$RESET" >&2
}

error() {
    printf '%s错误：%s%s\n' "$RED" "$*" "$RESET" >&2
}

cleanup() {
    if [[ -n "$TEMP_CONFIG" && -f "$TEMP_CONFIG" ]]; then
        rm -f -- "$TEMP_CONFIG"
    fi
}

handle_signal() {
    printf '\n' >&2
    warn '已取消，未完成的临时配置将被清理。'
    exit 130
}

trap cleanup EXIT
trap handle_signal INT TERM

die() {
    error "$*"
    exit 1
}

check_environment() {
    local os_id=''
    local os_version=''

    if (( EUID != 0 )); then
        die '请使用 root 身份运行。'
    fi

    if [[ ! -r /etc/os-release ]]; then
        die '无法读取 /etc/os-release；本工具仅支持 Debian 12/13。'
    fi

    # shellcheck disable=SC1091
    source /etc/os-release
    os_id="${ID:-}"
    os_version="${VERSION_ID:-}"
    os_version="${os_version%%.*}"

    if [[ "$os_id" != 'debian' || ( "$os_version" != '12' && "$os_version" != '13' ) ]]; then
        die "仅支持 Debian 12/13；当前系统为 ${PRETTY_NAME:-未知系统}。"
    fi

    if ! command -v jq >/dev/null 2>&1; then
        die '未找到 jq，请先手动安装 jq。'
    fi
}

detect_runtime_environment() {
    local detected=''
    local container=''

    if command -v systemd-detect-virt >/dev/null 2>&1; then
        detected="$(systemd-detect-virt 2>/dev/null || true)"
        container="$(systemd-detect-virt --container 2>/dev/null || true)"
    fi
    [[ -n "$detected" && "$detected" != 'none' ]] || detected='none'
    [[ -n "$container" && "$container" != 'none' ]] || container='none'
    VIRTUALIZATION="$detected"
    CONTAINER_VIRTUALIZATION="$container"
    if [[ "$container" != 'none' ]]; then
        ENVIRONMENT_LABEL="$container container"
        info "Virtualization: $detected"
        info "Container environment detected: $container."
    elif [[ "$detected" == 'none' ]]; then
        ENVIRONMENT_LABEL='Bare metal'
        info 'Virtualization: none'
    else
        ENVIRONMENT_LABEL="$detected virtual machine"
        info "Virtualization: $detected"
    fi
}

inspect_kernel_enforcement() {
    local all_value='unknown'
    local default_value='unknown'
    local loopback_value='unknown'
    local desired_value=0

    [[ "$NETWORK_STACK" == 'ipv4' ]] && desired_value=1
    if command -v sysctl >/dev/null 2>&1; then
        all_value="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || printf unknown)"
        default_value="$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || printf unknown)"
        loopback_value="$(sysctl -n net.ipv6.conf.lo.disable_ipv6 2>/dev/null || printf unknown)"
    fi
    if [[ "$all_value" == "$desired_value" &&
        "$default_value" == "$desired_value" &&
        "$loopback_value" == "$desired_value" ]]; then
        KERNEL_ENFORCEMENT='enabled'
        return 0
    fi
    KERNEL_ENFORCEMENT='unavailable'
    NETWORK_RESULT='SUCCESS_WITH_WARNINGS'
    warn "Kernel enforcement is unavailable for requested mode $NETWORK_STACK; application enforcement will be used."
}

print_network_result() {
    printf '\nRequested mode: %s\n' "$NETWORK_STACK"
    printf 'Kernel enforcement: %s\n' "$KERNEL_ENFORCEMENT"
    printf 'Application enforcement: %s\n' "$APPLICATION_ENFORCEMENT"
    printf 'Environment: %s\n' "$ENVIRONMENT_LABEL"
    printf 'Virtualization: %s\n' "$VIRTUALIZATION"
    printf 'Container: %s\n' "$CONTAINER_VIRTUALIZATION"
    printf 'Result: %s\n' "$NETWORK_RESULT"
}

read_line() {
    local target_name="$1"
    local prompt="$2"
    local secret="${3:-false}"
    local value=''
    local key=''
    local next_key=''
    local read_status=0
    local echo_input=false

    if [[ "$secret" != 'true' && -t 0 ]]; then
        echo_input=true
    fi

    printf '%s' "$prompt"
    while true; do
        if IFS= read -r -s -n 1 key; then
            :
        else
            read_status=$?
            printf '\n' >&2
            if (( read_status > 128 )); then
                return "$read_status"
            fi
            exit 0
        fi

        case "$key" in
            '')
                printf '\n'
                printf -v "$target_name" '%s' "$value"
                return 0
                ;;
            $'\177'|$'\b')
                if [[ -n "$value" ]]; then
                    value="${value%?}"
                    if [[ "$echo_input" == 'true' ]]; then
                        printf '\b \b'
                    fi
                fi
                ;;
            $'\e')
                if IFS= read -r -s -n 1 -t 0.05 next_key; then
                    consume_escape_sequence "$next_key"
                    continue
                fi
                if [[ "$MODULE_INPUT_ACTIVE" == 'true' ]]; then
                    printf '\n'
                    printf -v "$target_name" '%s' ''
                    return "$MODULE_CANCEL_STATUS"
                fi
                ;;
            *)
                value+="$key"
                if [[ "$echo_input" == 'true' ]]; then
                    printf '%s' "$key"
                fi
                ;;
        esac
    done
}

consume_escape_sequence() {
    local first_key="$1"
    local key=''

    case "$first_key" in
        '[')
            while IFS= read -r -s -n 1 -t 0.01 key; do
                [[ "$key" == [@-~] ]] && break
            done
            ;;
        'O')
            IFS= read -r -s -n 1 -t 0.01 key || true
            ;;
    esac
}

begin_module_build() {
    BUILT_ITEM=''
    MODULE_INPUT_ACTIVE=true
}

finish_module_build() {
    MODULE_INPUT_ACTIVE=false
}

module_prompt() {
    local prompt_status=0

    if "$@"; then
        return 0
    else
        prompt_status=$?
    fi

    BUILT_ITEM=''
    finish_module_build
    return "$prompt_status"
}

prompt_required() {
    local target_name="$1"
    local label="$2"
    local secret="${3:-false}"
    local input=''
    local prompt_status=0

    while true; do
        if read_line input "${label}：" "$secret"; then
            :
        else
            prompt_status=$?
            return "$prompt_status"
        fi
        if [[ -n "$input" ]]; then
            printf -v "$target_name" '%s' "$input"
            return
        fi
        error '此字段不能为空，请重新输入。'
    done
}

prompt_port() {
    local target_name="$1"
    local label="$2"
    local default_port="$3"
    local input=''
    local prompt_status=0

    while true; do
        if read_line input "${label} [${default_port}]：" false; then
            :
        else
            prompt_status=$?
            return "$prompt_status"
        fi
        input="${input:-$default_port}"
        if [[ "$input" =~ ^[0-9]+$ && ${#input} -le 5 ]] \
            && (( 10#$input >= 1 && 10#$input <= 65535 )); then
            printf -v "$target_name" '%s' "$((10#$input))"
            return
        fi
        error '端口必须是 1–65535 的整数。'
    done
}

prompt_yes_no() {
    local target_name="$1"
    local label="$2"
    local input=''
    local prompt_status=0

    while true; do
        if read_line input "${label} [y/n]：" false; then
            :
        else
            prompt_status=$?
            return "$prompt_status"
        fi
        case "${input,,}" in
            y|yes)
                printf -v "$target_name" '%s' 'yes'
                return
                ;;
            n|no)
                printf -v "$target_name" '%s' 'no'
                return
                ;;
            *)
                error '请输入 y、yes、n 或 no。'
                ;;
        esac
    done
}

prompt_numbered_choice() {
    local target_name="$1"
    local minimum="$2"
    local maximum="$3"
    local default_choice="${4:-}"
    local input=''
    local prompt_status=0

    while true; do
        if [[ -n "$default_choice" ]]; then
            if read_line input "请输入选项 [${default_choice}]：" false; then
                :
            else
                prompt_status=$?
                return "$prompt_status"
            fi
            input="${input:-$default_choice}"
        else
            if read_line input '请输入选项：' false; then
                :
            else
                prompt_status=$?
                return "$prompt_status"
            fi
        fi

        if [[ "$input" =~ ^[0-9]+$ && ${#input} -le 9 ]] \
            && (( 10#$input >= minimum && 10#$input <= maximum )); then
            printf -v "$target_name" '%s' "$((10#$input))"
            return
        fi
        error "请输入 ${minimum}–${maximum} 之间的数字。"
    done
}

prompt_method() {
    local target_name="$1"
    local choice=''
    local prompt_status=0

    printf '\n请选择 Shadowsocks 2022 method：\n\n'
    printf '1. 2022-blake3-aes-128-gcm（默认）\n'
    printf '2. 2022-blake3-aes-256-gcm\n'
    printf '3. 2022-blake3-chacha20-poly1305\n'
    if prompt_numbered_choice choice 1 3 1; then
        :
    else
        prompt_status=$?
        return "$prompt_status"
    fi

    case "$choice" in
        1) printf -v "$target_name" '%s' '2022-blake3-aes-128-gcm' ;;
        2) printf -v "$target_name" '%s' '2022-blake3-aes-256-gcm' ;;
        3) printf -v "$target_name" '%s' '2022-blake3-chacha20-poly1305' ;;
    esac
}

prompt_server_ip() {
    local target_name="$1"
    local candidate=''
    local prompt_status=0

    while true; do
        if prompt_required candidate '请输入服务器 IP' false; then
            :
        else
            prompt_status=$?
            return "$prompt_status"
        fi
        if [[ "$candidate" =~ [[:space:]] ]]; then
            error '服务器 IP 不得包含空格。'
            continue
        fi

        if [[ "$candidate" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
            || [[ "$candidate" == *:* && "$candidate" =~ ^[0-9A-Fa-f:]+$ ]]; then
            printf -v "$target_name" '%s' "$candidate"
            return
        fi

        error '请输入 IPv4 或 IPv6 地址，不接受域名。'
    done
}

is_valid_ipv4() {
    local candidate="$1"
    local octet=''
    local -a octets=()

    [[ "$candidate" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS='.' read -r -a octets <<<"$candidate"
    (( ${#octets[@]} == 4 )) || return 1
    for octet in "${octets[@]}"; do
        [[ ${#octet} -le 3 ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

is_valid_ipv6() {
    local candidate="$1"
    local ipv4_tail=''
    local left=''
    local right=''
    local part=''
    local explicit_parts=0
    local -a parts=()

    if [[ "$candidate" == *.* ]]; then
        ipv4_tail="${candidate##*:}"
        is_valid_ipv4 "$ipv4_tail" || return 1
        candidate="${candidate%:*}:0:0"
    fi

    [[ "$candidate" == *:* && "$candidate" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    [[ "$candidate" != *:::* ]] || return 1

    if [[ "$candidate" == *::* ]]; then
        left="${candidate%%::*}"
        right="${candidate#*::}"
        [[ "$right" != *::* ]] || return 1
        if [[ -n "$left" ]]; then
            [[ "$left" != :* && "$left" != *: ]] || return 1
            IFS=':' read -r -a parts <<<"$left"
            for part in "${parts[@]}"; do
                [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
                ((explicit_parts += 1))
            done
        fi
        if [[ -n "$right" ]]; then
            [[ "$right" != :* && "$right" != *: ]] || return 1
            IFS=':' read -r -a parts <<<"$right"
            for part in "${parts[@]}"; do
                [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
                ((explicit_parts += 1))
            done
        fi
        (( explicit_parts < 8 ))
        return
    fi

    [[ "$candidate" != :* && "$candidate" != *: ]] || return 1
    IFS=':' read -r -a parts <<<"$candidate"
    (( ${#parts[@]} == 8 )) || return 1
    for part in "${parts[@]}"; do
        [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
    done
}

is_valid_domain() {
    local candidate="$1"
    local label=''
    local -a labels=()

    (( ${#candidate} <= 253 )) || return 1
    [[ "$candidate" != .* && "$candidate" != *. && "$candidate" != *..* ]] || return 1
    [[ ! "$candidate" =~ ^[0-9.]+$ ]] || return 1
    IFS='.' read -r -a labels <<<"$candidate"
    for label in "${labels[@]}"; do
        (( ${#label} >= 1 && ${#label} <= 63 )) || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

prompt_server_address() {
    local target_name="$1"
    local candidate=''
    local prompt_status=0

    while true; do
        if prompt_required candidate '请输入 server' false; then
            :
        else
            prompt_status=$?
            return "$prompt_status"
        fi

        if [[ "$candidate" =~ [[:space:]] || "$candidate" == *://* \
            || "$candidate" == */* ]]; then
            error 'server 必须是 IPv4、IPv6 或域名，且不得包含空格、协议或路径。'
        elif is_valid_ipv4 "$candidate" || is_valid_ipv6 "$candidate" \
            || is_valid_domain "$candidate"; then
            printf -v "$target_name" '%s' "$candidate"
            return 0
        else
            error '请输入合法的 IPv4、IPv6 或域名；server 中不要附带端口。'
        fi
    done
}

tag_exists() {
    local candidate="$1"
    local existing=''

    for existing in "${OUTBOUND_TAGS[@]}"; do
        if [[ "$existing" == "$candidate" ]]; then
            return 0
        fi
    done
    return 1
}

prompt_outbound_tag() {
    local target_name="$1"
    local candidate=''
    local prompt_status=0

    while true; do
        if prompt_required candidate '请输入 outbound tag' false; then
            :
        else
            prompt_status=$?
            return "$prompt_status"
        fi
        if [[ "$candidate" =~ [[:space:]] ]]; then
            error 'outbound tag 不得包含空格。'
        elif [[ "$candidate" == 'direct' ]]; then
            error 'outbound tag 不得等于 direct。'
        elif tag_exists "$candidate"; then
            error "outbound tag '${candidate}' 已存在，请重新输入 tag。"
        else
            printf -v "$target_name" '%s' "$candidate"
            return
        fi
    done
}

append_inbound() {
    local item="$1"
    local updated=''

    if updated="$(jq -c --argjson item "$item" '. + [$item]' <<<"$INBOUNDS_JSON")"; then
        INBOUNDS_JSON="$updated"
        return 0
    fi
    return 1
}

append_outbound() {
    local item="$1"
    local updated=''

    if updated="$(jq -c --argjson item "$item" '. + [$item]' <<<"$OUTBOUNDS_JSON")"; then
        OUTBOUNDS_JSON="$updated"
        return 0
    fi
    return 1
}

reset_generation_state() {
    LOG_JSON='{}'
    INBOUNDS_JSON='[]'
    OUTBOUNDS_JSON='[]'
    ROUTE_JSON='{}'
    BUILT_ITEM=''
    WORKING_CONFIG_JSON=''
    OUTBOUND_TAGS=()
    MODULE_INPUT_ACTIVE=false

    if [[ -n "$TEMP_CONFIG" && -f "$TEMP_CONFIG" ]]; then
        rm -f -- "$TEMP_CONFIG"
    fi
    TEMP_CONFIG=''
}

discard_existing_changes() {
    reset_generation_state
}

load_existing_config_file() {
    local config_path="$1"

    if [[ ! -e "$config_path" ]]; then
        error "现有配置不存在：${config_path}"
        return 1
    fi
    if [[ ! -r "$config_path" ]]; then
        error "现有配置不可读：${config_path}"
        return 1
    fi
    if ! jq empty "$config_path" >/dev/null 2>&1; then
        error "现有配置不是合法 JSON：${config_path}"
        return 1
    fi
    if ! jq -e 'type == "object"' "$config_path" >/dev/null 2>&1; then
        error '现有配置的 JSON 顶层必须是对象。'
        return 1
    fi

    WORKING_CONFIG_JSON="$(jq -c '.' "$config_path")"
}

working_field_type() {
    local field="$1"

    jq -r --arg field "$field" \
        'if has($field) then (.[$field] | type) else "missing" end' \
        <<<"$WORKING_CONFIG_JSON"
}

ensure_working_array() {
    local field="$1"
    local field_type=''

    field_type="$(working_field_type "$field")"
    case "$field_type" in
        missing|array)
            return 0
            ;;
        *)
            error "现有配置的 .${field} 必须是数组，本轮修改已停止。"
            return 1
            ;;
    esac
}

ensure_working_route_object() {
    local field_type=''

    field_type="$(working_field_type 'route')"
    case "$field_type" in
        missing|object)
            return 0
            ;;
        *)
            error '现有配置的 .route 必须是对象，本轮修改已停止。'
            return 1
            ;;
    esac
}

working_tag_exists() {
    local field="$1"
    local tag="$2"

    jq -e --arg field "$field" --arg tag "$tag" \
        'any(.[$field][]?; (.tag? | type == "string") and .tag == $tag)' \
        <<<"$WORKING_CONFIG_JSON" >/dev/null
}

append_working_inbound() {
    local item="$1"
    local tag=''

    ensure_working_array 'inbounds' || return 1
    tag="$(jq -r '.tag // empty' <<<"$item")"
    if [[ -z "$tag" ]]; then
        error '新 inbound 缺少 tag，无法追加。'
        return 1
    fi
    if working_tag_exists 'inbounds' "$tag"; then
        error "inbound tag '${tag}' 已经存在，不允许重复追加。"
        return 1
    fi

    WORKING_CONFIG_JSON="$(jq -c --argjson item "$item" \
        '.inbounds = ((.inbounds // []) + [$item])' \
        <<<"$WORKING_CONFIG_JSON")"
}

refresh_outbound_tags_from_working() {
    local tag=''
    local existing=''
    local duplicate='false'

    ensure_working_array 'outbounds' || return 1
    OUTBOUND_TAGS=()
    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        duplicate='false'
        for existing in "${OUTBOUND_TAGS[@]}"; do
            if [[ "$existing" == "$tag" ]]; then
                duplicate='true'
                break
            fi
        done
        if [[ "$duplicate" == 'false' ]]; then
            OUTBOUND_TAGS+=("$tag")
        fi
    done < <(jq -r '
        .outbounds[]?
        | .tag?
        | select(type == "string" and length > 0)
    ' <<<"$WORKING_CONFIG_JSON")
}

append_working_outbound() {
    local item="$1"
    local tag=''
    local updated=''
    local original_config="$WORKING_CONFIG_JSON"
    local -a original_tags=("${OUTBOUND_TAGS[@]}")

    ensure_working_array 'outbounds' || return 1
    tag="$(jq -r '.tag // empty' <<<"$item")"
    if [[ -z "$tag" ]]; then
        error '新 outbound 的 tag 不能为空。'
        return 1
    fi
    if [[ "$tag" =~ [[:space:]] ]]; then
        error '新 outbound 的 tag 不得包含空格。'
        return 1
    fi
    if [[ "$tag" == 'direct' ]]; then
        error '追加模式暂不提供 direct outbound。'
        return 1
    fi
    if working_tag_exists 'outbounds' "$tag"; then
        error "outbound tag '${tag}' 已经存在，不允许重复追加。"
        return 1
    fi

    if updated="$(jq -c --argjson item "$item" \
        '.outbounds = ((.outbounds // []) + [$item])' \
        <<<"$WORKING_CONFIG_JSON")"; then
        WORKING_CONFIG_JSON="$updated"
        if refresh_outbound_tags_from_working; then
            return 0
        fi
        WORKING_CONFIG_JSON="$original_config"
        OUTBOUND_TAGS=("${original_tags[@]}")
    fi
    return 1
}

set_working_route_final() {
    local final_tag="$1"

    ensure_working_array 'outbounds' || return 1
    ensure_working_route_object || return 1
    if ! working_tag_exists 'outbounds' "$final_tag"; then
        error "outbound tag '${final_tag}' 不存在，不能设为 route.final。"
        return 1
    fi

    WORKING_CONFIG_JSON="$(jq -c --arg final "$final_tag" \
        '.route = (.route // {}) | .route.final = $final' \
        <<<"$WORKING_CONFIG_JSON")"
}

write_working_config_temp() {
    if [[ -n "$TEMP_CONFIG" && -f "$TEMP_CONFIG" ]]; then
        rm -f -- "$TEMP_CONFIG"
    fi
    TEMP_CONFIG=''
    create_temp_config
    jq . <<<"$WORKING_CONFIG_JSON" >"$TEMP_CONFIG"
}

display_working_tags() {
    local field="$1"
    local label="$2"
    local field_type=''
    local tag=''
    local count=0

    field_type="$(working_field_type "$field")"
    printf '\n当前已有的 %s tag：\n' "$label"
    if [[ "$field_type" == 'missing' ]]; then
        printf '（无）\n'
        return
    fi
    if [[ "$field_type" != 'array' ]]; then
        printf '（.%s 不是数组）\n' "$field"
        return
    fi

    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        printf -- '- %s\n' "$tag"
        ((count += 1))
    done < <(jq -r --arg field "$field" '
        .[$field][]?
        | .tag?
        | select(type == "string" and length > 0)
    ' <<<"$WORKING_CONFIG_JSON")

    if (( count == 0 )); then
        printf '（无）\n'
    fi
}

configure_log() {
    local choice=''

    printf '\n请选择日志等级：\n\n'
    printf '1. warn（默认）\n'
    printf '2. info\n'
    printf '3. error\n'
    printf '4. disabled\n'
    prompt_numbered_choice choice 1 4 1

    case "$choice" in
        1) LOG_JSON="$(jq -cn '{level:"warn",timestamp:true}')" ;;
        2) LOG_JSON="$(jq -cn '{level:"info",timestamp:true}')" ;;
        3) LOG_JSON="$(jq -cn '{level:"error",timestamp:true}')" ;;
        4) LOG_JSON="$(jq -cn '{disabled:true}')" ;;
    esac
}

select_network_stack() {
    local choice='' default_stack='' default_choice=1 default_source='本地 IPv6 地址与默认路由检测'
    if [[ -f "$NETWORK_STACK_STATE" ]]; then
        read -r default_stack <"$NETWORK_STACK_STATE" || true
    fi
    case "$default_stack" in
        ipv4|dual) default_source="初始化状态 $NETWORK_STACK_STATE" ;;
        *)
            default_stack=ipv4
            if [[ -n "$(ip -6 -o addr show scope global 2>/dev/null)" &&
                  -n "$(ip -6 route show default 2>/dev/null)" ]]; then
                default_stack=dual
            fi
            ;;
    esac
    [[ "$default_stack" != dual ]] || default_choice=2

    printf '\n请选择网络栈：\n\n'
    printf '1) IPv4\n'
    printf '2) Dual-stack\n'
    printf '默认：%s（来源：%s）\n' "$default_stack" "$default_source"
    prompt_numbered_choice choice 1 2 "$default_choice"

    case "$choice" in
        1) NETWORK_STACK='ipv4' ;;
        2) NETWORK_STACK='dual' ;;
    esac
    info "Applying application-level $NETWORK_STACK configuration."
    inspect_kernel_enforcement
}

get_listen_address() {
    case "$NETWORK_STACK" in
        ipv4) printf '0.0.0.0' ;;
        dual) printf '::' ;;
        *)
            error "未知网络栈：${NETWORK_STACK}"
            return 1
            ;;
    esac
}

build_reality_inbound() {
    local listen_port=''
    local listen_address=''
    local uuid=''
    local disguise_domain=''
    local handshake_port=''
    local private_key=''
    local short_id=''

    begin_module_build
    info '配置 VLESS Reality inbound'
    module_prompt prompt_port listen_port '请输入监听端口' 443 || return $?
    module_prompt prompt_required uuid '请输入 UUID' true || return $?
    module_prompt prompt_required disguise_domain '请输入 Reality 伪装域名' false || return $?
    module_prompt prompt_port handshake_port '请输入 Reality handshake.server_port' 443 || return $?
    module_prompt prompt_required private_key '请输入 Reality private_key' true || return $?
    module_prompt prompt_required short_id '请输入 Reality short_id' true || return $?
    listen_address="$(get_listen_address)" || return $?

    BUILT_ITEM="$(jq -cn \
        --arg listen_address "$listen_address" \
        --argjson listen_port "$listen_port" \
        --arg uuid "$uuid" \
        --arg disguise_domain "$disguise_domain" \
        --argjson handshake_port "$handshake_port" \
        --arg private_key "$private_key" \
        --arg short_id "$short_id" \
        '{
            type: "vless",
            tag: "vless-reality-in",
            listen: $listen_address,
            listen_port: $listen_port,
            users: [{
                name: "main",
                uuid: $uuid,
                flow: "xtls-rprx-vision"
            }],
            tls: {
                enabled: true,
                server_name: $disguise_domain,
                reality: {
                    enabled: true,
                    handshake: {
                        server: $disguise_domain,
                        server_port: $handshake_port
                    },
                    private_key: $private_key,
                    short_id: [$short_id]
                }
            }
        }')" || {
        BUILT_ITEM=''
        finish_module_build
        return 1
    }
    finish_module_build
}

build_transit_hysteria2_inbound() {
    local listen_port=''
    local listen_address=''
    local user_password=''
    local certificate_directory=''

    begin_module_build
    info '配置 Hysteria2 inbound'
    module_prompt prompt_port listen_port '请输入监听端口' 443 || return $?
    module_prompt prompt_required user_password '请输入 Hysteria2 用户 password' true || return $?
    module_prompt prompt_required certificate_directory '请输入 /etc/ssl/ 下的证书目录名' false || return $?
    listen_address="$(get_listen_address)" || return $?

    BUILT_ITEM="$(jq -cn \
        --arg listen_address "$listen_address" \
        --argjson listen_port "$listen_port" \
        --arg user_password "$user_password" \
        --arg certificate_path "/etc/ssl/${certificate_directory}/fullchain.pem" \
        --arg key_path "/etc/ssl/${certificate_directory}/privkey.pem" \
        '{
            type: "hysteria2",
            tag: "hy2-in",
            listen: $listen_address,
            listen_port: $listen_port,
            users: [{
                name: "main",
                password: $user_password
            }],
            tls: {
                enabled: true,
                certificate_path: $certificate_path,
                key_path: $key_path,
                min_version: "1.3"
            }
        }')" || {
        BUILT_ITEM=''
        finish_module_build
        return 1
    }
    finish_module_build
}

build_exit_hysteria2_inbound() {
    local listen_port=''
    local listen_address=''
    local user_password=''
    local certificate_directory=''

    begin_module_build
    info '配置 Hysteria2 inbound'
    module_prompt prompt_port listen_port '请输入监听端口' 32124 || return $?
    module_prompt prompt_required user_password '请输入 Hysteria2 用户 password' true || return $?
    module_prompt prompt_required certificate_directory '请输入 /etc/ssl/ 下的证书目录名' false || return $?
    listen_address="$(get_listen_address)" || return $?

    BUILT_ITEM="$(jq -cn \
        --arg listen_address "$listen_address" \
        --argjson listen_port "$listen_port" \
        --arg user_password "$user_password" \
        --arg certificate_path "/etc/ssl/${certificate_directory}/fullchain.pem" \
        --arg key_path "/etc/ssl/${certificate_directory}/privkey.pem" \
        '{
            type: "hysteria2",
            tag: "hy2-in",
            listen: $listen_address,
            listen_port: $listen_port,
            users: [{
                name: "main",
                password: $user_password
            }],
            tls: {
                enabled: true,
                certificate_path: $certificate_path,
                key_path: $key_path,
                min_version: "1.3"
            }
        }')" || {
        BUILT_ITEM=''
        finish_module_build
        return 1
    }
    finish_module_build
}

build_cf_tunnel_inbound() {
    local listen_port=''
    local uuid=''

    begin_module_build
    info '配置 CF Tunnel inbound'
    module_prompt prompt_port listen_port '请输入监听端口' 33333 || return $?
    module_prompt prompt_required uuid '请输入 UUID' true || return $?

    BUILT_ITEM="$(jq -cn \
        --argjson listen_port "$listen_port" \
        --arg uuid "$uuid" \
        '{
            type: "vless",
            tag: "cf-tunnel-in",
            listen: "127.0.0.1",
            listen_port: $listen_port,
            users: [{
                name: "cf-user",
                uuid: $uuid
            }],
            transport: {
                type: "ws",
                path: ""
            }
        }')" || {
        BUILT_ITEM=''
        finish_module_build
        return 1
    }
    finish_module_build
}

build_cf_websocket_inbound() {
    local listen_port=''
    local listen_address=''
    local uuid=''
    local certificate_directory=''
    local websocket_path=''

    begin_module_build
    info '配置 CF WebSocket inbound'
    module_prompt prompt_port listen_port '请输入监听端口' 8443 || return $?
    module_prompt prompt_required uuid '请输入 UUID' true || return $?
    module_prompt prompt_required certificate_directory '请输入 /etc/ssl/ 下的证书目录名' false || return $?
    module_prompt prompt_required websocket_path '请输入 WebSocket path' false || return $?
    if [[ "$websocket_path" != /* ]]; then
        websocket_path="/${websocket_path}"
    fi
    listen_address="$(get_listen_address)" || return $?

    BUILT_ITEM="$(jq -cn \
        --arg listen_address "$listen_address" \
        --argjson listen_port "$listen_port" \
        --arg uuid "$uuid" \
        --arg certificate_path "/etc/ssl/${certificate_directory}/fullchain.pem" \
        --arg key_path "/etc/ssl/${certificate_directory}/privkey.pem" \
        --arg websocket_path "$websocket_path" \
        '{
            type: "vless",
            tag: "vless-cf-ws-in",
            listen: $listen_address,
            listen_port: $listen_port,
            users: [{
                name: "cf-ws",
                uuid: $uuid
            }],
            tls: {
                enabled: true,
                certificate_path: $certificate_path,
                key_path: $key_path
            },
            transport: {
                type: "ws",
                path: $websocket_path
            }
        }')" || {
        BUILT_ITEM=''
        finish_module_build
        return 1
    }
    finish_module_build
}

build_exit_shadowsocks_inbound() {
    local listen_port=''
    local listen_address=''
    local method=''
    local password=''

    begin_module_build
    info '配置 SS2022 inbound'
    module_prompt prompt_port listen_port '请输入监听端口' 32123 || return $?
    module_prompt prompt_method method || return $?
    module_prompt prompt_required password '请输入 SS2022 password' true || return $?
    listen_address="$(get_listen_address)" || return $?

    BUILT_ITEM="$(jq -cn \
        --arg listen_address "$listen_address" \
        --argjson listen_port "$listen_port" \
        --arg method "$method" \
        --arg password "$password" \
        '{
            type: "shadowsocks",
            tag: "ss2022-in",
            listen: $listen_address,
            listen_port: $listen_port,
            method: $method,
            password: $password
        }')" || {
        BUILT_ITEM=''
        finish_module_build
        return 1
    }
    finish_module_build
}

configure_transit_inbounds() {
    while true; do
        INBOUNDS_JSON='[]'

        configure_optional_inbound '是否添加 VLESS Reality inbound？' \
            build_reality_inbound || return $?
        configure_optional_inbound '是否添加 Hysteria2 inbound？' \
            build_transit_hysteria2_inbound || return $?
        configure_optional_inbound '是否添加 CF Tunnel inbound？' \
            build_cf_tunnel_inbound || return $?
        configure_optional_inbound '是否添加 CF WebSocket inbound？' \
            build_cf_websocket_inbound || return $?

        if (( $(jq 'length' <<<"$INBOUNDS_JSON") > 0 )); then
            return
        fi

        error '中转配置至少需要一个 inbound，请重新选择。'
    done
}

configure_exit_inbounds() {
    while true; do
        INBOUNDS_JSON='[]'

        configure_optional_inbound '是否添加 SS2022 inbound？' \
            build_exit_shadowsocks_inbound || return $?
        configure_optional_inbound '是否添加 Hysteria2 inbound？' \
            build_exit_hysteria2_inbound || return $?
        configure_optional_inbound '是否添加 CF Tunnel inbound？' \
            build_cf_tunnel_inbound || return $?
        configure_optional_inbound '是否添加 CF WebSocket inbound？' \
            build_cf_websocket_inbound || return $?

        if (( $(jq 'length' <<<"$INBOUNDS_JSON") > 0 )); then
            return
        fi

        error '落地配置至少需要一个 inbound，请重新选择。'
    done
}

configure_optional_inbound() {
    local question="$1"
    local builder="$2"
    local answer=''
    local item=''
    local build_status=0

    while true; do
        prompt_yes_no answer "$question"
        [[ "$answer" == 'yes' ]] || return 0

        if "$builder"; then
            item="$BUILT_ITEM"
            append_inbound "$item" || return $?
            return 0
        else
            build_status=$?
        fi

        if (( build_status == MODULE_CANCEL_STATUS )); then
            warn '已取消当前 inbound，未保存任何字段。'
            continue
        fi
        return "$build_status"
    done
}

build_shadowsocks_outbound() {
    local tag=''
    local server=''
    local server_port=''
    local method=''
    local password=''

    begin_module_build
    info '配置 SS2022 outbound'
    module_prompt prompt_outbound_tag tag || return $?
    module_prompt prompt_server_ip server || return $?
    module_prompt prompt_port server_port '请输入 server_port' 32123 || return $?
    module_prompt prompt_method method || return $?
    module_prompt prompt_required password '请输入 SS2022 password' true || return $?

    BUILT_ITEM="$(jq -cn \
        --arg tag "$tag" \
        --arg server "$server" \
        --argjson server_port "$server_port" \
        --arg method "$method" \
        --arg password "$password" \
        '{
            type: "shadowsocks",
            tag: $tag,
            server: $server,
            server_port: $server_port,
            method: $method,
            password: $password
        }')" || {
        BUILT_ITEM=''
        finish_module_build
        return 1
    }
    finish_module_build
}

build_socks5_outbound() {
    local tag=''
    local server=''
    local server_port=''
    local use_auth=''
    local username=''
    local password=''

    begin_module_build
    info '配置 SOCKS5 outbound'
    module_prompt prompt_outbound_tag tag || return $?
    module_prompt prompt_server_address server || return $?
    module_prompt prompt_port server_port '请输入 server_port' 443 || return $?
    module_prompt prompt_yes_no use_auth '是否使用用户名和密码认证？' || return $?
    if [[ "$use_auth" == 'yes' ]]; then
        module_prompt prompt_required username '请输入 username' false || return $?
        module_prompt prompt_required password '请输入 password' true || return $?
    fi

    BUILT_ITEM="$(jq -cn \
        --arg tag "$tag" \
        --arg server "$server" \
        --argjson server_port "$server_port" \
        --arg use_auth "$use_auth" \
        --arg username "$username" \
        --arg password "$password" \
        '{
            type: "socks",
            tag: $tag,
            server: $server,
            server_port: $server_port,
            version: "5"
        } + if $use_auth == "yes" then {
            username: $username,
            password: $password
        } else {} end')" || {
        BUILT_ITEM=''
        finish_module_build
        return 1
    }
    finish_module_build
}

build_hysteria2_outbound() {
    local tag=''
    local server=''
    local server_port=''
    local password=''
    local server_name=''

    begin_module_build
    info '配置 Hysteria2 outbound'
    module_prompt prompt_outbound_tag tag || return $?
    module_prompt prompt_server_ip server || return $?
    module_prompt prompt_port server_port '请输入 server_port' 32124 || return $?
    module_prompt prompt_required password '请输入 Hysteria2 password' true || return $?
    module_prompt prompt_required server_name '请输入 tls.server_name' false || return $?

    BUILT_ITEM="$(jq -cn \
        --arg tag "$tag" \
        --arg server "$server" \
        --argjson server_port "$server_port" \
        --arg password "$password" \
        --arg server_name "$server_name" \
        '{
            type: "hysteria2",
            tag: $tag,
            server: $server,
            server_port: $server_port,
            password: $password,
            tls: {
                enabled: true,
                server_name: $server_name
            }
        }')" || {
        BUILT_ITEM=''
        finish_module_build
        return 1
    }
    finish_module_build
}

configure_transit_outbounds() {
    local outbound_choice=''
    local builder=''
    local item=''
    local tag=''
    local build_status=0

    OUTBOUNDS_JSON='[]'
    OUTBOUND_TAGS=()

    while true; do
        printf '\n请选择要添加的 outbound：\n\n'
        printf '1. SS2022 outbound\n'
        printf '2. SOCKS5 outbound\n'
        printf '3. Hysteria2 outbound\n'
        printf '4. 完成并返回\n'
        prompt_numbered_choice outbound_choice 1 4

        case "$outbound_choice" in
            1) builder='build_shadowsocks_outbound' ;;
            2) builder='build_socks5_outbound' ;;
            3) builder='build_hysteria2_outbound' ;;
            4) break ;;
        esac

        if "$builder"; then
            item="$BUILT_ITEM"
            tag="$(jq -r '.tag' <<<"$item")"
            if append_outbound "$item"; then
                OUTBOUND_TAGS+=("$tag")
            else
                return $?
            fi
        else
            build_status=$?
            if (( build_status == MODULE_CANCEL_STATUS )); then
                warn '已取消当前 outbound，未保存任何字段。'
                continue
            fi
            return "$build_status"
        fi
    done

    if append_outbound "$(jq -cn '{type:"direct",tag:"direct"}')"; then
        OUTBOUND_TAGS+=('direct')
    else
        return $?
    fi
}

configure_transit_route() {
    local choice=''
    local index=0
    local final_tag=''

    printf '\n请选择 route.final：\n\n'
    for index in "${!OUTBOUND_TAGS[@]}"; do
        printf '%d. %s\n' "$((index + 1))" "${OUTBOUND_TAGS[$index]}"
    done
    prompt_numbered_choice choice 1 "${#OUTBOUND_TAGS[@]}"
    final_tag="${OUTBOUND_TAGS[$((choice - 1))]}"

    ROUTE_JSON="$(jq -cn --arg final "$final_tag" '{
        rules: [
            {
                ip_is_private: true,
                action: "reject"
            },
            {
                action: "sniff"
            },
            {
                rule_set: [
                    "geosite-cn",
                    "geoip-cn"
                ],
                action: "reject"
            }
        ],
        rule_set: [
            {
                tag: "geosite-cn",
                type: "remote",
                format: "binary",
                url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/cn.srs",
                download_detour: "direct",
                update_interval: "1d"
            },
            {
                tag: "geoip-cn",
                type: "remote",
                format: "binary",
                url: "https://github.com/qljsyph/ruleset-icon/raw/refs/heads/main/sing-box/geoip/China-ASN-combined-ip.srs",
                download_detour: "direct",
                update_interval: "1d"
            }
        ],
        final: $final
    }')"
}

configure_exit_route() {
    ROUTE_JSON="$(jq -cn '{
        rules: [{
            ip_is_private: true,
            action: "reject"
        }]
    }')"
}

create_temp_config() {
    umask 077
    TEMP_CONFIG="$(mktemp "${TMPDIR:-/tmp}/sing-box-config.XXXXXX.json")"
}

generate_transit_config() {
    configure_log
    configure_transit_inbounds
    configure_transit_outbounds
    configure_transit_route
    create_temp_config

    jq -n \
        --argjson log "$LOG_JSON" \
        --argjson inbounds "$INBOUNDS_JSON" \
        --argjson outbounds "$OUTBOUNDS_JSON" \
        --argjson route "$ROUTE_JSON" \
        '{
            log: $log,
            inbounds: $inbounds,
            outbounds: $outbounds,
            route: $route
        }' >"$TEMP_CONFIG"
}

generate_exit_config() {
    configure_log
    configure_exit_inbounds
    configure_exit_route
    create_temp_config

    jq -n \
        --argjson log "$LOG_JSON" \
        --argjson inbounds "$INBOUNDS_JSON" \
        --argjson route "$ROUTE_JSON" \
        '{
            log: $log,
            inbounds: $inbounds,
            route: $route
        }' >"$TEMP_CONFIG"
}

add_inbound_to_working_config() {
    local config_kind=''
    local inbound_choice=''
    local target_tag=''
    local builder=''
    local build_status=0

    ensure_working_array 'inbounds' || return 1

    printf '\n现有配置属于：\n\n'
    printf '1. 中转配置\n'
    printf '2. 落地配置\n'
    printf '3. 返回\n'
    prompt_numbered_choice config_kind 1 3
    if [[ "$config_kind" == '3' ]]; then
        return 0
    fi

    while true; do
        printf '\n请选择要添加的 inbound：\n\n'
        if [[ "$config_kind" == '1' ]]; then
            printf '1. VLESS Reality inbound\n'
            printf '2. Hysteria2 inbound\n'
            printf '3. CF Tunnel inbound\n'
            printf '4. CF WebSocket inbound\n'
            printf '5. 返回\n'
            prompt_numbered_choice inbound_choice 1 5
            case "$inbound_choice" in
                1) target_tag='vless-reality-in'; builder='build_reality_inbound' ;;
                2) target_tag='hy2-in'; builder='build_transit_hysteria2_inbound' ;;
                3) target_tag='cf-tunnel-in'; builder='build_cf_tunnel_inbound' ;;
                4) target_tag='vless-cf-ws-in'; builder='build_cf_websocket_inbound' ;;
                5) return 0 ;;
            esac
        else
            printf '1. SS2022 inbound\n'
            printf '2. Hysteria2 inbound\n'
            printf '3. CF Tunnel inbound\n'
            printf '4. CF WebSocket inbound\n'
            printf '5. 返回\n'
            prompt_numbered_choice inbound_choice 1 5
            case "$inbound_choice" in
                1) target_tag='ss2022-in'; builder='build_exit_shadowsocks_inbound' ;;
                2) target_tag='hy2-in'; builder='build_exit_hysteria2_inbound' ;;
                3) target_tag='cf-tunnel-in'; builder='build_cf_tunnel_inbound' ;;
                4) target_tag='vless-cf-ws-in'; builder='build_cf_websocket_inbound' ;;
                5) return 0 ;;
            esac
        fi

        if working_tag_exists 'inbounds' "$target_tag"; then
            error "inbound tag '${target_tag}' 已经存在，不允许重复追加。"
            return 0
        fi

        if "$builder"; then
            if append_working_inbound "$BUILT_ITEM"; then
                success "已追加 inbound：${target_tag}"
            fi
            return 0
        else
            build_status=$?
            if (( build_status == MODULE_CANCEL_STATUS )); then
                warn '已取消当前 inbound，未保存任何字段。'
                continue
            fi
            return "$build_status"
        fi
    done
}

add_outbounds_to_working_config() {
    local outbound_choice=''
    local builder=''
    local build_status=0
    local tag=''

    ensure_working_array 'outbounds' || return 1
    refresh_outbound_tags_from_working || return 1

    while true; do
        printf '\n请选择要添加的 outbound：\n\n'
        printf '1. SS2022 outbound\n'
        printf '2. SOCKS5 outbound\n'
        printf '3. Hysteria2 outbound\n'
        printf '4. 完成并返回\n'
        prompt_numbered_choice outbound_choice 1 4

        case "$outbound_choice" in
            1) builder='build_shadowsocks_outbound' ;;
            2) builder='build_socks5_outbound' ;;
            3) builder='build_hysteria2_outbound' ;;
            4) return 0 ;;
        esac

        if "$builder"; then
            tag="$(jq -r '.tag' <<<"$BUILT_ITEM")"
            if append_working_outbound "$BUILT_ITEM"; then
                success "已追加 outbound：${tag}"
            fi
        else
            build_status=$?
            if (( build_status == MODULE_CANCEL_STATUS )); then
                warn '已取消当前 outbound，未保存任何字段。'
                continue
            fi
            return "$build_status"
        fi
    done
}

modify_working_route_final() {
    local current_final=''
    local action_choice=''
    local final_choice=''
    local index=0

    ensure_working_array 'outbounds' || return 1
    ensure_working_route_object || return 1
    refresh_outbound_tags_from_working || return 1

    current_final="$(jq -r '
        if ((.route // {}) | has("final")) then
            if .route.final == null then
                "未设置"
            elif (.route.final | type) == "string" then
                .route.final
            else
                (.route.final | tojson)
            end
        else
            "未设置"
        end
    ' <<<"$WORKING_CONFIG_JSON")"

    printf '\n当前 route.final：%s\n' "$current_final"
    printf '\n请选择操作：\n\n'
    printf '1. 保持当前值\n'
    printf '2. 从现有 outbound tag 中选择新值\n'
    prompt_numbered_choice action_choice 1 2
    if [[ "$action_choice" == '1' ]]; then
        return 0
    fi

    if (( ${#OUTBOUND_TAGS[@]} == 0 )); then
        error '当前没有可选择的 outbound tag。'
        return 0
    fi

    printf '\n请选择新的 route.final：\n\n'
    for index in "${!OUTBOUND_TAGS[@]}"; do
        printf '%d. %s\n' "$((index + 1))" "${OUTBOUND_TAGS[$index]}"
    done
    prompt_numbered_choice final_choice 1 "${#OUTBOUND_TAGS[@]}"

    if set_working_route_final "${OUTBOUND_TAGS[$((final_choice - 1))]}"; then
        success "route.final 已设置为：${OUTBOUND_TAGS[$((final_choice - 1))]}"
    fi
}

existing_config_preview_menu() {
    local choice=''
    local apply_status=0

    while true; do
        printf '请选择下一步：\n\n'
        printf '1. 确认应用配置\n'
        printf '2. 返回继续添加\n'
        printf '3. 放弃全部修改并返回主菜单\n'
        printf '4. 退出，不作修改\n'
        prompt_numbered_choice choice 1 4

        case "$choice" in
            1)
                if apply_config; then
                    return 0
                else
                    apply_status=$?
                fi
                if (( apply_status == 1 )); then
                    printf '\n'
                    continue
                fi
                return 4
                ;;
            2)
                if [[ -n "$TEMP_CONFIG" && -f "$TEMP_CONFIG" ]]; then
                    rm -f -- "$TEMP_CONFIG"
                fi
                TEMP_CONFIG=''
                return 1
                ;;
            3)
                discard_existing_changes
                return 2
                ;;
            4)
                discard_existing_changes
                return 3
                ;;
        esac
    done
}

edit_existing_config() {
    local menu_choice=''
    local preview_status=0

    if ! load_existing_config_file "$CONFIG_PATH"; then
        return 1
    fi

    while true; do
        display_working_tags 'inbounds' 'inbound'
        display_working_tags 'outbounds' 'outbound'

        printf '\n请选择操作：\n\n'
        printf '1. 添加 inbound\n'
        printf '2. 添加 outbound\n'
        printf '3. 修改 route.final\n'
        printf '4. 完成并预览\n'
        printf '5. 放弃并返回主菜单\n'
        prompt_numbered_choice menu_choice 1 5

        case "$menu_choice" in
            1)
                if ! add_inbound_to_working_config; then
                    continue
                fi
                ;;
            2)
                if ! add_outbounds_to_working_config; then
                    continue
                fi
                ;;
            3)
                if ! modify_working_route_final; then
                    continue
                fi
                ;;
            4)
                write_working_config_temp
                show_preview
                if existing_config_preview_menu; then
                    return 0
                else
                    preview_status=$?
                fi
                case "$preview_status" in
                    1) continue ;;
                    2) return 1 ;;
                    3) return 2 ;;
                    4) return 3 ;;
                esac
                ;;
            5)
                discard_existing_changes
                return 1
                ;;
        esac
    done
}

show_preview() {
    printf '\n%s完整配置预览：%s\n\n' "$CYAN" "$RESET"
    jq . "$TEMP_CONFIG"
    printf '\n'
}

show_service_failure() {
    local backup_path="$1"
    local status="$2"

    error "sing-box 服务状态异常：${status}"
    if [[ -n "$backup_path" ]]; then
        warn "旧配置备份路径：${backup_path}"
    else
        warn '应用前不存在旧配置，因此没有备份文件。'
    fi

    if command -v journalctl >/dev/null 2>&1; then
        journalctl -u sing-box -n 50 --no-pager || true
    else
        warn '未找到 journalctl，无法显示 sing-box 服务日志。'
    fi
}

apply_config_to_path() {
    local target_config="$1"
    local target_dir="$2"
    local sing_box_bin=''
    local backup_path=''
    local service_status=''
    local enable_output=''
    local enable_status=''
    local enable_check_exit=0

    if ! jq empty "$TEMP_CONFIG"; then
        error 'jq 校验失败；正式配置未修改，sing-box 未重启。'
        return 1
    fi

    if ! sing_box_bin="$(command -v sing-box)"; then
        error '未找到 sing-box；正式配置未修改，服务未重启。'
        return 1
    fi

    if ! "$sing_box_bin" check -c "$TEMP_CONFIG"; then
        error 'sing-box 配置检查失败；正式配置未修改，服务未重启。'
        return 1
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        error '未找到 systemctl；正式配置未修改，服务未重启。'
        return 1
    fi

    if ! install -d -m 0755 "$target_dir"; then
        error "无法创建配置目录：${target_dir}；正式配置未修改，服务未重启。"
        return 1
    fi

    if [[ -e "$target_config" ]]; then
        backup_path="${target_config}.bak-$(date '+%Y%m%d-%H%M%S')"
        if [[ -e "$backup_path" ]]; then
            error "备份目标已存在：${backup_path}；正式配置未修改。"
            return 1
        fi
        if ! cp -a -- "$target_config" "$backup_path"; then
            error "无法备份现有配置：${target_config}；正式配置未修改，服务未重启。"
            return 1
        fi
    fi

    if ! install -m 0600 -- "$TEMP_CONFIG" "$target_config"; then
        error "无法写入正式配置：${target_config}；服务未重启。"
        return 1
    fi
    success "配置已写入：${target_config}"
    if [[ -n "$backup_path" ]]; then
        success "旧配置备份路径：${backup_path}"
    else
        info '应用前不存在旧配置，已跳过备份。'
    fi

    if ! systemctl restart sing-box; then
        show_service_failure "$backup_path" 'restart 失败'
        return 2
    fi

    if service_status="$(systemctl is-active sing-box 2>&1)"; then
        if [[ "$service_status" != 'active' ]]; then
            show_service_failure "$backup_path" "${service_status:-未知}"
            return 2
        fi
    else
        show_service_failure "$backup_path" "${service_status:-未知}"
        return 2
    fi

    if ! enable_output="$(systemctl enable sing-box.service 2>&1)"; then
        error '配置已经应用且服务正在运行，但设置开机自启失败。'
        if [[ -n "$enable_output" ]]; then
            warn "systemctl enable 诊断：${enable_output}"
        else
            warn 'systemctl enable 未返回诊断信息。'
        fi
        return 2
    fi

    if enable_status="$(systemctl is-enabled sing-box.service 2>&1)"; then
        enable_check_exit=0
    else
        enable_check_exit=$?
    fi
    if (( enable_check_exit != 0 )) || [[ "$enable_status" != 'enabled' ]]; then
        error "配置已经应用且服务正在运行，但开机自启状态验证失败：${enable_status:-无输出}；退出码：${enable_check_exit}"
        return 2
    fi

    success "sing-box 当前状态：${service_status}；开机自启状态：${enable_status}"
    print_network_result
    return 0
}

apply_config() {
    apply_config_to_path "$CONFIG_PATH" "$CONFIG_DIR"
}

choose_config_type() {
    local target_name="$1"
    local choice=''

    printf '\n请选择配置类型：\n\n'
    printf '1. 新建中转小鸡配置\n'
    printf '2. 新建落地小鸡配置\n'
    printf '3. 添加到现有配置\n'
    printf '4. 退出\n'
    prompt_numbered_choice choice 1 4
    printf -v "$target_name" '%s' "$choice"
}

final_menu() {
    local choice=''
    local apply_status=0

    while true; do
        printf '请选择下一步：\n\n'
        printf '1. 确认应用配置\n'
        printf '2. 重新生成\n'
        printf '3. 退出，不作修改\n'
        prompt_numbered_choice choice 1 3

        case "$choice" in
            1)
                if apply_config; then
                    return 0
                else
                    apply_status=$?
                fi

                if (( apply_status == 1 )); then
                    printf '\n'
                    continue
                fi
                return 2
                ;;
            2)
                reset_generation_state
                return 1
                ;;
            3)
                return 3
                ;;
        esac
    done
}

main() {
    local config_type=''
    local menu_status=0
    local edit_status=0

    init_colors
    check_environment
    detect_runtime_environment
    select_network_stack

    while true; do
        reset_generation_state
        choose_config_type config_type

        case "$config_type" in
            1) generate_transit_config ;;
            2) generate_exit_config ;;
            3)
                if edit_existing_config; then
                    return 0
                else
                    edit_status=$?
                fi

                case "$edit_status" in
                    1)
                        reset_generation_state
                        continue
                        ;;
                    2)
                        return 0
                        ;;
                    3)
                        return 1
                        ;;
                    *)
                        die "添加到现有配置流程返回了未知状态：${edit_status}"
                        ;;
                esac
                ;;
            4)
                info '已退出，未作任何修改。'
                return 0
                ;;
        esac

        show_preview

        if final_menu; then
            return 0
        else
            menu_status=$?
        fi

        case "$menu_status" in
            1)
                info '已清除本轮数据，请重新生成。'
                ;;
            2)
                return 1
                ;;
            3)
                info '已退出，未作任何修改。'
                return 0
                ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
SINGBOX_WIZARD
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
