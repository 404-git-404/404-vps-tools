#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

readonly DEFAULT_SSH_PORT='53651'
readonly APT_WAIT_MAX="${VPS_INIT_APT_WAIT:-1800}"
readonly LOCK_FILE='/run/lock/vps-init.lock'
readonly BACKUP_ROOT='/root/vps-init-backups'
readonly SSH_MAIN='/etc/ssh/sshd_config'
readonly SSH_DIR='/etc/ssh/sshd_config.d'
readonly SSH_DROPIN='/etc/ssh/sshd_config.d/00-vps-init.conf'
readonly AUTHORIZED_KEYS='/root/.ssh/authorized_keys'
readonly NETWORK_SYSCTL='/etc/sysctl.d/99-vps-init-network.conf'
readonly TCP_SYSCTL='/etc/sysctl.d/99-vps-init-tcp.conf'
readonly BBR_MODULES='/etc/modules-load.d/vps-init-bbr.conf'
readonly SMARTDNS_CONF='/etc/smartdns/smartdns.conf'
readonly SMARTDNS_CACHE='/var/cache/smartdns/smartdns.cache'
readonly SMARTDNS_APT_PIN='/etc/apt/preferences.d/vps-init-smartdns'
readonly SMARTDNS_RELEASE='Release48.4'
readonly SMARTDNS_VERSION='1.2026.08.05-0921'
readonly SMARTDNS_DEB_VERSION='2026.08.05-0921'
readonly SAGER_KEY_FINGERPRINT='2C317FBD5D886B4E89BAE8DA6D9152172A2B2F0C'
readonly SINGBOX_CONFIG='/etc/sing-box/config.json'
readonly SINGBOX_DROPIN_DIR='/etc/systemd/system/sing-box.service.d'
readonly SINGBOX_DROPIN='/etc/systemd/system/sing-box.service.d/10-vps-init-config-gate.conf'
readonly SINGBOX_MANAGED_MARKER='/var/lib/vps-init/sing-box-managed'
readonly CF_TOOL='/usr/local/sbin/vps-init-cloudflare-8443'
readonly CF_SERVICE='/etc/systemd/system/vps-init-cloudflare-8443.service'
readonly CF_TIMER='/etc/systemd/system/vps-init-cloudflare-8443.timer'
readonly SWAPFILE='/swapfile-vps-init'
readonly LEGACY_NETWORK_UNIT='/etc/systemd/system/404-network-stack.service'
readonly LEGACY_NETWORK_HELPER='/usr/local/libexec/404-network-stack'
readonly LEGACY_IPV6_SYSCTL='/etc/sysctl.d/99-disable-ipv6.conf'

CURRENT_STEP='启动'
TMP_DIR=''
BACKUP_DIR=''
SSH_PORT="$DEFAULT_SSH_PORT"
KEEP_SSH_22=true
DO_FULL_UPGRADE=true
SSH_PORT_SET=false
KEEP_SSH_22_SET=false
DO_FULL_UPGRADE_SET=false
BASE_ONLY=false
INSTALL_MODE=''
SINGBOX_RUNTIME_MASK=false
NETWORK_REQUEST='auto'
NETWORK_STACK='unknown'
SING_BOX_VERSION=''
PUBKEY_ARGUMENT=''
PUBKEY_FILE=''
PUBLIC_KEY=''
CF8443_MODE='auto' # auto = fresh install off; existing managed install preserved
CONTAINER_KIND='none'
SSH_TX=false
DNS_TX=false
UFW_TX=false
UFW_OLD_ACTIVE=false
PREAUTH_SSH_PORT_ADDED=false
PREAUTH_22_ADDED=false
SMARTDNS_OLD_ACTIVE=false
SMARTDNS_OLD_ENABLED=false
SMARTDNS_DID_INSTALL=false
SMARTDNS_TRANSPORT='unknown'
RESOLVED_OLD_ACTIVE=false
RESOLVED_OLD_ENABLED=false
SINGBOX_WAS_INSTALLED=false
SINGBOX_WAS_ACTIVE=false
SINGBOX_WAS_ENABLED=false
SINGBOX_CONFIG_PREEXISTED=false
SINGBOX_WAS_MANAGED=false
SWAP_RECOMMENDED_MIB=0
PERSIST_RESOLV_IMMUTABLE=false
IPV6_OLD_ALL='0'
IPV6_OLD_DEFAULT='0'
IPV6_OLD_LO='0'

# Files whose i/a attributes were temporarily cleared. Values are original lsattr flags.
declare -A ORIGINAL_ATTRS=()

log()  { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
用法：
  bash 404notfound.sh
  bash 404notfound.sh [选项]

交互菜单：快速安装、自定义安装、退出、仅安装/更新 SmartDNS、仅部署 sing-box。
仅部署 sing-box 独立运行节点配置向导；完整初始化只安装 sing-box，不创建节点。

默认流程：
  - Debian 12/13 amd64/arm64
  - 询问 SSH 公钥、SSH 端口、是否保留 22、是否 full-upgrade
  - 低内存且无合适 Swap 时才询问是否创建推荐 Swap
  - 自动检测 IPv6 是否真正可用：可用 => dual；不可用 => ipv4 并关闭 IPv6
  - SmartDNS 自动选择 IPv4-only 或 IPv4+IPv6；优先 H3，失败自动回退 UDP/TCP 53
  - 443/tcp + 443/udp 默认开放
  - Cloudflare 8443 默认不启用，使用 --cloudflare-8443 显式启用

选项：
  --pubkey "KEY"             预先提供 SSH 公钥
  --pubkey-file FILE         从文件读取 SSH 公钥
  --ssh-port PORT            SSH 新端口（默认 53651）
  --keep-22                  保留 22/tcp（默认）
  --close-22                 不由本脚本开放 22/tcp
  --full-upgrade             执行 full-upgrade（默认）
  --skip-upgrade             仅 apt update，不执行 full-upgrade
  --sing-box-version VER     指定 sing-box 版本；未指定时已安装版本不会被重跑升级
  --network-stack MODE       auto、ipv4、dual（默认 auto）
  --cloudflare-8443          启用 Cloudflare-only 8443/tcp + 每日刷新
  --no-cloudflare-8443       删除本脚本管理的 Cloudflare 8443 规则/定时器
  --base-only                只完成系统更新和基础工具安装
  --smartdns-only            仅安装/更新 SmartDNS 并验证系统 DNS
  --sing-box-only            仅安装 sing-box 并进入节点配置向导
  --help                     显示帮助
EOF
}

read_tty() {
  local prompt=$1 var=$2
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
  if [[ "$SINGBOX_RUNTIME_MASK" == true ]]; then
    systemctl disable sing-box.service >/dev/null 2>&1 || true
    systemctl stop sing-box.service >/dev/null 2>&1 || true
    systemctl unmask --runtime sing-box.service >/dev/null 2>&1 || true
  fi
  restore_attrs
  [[ -z "$TMP_DIR" || ! -d "$TMP_DIR" ]] || rm -rf -- "$TMP_DIR"
  trap - EXIT
  exit "$rc"
}

rollback_ssh() {
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
  if sshd -t >/dev/null 2>&1; then systemctl reload ssh.service >/dev/null 2>&1 || true; fi
  if [[ "$PREAUTH_SSH_PORT_ADDED" == true ]]; then ufw_delete_comment_rules 'vps-init-ssh' >/dev/null 2>&1 || true; PREAUTH_SSH_PORT_ADDED=false; fi
  if [[ "$PREAUTH_22_ADDED" == true ]]; then ufw_delete_comment_rules 'vps-init-ssh-backup' >/dev/null 2>&1 || true; PREAUTH_22_ADDED=false; fi
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
  if [[ -e "$BACKUP_DIR/dns/network-sysctl" ]]; then
    cp -a "$BACKUP_DIR/dns/network-sysctl" "$NETWORK_SYSCTL" 2>/dev/null || true
  elif [[ -e "$BACKUP_DIR/dns/no-network-sysctl" ]]; then
    rm -f -- "$NETWORK_SYSCTL"
  fi
  if [[ "$IPV6_OLD_ALL" =~ ^[01]$ ]]; then sysctl -q -w "net.ipv6.conf.all.disable_ipv6=$IPV6_OLD_ALL" 2>/dev/null || true; fi
  if [[ "$IPV6_OLD_DEFAULT" =~ ^[01]$ ]]; then sysctl -q -w "net.ipv6.conf.default.disable_ipv6=$IPV6_OLD_DEFAULT" 2>/dev/null || true; fi
  if [[ "$IPV6_OLD_LO" =~ ^[01]$ ]]; then sysctl -q -w "net.ipv6.conf.lo.disable_ipv6=$IPV6_OLD_LO" 2>/dev/null || true; fi
  if [[ -L "$BACKUP_DIR/dns/resolv.conf.symlink" ]]; then
    rm -f /etc/resolv.conf
    ln -s "$(readlink "$BACKUP_DIR/dns/resolv.conf.symlink")" /etc/resolv.conf 2>/dev/null || true
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
    ufw --force enable >/dev/null 2>&1 || true
    ufw --force reload >/dev/null 2>&1 || true
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
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  (( 10#$p >= 1 && 10#$p <= 65535 )) || return 1
  case "$p" in 22|53|80|443|8443) return 1 ;; esac
}

parse_args() {
  while (( $# )); do
    case "$1" in
      --pubkey) [[ $# -ge 2 ]] || die '--pubkey 缺少参数。'; PUBKEY_ARGUMENT=$2; shift 2 ;;
      --pubkey-file) [[ $# -ge 2 ]] || die '--pubkey-file 缺少参数。'; PUBKEY_FILE=$2; shift 2 ;;
      --ssh-port) [[ $# -ge 2 ]] || die '--ssh-port 缺少参数。'; SSH_PORT=$2; SSH_PORT_SET=true; shift 2 ;;
      --keep-22) KEEP_SSH_22=true; KEEP_SSH_22_SET=true; shift ;;
      --close-22) KEEP_SSH_22=false; KEEP_SSH_22_SET=true; shift ;;
      --full-upgrade) DO_FULL_UPGRADE=true; DO_FULL_UPGRADE_SET=true; shift ;;
      --skip-upgrade) DO_FULL_UPGRADE=false; DO_FULL_UPGRADE_SET=true; shift ;;
      --sing-box-version) [[ $# -ge 2 ]] || die '--sing-box-version 缺少参数。'; SING_BOX_VERSION=${2#v}; shift 2 ;;
      --network-stack) [[ $# -ge 2 ]] || die '--network-stack 缺少参数。'; NETWORK_REQUEST=$2; shift 2 ;;
      --cloudflare-8443) CF8443_MODE='enable'; shift ;;
      --no-cloudflare-8443) CF8443_MODE='disable'; shift ;;
      --base-only|--smartdns-only|--sing-box-only)
        [[ -z "$INSTALL_MODE" ]] || die '只能选择一种独立运行模式。'
        case "$1" in
          --base-only) BASE_ONLY=true; INSTALL_MODE=base ;;
          --smartdns-only) INSTALL_MODE=smartdns ;;
          --sing-box-only) INSTALL_MODE=singbox ;;
        esac
        shift ;;
      --help|-h) usage; exit 0 ;;
      *) die "未知参数：$1" ;;
    esac
  done
  validate_port "$SSH_PORT" || die "SSH 端口无效：$SSH_PORT（不能使用 22/53/80/443/8443）。"
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
  if [[ ! -d /run/systemd/system ]] || ! command -v systemctl >/dev/null 2>&1; then
    die '需要正在运行的 systemd。'
  fi
  command -v dpkg >/dev/null 2>&1 || die '缺少 dpkg。'
  local arch free_kb audit
  arch=$(dpkg --print-architecture)
  [[ "$arch" == amd64 || "$arch" == arm64 ]] || die "仅支持 amd64/arm64，当前：$arch。"
  free_kb=$(df -Pk / | awk 'NR==2{print $4}')
  (( free_kb >= 2097152 )) || die '根分区至少需要 2GiB 可用空间。'
  audit=$(dpkg --audit 2>&1 || true)
  [[ -z "$audit" ]] || die "dpkg 当前存在未完成/损坏状态：$audit"
  if [[ "$INSTALL_MODE" == quick || "$INSTALL_MODE" == custom ]]; then
    systemctl is-active --quiet ssh.service || die 'ssh.service 未运行；完整初始化拒绝继续。'
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
  apt_get install -y util-linux e2fsprogs ca-certificates curl gnupg openssh-client
}

mem_total_mib() { awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo; }
swap_total_mib() { awk '/SwapTotal:/ {print int($2/1024)}' /proc/meminfo; }

recommend_swap() {
  local mem swap
  mem=$(mem_total_mib)
  swap=$(swap_total_mib)
  SWAP_RECOMMENDED_MIB=0
  if [[ "$CONTAINER_KIND" != none ]]; then
    log '容器环境：跳过自动 Swap 文件建议。'
    return 0
  fi
  (( swap < 512 )) || return 0
  if (( mem <= 1024 )); then
    SWAP_RECOMMENDED_MIB=2048
  elif (( mem <= 2048 )); then
    SWAP_RECOMMENDED_MIB=1024
  fi
}

create_swap() {
  local target_mib=$1 free_kb required_kb
  CURRENT_STEP='创建 Swap'
  free_kb=$(df -Pk / | awk 'NR==2 {print $4}')
  required_kb=$(( (target_mib + 1024) * 1024 ))
  (( free_kb >= required_kb )) || die "根分区空间不足：创建 ${target_mib}MiB Swap 后还需要至少保留 1GiB。"
  command -v mkswap >/dev/null 2>&1 || die '缺少 mkswap。'
  command -v swapon >/dev/null 2>&1 || die '缺少 swapon。'
  [[ ! -L "$SWAPFILE" ]] || die "$SWAPFILE 不能是符号链接。"
  if swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "$SWAPFILE"; then
    log "$SWAPFILE 已启用，跳过创建。"
    return 0
  fi
  if [[ -e "$SWAPFILE" ]]; then
    make_mutable "$SWAPFILE"
    rm -f -- "$SWAPFILE"
  fi
  if command -v fallocate >/dev/null 2>&1 && fallocate -l "${target_mib}M" "$SWAPFILE" 2>/dev/null; then
    :
  else
    dd if=/dev/zero of="$SWAPFILE" bs=1M count="$target_mib" status=progress
  fi
  chmod 0600 "$SWAPFILE"
  mkswap "$SWAPFILE" >/dev/null
  swapon "$SWAPFILE"
  reject_symlink /etc/fstab
  make_mutable /etc/fstab
  grep -Fq "$SWAPFILE none swap sw 0 0" /etc/fstab || printf '%s\n' "$SWAPFILE none swap sw 0 0" >>/etc/fstab
  log "已创建并启用 ${target_mib}MiB Swap：$SWAPFILE"
}

collect_choices() {
  [[ "$BASE_ONLY" == true ]] && return 0
  local answer=''
  if [[ -z "$PUBKEY_ARGUMENT" && -z "$PUBKEY_FILE" ]]; then
    read_tty 'SSH 公钥: ' PUBKEY_ARGUMENT
  fi
  if [[ "$SSH_PORT_SET" == false ]]; then
    read_tty "SSH 端口 [$DEFAULT_SSH_PORT]: " answer
    [[ -z "$answer" ]] || SSH_PORT=$answer
  fi
  validate_port "$SSH_PORT" || die "SSH 端口无效：$SSH_PORT。"
  if [[ "$KEEP_SSH_22_SET" == false ]]; then
    if ask_yes_no '保留 SSH 22/tcp 作为备用？' true; then KEEP_SSH_22=true; else KEEP_SSH_22=false; fi
  fi
  if [[ "$DO_FULL_UPGRADE_SET" == false ]]; then
    if ask_yes_no '执行 apt full-upgrade？' true; then DO_FULL_UPGRADE=true; else DO_FULL_UPGRADE=false; fi
  fi
}

update_system_and_tools() {
  CURRENT_STEP='系统更新与基础工具'
  local sing_was_held=false smart_was_held=false sing_temp_hold=false smart_temp_hold=false upgrade_rc=0
  wait_for_package_manager
  apt_get update
  if [[ "$DO_FULL_UPGRADE" == true ]]; then
    if apt-mark showhold 2>/dev/null | grep -Fxq sing-box; then sing_was_held=true || true; fi
    if apt-mark showhold 2>/dev/null | grep -Fxq smartdns; then smart_was_held=true || true; fi
    if dpkg-query -W sing-box >/dev/null 2>&1 && [[ "$sing_was_held" == false ]]; then
      apt-mark hold sing-box >/dev/null
      sing_temp_hold=true
      log 'full-upgrade 前临时 hold 已安装的 sing-box，避免重跑隐式升级。'
    fi
    if dpkg-query -W smartdns >/dev/null 2>&1 && [[ "$smart_was_held" == false ]]; then
      apt-mark hold smartdns >/dev/null
      smart_temp_hold=true
      log 'full-upgrade 前临时 hold SmartDNS，避免 Debian 版本号覆盖 GitHub Release。'
    fi
    if apt_get full-upgrade -y; then upgrade_rc=0; else upgrade_rc=$?; fi
    [[ "$sing_temp_hold" == false ]] || apt-mark unhold sing-box >/dev/null 2>&1 || true
    [[ "$smart_temp_hold" == false ]] || apt-mark unhold smartdns >/dev/null 2>&1 || true
    (( upgrade_rc == 0 )) || die "apt full-upgrade 失败（退出码 $upgrade_rc）；临时 hold 已恢复。"
  fi
  apt_get install -y \
    ca-certificates curl wget git rsync tar unzip xz-utils jq nano gnupg openssl socat cron \
    openssh-server ufw dnsutils iproute2 iputils-ping netcat-openbsd mtr-tiny traceroute tcpdump \
    procps lsof htop chrony vnstat python3 python3-systemd util-linux file sudo e2fsprogs psmisc \
    fail2ban kmod
  if ! command -v curl >/dev/null || ! command -v sshd >/dev/null || ! command -v ufw >/dev/null; then
    die '基础工具验证失败。'
  fi
}

collect_public_key() {
  CURRENT_STEP='验证 SSH 公钥'
  local keyfile="$TMP_DIR/public-key"
  if [[ -n "$PUBKEY_FILE" ]]; then
    [[ -r "$PUBKEY_FILE" ]] || die "无法读取公钥文件：$PUBKEY_FILE"
    PUBLIC_KEY=$(awk 'NF && $1 !~ /^#/ {print; exit}' "$PUBKEY_FILE")
  else
    PUBLIC_KEY=$(printf '%s\n' "$PUBKEY_ARGUMENT" | awk 'NF {print; exit}')
  fi
  [[ -n "$PUBLIC_KEY" ]] || die 'SSH 公钥不能为空。'
  printf '%s\n' "$PUBLIC_KEY" >"$keyfile"
  ssh-keygen -l -f "$keyfile" >/dev/null 2>&1 || die 'SSH 公钥无法通过 ssh-keygen 校验。'
}

install_authorized_key() {
  CURRENT_STEP='安装 SSH 公钥'
  local keytmp="$TMP_DIR/newkey" fingerprint existing=''
  printf '%s\n' "$PUBLIC_KEY" >"$keytmp"
  fingerprint=$(ssh-keygen -lf "$keytmp" | awk '{print $2}')
  [[ ! -L /root/.ssh ]] || die '/root/.ssh 不能是符号链接。'
  install -d -o root -g root -m 0700 /root/.ssh
  reject_symlink "$AUTHORIZED_KEYS"
  make_mutable "$AUTHORIZED_KEYS"
  touch "$AUTHORIZED_KEYS"
  chown root:root "$AUTHORIZED_KEYS"
  chmod 0600 "$AUTHORIZED_KEYS"
  existing=$(ssh-keygen -lf "$AUTHORIZED_KEYS" 2>/dev/null | awk '{print $2}' || true)
  if grep -Fqx "$fingerprint" <<<"$existing"; then
    log 'authorized_keys 已有相同公钥。'
  else
    printf '%s\n' "$PUBLIC_KEY" >>"$AUTHORIZED_KEYS"
    log "SSH 公钥已添加：$fingerprint"
  fi
}

ipv4_https_works() {
  curl -4 --fail --silent --show-error --output /dev/null --connect-timeout 5 --max-time 10 https://www.google.com/generate_204 2>/dev/null ||
    curl -4 --fail --silent --show-error --output /dev/null --connect-timeout 5 --max-time 10 https://icanhazip.com 2>/dev/null
}

ipv6_global_present() {
  ip -6 addr show scope global 2>/dev/null | grep -q 'inet6 '
}

ipv6_route_present() {
  ip -6 route get 2606:4700:4700::1111 >/dev/null 2>&1
}

ipv6_https_works() {
  curl -6 --fail --silent --show-error --output /dev/null --connect-timeout 5 --max-time 10 https://icanhazip.com 2>/dev/null ||
    curl -6 --fail --silent --show-error --output /dev/null --connect-timeout 5 --max-time 10 https://www.google.com/generate_204 2>/dev/null
}

ssh_session_uses_ipv6() {
  local local_addr=''
  [[ -n "${SSH_CONNECTION:-}" ]] || return 1
  local_addr=$(awk '{print $3}' <<<"$SSH_CONNECTION")
  [[ "$local_addr" == *:* ]]
}

detect_network_stack() {
  CURRENT_STEP='检测网络栈'
  local old_all old_default old_lo
  ipv4_https_works || die '未检测到可用 IPv4 HTTPS 出站；本脚本支持 IPv4-only 或双栈，不支持 IPv6-only。'
  case "$NETWORK_REQUEST" in
    ipv4) NETWORK_STACK='ipv4' ;;
    dual) NETWORK_STACK='dual' ;;
    auto)
      # 旧版初始化可能已经把 IPv6 sysctl 关闭。为避免把“被关闭”误判成“供应商无 IPv6”，
      # 在非容器环境临时启用后再做地址、路由和真实 HTTPS 出站三重检测，随后恢复原运行状态。
      if [[ "$CONTAINER_KIND" == none ]]; then
        old_all=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)
        old_default=$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo 0)
        old_lo=$(sysctl -n net.ipv6.conf.lo.disable_ipv6 2>/dev/null || echo 0)
        sysctl -q -w net.ipv6.conf.all.disable_ipv6=0 2>/dev/null || true
        sysctl -q -w net.ipv6.conf.default.disable_ipv6=0 2>/dev/null || true
        sysctl -q -w net.ipv6.conf.lo.disable_ipv6=0 2>/dev/null || true
        if [[ "$old_all$old_default$old_lo" != 000 ]]; then sleep 3; fi
      fi
      if ipv6_global_present && ipv6_route_present && ipv6_https_works; then
        NETWORK_STACK='dual'
      else
        NETWORK_STACK='ipv4'
      fi
      if [[ "$CONTAINER_KIND" == none ]]; then
        if [[ "$old_all" =~ ^[01]$ ]]; then sysctl -q -w "net.ipv6.conf.all.disable_ipv6=$old_all" 2>/dev/null || true; fi
        if [[ "$old_default" =~ ^[01]$ ]]; then sysctl -q -w "net.ipv6.conf.default.disable_ipv6=$old_default" 2>/dev/null || true; fi
        if [[ "$old_lo" =~ ^[01]$ ]]; then sysctl -q -w "net.ipv6.conf.lo.disable_ipv6=$old_lo" 2>/dev/null || true; fi
      fi
      ;;
  esac
  if [[ "$NETWORK_STACK" == ipv4 ]] && ssh_session_uses_ipv6; then
    die '当前 SSH 会话正在通过 IPv6；为避免断线，拒绝关闭 IPv6。请先用 IPv4 SSH 登录后重跑。'
  fi
  log "网络模式：$NETWORK_STACK（请求：$NETWORK_REQUEST）"
}

apply_network_stack() {
  CURRENT_STEP='应用网络栈'
  local value=0 scope out restricted=false
  [[ "$NETWORK_STACK" == ipv4 ]] && value=1
  reject_symlink "$NETWORK_SYSCTL"
  make_mutable "$NETWORK_SYSCTL"
  cat >"$NETWORK_SYSCTL" <<EOF
# Managed by vps-init.sh
net.ipv6.conf.all.disable_ipv6 = $value
net.ipv6.conf.default.disable_ipv6 = $value
net.ipv6.conf.lo.disable_ipv6 = $value
EOF
  for scope in all default lo; do
    if ! out=$(sysctl -w "net.ipv6.conf.$scope.disable_ipv6=$value" 2>&1); then
      if grep -Eqi 'permission denied|operation not permitted|read-only' <<<"$out"; then
        restricted=true
      else
        die "设置 IPv6 sysctl 失败：$out"
      fi
    fi
  done
  if [[ "$restricted" == true ]]; then
    warn '宿主/容器禁止修改 IPv6 sysctl；SmartDNS 仍按检测结果配置，但内核级开关无法保证。'
  fi
}

configure_chrony() {
  CURRENT_STEP='配置 Chrony'
  systemctl enable chrony.service >/dev/null 2>&1 || true
  if ! systemctl restart chrony.service; then
    if [[ "$CONTAINER_KIND" != none ]]; then
      warn '容器环境中 Chrony 无法启动；继续执行。'
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
    [[ "$bbr" == true ]] && echo 'net.core.default_qdisc = fq'
    [[ "$bbr" == true ]] && echo 'net.ipv4.tcp_congestion_control = bbr'
    cat <<'EOF'
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_moderate_rcvbuf = 1
EOF
  } >"$TCP_SYSCTL"
  sysctl_try net.core.rmem_max 33554432 || true
  sysctl_try net.core.wmem_max 33554432 || true
  sysctl_try net.ipv4.tcp_rmem '4096 131072 33554432' || true
  sysctl_try net.ipv4.tcp_wmem '4096 16384 33554432' || true
  sysctl_try net.ipv4.tcp_window_scaling 1 || true
  sysctl_try net.ipv4.tcp_moderate_rcvbuf 1 || true
  if [[ "$bbr" == true ]]; then
    printf 'tcp_bbr\n' >"$BBR_MODULES"
    sysctl_try net.core.default_qdisc fq || true
    sysctl_try net.ipv4.tcp_congestion_control bbr || true
    log "BBR：$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown) / qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
  else
    rm -f "$BBR_MODULES"
    warn '当前内核不提供 BBR；TCP buffer 调优已应用，未写入无效 BBR 配置。'
  fi
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
  install -d -m 0755 /etc/apt/keyrings
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
    systemctl is-active --quiet sing-box.service 2>/dev/null && SINGBOX_WAS_ACTIVE=true || SINGBOX_WAS_ACTIVE=false
    systemctl is-enabled --quiet sing-box.service 2>/dev/null && SINGBOX_WAS_ENABLED=true || SINGBOX_WAS_ENABLED=false
  else
    SINGBOX_WAS_INSTALLED=false
    SINGBOX_WAS_ACTIVE=false
    SINGBOX_WAS_ENABLED=false
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
    systemctl disable sing-box.service >/dev/null 2>&1 || true
    systemctl stop sing-box.service >/dev/null 2>&1 || true
    return 0
  fi
  if [[ "$SINGBOX_WAS_ENABLED" == true ]]; then systemctl enable sing-box.service >/dev/null 2>&1 || true; else systemctl disable sing-box.service >/dev/null 2>&1 || true; fi
  if [[ "$SINGBOX_WAS_ACTIVE" == true ]]; then systemctl restart sing-box.service; else systemctl stop sing-box.service >/dev/null 2>&1 || true; fi
}

install_sing_box() {
  CURRENT_STEP='安装 sing-box'
  capture_singbox_state
  configure_sagernet_repo
  apt_get update

  if [[ "$SINGBOX_WAS_INSTALLED" == true && -z "$SING_BOX_VERSION" ]]; then
    if [[ "$SINGBOX_WAS_MANAGED" == true ]]; then
      configure_singbox_boot_gate
      mark_singbox_managed
      if [[ ! -e "$SINGBOX_CONFIG" ]]; then
        systemctl stop sing-box.service >/dev/null 2>&1 || true
      fi
      log "sing-box 已由 vps-init 管理，重跑不升级；保持原有启用状态，配置不存在时保持 inactive：$(sing-box version 2>/dev/null | head -1 || true)"
    else
      log "检测到脚本运行前已存在的 sing-box；重跑默认不升级，也不改其 service/config 状态：$(sing-box version 2>/dev/null | head -1 || true)"
    fi
    return 0
  fi

  if [[ "$SINGBOX_WAS_INSTALLED" == false ]]; then
    [[ ! -e /run/systemd/system/sing-box.service && ! -L /run/systemd/system/sing-box.service ]] ||
      die 'sing-box 已有 runtime service 覆盖或 mask，请先检查。'
    systemctl mask --runtime sing-box.service
    SINGBOX_RUNTIME_MASK=true
  fi

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
  if [[ -f "$NETWORK_SYSCTL" ]]; then cp -a "$NETWORK_SYSCTL" "$BACKUP_DIR/dns/network-sysctl"; else touch "$BACKUP_DIR/dns/no-network-sysctl"; fi
  IPV6_OLD_ALL=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)
  IPV6_OLD_DEFAULT=$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo 0)
  IPV6_OLD_LO=$(sysctl -n net.ipv6.conf.lo.disable_ipv6 2>/dev/null || echo 0)
  if [[ -L /etc/resolv.conf ]]; then
    ln -s "$(readlink /etc/resolv.conf)" "$BACKUP_DIR/dns/resolv.conf.symlink"
  elif [[ -e /etc/resolv.conf ]]; then
    cp -a /etc/resolv.conf "$BACKUP_DIR/dns/resolv.conf"
  fi
  systemctl is-active --quiet smartdns.service 2>/dev/null && SMARTDNS_OLD_ACTIVE=true || SMARTDNS_OLD_ACTIVE=false
  systemctl is-enabled --quiet smartdns.service 2>/dev/null && SMARTDNS_OLD_ENABLED=true || SMARTDNS_OLD_ENABLED=false
  systemctl is-active --quiet systemd-resolved.service 2>/dev/null && RESOLVED_OLD_ACTIVE=true || RESOLVED_OLD_ACTIVE=false
  systemctl is-enabled --quiet systemd-resolved.service 2>/dev/null && RESOLVED_OLD_ENABLED=true || RESOLVED_OLD_ENABLED=false
}

write_smartdns_config() {
  local out=$1 transport=${2:-h3}

  if [[ "$NETWORK_STACK" == ipv4 ]]; then
    cat >"$out" <<'EOF'
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
force-AAAA-SOA yes

log-level warn
log-console no
log-syslog yes
audit-enable no

ca-file /etc/ssl/certs/ca-certificates.crt
EOF
  else
    cat >"$out" <<'EOF'
bind 127.0.0.1:53
bind-tcp 127.0.0.1:53
bind [::1]:53
bind-tcp [::1]:53

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
force-AAAA-SOA no

log-level warn
log-console no
log-syslog yes
audit-enable no

ca-file /etc/ssl/certs/ca-certificates.crt
EOF
  fi

  case "$transport" in
    h3)
      cat >>"$out" <<'EOF'

# Preferred upstream: Cloudflare + Google DNS-over-HTTPS/3 (UDP/443)
server-h3 h3://cloudflare-dns.com/dns-query -host-ip 1.1.1.1
server-h3 h3://dns.google/dns-query -host-ip 8.8.8.8
EOF
      if [[ "$NETWORK_STACK" == dual ]]; then
        cat >>"$out" <<'EOF'
server-h3 h3://cloudflare-dns.com/dns-query -host-ip 2606:4700:4700::1111
server-h3 h3://dns.google/dns-query -host-ip 2001:4860:4860::8888
EOF
      fi
      ;;
    dns53)
      cat >>"$out" <<'EOF'

# Automatic fallback when H3/UDP443 is unavailable.
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
  local a='' aaaa='' tcp_a=''
  tcp_a=$(dig @127.0.0.1 google.com A +tcp +short +time=6 +tries=2 2>/dev/null || true)
  grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' <<<"$tcp_a" || return 1
  a=$(dig @127.0.0.1 google.com A +short +time=6 +tries=2 2>/dev/null || true)
  grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' <<<"$a" || return 1

  aaaa=$(dig @127.0.0.1 google.com AAAA +short +time=6 +tries=2 2>/dev/null || true)
  if [[ "$NETWORK_STACK" == ipv4 ]]; then
    [[ -z "$aaaa" ]]
  else
    grep -Eq '^[0-9a-fA-F:]*:[0-9a-fA-F:]+$' <<<"$aaaa"
  fi
}

smartdns_try_transport() {
  local transport=$1 staged=$2
  write_smartdns_config "$staged" "$transport"
  make_mutable "$SMARTDNS_CONF"
  install -m 0644 "$staged" "$SMARTDNS_CONF"

  if ! systemctl restart smartdns.service >/dev/null 2>&1; then
    return 1
  fi
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
  if smartdns_try_transport h3 "$staged"; then
    SMARTDNS_TRANSPORT='H3'
    log 'SmartDNS H3/UDP443 健康检查通过。'
  else
    warn 'SmartDNS H3/UDP443 不可用，自动回退到 Cloudflare/Google UDP+TCP 53。'
    if smartdns_try_transport dns53 "$staged"; then
      SMARTDNS_TRANSPORT='DNS53'
      log 'SmartDNS UDP/TCP 53 回退健康检查通过。'
    else
      journalctl -u smartdns -n 60 --no-pager >&2 || true
      die 'SmartDNS H3 与 UDP/TCP 53 上游均未通过健康检查。'
    fi
  fi

  log "SmartDNS 健康检查通过：$(smartdns -v 2>/dev/null | head -1)；上游=$SMARTDNS_TRANSPORT"
}

cleanup_legacy_network_stack() {
  CURRENT_STEP='迁移旧网络栈组件'
  local found=false
  if [[ -e "$LEGACY_NETWORK_UNIT" || -e "$LEGACY_NETWORK_HELPER" || -e "$LEGACY_IPV6_SYSCTL" ]]; then
    found=true
    install -d -m 0700 "$BACKUP_DIR/legacy-404-network"
    [[ ! -e "$LEGACY_NETWORK_UNIT" ]] || cp -a "$LEGACY_NETWORK_UNIT" "$BACKUP_DIR/legacy-404-network/"
    [[ ! -e "$LEGACY_NETWORK_HELPER" ]] || cp -a "$LEGACY_NETWORK_HELPER" "$BACKUP_DIR/legacy-404-network/"
    [[ ! -e "$LEGACY_IPV6_SYSCTL" ]] || cp -a "$LEGACY_IPV6_SYSCTL" "$BACKUP_DIR/legacy-404-network/"
    systemctl disable --now 404-network-stack.service >/dev/null 2>&1 || true
    make_mutable "$LEGACY_NETWORK_UNIT"
    make_mutable "$LEGACY_NETWORK_HELPER"
    make_mutable "$LEGACY_IPV6_SYSCTL"
    rm -f -- "$LEGACY_NETWORK_UNIT" "$LEGACY_NETWORK_HELPER" "$LEGACY_IPV6_SYSCTL" /run/404-network-stack.status
    systemctl daemon-reload
  fi
  [[ "$found" == false ]] || log '已备份并移除旧 404-network-stack 持久化组件，避免重启后覆盖新网络策略。'
}

configure_system_dns() {
  CURRENT_STEP='固定系统 DNS'
  local staged="$TMP_DIR/resolv.conf"
  cat >"$staged" <<'EOF'
nameserver 127.0.0.1
options timeout:2 attempts:2
EOF
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
      split("port permitrootlogin pubkeyauthentication authenticationmethods passwordauthentication kbdinteractiveauthentication challengeresponseauthentication permitemptypasswords usepam x11forwarding authorizedkeysfile authorizedkeyscommand authorizedkeyscommanduser allowusers allowgroups denyusers denygroups", a, " ")
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
    [[ "$KEEP_SSH_22" == true ]] && echo 'Port 22'
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

preauthorize_ufw_ssh() {
  if ufw status 2>/dev/null | grep -q '^Status: active$'; then
    if ! ufw status 2>/dev/null | grep -Eq "^${SSH_PORT}/tcp[[:space:]]+ALLOW"; then
      ufw allow "$SSH_PORT/tcp" comment 'vps-init-ssh' >/dev/null
      PREAUTH_SSH_PORT_ADDED=true
    fi
    if [[ "$KEEP_SSH_22" == true ]] && ! ufw status 2>/dev/null | grep -Eq '^(22/tcp|OpenSSH)[[:space:]]+ALLOW'; then
      ufw allow 22/tcp comment 'vps-init-ssh-backup' >/dev/null
      PREAUTH_22_ADDED=true
    fi
  fi
}

validate_sshd_effective() {
  local eff ports authfile authcmd
  eff=$(sshd -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null) || return 1
  ports=$(awk '$1=="port"{print $2}' <<<"$eff" | sort -nu)
  grep -Fxq "$SSH_PORT" <<<"$ports" || return 1
  if [[ "$KEEP_SSH_22" == true ]]; then grep -Fxq 22 <<<"$ports" || return 1; else ! grep -Fxq 22 <<<"$ports" || return 1; fi
  grep -Eq '^permitrootlogin (prohibit-password|without-password)$' <<<"$eff" || return 1
  grep -Eq '^pubkeyauthentication yes$' <<<"$eff" || return 1
  grep -Eq '^passwordauthentication no$' <<<"$eff" || return 1
  grep -Eq '^kbdinteractiveauthentication no$' <<<"$eff" || return 1
  authfile=$(awk '$1=="authorizedkeysfile"{$1=""; sub(/^ /,""); print; exit}' <<<"$eff")
  grep -Eq '(^|[[:space:]])\.ssh/authorized_keys([[:space:]]|$)|/root/\.ssh/authorized_keys' <<<"$authfile" || return 1
  authcmd=$(awk '$1=="authorizedkeyscommand"{print $2; exit}' <<<"$eff")
  [[ "$authcmd" == none ]] || return 1
}

configure_ssh() {
  CURRENT_STEP='配置 SSH'
  systemctl is-active --quiet ssh.service || die 'ssh.service 未运行。'
  [[ -f "$SSH_MAIN" && ! -L "$SSH_MAIN" ]] || die "$SSH_MAIN 必须是普通文件。"
  [[ ! -L "$SSH_DIR" ]] || die "$SSH_DIR 不能是符号链接。"
  if systemctl is-active --quiet ssh.socket 2>/dev/null; then die '检测到 ssh.socket 激活；为避免锁死，请先转换为 ssh.service 后再运行。'; fi
  ss -H -ltnp "sport = :$SSH_PORT" 2>/dev/null | grep -qv sshd && die "$SSH_PORT/tcp 已被非 sshd 进程占用。"
  backup_ssh_state
  SSH_TX=true
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
  validate_sshd_effective || die 'sshd -T 最终策略不符合目标。'
  systemctl reload ssh.service || die 'reload ssh.service 失败。'
  local attempt
  for ((attempt=0; attempt<10; attempt++)); do ss -H -ltn "sport = :$SSH_PORT" 2>/dev/null | grep -q . && break; sleep 1; done
  ss -H -ltn "sport = :$SSH_PORT" 2>/dev/null | grep -q . || die "$SSH_PORT/tcp 未开始监听。"
  if [[ "$KEEP_SSH_22" == true ]]; then ss -H -ltn 'sport = :22' 2>/dev/null | grep -q . || die '22/tcp 未保持监听。'; fi
  validate_sshd_effective || die 'reload 后 SSH 策略验证失败。'
  SSH_TX=false
  PREAUTH_SSH_PORT_ADDED=false
  PREAUTH_22_ADDED=false
  log "SSH 配置完成：$SSH_PORT/tcp；保留 22=$KEEP_SSH_22。"
}

backup_ufw_state() {
  install -d -m 0700 "$BACKUP_DIR/ufw"
  ufw status 2>/dev/null | grep -q '^Status: active$' && UFW_OLD_ACTIVE=true || UFW_OLD_ACTIVE=false
  [[ ! -d /etc/ufw ]] || cp -a /etc/ufw "$BACKUP_DIR/ufw/etc-ufw"
  [[ ! -e /etc/default/ufw ]] || cp -a /etc/default/ufw "$BACKUP_DIR/ufw/default-ufw"
}

ufw_delete_comment_rules() {
  local comment=$1 nums
  while true; do
    nums=$(ufw status numbered 2>/dev/null | awk -v c="# $comment" 'index($0,c){n=$0; sub(/^\[[[:space:]]*/,"",n); sub(/\].*/,"",n); gsub(/[[:space:]]/,"",n); if(n~/^[0-9]+$/) print n}' | sort -rn)
    [[ -n "$nums" ]] || break
    while IFS= read -r n; do [[ -n "$n" ]] && ufw --force delete "$n" >/dev/null; done <<<"$nums"
  done
}

configure_ufw() {
  CURRENT_STEP='配置 UFW'
  backup_ufw_state
  UFW_TX=true
  make_mutable /etc/default/ufw
  if [[ -f /etc/default/ufw ]]; then
    if [[ "$NETWORK_STACK" == dual ]]; then sed -i -E 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw; else sed -i -E 's/^IPV6=.*/IPV6=no/' /etc/default/ufw; fi
  fi
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw_delete_comment_rules 'vps-init-ssh'
  ufw_delete_comment_rules 'vps-init-ssh-backup'
  ufw_delete_comment_rules 'vps-init-443-tcp'
  ufw_delete_comment_rules 'vps-init-443-udp'
  ufw allow "$SSH_PORT/tcp" comment 'vps-init-ssh' >/dev/null
  if [[ "$KEEP_SSH_22" == true ]]; then
    ufw allow 22/tcp comment 'vps-init-ssh-backup' >/dev/null
  elif ufw status 2>/dev/null | grep -Eq '^(22/tcp|OpenSSH)[[:space:]]+ALLOW'; then
    warn '选择了不保留 22，但检测到非本脚本管理的 22/OpenSSH ALLOW 规则；基于 ownership boundary 未删除，请人工确认。'
  fi
  ufw allow 443/tcp comment 'vps-init-443-tcp' >/dev/null
  ufw allow 443/udp comment 'vps-init-443-udp' >/dev/null
  ufw --force enable >/dev/null
  ufw status | grep -q '^Status: active$' || die 'UFW 未成功启用。'
  ufw status | grep -Eq "^${SSH_PORT}/tcp[[:space:]]+ALLOW" || die 'UFW 未放行新 SSH 端口。'
  UFW_TX=false
}

write_cf_tool() {
  local path
  for path in "$CF_TOOL" "$CF_SERVICE" "$CF_TIMER"; do
    reject_symlink "$path"
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

configure_fail2ban() {
  CURRENT_STEP='配置 Fail2ban'
  local path
  local -a managed_files=(
    /etc/fail2ban/jail.d/00-vps-init-defaults.local
    /etc/fail2ban/jail.d/vps-init-sshd.local
    /etc/fail2ban/filter.d/vps-init-sing-box-reality.conf
    /etc/fail2ban/jail.d/vps-init-sing-box-reality.local
  )
  install -d -m 0755 /etc/fail2ban/jail.d /etc/fail2ban/filter.d
  for path in "${managed_files[@]}"; do
    reject_symlink "$path"
    make_mutable "$path"
  done
  cat >/etc/fail2ban/jail.d/00-vps-init-defaults.local <<'EOF'
[DEFAULT]
backend = systemd
banaction = ufw[blocktype=deny]
ignoreip = 127.0.0.1/8 ::1
EOF
  cat >/etc/fail2ban/jail.d/vps-init-sshd.local <<'EOF'
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
  cat >/etc/fail2ban/filter.d/vps-init-sing-box-reality.conf <<'EOF'
[Definition]
failregex = ^.*inbound/vless\[[^]]+\]: process connection from \[?<HOST>\]?:\d+: TLS handshake: REALITY: processed invalid connection$
ignoreregex =
journalmatch = _SYSTEMD_UNIT=sing-box.service
EOF
  cat >/etc/fail2ban/jail.d/vps-init-sing-box-reality.local <<'EOF'
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
  fail2ban-client -t >/dev/null || die 'Fail2ban 配置测试失败。'
  systemctl enable fail2ban.service >/dev/null
  systemctl restart fail2ban.service
  local attempt
  for ((attempt=0; attempt<15; attempt++)); do fail2ban-client ping >/dev/null 2>&1 && break; sleep 1; done
  fail2ban-client ping >/dev/null 2>&1 || die 'Fail2ban 未就绪。'
  log "Fail2ban jails：$(fail2ban-client status | sed -n 's/.*Jail list:[[:space:]]*//p')"
}

print_report() {
  cat <<EOF

============================================================
VPS 初始化完成
============================================================
系统          : ${PRETTY_NAME:-Debian}
网络栈        : $NETWORK_STACK
SSH           : $SSH_PORT/tcp；保留 22=$KEEP_SSH_22
UFW           : $(ufw status | head -1)
SmartDNS      : $(smartdns -v 2>/dev/null | head -1 || echo unavailable)
SmartDNS 模式 : $([[ "$NETWORK_STACK" == ipv4 ]] && echo 'IPv4-only' || echo 'IPv4+IPv6') / $SMARTDNS_TRANSPORT
sing-box      : $(sing-box version 2>/dev/null | head -1 || echo unavailable)
Fail2ban      : $(systemctl is-active fail2ban.service 2>/dev/null || true)
BBR           : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unavailable)
Swap          : $(awk '/SwapTotal:/ {printf "%.0f MiB", $2/1024}' /proc/meminfo)
备份目录      : $BACKUP_DIR
需要重启      : $([[ -e /var/run/reboot-required ]] && echo yes || echo no)
============================================================
请保持当前 SSH 会话，并从另一终端测试新端口 $SSH_PORT 后再决定是否人工移除 22。
EOF
}

select_install_mode() {
  [[ -z "$INSTALL_MODE" ]] || return 0
  local choice=''
  while true; do
    printf '\n1. 快速安装\n2. 自定义安装\n3. 退出\n4. 仅安装/更新 SmartDNS\n5. 仅部署 sing-box\n' >/dev/tty
    read_tty '请选择 [1-5]: ' choice
    case "$choice" in
      1) INSTALL_MODE=quick; return 0 ;;
      2) INSTALL_MODE=custom; return 0 ;;
      3) exit 0 ;;
      4) INSTALL_MODE=smartdns; return 0 ;;
      5) INSTALL_MODE=singbox; return 0 ;;
      *) printf '无效选择。\n' >/dev/tty ;;
    esac
  done
}

custom_phase_one() {
  if [[ "$DO_FULL_UPGRADE_SET" == false ]]; then
    if ask_yes_no '执行 apt full-upgrade？' true; then DO_FULL_UPGRADE=true; else DO_FULL_UPGRADE=false; fi
    DO_FULL_UPGRADE_SET=true
  fi
  install_early_dependencies
  update_system_and_tools
  local choice=''
  while true; do
    printf '\n基础工具已经安装完成。\n1. 继续完整初始化\n2. 退出，用于测试 IP、线路和基础环境\n' >/dev/tty
    read_tty '请选择 [1-2]: ' choice
    case "$choice" in
      1) return 0 ;;
      2) log '已在基础工具阶段停止；备份目录：'"$BACKUP_DIR"; exit 0 ;;
      *) printf '无效选择。\n' >/dev/tty ;;
    esac
  done
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
    auto)
      if ipv6_global_present && ipv6_route_present && ipv6_https_works; then
        NETWORK_STACK=dual
      else
        NETWORK_STACK=ipv4
      fi ;;
  esac
  backup_dns_state
  DNS_TX=true
  install_and_configure_smartdns
  configure_system_dns
  log "SmartDNS 完成：网络模式=$NETWORK_STACK；上游=$SMARTDNS_TRANSPORT；备份=$BACKUP_DIR"
}

run_singbox_only() {
  [[ -r /dev/tty && -w /dev/tty ]] || die '节点配置向导需要交互式 /dev/tty。'
  install_component_dependencies
  install_sing_box
  run_node_config_wizard </dev/tty
}

main() {
  parse_args "$@"
  select_install_mode
  preflight
  acquire_lock
  case "$INSTALL_MODE" in
    smartdns) run_smartdns_only; return 0 ;;
    singbox) run_singbox_only; return 0 ;;
  esac
  if [[ "$INSTALL_MODE" == quick ]]; then
    SSH_PORT_SET=true
    KEEP_SSH_22_SET=true
    DO_FULL_UPGRADE_SET=true
  fi
  if [[ "$INSTALL_MODE" == custom ]]; then
    custom_phase_one
  fi
  collect_choices
  if [[ "$INSTALL_MODE" != custom ]]; then
    install_early_dependencies
  fi
  if [[ "$BASE_ONLY" == false ]]; then
    collect_public_key
    install_authorized_key
  fi
  recommend_swap
  if (( SWAP_RECOMMENDED_MIB > 0 )); then
    if ask_yes_no "检测到 $(mem_total_mib)MiB RAM、当前 Swap $(swap_total_mib)MiB；建议创建 ${SWAP_RECOMMENDED_MIB}MiB Swap。创建？" true; then
      create_swap "$SWAP_RECOMMENDED_MIB"
    fi
  fi
  if [[ "$INSTALL_MODE" != custom ]]; then
    update_system_and_tools
  fi
  if [[ "$BASE_ONLY" == true ]]; then
    log '已按 --base-only 完成系统更新与基础工具安装。'
    return 0
  fi
  detect_network_stack
  configure_chrony
  configure_tcp_tuning
  install_sing_box
  backup_dns_state
  DNS_TX=true
  apply_network_stack
  install_and_configure_smartdns
  configure_system_dns
  cleanup_legacy_network_stack
  configure_ssh
  configure_ufw
  configure_cf8443
  configure_fail2ban
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
    local choice=''

    printf '\n请选择网络栈：\n\n'
    printf '1) IPv4-only [默认]\n'
    printf '2) IPv6-only\n'
    printf '3) Dual-stack\n'
    prompt_numbered_choice choice 1 3 1

    case "$choice" in
        1) NETWORK_STACK='ipv4' ;;
        2) NETWORK_STACK='ipv6' ;;
        3) NETWORK_STACK='dual' ;;
    esac
    info "Applying application-level $NETWORK_STACK configuration."
    inspect_kernel_enforcement
}

get_listen_address() {
    case "$NETWORK_STACK" in
        ipv4) printf '0.0.0.0' ;;
        ipv6|dual) printf '::' ;;
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
