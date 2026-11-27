#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export LC_ALL=C

readonly SCRIPT_VERSION='0.2.0'
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
readonly BBR_MODULES='/etc/modules-load.d/vps-init-bbr.conf'
readonly TRUSTED_KEYS_STATE='/var/lib/404-vps-tools/trusted-key-fingerprints'
readonly LEGACY_NETWORK_STACK_STATE='/var/lib/404-vps-tools/network-stack'
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
readonly POLICY_RC_D='/usr/sbin/policy-rc.d'
readonly POLICY_RC_D_BACKUP='/usr/sbin/policy-rc.d.404-vps-backup'
readonly POLICY_RC_D_MARK='# 404-vps-tools: temporary sing-box service restart block'
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
LOCK_HELD=false
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
SINGBOX_CHECK_OUTPUT=''
SINGBOX_CHECK_BIN=''
SINGBOX_CHECK_CWD='/'
SINGBOX_CHECK_REASON=''
SINGBOX_CHECK_ARGS=()
POLICY_RC_D_ACTIVE=false
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

C_OUT_RESET='' C_OUT_BOLD='' C_OUT_DIM='' C_OUT_RED='' C_OUT_GREEN='' C_OUT_YELLOW='' C_OUT_CYAN=''
C_ERR_RESET='' C_ERR_BOLD='' C_ERR_DIM='' C_ERR_RED='' C_ERR_GREEN='' C_ERR_YELLOW='' C_ERR_CYAN=''
C_TTY_RESET='' C_TTY_BOLD='' C_TTY_DIM='' C_TTY_RED='' C_TTY_GREEN='' C_TTY_YELLOW='' C_TTY_CYAN=''
C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_CYAN=''
UI_TARGET='out'
UI_TL='╭' UI_TR='╮' UI_BL='╰' UI_BR='╯' UI_V='│' UI_H='─' UI_ML='├' UI_MR='┤'
UI_WIDTH=72

ui_set_palette() {
  local prefix=$1 enabled=$2
  if [[ "$enabled" == true ]]; then
    printf -v "${prefix}_RESET" '%s' $'\033[0m'
    printf -v "${prefix}_BOLD" '%s' $'\033[1m'
    printf -v "${prefix}_DIM" '%s' $'\033[2m'
    printf -v "${prefix}_RED" '%s' $'\033[31m'
    printf -v "${prefix}_GREEN" '%s' $'\033[32m'
    printf -v "${prefix}_YELLOW" '%s' $'\033[33m'
    printf -v "${prefix}_CYAN" '%s' $'\033[36m'
  else
    printf -v "${prefix}_RESET" '%s' ''
    printf -v "${prefix}_BOLD" '%s' ''
    printf -v "${prefix}_DIM" '%s' ''
    printf -v "${prefix}_RED" '%s' ''
    printf -v "${prefix}_GREEN" '%s' ''
    printf -v "${prefix}_YELLOW" '%s' ''
    printf -v "${prefix}_CYAN" '%s' ''
  fi
}

ui_use_target() {
  local target=${1:-out}
  UI_TARGET=$target
  case "$target" in
    out)
      if [[ -t 1 && -n "$C_OUT_RESET" ]]; then
        C_RESET=$C_OUT_RESET C_BOLD=$C_OUT_BOLD C_DIM=$C_OUT_DIM
        C_RED=$C_OUT_RED C_GREEN=$C_OUT_GREEN C_YELLOW=$C_OUT_YELLOW C_CYAN=$C_OUT_CYAN
      else
        C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_CYAN=''
      fi ;;
    err)
      if [[ -t 2 && -n "$C_ERR_RESET" ]]; then
        C_RESET=$C_ERR_RESET C_BOLD=$C_ERR_BOLD C_DIM=$C_ERR_DIM
        C_RED=$C_ERR_RED C_GREEN=$C_ERR_GREEN C_YELLOW=$C_ERR_YELLOW C_CYAN=$C_ERR_CYAN
      else
        C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_CYAN=''
      fi ;;
    tty)
      C_RESET=$C_TTY_RESET C_BOLD=$C_TTY_BOLD C_DIM=$C_TTY_DIM
      C_RED=$C_TTY_RED C_GREEN=$C_TTY_GREEN C_YELLOW=$C_TTY_YELLOW C_CYAN=$C_TTY_CYAN ;;
  esac
}

ui_init() {
  local color_allowed=false out_color=false err_color=false tty_color=false
  local size='' cols=''
  if [[ -z "${NO_COLOR+x}" && "${TERM:-}" != dumb ]]; then
    color_allowed=true
  fi
  if [[ "$color_allowed" == true ]]; then
    if [[ -t 1 ]]; then out_color=true; fi
    if [[ -t 2 ]]; then err_color=true; fi
    if [[ -w /dev/tty ]] && ( exec 3>>/dev/tty && [[ -t 3 ]] ) 2>/dev/null; then
      tty_color=true
    fi
  fi
  ui_set_palette C_OUT "$out_color"
  ui_set_palette C_ERR "$err_color"
  ui_set_palette C_TTY "$tty_color"
  ui_use_target out

  if [[ "${TERM:-}" == linux ]]; then
    UI_TL='+' UI_TR='+' UI_BL='+' UI_BR='+'
    UI_V='|' UI_H='-' UI_ML='+' UI_MR='+'
  else
    UI_TL='╭' UI_TR='╮' UI_BL='╰' UI_BR='╯'
    UI_V='│' UI_H='─' UI_ML='├' UI_MR='┤'
  fi

  UI_WIDTH=72
  if [[ -r /dev/tty ]]; then
    size=$({ stty size </dev/tty; } 2>/dev/null || true)
  fi
  if [[ "$size" =~ ^[0-9]+[[:space:]]+([0-9]+)$ ]]; then
    cols=${BASH_REMATCH[1]}
    if (( cols > 0 && cols < 72 )); then
      UI_WIDTH=$cols
    fi
  fi
}

ui_tty_writable() {
  ( : >>/dev/tty ) 2>/dev/null
}

ui_repeat() {
  local char=$1 count=$2 out=''
  (( count > 0 )) || return 0
  printf -v out '%*s' "$count" ''
  printf '%s' "${out// /$char}"
}

ui_display_width() {
  local width
  width=$(LC_ALL=C.UTF-8 wc -L <<<"$1")
  printf '%s' "${width//[[:space:]]/}"
}

ui_box_top() {
  local title=${1:-} b_color=$C_CYAN t_color=$C_BOLD r_color=$C_RESET
  local tw fill
  if [[ "$UI_TARGET" == out && ! -t 1 ]]; then b_color='' t_color='' r_color=''; fi
  if [[ -z "$title" ]]; then
    fill=$((UI_WIDTH - 2))
    printf '%s%s%s%s%s\n' "$b_color" "$UI_TL" "$(ui_repeat "$UI_H" "$fill")" "$UI_TR" "$r_color"
    return 0
  fi
  tw=$(ui_display_width "$title")
  fill=$((UI_WIDTH - tw - 5))
  if (( fill >= 1 )); then
    printf '%s%s%s%s %s%s%s %s%s%s%s\n' \
      "$b_color" "$UI_TL" "$UI_H" "$r_color" \
      "$t_color" "$title" "$r_color" \
      "$b_color" "$(ui_repeat "$UI_H" "$fill")" "$UI_TR" "$r_color"
  else
    printf '%s%s%s%s %s%s%s\n' \
      "$b_color" "$UI_TL" "$UI_H" "$r_color" \
      "$t_color" "$title" "$r_color"
  fi
}

declare -A UI_CHAR_WIDTH_CACHE=()
UI_CHAR_WIDTH=1
declare -a UI_WRAP_SEGS=() UI_WRAP_WIDTHS=()

# Display width of one character into UI_CHAR_WIDTH. Printable ASCII is 1; anything else is
# measured once with wc -L and cached, so wrapping never spawns a process per character.
# Callers must already run under a UTF-8 LC_ALL (see ui_wrap_text).
ui_char_width() {
  local ch=$1 code=0 w
  printf -v code '%d' "'$ch" 2>/dev/null || code=0
  if (( code >= 32 && code <= 126 )); then
    UI_CHAR_WIDTH=1
    return 0
  fi
  if [[ -z "${UI_CHAR_WIDTH_CACHE[$ch]+x}" ]]; then
    w=$(LC_ALL=C.UTF-8 wc -L <<<"$ch")
    UI_CHAR_WIDTH_CACHE[$ch]=${w//[[:space:]]/}
  fi
  UI_CHAR_WIDTH=${UI_CHAR_WIDTH_CACHE[$ch]}
}

# Split plain text into segments no wider than $2 display columns (UI_WRAP_SEGS, with each segment's
# width in UI_WRAP_WIDTHS). Break after a space or Chinese punctuation found in the latter half of a
# segment, else hard-break; no character is dropped. Continuation segments are indented by the
# original leading spaces + 2 (capped at half the inner width so progress is always possible).
ui_wrap_text() {
  local text=$1 inner=$2
  local LC_ALL=C.UTF-8
  local punct='，。；、：' lead cont indent n=${#text} i j k start=0 avail cum brk seg first=true
  local -a ch=() cw=()
  UI_WRAP_SEGS=() UI_WRAP_WIDTHS=()
  lead=${text%%[! ]*}
  cont=$(( ${#lead} + 2 ))
  if (( cont > inner / 2 )); then cont=$(( inner / 2 )); fi
  printf -v indent '%*s' "$cont" ''
  for (( i = 0; i < n; i++ )); do
    ch[i]=${text:i:1}
    ui_char_width "${ch[i]}"
    cw[i]=$UI_CHAR_WIDTH
  done
  while (( start < n )); do
    if [[ "$first" == true ]]; then avail=$inner; else avail=$(( inner - cont )); fi
    cum=0 j=$start brk=-1
    while (( j < n && cum + cw[j] <= avail )); do
      cum=$(( cum + cw[j] ))
      if (( cum * 2 > avail )) && [[ "${ch[j]}" == ' ' || "$punct" == *"${ch[j]}"* ]]; then brk=$j; fi
      j=$(( j + 1 ))
    done
    if (( j == start )); then
      j=$(( start + 1 ))  # a character wider than the box still makes progress
      cum=${cw[start]}
    elif (( j < n && brk >= 0 )); then
      j=$(( brk + 1 ))
      cum=0
      for (( k = start; k < j; k++ )); do cum=$(( cum + cw[k] )); done
    fi
    seg=''
    for (( k = start; k < j; k++ )); do seg+=${ch[k]}; done
    if [[ "$first" == true ]]; then
      UI_WRAP_SEGS+=("$seg")
      UI_WRAP_WIDTHS+=("$cum")
    else
      UI_WRAP_SEGS+=("${indent}${seg}")
      UI_WRAP_WIDTHS+=("$(( cont + cum ))")
    fi
    first=false
    start=$j
  done
}

# Internal: $1 plain text, $2 rendered text (used only when the line fits), $3 optional whole-line color.
ui_box_emit() {
  local plain=$1 rendered=$2 color=$3 b_color=$C_CYAN r_color=$C_RESET
  local w inner pad i text
  if [[ "$UI_TARGET" == out && ! -t 1 ]]; then
    b_color='' r_color='' rendered=$plain color=''
  fi
  w=$(ui_display_width "$plain")
  inner=$((UI_WIDTH - 4))
  if (( w <= inner )); then
    if [[ -n "$color" ]]; then rendered="${color}${plain}${r_color}"; fi
    pad=$((inner - w))
    printf '%s%s%s %s%s %s%s%s\n' \
      "$b_color" "$UI_V" "$r_color" \
      "$rendered" "$(ui_repeat ' ' "$pad")" \
      "$b_color" "$UI_V" "$r_color"
    return 0
  fi
  ui_wrap_text "$plain" "$inner"
  for i in "${!UI_WRAP_SEGS[@]}"; do
    text=${UI_WRAP_SEGS[i]}
    if [[ -n "$color" ]]; then text="${color}${text}${r_color}"; fi
    pad=$((inner - UI_WRAP_WIDTHS[i]))
    printf '%s%s%s %s%s %s%s%s\n' \
      "$b_color" "$UI_V" "$r_color" \
      "$text" "$(ui_repeat ' ' "$pad")" \
      "$b_color" "$UI_V" "$r_color"
  done
}

# ui_box_line <plain> [rendered]: rendered may color part of the line; a wrapped line is uncolored.
ui_box_line() {
  ui_box_emit "$1" "${2-$1}" ''
}

# ui_box_line_color <color> <text>: color the whole line, every wrapped segment included.
ui_box_line_color() {
  ui_box_emit "$2" "$2" "$1"
}

ui_box_sep() {
  local b_color=$C_CYAN r_color=$C_RESET fill=$((UI_WIDTH - 2))
  if [[ "$UI_TARGET" == out && ! -t 1 ]]; then b_color='' r_color=''; fi
  printf '%s%s%s%s%s\n' "$b_color" "$UI_ML" "$(ui_repeat "$UI_H" "$fill")" "$UI_MR" "$r_color"
}

ui_box_bottom() {
  local b_color=$C_CYAN r_color=$C_RESET fill=$((UI_WIDTH - 2))
  if [[ "$UI_TARGET" == out && ! -t 1 ]]; then b_color='' r_color=''; fi
  printf '%s%s%s%s%s\n' "$b_color" "$UI_BL" "$(ui_repeat "$UI_H" "$fill")" "$UI_BR" "$r_color"
}

ui_menu_item() {
  local num=$1 label=$2 color=${3:-${C_BOLD}${C_GREEN}}
  ui_box_line "${num}. ${label}" "${color}${num}.${C_RESET} ${label}"
}

ui_box_kv() {
  local key=$1 val=$2 warn_flag=${3:-false}
  local plain="${key}${val}"
  if [[ "$warn_flag" == true && -n "$C_YELLOW" ]]; then
    ui_box_line "$plain" "${key}${C_YELLOW}${val}${C_RESET}"
  else
    ui_box_line "$plain"
  fi
}

ui_init

log() {
  if [[ -t 1 && -n "$C_OUT_CYAN" ]]; then
    printf '%s[INFO]%s %s\n' "$C_OUT_CYAN" "$C_OUT_RESET" "$*"
  else
    printf '[INFO] %s\n' "$*"
  fi
}

warn() {
  if [[ -t 2 && -n "$C_ERR_YELLOW" ]]; then
    printf '%s[WARN]%s %s\n' "$C_ERR_YELLOW" "$C_ERR_RESET" "$*" >&2
  else
    printf '[WARN] %s\n' "$*" >&2
  fi
}

usage() {
  cat <<'EOF'
用法：
  bash debian-init.sh
  bash debian-init.sh [选项]

交互菜单：1 快速初始化、2 自定义初始化、3 SmartDNS、4 安装/升级 sing-box、5 Fail2ban、6 系统更新、7 清理、8 安全加固、9 重装为官方 Debian 13（会清空整机）、0 退出。
选项 9 只能从菜单进入：仅 KVM + BIOS + amd64，保留当前 IPv4/IPv6 和 root 公钥，确认主机名后下载校验官方安装器并重启。
选项 4 安装或升级 sing-box，配置通过检查后才重启；完整初始化只安装 sing-box，不创建节点。

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
  --sing-box-version VER     指定 sing-box 版本；初始化中已安装版本不会被重跑升级
  --network-stack MODE       auto、ipv4、dual（默认 auto），显式参数跳过网络菜单
                             ipv4 持久禁用各接口 IPv6，保留原始网络配置
  --cloudflare-8443          启用 Cloudflare-only 8443/tcp + 每日刷新
  --no-cloudflare-8443       删除本脚本管理的 Cloudflare 8443 规则/定时器
  --base-only                只完成系统更新和基础工具安装
  --smartdns-only            仅安装/更新 SmartDNS 并验证系统 DNS
  --sing-box-only            安装/升级 sing-box（等同菜单 4）
  --fail2ban-only            仅安装/更新 Fail2ban 并验证 Jail
  --cleanup-only             系统清理，删除软件包和旧内核需分别确认
  --update-only              仅系统更新，保留 sing-box/SmartDNS hold，不安装初始化工具
  --audit                    只读体检，完整报告输出到终端，不创建备份、锁或临时文件
  --version                  显示版本并退出
  --help                     显示帮助
EOF
}

read_tty() {
  local prompt=$1 var=$2
  [[ "$CONFIG_CONFIRMED" == false ]] || die "执行阶段出现未预收集的交互：$prompt"
  [[ -r /dev/tty && -w /dev/tty ]] || die '需要交互输入，但当前没有可用 /dev/tty。'
  if [[ -n "$C_TTY_BOLD" ]]; then
    if [[ "$prompt" == *' [Y/n] ' ]]; then
      printf '%s%s%s [%sY%s/n] ' "$C_TTY_BOLD" "${prompt%' [Y/n] '}" "$C_TTY_RESET" "${C_TTY_BOLD}${C_TTY_CYAN}" "$C_TTY_RESET" >/dev/tty
    elif [[ "$prompt" == *' [y/N] ' ]]; then
      printf '%s%s%s [y/%sN%s] ' "$C_TTY_BOLD" "${prompt%' [y/N] '}" "$C_TTY_RESET" "${C_TTY_BOLD}${C_TTY_CYAN}" "$C_TTY_RESET" >/dev/tty
    else
      printf '%s%s%s' "$C_TTY_BOLD" "$prompt" "$C_TTY_RESET" >/dev/tty
    fi
  else
    printf '%s' "$prompt" >/dev/tty
  fi
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
  if [[ "${REINSTALL_ARMED:-false}" == true ]]; then reinstall_abort_cleanup; fi
  policy_rc_d_restore
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
  if [[ -t 2 && -n "$C_ERR_RED" ]]; then
    printf '%s[ERROR]%s 步骤“%s”第 %s 行失败（退出码 %s）。\n' "${C_ERR_BOLD}${C_ERR_RED}" "$C_ERR_RESET" "$CURRENT_STEP" "$line" "$rc" >&2
  else
    printf '[ERROR] 步骤“%s”第 %s 行失败（退出码 %s）。\n' "$CURRENT_STEP" "$line" "$rc" >&2
  fi
  exit "$rc"
}

on_signal() {
  local sig=$1
  # Rollback must finish: ignore repeated signals from here on, and put policy-rc.d back first.
  trap - ERR
  trap '' HUP INT TERM
  if [[ "${REINSTALL_ARMED:-false}" == true ]]; then reinstall_abort_cleanup || true; fi
  policy_rc_d_restore || true
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
  if [[ -t 2 && -n "$C_ERR_RED" ]]; then
    printf '%s[ERROR]%s 步骤“%s”：%s\n' "${C_ERR_BOLD}${C_ERR_RED}" "$C_ERR_RESET" "$CURRENT_STEP" "$*" >&2
  else
    printf '[ERROR] 步骤“%s”：%s\n' "$CURRENT_STEP" "$*" >&2
  fi
  if [[ "${REINSTALL_ARMED:-false}" == true ]]; then reinstall_abort_cleanup || true; fi
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
      --version|-V) printf 'debian-init.sh %s\n' "$SCRIPT_VERSION"; exit 0 ;;
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
  # Option 9 may take the lock early to clear leftovers; re-opening fd 9 would drop it briefly.
  [[ "$LOCK_HELD" == false ]] || return 0
  install -d -m 0755 /run/lock
  exec 9>"$LOCK_FILE"
  flock -n 9 || die '已有另一个 vps-init.sh 正在运行。'
  LOCK_HELD=true
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
  LC_ALL=C awk -v kib="$1" 'BEGIN {
    mib=int(kib/1024 + 0.5)
    if (kib <= 0) print "0 MiB"
    else if (kib < 512) print "<1 MiB"
    else if (mib < 1024) printf "%.0f MiB\n", mib
    else printf "%.1f GiB\n", int(kib*10/1048576 + 0.5)/10
  }'
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
      if ui_tty_writable; then
        ui_use_target tty
        {
          printf '\n'
          ui_box_top 'SSH 端口'
          ui_menu_item 1 '22 only'
          ui_menu_item 2 '53651 only（默认）'
          ui_menu_item 3 '自定义端口 only'
          ui_menu_item 4 '保留现有 SSH 配置'
          ui_box_bottom
        } >/dev/tty
        ui_use_target out
      fi
      read_tty '请选择 SSH 端口 [1-4]: ' choice
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
      if ui_tty_writable; then
        ui_use_target tty
        {
          printf '\n'
          ui_box_top '网络模式'
          ui_menu_item 1 'Auto（默认）'
          ui_menu_item 2 'IPv4-only'
          ui_menu_item 3 'Dual-Stack'
          ui_box_bottom
        } >/dev/tty
        ui_use_target out
      fi
      read_tty '请选择网络模式 [1-3]: ' choice
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
    log "IPv6 HTTPS $provider: FAIL (no HTTP response: $result)"
  else
    rc=$?
    log "IPv6 HTTPS $provider: FAIL (curl $rc: $result)"
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
    log "IPv6 Global Address: FAIL (${detail:-no usable global unicast address})"
  fi
  if detail=$(ipv6_route_present 2>&1); then
    route=true
    log 'IPv6 Default Route: PASS'
  else
    log "IPv6 Default Route: FAIL (${detail:-no usable default route})"
  fi
  if [[ "$address" == true && "$route" == true ]]; then
    if ipv6_https_works; then NETWORK_STACK=dual; fi
  else
    log 'IPv6 HTTPS Cloudflare: FAIL (skipped: address or default route unavailable)'
    log 'IPv6 HTTPS Google: FAIL (skipped: address or default route unavailable)'
  fi
  if [[ "$NETWORK_STACK" == ipv4 ]]; then
    log '未检测到可用的 IPv6，按 IPv4-only 处理（正常结果，不是错误）'
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
      if ui_tty_writable; then
        ui_use_target tty
        {
          printf '\n'
          ui_box_top '重启后 IPv6'
          ui_menu_item 1 '恢复 IPv6：写入脚本管理的 /etc/sysctl.d/99-vps-init-network.conf 覆盖上述设置（不修改原有文件）'
          ui_menu_item 2 '保留，Auto 按 IPv4 处理（默认）'
          ui_box_bottom
        } >/dev/tty
        ui_use_target out
      fi
      read_tty '请选择 [1-2]: ' choice
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

sagernet_repo_source() {
  printf '%s\n' 'Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.gpg'
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
  sagernet_repo_source >/etc/apt/sources.list.d/sagernet.sources
}

# Any *.json counts: the stock unit starts "-C /etc/sing-box", which merges every file in it.
singbox_has_config() {
  compgen -G "${SINGBOX_CONFIG%/*}/*.json" >/dev/null
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
ConditionPathExistsGlob=/etc/sing-box/*.json
EOF
  install -m 0644 "$TMP_DIR/sing-box-config-gate.conf" "$SINGBOX_DROPIN"
  systemctl daemon-reload
}

mark_singbox_managed() {
  install -d -m 0755 "$(dirname "$SINGBOX_MANAGED_MARKER")"
  printf 'managed-by-vps-init\n' >"$SINGBOX_MANAGED_MARKER"
}

# Only the config.json the package itself drops on a first install goes away: it did not exist
# before the install, so it cannot be the user's. Split files such as 00-main.json are never touched.
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
      if ! singbox_has_config; then
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

# While sing-box is installed or changed, policy-rc.d (exit 101) stops maintainer scripts from
# restarting the service, so a new binary never runs before its config has been checked. A
# pre-existing policy-rc.d is moved aside and always put back, whatever the exit path. These
# functions run in || contexts where errexit is off, so every file operation is checked.
policy_rc_d_is_stub() {
  [[ -f "$POLICY_RC_D" && ! -L "$POLICY_RC_D" ]] && grep -Fq -- "$POLICY_RC_D_MARK" "$POLICY_RC_D" 2>/dev/null
}

policy_rc_d_block() {
  [[ "$POLICY_RC_D_ACTIVE" == false ]] || return 0
  if [[ -e "$POLICY_RC_D_BACKUP" || -L "$POLICY_RC_D_BACKUP" ]]; then
    # Left by an interrupted run: the user's file goes back before anything else happens.
    if [[ -e "$POLICY_RC_D" || -L "$POLICY_RC_D" ]] && ! policy_rc_d_is_stub; then
      die "发现 $POLICY_RC_D_BACKUP 且 $POLICY_RC_D 不是本脚本创建，请先手动确认并还原。"
    fi
    if { ! policy_rc_d_is_stub || rm -f -- "$POLICY_RC_D"; } && mv -f -- "$POLICY_RC_D_BACKUP" "$POLICY_RC_D"; then
      warn "已还原上次中断遗留的 $POLICY_RC_D。"
    else
      warn "无法还原上次中断遗留的 $POLICY_RC_D_BACKUP。"
      return 1
    fi
  elif policy_rc_d_is_stub; then
    # A stub without a backup means the user never had a policy-rc.d: delete it, never back it up.
    if ! rm -f -- "$POLICY_RC_D"; then
      warn "无法删除上次中断遗留的 policy-rc.d 脚桩：$POLICY_RC_D"
      return 1
    fi
    warn "已删除上次中断遗留的 policy-rc.d 脚桩：$POLICY_RC_D"
  fi
  # From here a failure or a signal must put things back, so restoring is armed first.
  POLICY_RC_D_ACTIVE=true
  if [[ -e "$POLICY_RC_D" || -L "$POLICY_RC_D" ]]; then
    if ! mv -- "$POLICY_RC_D" "$POLICY_RC_D_BACKUP"; then
      warn "无法移走现有 $POLICY_RC_D。"
      policy_rc_d_restore || true
      return 1
    fi
  fi
  if ! printf '#!/bin/sh\n%s\nexit 101\n' "$POLICY_RC_D_MARK" >"$TMP_DIR/policy-rc.d" ||
    ! install -m 0755 "$TMP_DIR/policy-rc.d" "$POLICY_RC_D"; then
    warn "无法写入临时 $POLICY_RC_D。"
    policy_rc_d_restore || true
    return 1
  fi
}

# Restoring is driven by what is on disk: drop our stub, then put a backup back if one exists.
policy_rc_d_restore() {
  [[ "$POLICY_RC_D_ACTIVE" == true ]] || return 0
  local rc=0
  if policy_rc_d_is_stub; then rm -f -- "$POLICY_RC_D" || rc=1; fi
  if [[ -e "$POLICY_RC_D_BACKUP" || -L "$POLICY_RC_D_BACKUP" ]]; then
    mv -f -- "$POLICY_RC_D_BACKUP" "$POLICY_RC_D" || rc=1
  fi
  if (( rc == 0 )); then
    POLICY_RC_D_ACTIVE=false
  else
    warn "无法还原 $POLICY_RC_D，原文件备份在 $POLICY_RC_D_BACKUP。"
  fi
  return "$rc"
}

# apt-get install for sing-box with service restarts blocked; needrestart only lists.
singbox_apt_install() {
  local rc=0
  policy_rc_d_block || return 1
  NEEDRESTART_MODE=l apt_get install -y "$@" || rc=$?
  policy_rc_d_restore || rc=1
  return "$rc"
}

singbox_installed_version() {
  local status
  status=$(dpkg-query -W -f='${db:Status-Status}' sing-box 2>/dev/null) || status=''
  [[ "$status" == installed ]] || return 1
  dpkg-query -W -f='${Version}' sing-box
}

singbox_repo_has_version() {
  local versions
  versions=$(apt-cache madison sing-box | awk '{print $3}') || return 1
  grep -Fxq -- "$1" <<<"$versions"
}

# Work out, before anything is installed, how to run "sing-box check" exactly like the service
# starts. Only the plain systemd form is trusted: one ExecStart whose program is an executable
# named sing-box, no quoting or escapes, standard -c/-C/-D arguments, no Environment/EnvironmentFile.
# Anything else sets SINGBOX_CHECK_REASON and fails, and the caller does not upgrade.
singbox_resolve_check() {
  local exec_out line argv path_field tok value wd env_value env_files cfg_path re n i run_count=0 have_config=false
  local -a toks=() exec_lines=()
  SINGBOX_CHECK_BIN=''
  SINGBOX_CHECK_CWD='/'
  SINGBOX_CHECK_REASON=''
  SINGBOX_CHECK_ARGS=()
  exec_out=$(systemctl show -p ExecStart --value sing-box.service 2>/dev/null) || exec_out=''
  mapfile -t exec_lines < <(printf '%s\n' "$exec_out" | sed '/^[[:space:]]*$/d')
  if (( ${#exec_lines[@]} != 1 )); then SINGBOX_CHECK_REASON="ExecStart 有 ${#exec_lines[@]} 条，只支持 1 条"; return 1; fi
  line=${exec_lines[0]}
  re='^\{ path=([^;]*) ; argv\[\]=(.*) ; ignore_errors='
  if [[ ! "$line" =~ $re ]]; then SINGBOX_CHECK_REASON='无法解析 systemctl show 的 ExecStart 输出'; return 1; fi
  path_field=${BASH_REMATCH[1]}
  argv=${BASH_REMATCH[2]}
  if [[ "$argv" == *[\"\'\\\$]* ]]; then SINGBOX_CHECK_REASON='ExecStart 含引号、反斜杠或变量'; return 1; fi
  if [[ "$argv" == *'  '* || "$argv" == ' '* || "$argv" == *' ' || "$argv" == *$'\t'* ]]; then
    SINGBOX_CHECK_REASON='ExecStart 含空参数、首尾空格或制表符'
    return 1
  fi
  IFS=' ' read -r -a toks <<<"$argv"
  n=${#toks[@]}
  if (( n == 0 )) || [[ "${toks[0]}" != /* || "${toks[0]}" != "$path_field" || "${toks[0]##*/}" != sing-box ||
    ! -f "${toks[0]}" || ! -x "${toks[0]}" ]]; then
    SINGBOX_CHECK_REASON="ExecStart 的程序不是名为 sing-box 的可执行文件（${toks[0]:-空}；env/sh 包装等不支持）"
    return 1
  fi
  env_value=$(systemctl show -p Environment --value sing-box.service 2>/dev/null) || env_value=''
  env_files=$(systemctl show -p EnvironmentFiles --value sing-box.service 2>/dev/null) || env_files=''
  if [[ -n "${env_value//[[:space:]]/}" || -n "${env_files//[[:space:]]/}" ]]; then
    SINGBOX_CHECK_REASON='服务设置了 Environment/EnvironmentFile，无法可靠还原运行环境'
    return 1
  fi
  wd=$(systemctl show -p WorkingDirectory --value sing-box.service 2>/dev/null) || wd=''
  if [[ -n "$wd" ]]; then
    if [[ "$wd" != /* || ! -d "$wd" ]]; then SINGBOX_CHECK_REASON="WorkingDirectory 不是现有的绝对目录：$wd"; return 1; fi
    SINGBOX_CHECK_CWD=$wd
  fi
  SINGBOX_CHECK_BIN=${toks[0]}
  for ((i = 1; i < n; i++)); do
    tok=${toks[i]}
    case "$tok" in
      run) run_count=$((run_count + 1)) ;;
      -c|-C|-D|--config|--config-directory|--directory)
        if (( i + 1 >= n )) || [[ "${toks[i + 1]}" == -* ]]; then SINGBOX_CHECK_REASON="ExecStart 参数 $tok 缺少值"; return 1; fi
        value=${toks[i + 1]}
        i=$((i + 1))
        cfg_path=$value
        if [[ "$cfg_path" != /* ]]; then cfg_path=$SINGBOX_CHECK_CWD/$cfg_path; fi
        case "$tok" in
          -c|--config)
            have_config=true
            if [[ ! -f "$cfg_path" ]]; then SINGBOX_CHECK_REASON="ExecStart 指向的配置文件不存在：$cfg_path"; return 1; fi ;;
          -C|--config-directory)
            have_config=true
            if [[ ! -d "$cfg_path" ]]; then SINGBOX_CHECK_REASON="ExecStart 指向的配置目录不存在：$cfg_path"; return 1; fi ;;
          *)
            if [[ ! -d "$cfg_path" ]]; then SINGBOX_CHECK_REASON="ExecStart 的工作目录（$tok）不存在：$cfg_path"; return 1; fi ;;
        esac
        SINGBOX_CHECK_ARGS+=("$tok" "$value") ;;
      *)
        SINGBOX_CHECK_REASON="ExecStart 含不在白名单内的参数：$tok"
        return 1 ;;
    esac
  done
  if (( run_count != 1 )); then SINGBOX_CHECK_REASON="ExecStart 中子命令 run 出现 $run_count 次，必须恰好 1 次"; return 1; fi
  if [[ "$have_config" == false ]]; then SINGBOX_CHECK_REASON='ExecStart 中没有 -c/-C 配置参数'; return 1; fi
}

# Run the check with the program and arguments singbox_resolve_check settled on, never another binary.
singbox_run_check() {
  SINGBOX_CHECK_OUTPUT=''
  ( IFS=' '; log "sing-box check ${SINGBOX_CHECK_ARGS[*]}（目录 $SINGBOX_CHECK_CWD）" )
  SINGBOX_CHECK_OUTPUT=$(cd "$SINGBOX_CHECK_CWD" && "$SINGBOX_CHECK_BIN" check "${SINGBOX_CHECK_ARGS[@]}" 2>&1) || return 1
}

# Put the previous package version back so program and config match on the next start.
singbox_downgrade() {
  local version=$1
  singbox_repo_has_version "$version" || return 1
  singbox_apt_install --allow-downgrades "sing-box=$version" || return 1
  [[ "$(singbox_installed_version || true)" == "$version" ]]
}

# After a downgrade, bring a service that went down back up from a clean unit state.
singbox_start_after_downgrade() {
  systemctl stop sing-box.service || true
  systemctl daemon-reload || true
  systemctl reset-failed sing-box.service || true
  systemctl start sing-box.service || true
  sleep 5
  systemctl is-active --quiet sing-box.service
}

# Menu option 4. A held, unconfigured or first-time install is never checked or started; a
# configured one is only restarted after the new version accepts the config the service uses.
# With a config whose start-up arguments cannot be determined, nothing is installed.
upgrade_sing_box() {
  CURRENT_STEP='安装/升级 sing-box'
  local old_ver='' new_ver='' final_ver='' held_list='' held=false was_active=false has_config=false
  local hold_note='否' check_note='未检查' restart_note='否' downgrade_note='否' pkg_note='否' fail_reason=''
  local pid_before='' pid_after='' rollback=false pkg_restarted=false args_known=true a
  local -a target=() alerts=()

  capture_singbox_state
  configure_sagernet_repo
  apt_get update

  old_ver=$(singbox_installed_version) || old_ver=''
  SINGBOX_WAS_INSTALLED=false
  if [[ -n "$old_ver" ]]; then SINGBOX_WAS_INSTALLED=true; fi
  if systemctl is-active --quiet sing-box.service; then was_active=true; fi
  if singbox_has_config || [[ "$was_active" == true ]]; then has_config=true; fi
  held_list=$(apt-mark showhold) || die '无法读取 APT hold 状态。'
  if grep -Fxq sing-box <<<"$held_list"; then held=true; fi
  if [[ "$was_active" == true ]]; then pid_before=$(systemctl show -p MainPID --value sing-box.service 2>/dev/null) || pid_before=''; fi
  log "sing-box 当前：版本=${old_ver:-未安装}，运行=$was_active，配置=$has_config，hold=$held"
  if [[ "$held" == false && -n "$old_ver" && "$has_config" == true ]] && ! singbox_resolve_check; then args_known=false; fi

  if [[ "$held" == true ]]; then
    hold_note='是（已被 hold，跳过升级）'
    log 'sing-box 已被 hold，跳过升级。'
  elif [[ "$args_known" == false ]]; then
    check_note="无法确定（$SINGBOX_CHECK_REASON）"
    warn "无法确定服务的启动参数（原因：$SINGBOX_CHECK_REASON），为安全起见未升级，请手动升级。"
  else
    if [[ -n "$SING_BOX_VERSION" ]]; then
      singbox_repo_has_version "$SING_BOX_VERSION" || die "仓库中找不到 sing-box=$SING_BOX_VERSION。"
      target=(--allow-downgrades "sing-box=$SING_BOX_VERSION")
    elif [[ -n "$old_ver" ]]; then
      target=(--only-upgrade sing-box)
    else
      target=(sing-box)
    fi
    singbox_apt_install "${target[@]}" || die 'sing-box 安装/升级失败。'
    new_ver=$(singbox_installed_version) || die '安装后找不到 sing-box。'
    install -d -m 0755 "${SINGBOX_CONFIG%/*}"
    if [[ "$was_active" == true ]]; then
      pid_after=$(systemctl show -p MainPID --value sing-box.service 2>/dev/null) || pid_after=''
      if [[ "$pid_after" != "$pid_before" ]]; then
        pkg_restarted=true
        pkg_note="是（MainPID $pid_before → ${pid_after:-无}）"
        warn "软件包自行重启了服务（MainPID $pid_before → ${pid_after:-无}），policy-rc.d 没能拦住；立即检查配置。"
      fi
    fi
    if [[ -z "$old_ver" || "$SINGBOX_WAS_MANAGED" == true ]]; then
      configure_singbox_boot_gate
      remove_fresh_singbox_default_config
      mark_singbox_managed
    fi

    if [[ -z "$old_ver" ]]; then
      check_note='未检查（首次安装）'
    elif [[ "$has_config" == false ]]; then
      check_note='未检查（没有配置）'
    elif [[ "$new_ver" == "$old_ver" ]]; then
      check_note='未检查（版本未变化）'
    elif singbox_run_check; then
      check_note='通过'
      if [[ "$was_active" == true ]]; then
        systemctl daemon-reload || true
        systemctl restart sing-box.service || true
        sleep 5
        if systemctl is-active --quiet sing-box.service; then
          restart_note='是'
        else
          restart_note='失败'
          fail_reason=$(journalctl -u sing-box.service -n 15 --no-pager -o cat 2>&1 || true)
          rollback=true
        fi
      else
        restart_note='否（原本未运行）'
      fi
    else
      check_note='未通过'
      fail_reason=$SINGBOX_CHECK_OUTPUT
      rollback=true
    fi

    if [[ "$rollback" == true ]]; then
      if singbox_downgrade "$old_ver"; then
        downgrade_note="是（$new_ver → $old_ver）"
        warn "新版本 $new_ver 与现有配置不兼容，已回退到 $old_ver。"
        # A service the package restarted (or that is down) must be started again so the old version runs.
        if [[ "$was_active" == true ]] && { [[ "$pkg_restarted" == true ]] || ! systemctl is-active --quiet sing-box.service; }; then
          if singbox_start_after_downgrade; then
            if [[ "$pkg_restarted" == true ]]; then restart_note='软件包重启了服务，已回退并重新启动'; else restart_note='服务曾中断，已回退并重新启动'; fi
          else
            restart_note='服务中断，回退后仍未能启动'
          fi
        elif [[ "$restart_note" != 失败 ]]; then
          restart_note='否（原进程未动）'
        fi
      else
        downgrade_note="失败（仓库中找不到 $old_ver 或降级未成功）"
        if [[ "$was_active" == true ]] && ! systemctl is-active --quiet sing-box.service; then
          alerts+=("服务已中断，当前未运行；无法回退到 $old_ver，请先修改配置")
        elif [[ "$pkg_restarted" == true ]]; then
          alerts+=("软件包已自行重启服务，当前运行的是不兼容的新版本 $new_ver，且无法回退到 $old_ver，请先修改配置")
        else
          alerts+=("未重启，但下次开机将无法启动：重启后 sing-box 将无法启动，请先修改配置（新版本 $new_ver 与现有配置不兼容，无法回退到 $old_ver）")
        fi
      fi
      if [[ -n "$fail_reason" ]]; then
        warn '失败原因：'
        printf '%s\n' "$fail_reason" | head -n 30 >&2 || true
      fi
    fi
  fi

  final_ver=$(singbox_installed_version) || final_ver=''
  if [[ -n "$final_ver" ]]; then restore_singbox_state; fi
  if [[ "$was_active" == true ]] && ! systemctl is-active --quiet sing-box.service; then
    alerts+=('sing-box 服务已中断，当前未运行')
  fi

  ui_use_target out
  ui_box_top 'sing-box 安装/升级报告'
  ui_box_line "版本：${old_ver:-未安装} → ${final_ver:-未安装}"
  ui_box_line "hold：$hold_note"
  ui_box_line "配置检查：$check_note"
  ui_box_line "软件包自行重启服务：$pkg_note"
  ui_box_line "已重启：$restart_note"
  ui_box_line "已降级：$downgrade_note"
  ui_box_line "服务状态：$(systemctl is-active sing-box.service 2>/dev/null || true)"
  ui_box_line "开机自启：$(systemctl is-enabled sing-box.service 2>/dev/null || true)"
  ui_box_bottom
  for a in "${alerts[@]}"; do warn "!!! $a !!!"; done
  (( ${#alerts[@]} == 0 )) || die 'sing-box 升级未能恢复到可用状态，见上方告警。'
}

# Best-effort cleanup of a state file older versions wrote. It must never stop the run, so a file
# that cannot be backed up or made mutable is only reported.
remove_legacy_network_stack_state() {
  local path=$LEGACY_NETWORK_STACK_STATE backup out flags
  [[ -f "$path" && ! -L "$path" ]] || return 0
  if [[ -n "$BACKUP_DIR" ]]; then
    backup="$BACKUP_DIR/files$path"
    if [[ ! -e "$backup" ]] && ! { install -d -m 0700 "${backup%/*}" && cp -a -- "$path" "$backup"; }; then
      warn "无法备份旧版网络栈状态文件，保留：$path"
      return 0
    fi
  fi
  if command -v lsattr >/dev/null 2>&1 && command -v chattr >/dev/null 2>&1; then
    out=$(lsattr -d -- "$path" 2>/dev/null || true)
    flags=${out%% *}
    if [[ "$flags" == *i* || "$flags" == *a* ]] && ! chattr -i -a -- "$path"; then
      warn "无法解除旧版网络栈状态文件的 immutable/append-only 属性，保留：$path"
      return 0
    fi
  fi
  if rm -f -- "$path"; then
    log "已删除旧版网络栈状态文件：$path"
  else
    warn "无法删除旧版网络栈状态文件：$path"
  fi
  return 0
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
  local out=$1 transport=${2:-h2} aaaa_soa
  case "$NETWORK_STACK" in
    ipv4) aaaa_soa=yes ;;
    dual) aaaa_soa=no ;;
    *) die "内部错误：写 SmartDNS 配置时网络栈未确定（$NETWORK_STACK）。" ;;
  esac
  # Listen on IPv4 loopback only: it exists regardless of any later disable_ipv6 policy.
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
  if [[ "$NETWORK_STACK" == ipv4 ]]; then
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
refuse() { echo "WARNING: $1; existing Cloudflare 8443 rules were left unchanged." >&2; exit 1; }
for family in v4 v6; do
  curl -fsSL --proto '=https' --retry 3 --connect-timeout 10 --max-time 60 "https://www.cloudflare.com/ips-$family" -o "$TMP/$family" ||
    refuse "downloading the Cloudflare IP$family list failed"
done
# Nothing below is touched unless both lists pass: every line a real network CIDR of the right
# family, a plausible count, and no catch-all, private, loopback or multicast range.
python3 - "$TMP/v4" "$TMP/v6" <<'PY' || refuse 'the downloaded Cloudflare IP lists failed validation'
import ipaddress, sys
LIMITS = {4: (5, 100, 8), 6: (3, 100, 16)}  # version: (min entries, max entries, min prefix length)
for version, path in zip((4, 6), sys.argv[1:]):
    low, high, min_prefix = LIMITS[version]
    with open(path, encoding='ascii', errors='strict') as handle:
        lines = [line.strip() for line in handle if line.strip()]
    networks = set()
    for line in lines:
        if '/' not in line:
            raise SystemExit(f'IPv{version} list: not a CIDR: {line[:60]!r}')
        try:
            network = ipaddress.ip_network(line, strict=True)
        except ValueError as error:
            raise SystemExit(f'IPv{version} list: invalid CIDR {line[:60]!r}: {error}')
        if network.version != version:
            raise SystemExit(f'IPv{version} list: wrong address family: {line}')
        if network.prefixlen < min_prefix:
            raise SystemExit(f'IPv{version} list: range too wide: {line}')
        if (not network.is_global or network.is_private or network.is_loopback or
                network.is_link_local or network.is_multicast or network.is_reserved or
                network.is_unspecified):
            raise SystemExit(f'IPv{version} list: non-public range: {line}')
        networks.add(network)
    if not low <= len(networks) <= high:
        raise SystemExit(f'IPv{version} list: {len(networks)} entries, expected {low}-{high}')
    with open(f'{path}.ok', 'w', newline='\n') as out:
        out.write(''.join(f'{network}\n' for network in sorted(networks)))
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
while IFS= read -r cidr; do [[ -n "$cidr" ]] && ufw allow proto tcp from "$cidr" to any port 8443 comment "$COMMENT" >/dev/null; done <"$TMP/v4.ok"
if grep -Eq '^IPV6=yes' /etc/default/ufw 2>/dev/null; then
  while IFS= read -r cidr; do [[ -n "$cidr" ]] && ufw allow proto tcp from "$cidr" to any port 8443 comment "$COMMENT" >/dev/null; done <"$TMP/v6.ok"
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
    if [[ "$unit" == sing-box.service && "$enabled" == enabled ]] && ! singbox_has_config; then extra='；已启用，等待配置'; fi
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

audit_apt_policy() {
  LC_ALL=C apt-cache -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache= policy "$@" 2>/dev/null
}

audit_apt_version_sources() {
  printf '%s\n' "$2" | awk -v version="$1" '
    /^[ ]*Version table:[ ]*$/ { in_table=1; selected=0; next }
    !in_table { next }
    /^ \*\*\* / || /^     [^[:space:]]/ {
      current=($1 == "***" ? $2 : $1)
      selected=((current "") == (version ""))
      next
    }
    /^       [ ]*-?[0-9]+([[:space:]]|$)/ { if (selected) print; next }
    { selected=0 }
  '
}

audit_debian_package() {
  # Require the *installed version* to have an official origin in the local APT cache.
  # No network access. Unknown/obsolete versions are intentionally reported for review.
  local version policy sources
  version=$(dpkg-query -W -f='${Version}' -- "$1" 2>/dev/null) || return 1
  [[ -n "$version" ]] || return 1
  policy=$(audit_apt_policy -- "$1") || return 1
  sources=$(awk '
    /^[ ]*[0-9]+ / {source=$0; sub(/^[ ]*[0-9]+ /,"",source)}
    /release / && /(^|[, ])o=Debian([, ]|$)/ {print source}
  ' <<<"$AUDIT_APT_SOURCES")
  audit_apt_version_sources "$version" "$policy" | awk -v sources="$sources" '
    BEGIN {n=split(sources,s,"\n"); for(i=1;i<=n;i++) official[s[i]]=1}
    {sub(/^[ ]*-?[0-9]+[ ]+/,""); if(official[$0]) ok=1}
    END {exit !ok}'
}

audit_singbox_sagernet_origin() {
  local version policy
  version=$(dpkg-query -W -f='${Version}' -- sing-box 2>/dev/null) || return 1
  [[ -n "$version" ]] || return 1
  policy=$(audit_apt_policy -- sing-box) || return 1
  audit_apt_version_sources "$version" "$policy" | awk '
    $2 ~ /^https:\/\/deb\.sagernet\.org\/?$/ { found=1 }
    END { exit !found }
  '
}

audit_sagernet_repo_matches() {
  local source="$AUDIT_ROOT/etc/apt/sources.list.d/sagernet.sources"
  local key="$AUDIT_ROOT/etc/apt/keyrings/sagernet.gpg"
  local file status
  [[ -f "$source" && ! -L "$source" && -f "$key" && ! -L "$key" && -s "$key" ]] &&
    cmp -s -- "$source" <(sagernet_repo_source) || return 1
  for file in "$AUDIT_ROOT/etc/apt/sources.list" \
    "$AUDIT_ROOT/etc/apt/sources.list.d/"*.list "$AUDIT_ROOT/etc/apt/sources.list.d/"*.sources; do
    [[ "$file" != "$source" && -f "$file" ]] || continue
    status=0
    LC_ALL=C grep -Fqi -- sagernet.org "$file" 2>/dev/null || status=$?
    [[ "$status" == 1 ]] || return 1
  done
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
  AUDIT_APT_SOURCES=$(audit_apt_policy || true)
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
    if audit_debian_package "$package"; then continue; fi
    if [[ "$package" == sing-box ]] && audit_singbox_sagernet_origin; then
      if audit_sagernet_repo_matches; then continue; fi
      audit_add B package "$package" 'sing-box 来自 deb.sagernet.org，但源配置或密钥文件不是本工具写入的版本，请核实'
    else
      audit_add B package "$package" '本地缓存不能证明已安装版本来自 Debian 官方源（包括缓存缺失或旧版本），请核实'
    fi
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
  local mode=${1:-summary} level title desc level_color row count type target detail seen label help
  ui_use_target out
  printf '\n'
  ui_box_top '安全体检报告'
  for level in A B C; do
    if [[ "$level" != A ]]; then ui_box_sep; fi
    case "$level" in
      A)
        title='A 建议删除'
        desc='这些是登录钥匙或商家助手；确认不需要再处理，默认保留。'
        level_color="$C_YELLOW" ;;
      B)
        title='B 需要你看一眼'
        desc='这些有额外权限或后台行为；可能是你装的，只报告。'
        level_color="$C_CYAN" ;;
      C)
        title='C 严重异常'
        desc='这些会改变系统或登录信任；只报告，建议用官方系统重装。'
        level_color="${C_BOLD}${C_RED}" ;;
    esac
    count=0
    for row in "${AUDIT_FINDINGS[@]}"; do [[ "$row" != "$level"$'\t'* ]] || count=$((count + 1)); done
    ui_box_line_color "$level_color" "${title}（${count} 项）"
    ui_box_line_color "$C_DIM" "  ${desc}"
    if [[ "$mode" == full ]]; then
      seen=$'\n'
      for row in "${AUDIT_FINDINGS[@]}"; do
        [[ "$row" == "$level"$'\t'* ]] || continue
        IFS=$'\t' read -r _ type target detail <<<"$row"
        if [[ "$seen" != *$'\n'"$type"$'\n'* ]]; then
          seen+="$type"$'\n'
          label=$(audit_type_label "$type")
          help=$(audit_type_help "$type")
          ui_box_line "  ▸ ${label}：${help}" "  ${level_color}▸ ${label}${C_RESET}：${help}"
        fi
        ui_box_line "      - ${target} — ${detail}"
      done
    fi
  done
  ui_box_sep
  ui_box_line "当前会话公钥：${AUDIT_SESSION_KEY:-无法确定，禁止删除公钥}"
  ui_box_bottom
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
  done
  if (( ${#HARDENING_ACTIONS[@]} == 0 )); then
    rm -rf -- "$BACKUP_DIR"
    log '没有执行任何修改，已删除未使用的备份目录。'
    BACKUP_DIR=''
    return 0
  fi
  install -m 0600 /dev/null "$BACKUP_DIR/actions.txt"
  printf -- '- %s\n' "${HARDENING_ACTIONS[@]}" >"$BACKUP_DIR/actions.txt"
  collect_security_audit
  print_security_audit full >"$BACKUP_DIR/audit-after.txt"
  print_security_audit full
  printf '\n加固报告：\n'
  printf '  - %s\n' "${HARDENING_ACTIONS[@]}"
  log "备份与体检报告：$BACKUP_DIR（audit-before.txt、audit-after.txt、actions.txt）"
}

print_report() {
  local ssh_listeners fail2ban_status='已安装、自启并运行；sshd 和 sshd-slow 已验证'
  local ssh_display ufw_status smartdns_ver smartdns_mode singbox_ver tcp_cc tcp_qdisc swap_val sys_dns auto_sec reboot_needed
  local ipv6_lines line
  local ssh_warn=false ufw_warn=false smartdns_warn=false singbox_warn=false fail2ban_warn=false auto_sec_warn=false reboot_warn=false cleanup_warn=false
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
  ssh_display="${ssh_listeners:-未检测到}"
  if [[ "$PRESERVE_SSH" == true ]]; then ssh_display+='（保留现有配置）'; fi
  if [[ -z "$ssh_listeners" ]]; then ssh_warn=true; fi
  ufw_status=$(ufw status 2>/dev/null | sed -n '1p' || echo unavailable)
  if [[ "$ufw_status" != 'Status: active' ]]; then ufw_warn=true; fi
  smartdns_ver=$(smartdns -v 2>/dev/null | head -1 || echo unavailable)
  if [[ "$smartdns_ver" == unavailable ]]; then smartdns_warn=true; fi
  smartdns_mode="$([[ "$NETWORK_STACK" == ipv4 ]] && echo 'A only' || echo 'A + AAAA') / $SMARTDNS_TRANSPORT"
  singbox_ver=$(sing-box version 2>/dev/null | head -1 || echo unavailable)
  if [[ "$singbox_ver" == unavailable ]]; then singbox_warn=true; fi
  if [[ "$fail2ban_status" == *未安装* ]]; then fail2ban_warn=true; fi
  tcp_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unavailable)
  tcp_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unavailable)
  swap_val=$(awk '/SwapTotal:/ {printf "%.0f MiB", $2/1024}' /proc/meminfo)
  if [[ "$EARLY_DNS_FIXED" == true ]]; then
    sys_dns="已提前修复系统 DNS，原文件备份在 $EARLY_DNS_BACKUP"
  else
    sys_dns='未提前修复（系统 DNS 原本可用）'
  fi
  if security_updates_enabled; then auto_sec='已启用'; else auto_sec='未启用'; auto_sec_warn=true; fi
  if [[ -e /run/reboot-required ]]; then reboot_needed='yes'; reboot_warn=true; else reboot_needed='no'; fi
  if [[ "$SAFE_CLEANUP_RESULT" == *未全部完成* || "$SAFE_CLEANUP_RESULT" == 未执行 ]]; then cleanup_warn=true; fi
  ipv6_lines=$(ipv6_report_lines)

  ui_use_target out
  printf '\n'
  ui_box_top 'VPS 初始化完成'
  ui_box_line "脚本版本      : $SCRIPT_VERSION"
  ui_box_line "系统          : ${PRETTY_NAME:-Debian}"
  ui_box_line "网络栈        : $NETWORK_STACK（策略 $NETWORK_REQUEST）"
  if [[ "$NETWORK_REQUEST" == ipv4 ]]; then
    ui_box_line "内核 IPv6     : $IPV4_POLICY_STATUS"
  fi
  ui_box_kv 'SSH 实际监听  : ' "$ssh_display" "$ssh_warn"
  ui_box_kv 'UFW           : ' "$ufw_status" "$ufw_warn"
  ui_box_kv 'SmartDNS      : ' "$smartdns_ver" "$smartdns_warn"
  ui_box_line "SmartDNS 模式 : $smartdns_mode"
  ui_box_line 'SmartDNS 监听 : 127.0.0.1:53（UDP+TCP）'
  ui_box_line "备用 DNS      : $FALLBACK_DNS（resolv.conf 第二个 nameserver）"
  if [[ -n "$ipv6_lines" ]]; then
    while IFS= read -r line; do
      ui_box_line "$line"
    done <<<"$ipv6_lines"
  fi
  ui_box_kv 'sing-box      : ' "$singbox_ver" "$singbox_warn"
  ui_box_kv 'Fail2ban      : ' "$fail2ban_status" "$fail2ban_warn"
  ui_box_line "TCP / qdisc   : $tcp_cc / $tcp_qdisc"
  ui_box_line "Swap          : $swap_val"
  ui_box_line "系统 DNS      : $sys_dns"
  ui_box_line "备份目录      : $BACKUP_DIR"
  ui_box_kv '自动安全更新  : ' "$auto_sec" "$auto_sec_warn"
  ui_box_kv '需要重启      : ' "$reboot_needed" "$reboot_warn"
  ui_box_kv '安全清理      : ' "$SAFE_CLEANUP_RESULT" "$cleanup_warn"
  ui_box_line '重启后可运行 [7] 清理旧内核和无用包'
  ui_box_line '开机自启检查（不额外启动）：'
  if [[ -n "$BOOT_REPORT" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      if [[ "$line" == *失败* || "$line" == *'不是 active'* || "$line" == *未获得持久自启状态* || "$line" == *冲突* ]]; then
        ui_box_line "$line" "${C_YELLOW}${line}${C_RESET}"
      else
        ui_box_line "$line"
      fi
    done <<<"$BOOT_REPORT"
  fi
  ui_box_bottom
  printf '%s请保持当前 SSH 会话，并从另一终端验证所需的 SSH 监听地址和端口。%s\n' "$C_YELLOW" "$C_RESET"
}

select_install_mode() {
  [[ -z "$INSTALL_MODE" ]] || return 0
  local choice=''
  while true; do
    if ui_tty_writable; then
      ui_use_target tty
      {
        printf '\n'
        ui_box_top "404-vps-tools · debian-init.sh v$SCRIPT_VERSION"
        ui_menu_item 1 '快速初始化'
        ui_menu_item 2 '自定义初始化'
        ui_menu_item 3 '仅安装/更新 SmartDNS'
        ui_menu_item 4 '安装/升级 sing-box'
        ui_menu_item 5 '仅安装/更新 Fail2ban'
        ui_menu_item 6 '仅更新系统'
        ui_menu_item 7 '系统清理'
        ui_menu_item 8 '安全加固（体检 → 建议 → 确认后执行）' "$C_YELLOW"
        ui_menu_item 9 '重装为官方 Debian 13（会清空整机）' "${C_BOLD}${C_RED}"
        ui_menu_item 0 '退出' "$C_DIM"
        ui_box_bottom
      } >/dev/tty
      ui_use_target out
    fi
    read_tty '请选择 [0-9]: ' choice
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
      9) INSTALL_MODE=reinstall; return 0 ;;
      *) printf '无效选择。\n' >/dev/tty ;;
    esac
  done
}

collect_custom_phase_choice() {
  local choice=''
  while true; do
    if ui_tty_writable; then
      ui_use_target tty
      {
        printf '\n'
        ui_box_top '选择基础工具安装后的流程'
        ui_menu_item 1 '继续完整初始化'
        ui_menu_item 2 '完成基础工具后退出，用于测试 IP、线路和基础环境'
        ui_box_bottom
      } >/dev/tty
      ui_use_target out
    fi
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
  ui_use_target out
  printf '\n'
  ui_box_top '本次执行配置'
  ui_box_line "模式：${INSTALL_MODE}；仅基础工具：${BASE_ONLY}"
  ui_box_line "SSH：${ssh}"
  ui_box_line "公钥：${key}"
  ui_box_line "网络：${network}"
  ui_box_line "full-upgrade：${DO_FULL_UPGRADE}；Swap：${SWAP_CONFIRMED_MIB}MiB（0 表示不创建）"
  ui_box_line "自动安全更新：${AUTO_SECURITY}"
  if [[ "$NETWORK_REQUEST" == auto && "$BASE_ONLY" == false ]]; then
    case "$IPV6_BOOT_STATE:$IPV6_RESTORE_CHOICE" in
      off:restore) ui_box_line "重启后 IPv6：将被现有配置关闭；选择恢复，写入 ${NETWORK_SYSCTL} 覆盖，不改原文件" ;;
      off:keep) ui_box_line '重启后 IPv6：将被现有配置关闭；保留，Auto 按 ipv4 处理' ;;
      kernel-off:*) ui_box_line '重启后 IPv6：内核已禁用，按 ipv4 处理' ;;
      pending:*) ui_box_line '重启后 IPv6：迁移脚本旧策略后复查' ;;
    esac
  fi
  if [[ "$BASE_ONLY" == false ]]; then
    ui_box_line "DNS：SmartDNS 仅监听 127.0.0.1:53；resolv.conf 备用 ${FALLBACK_DNS}"
  fi
  ui_box_bottom
}

install_component_dependencies() {
  CURRENT_STEP='安装组件依赖'
  wait_for_package_manager
  apt_get update
  case "$INSTALL_MODE" in
    smartdns) apt_get install -y ca-certificates curl dnsutils iproute2 util-linux e2fsprogs ;;
    singbox) apt_get install -y ca-certificates curl gnupg util-linux e2fsprogs ;;
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
  install_component_dependencies
  remove_legacy_network_stack_state
  upgrade_sing_box
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
    {
      distributor=$0
      sub(/^[[:space:]]+/, "", distributor)
      sub(/[[:space:]]+$/, "", distributor)
      if (distributor == "GRUB_DISTRIBUTOR=`( . /etc/os-release && echo ${NAME} )`" ||
          distributor == "GRUB_DISTRIBUTOR=`lsb_release -i -s 2> /dev/null || echo Debian`") next
      unsafe=1
    }
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
    /^### BEGIN([[:space:]]|$)/ {
      if (section_end != "") { unsafe=1; next }
      if ($0 ~ /^### BEGIN .*\/10_linux ###$/) {
        standard=1
        linux_done=0
      } else if ($0 ~ /^### BEGIN \/etc\/grub\.d\/30_uefi-firmware ###$/) {
        if (!linux_done) unsafe=1
        firmware=1
      }
      if (standard || firmware) {
        section_end=$0
        sub(/^### BEGIN /, "### END ", section_end)
      }
      next
    }
    /^### END([[:space:]]|$)/ {
      if (section_end != "") {
        if ($0 != section_end) { unsafe=1; next }
        if (standard) linux_done=1
        section_end=""
        standard=firmware=0
      } else if ($0 ~ /^### END .*\/10_linux ###$/ ||
                 $0 ~ /^### END \/etc\/grub\.d\/30_uefi-firmware ###$/) {
        unsafe=1
      }
      next
    }
    /^[[:space:]]*source[[:space:]]/ && $0 !~ /^[[:space:]]*source[[:space:]]+\$\{?(prefix|config_directory)\}?\/custom\.cfg[[:space:]]*$/ { unsafe=1 }
    /^[[:space:]]*(configfile|chainloader|blscfg)([[:space:]]|$)/ { unsafe=1 }
    /^[[:space:]]*set default=/ && $0 !~ /^[[:space:]]*set default="(0|\$\{next_entry\})"[[:space:]]*$/ { unsafe=1 }
    /^[[:space:]]*set default="0"[[:space:]]*$/ { fallback=1 }
    /^[[:space:]]*(linux|linux16|linuxefi|initrd|initrd16|initrdefi)([[:space:]]|$)/ && firmware { unsafe=1 }
    /^[[:space:]]*(menuentry|submenu)[[:space:]]/ {
      if (firmware) {
        if (!entries || $0 !~ /^[[:space:]]*menuentry[[:space:]]+\047UEFI Firmware Settings\047([[:space:]]|$)/ ||
            ++firmware_entries > 1) unsafe=1
        next
      }
      if (!standard || (!entries && $1 != "menuentry")) unsafe=1
      entries++
    }
    /^[[:space:]]*linux[[:space:]]/ && entries == 1 && standard {
      if ($2 !~ /^\/(boot\/)?vmlinuz-[a-zA-Z0-9.+~-]+$/ || kernel != "") unsafe=1
      kernel=$2; sub(/^.*\/vmlinuz-/, "", kernel)
    }
    END { if (unsafe || section_end != "" || !fallback || kernel == "") exit 1; print kernel }
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
  if [[ -z "$candidates" ]]; then CLEANUP_RESULT='无需清理（仅保留当前、默认与备用内核）'; return; fi
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
  local before after total used orphans kernels gained swaps=''
  local before_display after_display='' space_status enough_space=false
  local CLEANUP_RESULT
  before=$(root_free_kib) || die '无法读取清理前的根分区空间。'
  IFS=' ' read -r total used < <(df -Pk / | awk 'NR == 2 { print $2, $3 }') || die '无法读取根分区容量。'
  before_display=$(format_mib "$before")
  printf '磁盘总容量：%s\n已用空间：%s\n可用空间：%s\n' "$(format_mib "$total")" "$(format_mib "$used")" "$before_display"
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
  if after=$(root_free_kib); then
    after_display=$(format_mib "$after")
    if (( after > before )); then
      gained=$(format_mib "$((after - before))")
    elif (( after == before )); then
      gained='0 MiB'
    else
      gained='约 0（清理期间有其他写入）'
    fi
    if (( after >= MIN_ROOT_FREE_KIB )); then
      enough_space=true
      space_status='PASS'
    else
      space_status="FAIL，还需释放 $(format_mib "$((MIN_ROOT_FREE_KIB - after))")"
    fi
  fi

  printf '\n'
  ui_use_target out
  ui_box_top '系统清理报告'
  ui_box_line "系统：Debian $VERSION_ID"
  ui_box_line "清理前可用：$before_display"
  if [[ -n "$after_display" ]]; then
    ui_box_line "清理后可用：$after_display"
    ui_box_line "实际增加可用空间：$gained"
    if [[ "$enough_space" == true ]]; then
      ui_box_line_color "$C_GREEN" "安装所需 2GiB 空间：$space_status"
    else
      ui_box_line_color "$C_RED" "安装所需 2GiB 空间：$space_status"
    fi
  else
    ui_box_line_color "$C_YELLOW" '清理后可用：读取失败'
  fi
  ui_box_line "APT 缓存：$SAFE_CLEANUP_APT"
  ui_box_line "Journal：$SAFE_CLEANUP_JOURNAL"
  ui_box_line "临时文件：$SAFE_CLEANUP_TMPFILES"
  ui_box_line "无用软件包：$orphans"
  ui_box_line "旧内核：$kernels"
  ui_box_line 'Swap：未修改'
  ui_box_bottom
  if [[ -z "$after_display" ]]; then warn '无法读取清理后的根分区空间。'; fi
}

# ==============================================================================
# 菜单 [9]：重装为官方 Debian 13（trixie）amd64，仅 KVM + BIOS，GPT 分区，无 swap。
# 只能从菜单进入，没有命令行参数。
#
# 测试专用开关：只读环境变量 VPS_INIT_REINSTALL_TEST（不写进 --help 和 README）
#   dry-run         完成检查、确认、下载校验和应答生成，打印 preseed、net.env 和网卡配置预览；
#                   不改 GRUB、不重启，结束时自动清理 /boot/404-reinstall*
#   selfcheck-fail  预期扇区数故意加 1，安装器分区前自检失败，等待 SELFCHECK_DELAY（120 秒）后重启回旧系统
#   no-reboot       完成全部准备（包括 GRUB 一次性启动项），但不重启
#   为空或未设置时正常运行；其他取值直接 die。
# ==============================================================================
readonly REINSTALL_SUITE='trixie'
readonly REINSTALL_ARCH='amd64'
readonly REINSTALL_MIRROR='https://deb.debian.org/debian'
readonly REINSTALL_GRUB_ENTRY_ID='reinstall-debian13'
readonly REINSTALL_MARK_BEGIN='### BEGIN 404-reinstall ###'
readonly REINSTALL_MARK_END='### END 404-reinstall ###'
readonly REINSTALL_SELFCHECK_TEST_DELAY=120
readonly REINSTALL_MIN_SECTORS=8388608
readonly -a REINSTALL_CURL_OPTS=(--proto '=https' --tlsv1.2 -fsSL --retry 3 --connect-timeout 15)
# Paths are plain variables (not readonly) so offline tests can point them at a temporary tree.
REINSTALL_SYS_ROOT='/sys'
REINSTALL_KEYRING_DIR='/usr/share/keyrings'
REINSTALL_KEYRING=''
REINSTALL_BOOT_DIR='/boot/404-reinstall'
REINSTALL_BOOT_TMP_DIR='/boot/404-reinstall.tmp'
REINSTALL_GRUB_CFG='/boot/grub/grub.cfg'
REINSTALL_CUSTOM_CFG='/boot/grub/custom.cfg'
REINSTALL_CUSTOM_BAK='/boot/grub/custom.cfg.404bak'
REINSTALL_KEXEC_DEFAULT='/etc/default/kexec'
REINSTALL_AUTHORIZED_KEYS=$AUTHORIZED_KEYS

REINSTALL_TEST_MODE=''
# true from the start of the download until right before reboot: every failure, Ctrl+C, HUP or
# TERM in that window runs reinstall_cleanup through the existing cleanup/die/on_signal paths.
REINSTALL_ARMED=false
REINSTALL_STAGE_DIR=''
REINSTALL_HOST=''
REINSTALL_NEW_HOST=''
REINSTALL_HOST_VALID=true
REINSTALL_NEED_GPGV=false
REINSTALL_DISK=''
REINSTALL_DISK_SECTORS=0
REINSTALL_DISK_SIZE=''
REINSTALL_GRUB_FS=''
REINSTALL_V4_MODE=''
REINSTALL_V4_IFACE=''
REINSTALL_V4_ADDR=''
REINSTALL_V4_PREFIX=''
REINSTALL_V4_NETMASK=''
REINSTALL_V4_GW=''
REINSTALL_V4_MAC=''
REINSTALL_V6_MODE='none'
REINSTALL_V6_IFACE=''
REINSTALL_V6_ADDR=''
REINSTALL_V6_GW=''
REINSTALL_V6_EXTRA=''
REINSTALL_V6_MAC=''
REINSTALL_KEYS_DISCARDED=0
REINSTALL_ROOT_PASS=''
REINSTALL_ROOT_HASH=''
declare -a REINSTALL_KEYS=() REINSTALL_KEY_FPS=() REINSTALL_KEY_HAS_OPTS=() REINSTALL_LEFTOVERS=() REINSTALL_CUSTOM_TMPS=()

# Overridable wrapper so offline tests can feed recorded `ip` output.
reinstall_ip() {
  ip "$@"
}

reinstall_fail() {
  local IFS=' '
  die "无法重装：$*"
}

# Join arguments with single spaces. The script runs with IFS=$'\n\t', so a bare "${arr[*]}"
# would put each element on its own line.
reinstall_join() {
  local IFS=' '
  printf '%s' "$*"
}

# Dotted-quad IPv4 with four fields of 0-255.
reinstall_is_ipv4() {
  local IFS=. part
  local -a parts=()
  [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
  read -r -a parts <<<"$1"
  for part in "${parts[@]}"; do
    (( 10#$part <= 255 )) || return 1
  done
}

reinstall_parse_test_mode() {
  case "${VPS_INIT_REINSTALL_TEST:-}" in
    '') REINSTALL_TEST_MODE='' ;;
    dry-run|selfcheck-fail|no-reboot) REINSTALL_TEST_MODE=$VPS_INIT_REINSTALL_TEST ;;
    *) die "VPS_INIT_REINSTALL_TEST 取值无效：${VPS_INIT_REINSTALL_TEST}（仅支持 dry-run、selfcheck-fail、no-reboot）。" ;;
  esac
}

# ---- 遗留检测与清理 ----------------------------------------------------------

reinstall_strip_mark_block() {
  awk -v b="$REINSTALL_MARK_BEGIN" -v e="$REINSTALL_MARK_END" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip { print }
  ' "$1"
}

reinstall_custom_cfg_has_mark() {
  [[ -f "$REINSTALL_CUSTOM_CFG" ]] && grep -Fxq -- "$REINSTALL_MARK_BEGIN" "$REINSTALL_CUSTOM_CFG"
}

reinstall_next_entry_is_ours() {
  command -v grub-editenv >/dev/null 2>&1 || return 1
  grub-editenv list 2>/dev/null | grep -Fxq -- "next_entry=$REINSTALL_GRUB_ENTRY_ID"
}

# Temporary custom.cfg rewrites (mktemp next to custom.cfg) left behind by an interrupted run.
reinstall_custom_tmp_files() {
  local f
  REINSTALL_CUSTOM_TMPS=()
  for f in "$REINSTALL_CUSTOM_CFG".404tmp.*; do
    if [[ -e "$f" || -L "$f" ]]; then REINSTALL_CUSTOM_TMPS+=("$f"); fi
  done
  (( ${#REINSTALL_CUSTOM_TMPS[@]} > 0 ))
}

# Fill REINSTALL_LEFTOVERS; succeed when any of the six signals is present. The custom.cfg
# backup is tested with -f here and in reinstall_cleanup alike.
reinstall_detect_leftover() {
  REINSTALL_LEFTOVERS=()
  if [[ -e "$REINSTALL_BOOT_DIR" ]]; then REINSTALL_LEFTOVERS+=("$REINSTALL_BOOT_DIR"); fi
  if [[ -e "$REINSTALL_BOOT_TMP_DIR" ]]; then REINSTALL_LEFTOVERS+=("$REINSTALL_BOOT_TMP_DIR"); fi
  if reinstall_custom_cfg_has_mark; then REINSTALL_LEFTOVERS+=("$REINSTALL_CUSTOM_CFG 中的 404-reinstall 启动项"); fi
  if reinstall_next_entry_is_ours; then REINSTALL_LEFTOVERS+=("GRUB next_entry=$REINSTALL_GRUB_ENTRY_ID"); fi
  if [[ -f "$REINSTALL_CUSTOM_BAK" ]]; then REINSTALL_LEFTOVERS+=("$REINSTALL_CUSTOM_BAK（custom.cfg 备份）"); fi
  if reinstall_custom_tmp_files; then REINSTALL_LEFTOVERS+=("${REINSTALL_CUSTOM_TMPS[@]}"); fi
  (( ${#REINSTALL_LEFTOVERS[@]} > 0 ))
}

# Remove everything a reinstall preparation may have created. Safe to run repeatedly, and it
# only touches custom.cfg / next_entry when they carry this script's marker or entry id.
reinstall_cleanup() {
  local tmp
  if [[ -n "$REINSTALL_STAGE_DIR" ]]; then rm -rf -- "$REINSTALL_STAGE_DIR"; fi
  REINSTALL_STAGE_DIR=''
  rm -rf -- "$REINSTALL_BOOT_DIR" "$REINSTALL_BOOT_TMP_DIR"
  if reinstall_custom_tmp_files; then
    rm -f -- "${REINSTALL_CUSTOM_TMPS[@]}"
    log '已删除中断留下的 custom.cfg 临时文件'
  fi
  if [[ -f "$REINSTALL_CUSTOM_BAK" ]]; then
    mv -f -- "$REINSTALL_CUSTOM_BAK" "$REINSTALL_CUSTOM_CFG"
    log "已从备份还原 $REINSTALL_CUSTOM_CFG"
  elif reinstall_custom_cfg_has_mark; then
    tmp=$(mktemp "$REINSTALL_CUSTOM_CFG.404tmp.XXXXXX")
    reinstall_strip_mark_block "$REINSTALL_CUSTOM_CFG" >"$tmp"
    if grep -q '[^[:space:]]' "$tmp"; then
      chmod 0644 -- "$tmp"
      mv -f -- "$tmp" "$REINSTALL_CUSTOM_CFG"
      log "已移除 $REINSTALL_CUSTOM_CFG 中的 404-reinstall 启动项"
    else
      rm -f -- "$tmp" "$REINSTALL_CUSTOM_CFG"
      log "已删除只含 404-reinstall 启动项的 $REINSTALL_CUSTOM_CFG"
    fi
  fi
  if reinstall_next_entry_is_ours; then
    grub-editenv - unset next_entry
    log '已清除 GRUB next_entry'
  fi
}

# Called from cleanup, die and on_signal while REINSTALL_ARMED is true.
reinstall_abort_cleanup() {
  [[ "${REINSTALL_ARMED:-false}" == true ]] || return 0
  REINSTALL_ARMED=false
  trap '' HUP INT TERM
  warn '重装准备未完成，正在清理已下载的文件和 GRUB 启动项。'
  reinstall_cleanup || true
  if reinstall_detect_leftover; then
    warn "仍有遗留：$(reinstall_join "${REINSTALL_LEFTOVERS[@]}")；请重新运行 [9] 清除，或手动删除后再重启。"
  else
    warn '已清理，系统启动项未改变。'
  fi
}

reinstall_check_leftover() {
  local item
  reinstall_detect_leftover || return 0
  warn '检测到上次未完成的重装准备（下次重启可能会清空整机）'
  for item in "${REINSTALL_LEFTOVERS[@]}"; do warn "  - $item"; done
  if ! ask_yes_no '是否清除这些遗留？' true; then
    log '已保留上次的重装准备，未做任何修改。'
    exit 0
  fi
  acquire_lock
  reinstall_cleanup
  if reinstall_detect_leftover; then
    reinstall_fail "清除后仍有遗留：$(reinstall_join "${REINSTALL_LEFTOVERS[@]}")"
  fi
  log '已清除上次的重装准备。'
}

# ---- 环境检查（只读） --------------------------------------------------------

reinstall_ip4_to_int() {
  local IFS=.
  local a b c d
  read -r a b c d <<<"$1"
  printf '%u\n' $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

reinstall_prefix_to_mask4() {
  local p=$1 mask=0
  if (( p > 0 )); then mask=$(( (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF )); fi
  printf '%d.%d.%d.%d\n' $(( (mask >> 24) & 255 )) $(( (mask >> 16) & 255 )) $(( (mask >> 8) & 255 )) $(( mask & 255 ))
}

reinstall_ipv4_in_subnet() {
  local ip_i gw_i mask_i=0 prefix=$2
  ip_i=$(reinstall_ip4_to_int "$1")
  gw_i=$(reinstall_ip4_to_int "$3")
  if (( prefix > 0 )); then mask_i=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF )); fi
  (( (ip_i & mask_i) == (gw_i & mask_i) ))
}

# Print the word after $1 in the route line $2 (e.g. "via", "dev", "src").
reinstall_route_field() {
  awk -v k="$1" '{ for (i = 1; i < NF; i++) if ($i == k) { print $(i + 1); exit } }' <<<"$2"
}

# 1. root（已在入口检查）、Debian 12/13、amd64
reinstall_check_system() {
  local os_id='' os_ver='' arch
  [[ -r /etc/os-release ]] || reinstall_fail '无法读取 /etc/os-release'
  os_id=$(awk -F= '$1 == "ID" { gsub(/"/, "", $2); print $2 }' /etc/os-release)
  os_ver=$(awk -F= '$1 == "VERSION_ID" { gsub(/"/, "", $2); print $2 }' /etc/os-release)
  if [[ "$os_id" != debian || ! "$os_ver" =~ ^(12|13)$ ]]; then
    reinstall_fail "仅支持 Debian 12 或 13（当前 ID=${os_id:-未知} VERSION_ID=${os_ver:-未知}）"
  fi
  command -v dpkg >/dev/null 2>&1 || reinstall_fail '缺少 dpkg，无法确认架构'
  arch=$(dpkg --print-architecture 2>/dev/null || true)
  [[ "$arch" == amd64 ]] || reinstall_fail "仅支持 amd64 架构（当前 ${arch:-未知}）"
}

# 2. KVM、非容器、无 /proc/vz
reinstall_check_virt() {
  local virt
  command -v systemd-detect-virt >/dev/null 2>&1 || reinstall_fail '缺少 systemd-detect-virt，无法确认虚拟化环境'
  virt=$(systemd-detect-virt 2>/dev/null || true)
  [[ "$virt" == kvm ]] || reinstall_fail "仅支持 KVM 虚拟化（当前 systemd-detect-virt=${virt:-unknown}）"
  if systemd-detect-virt -qc 2>/dev/null; then reinstall_fail '不支持容器环境'; fi
  [[ ! -e /proc/vz ]] || reinstall_fail '不支持 OpenVZ 环境（检测到 /proc/vz）'
}

# 3. 仅 BIOS
reinstall_check_firmware() {
  [[ ! -d "$REINSTALL_SYS_ROOT/firmware/efi" ]] || reinstall_fail "检测到 $REINSTALL_SYS_ROOT/firmware/efi（当前仅支持 BIOS 启动）"
}

# 4. 内存 >= 512 MiB
reinstall_check_memory() {
  local mem_kb
  mem_kb=$(awk '$1 == "MemTotal:" { print $2 }' /proc/meminfo)
  if [[ ! "$mem_kb" =~ ^[0-9]+$ ]] || (( mem_kb < 524288 )); then
    reinstall_fail "内存不足 512 MiB（MemTotal=${mem_kb:-0} KiB）"
  fi
}

# 5b. 目标盘 >= 4 GiB，且同扇区数的块设备恰好 1 块（读 REINSTALL_SYS_ROOT）
reinstall_check_disk_sizes() {
  local disk=$1 sectors blk name size count=0
  [[ -r "$REINSTALL_SYS_ROOT/block/$disk/size" ]] || reinstall_fail "无法读取目标盘 /dev/$disk 的扇区数"
  sectors=$(<"$REINSTALL_SYS_ROOT/block/$disk/size")
  if [[ ! "$sectors" =~ ^[0-9]+$ ]] || (( sectors < REINSTALL_MIN_SECTORS )); then
    reinstall_fail "目标盘 /dev/$disk 小于 4 GiB（扇区数 ${sectors:-0}）"
  fi
  for blk in "$REINSTALL_SYS_ROOT"/block/*; do
    [[ -r "$blk/size" ]] || continue
    name=${blk##*/}
    case "$name" in loop*|ram*|zram*|sr*|nbd*|fd*) continue ;; esac
    size=$(<"$blk/size")
    if [[ "$size" == "$sectors" ]]; then count=$((count + 1)); fi
  done
  if (( count != 1 )); then
    reinstall_fail "与目标盘 /dev/$disk 扇区数（$sectors）相同的块设备有 $count 块，要求恰好 1 块"
  fi
  REINSTALL_DISK=$disk
  REINSTALL_DISK_SECTORS=$sectors
}

# 5. 根分区必须是普通分区，取其所在整盘
reinstall_check_disk() {
  local root_src disk size
  root_src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
  [[ -n "$root_src" ]] || reinstall_fail '无法识别根分区设备'
  if [[ ! "$root_src" =~ ^/dev/(vd[a-z]+[0-9]+|sd[a-z]+[0-9]+|nvme[0-9]+n[0-9]+p[0-9]+)$ ]]; then
    reinstall_fail "根分区不是普通分区（当前 $root_src，不支持 dm/md 等设备）"
  fi
  disk=$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -n 1 || true)
  [[ -n "$disk" ]] || reinstall_fail "无法获取根分区所在整盘（root=$root_src）"
  reinstall_check_disk_sizes "$disk"
  size=$(lsblk -ndo SIZE "/dev/$disk" 2>/dev/null | tr -d '[:space:]' || true)
  REINSTALL_DISK_SIZE=${size:-"$REINSTALL_DISK_SECTORS 扇区"}
}

# 6. GRUB：工具、next_entry 与 41_custom 逻辑、无抽象层、ext2/xfs
reinstall_check_grub() {
  local cmd abstraction
  for cmd in grub-reboot grub-editenv grub-probe grub-mkrelpath; do
    command -v "$cmd" >/dev/null 2>&1 || reinstall_fail "缺少 GRUB 工具：$cmd"
  done
  [[ -r "$REINSTALL_GRUB_CFG" ]] || reinstall_fail "缺少 $REINSTALL_GRUB_CFG"
  grep -Fq 'next_entry' "$REINSTALL_GRUB_CFG" || reinstall_fail "$REINSTALL_GRUB_CFG 中没有 next_entry 逻辑"
  grep -Fq '41_custom' "$REINSTALL_GRUB_CFG" || reinstall_fail "$REINSTALL_GRUB_CFG 中没有 41_custom"
  abstraction=$(grub-probe --target=abstraction /boot/grub 2>/dev/null || true)
  [[ -z "$abstraction" ]] || reinstall_fail "/boot/grub 使用了不支持的抽象层（$abstraction）"
  REINSTALL_GRUB_FS=$(grub-probe --target=fs /boot/grub 2>/dev/null || true)
  if [[ "$REINSTALL_GRUB_FS" != ext2 && "$REINSTALL_GRUB_FS" != xfs ]]; then
    reinstall_fail "/boot/grub 文件系统不支持（当前 ${REINSTALL_GRUB_FS:-unknown}，仅支持 ext2/3/4 和 xfs）"
  fi
}

# 7. kexec 不能绕过 GRUB
# Matches LOAD_KEXEC=true, LOAD_KEXEC="true" and LOAD_KEXEC='true'.
reinstall_check_kexec() {
  if [[ -f "$REINSTALL_KEXEC_DEFAULT" ]] &&
    grep -Eq "^[[:space:]]*LOAD_KEXEC[[:space:]]*=[[:space:]]*[\"']?true[\"']?" "$REINSTALL_KEXEC_DEFAULT"; then
    reinstall_fail "$REINSTALL_KEXEC_DEFAULT 启用了 LOAD_KEXEC=true，重启会绕过 GRUB"
  fi
}

# Prefer debian-archive-keyring.gpg, fall back to the .pgp next to it (Debian 13 ships .pgp).
reinstall_pick_keyring() {
  local candidate
  REINSTALL_KEYRING=''
  for candidate in "$REINSTALL_KEYRING_DIR/debian-archive-keyring.gpg" "$REINSTALL_KEYRING_DIR/debian-archive-keyring.pgp"; do
    if [[ -r "$candidate" ]]; then
      REINSTALL_KEYRING=$candidate
      return 0
    fi
  done
  reinstall_fail "缺少 Debian 密钥环：$REINSTALL_KEYRING_DIR/debian-archive-keyring.gpg 或 .pgp"
}

# 8. 工具与密钥环。gpgv 不是必需项：Debian 13 的 apt 改用 sqv，缺少时确认后再安装。
reinstall_check_tools() {
  local cmd
  for cmd in curl cpio gzip sha256sum openssl ssh-keygen wc stty; do
    command -v "$cmd" >/dev/null 2>&1 || reinstall_fail "缺少必要工具：$cmd"
  done
  REINSTALL_NEED_GPGV=false
  if ! command -v gpgv >/dev/null 2>&1; then REINSTALL_NEED_GPGV=true; fi
  reinstall_pick_keyring
}

# 9. /boot 所在文件系统剩余 >= 200 MiB
reinstall_check_boot_space() {
  local avail
  avail=$(df -Pk /boot 2>/dev/null | awk 'NR == 2 { print $4 }')
  if [[ ! "$avail" =~ ^[0-9]+$ ]] || (( avail < 204800 )); then
    reinstall_fail "/boot 所在文件系统剩余空间不足 200 MiB（当前 $(( ${avail:-0} / 1024 )) MiB）"
  fi
}

# Print the options field of an authorized_keys line (empty when the line starts with the key
# type). The field ends at the first whitespace outside double quotes; \" inside quotes is kept.
reinstall_key_options() {
  local line=$1 first ch opts='' quoted=false i
  line=${line#"${line%%[![:space:]]*}"}
  first=${line%%[[:space:]]*}
  if [[ "$first" =~ ^(ssh-|ecdsa-|sk-) ]]; then return 0; fi
  for (( i = 0; i < ${#line}; i++ )); do
    ch=${line:i:1}
    if [[ "$quoted" == true && "$ch" == "\\" ]]; then
      opts+=${line:i:2}
      i=$((i + 1))
      continue
    fi
    if [[ "$ch" == '"' ]]; then
      if [[ "$quoted" == true ]]; then quoted=false; else quoted=true; fi
    elif [[ "$quoted" == false && ( "$ch" == ' ' || "$ch" == $'\t' ) ]]; then
      break
    fi
    opts+=$ch
  done
  printf '%s' "$opts"
}

# Succeed when an options field contains command= or restrict (option names are case-insensitive).
reinstall_key_options_restricted() {
  local opts=$1 ch name='' in_name=true quoted=false i
  for (( i = 0; i <= ${#opts}; i++ )); do
    ch=${opts:i:1}
    if [[ "$quoted" == true ]]; then
      if [[ "$ch" == "\\" ]]; then i=$((i + 1)); elif [[ "$ch" == '"' ]]; then quoted=false; fi
      continue
    fi
    if [[ -z "$ch" || "$ch" == ',' ]]; then
      name=${name,,}
      if [[ "$name" == command || "$name" == restrict ]]; then return 0; fi
      name='' in_name=true
      continue
    fi
    if [[ "$ch" == '"' ]]; then quoted=true; continue; fi
    if [[ "$ch" == '=' ]]; then in_name=false; continue; fi
    if [[ "$in_name" == true ]]; then name+=$ch; fi
  done
  return 1
}

# 10. root 的 authorized_keys：有效行原样保留（含 options），且至少一把不带 command=/restrict
reinstall_check_keys() {
  local line fp opts usable=0
  REINSTALL_KEYS=() REINSTALL_KEY_FPS=() REINSTALL_KEY_HAS_OPTS=() REINSTALL_KEYS_DISCARDED=0
  [[ -r "$REINSTALL_AUTHORIZED_KEYS" ]] || reinstall_fail "不存在可读的 $REINSTALL_AUTHORIZED_KEYS"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    if [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]]; then
      REINSTALL_KEYS_DISCARDED=$((REINSTALL_KEYS_DISCARDED + 1))
      continue
    fi
    if fp=$(printf '%s\n' "$line" | ssh-keygen -l -f - 2>/dev/null) && [[ -n "$fp" ]]; then
      opts=$(reinstall_key_options "$line")
      REINSTALL_KEYS+=("$line")
      REINSTALL_KEY_FPS+=("$fp")
      if [[ -n "$opts" ]]; then REINSTALL_KEY_HAS_OPTS+=(true); else REINSTALL_KEY_HAS_OPTS+=(false); fi
      if [[ -z "$opts" ]] || ! reinstall_key_options_restricted "$opts"; then usable=$((usable + 1)); fi
    else
      REINSTALL_KEYS_DISCARDED=$((REINSTALL_KEYS_DISCARDED + 1))
    fi
  done <"$REINSTALL_AUTHORIZED_KEYS"
  log "公钥检查：有效 ${#REINSTALL_KEYS[@]} 把（可交互登录 $usable 把），丢弃空行/注释/无效行 $REINSTALL_KEYS_DISCARDED 行"
  (( ${#REINSTALL_KEYS[@]} > 0 )) || reinstall_fail "$REINSTALL_AUTHORIZED_KEYS 中没有有效的 SSH 公钥"
  (( usable > 0 )) || reinstall_fail '没有可用于交互登录的公钥（全部带有 command= 或 restrict 限制）'
}

# 11. IPv4（必须有）：恰好 1 条默认路由、默认网卡上恰好 1 个全局地址
reinstall_check_ipv4() {
  local -a v4_routes=() v4_addrs=()
  local route cidr
  mapfile -t v4_routes < <(reinstall_ip -4 route show default | sed '/^[[:space:]]*$/d' || true)
  (( ${#v4_routes[@]} == 1 )) || reinstall_fail "IPv4 默认路由必须恰好 1 条（当前 ${#v4_routes[@]} 条）"
  route=${v4_routes[0]}
  REINSTALL_V4_GW=$(reinstall_route_field via "$route")
  REINSTALL_V4_IFACE=$(reinstall_route_field dev "$route")
  if [[ -z "$REINSTALL_V4_GW" || -z "$REINSTALL_V4_IFACE" ]]; then
    reinstall_fail "无法解析 IPv4 默认路由的网关或网卡（$route）"
  fi
  # e.g. RFC 5549 "default via inet6 fe80::1": the word after via is not an IPv4 address.
  reinstall_is_ipv4 "$REINSTALL_V4_GW" || reinstall_fail 'IPv4 默认路由的网关不是 IPv4 地址，暂不支持'
  mapfile -t v4_addrs < <(reinstall_ip -4 -o addr show scope global dev "$REINSTALL_V4_IFACE" | sed '/^[[:space:]]*$/d' || true)
  if (( ${#v4_addrs[@]} != 1 )); then
    reinstall_fail "IPv4 默认网卡 $REINSTALL_V4_IFACE 上的全局地址必须恰好 1 个（当前 ${#v4_addrs[@]} 个）"
  fi
  cidr=$(awk '{ print $4 }' <<<"${v4_addrs[0]}")
  REINSTALL_V4_ADDR=${cidr%/*}
  REINSTALL_V4_PREFIX=${cidr#*/}
  reinstall_is_ipv4 "$REINSTALL_V4_ADDR" || reinstall_fail "IPv4 地址不是合法的 IPv4 地址（$cidr），暂不支持"
  if [[ "$cidr" != */* || ! "$REINSTALL_V4_PREFIX" =~ ^[0-9]{1,2}$ ]] || (( 10#$REINSTALL_V4_PREFIX > 32 )); then
    reinstall_fail "无法解析 IPv4 地址/前缀（$cidr）"
  fi
  REINSTALL_V4_PREFIX=$((10#$REINSTALL_V4_PREFIX))
  REINSTALL_V4_NETMASK=$(reinstall_prefix_to_mask4 "$REINSTALL_V4_PREFIX")
  if grep -qw dynamic <<<"${v4_addrs[0]}"; then
    REINSTALL_V4_MODE='dhcp'
  else
    REINSTALL_V4_MODE='static'
    if (( REINSTALL_V4_PREFIX != 32 )) &&
      ! reinstall_ipv4_in_subnet "$REINSTALL_V4_ADDR" "$REINSTALL_V4_PREFIX" "$REINSTALL_V4_GW"; then
      reinstall_fail 'IPv4 网关不在本网段，第一版不支持'
    fi
  fi
}

# 12. IPv6（可选）：0 条默认路由不配置，多于 1 条拒绝
reinstall_check_ipv6() {
  local -a v6_routes=() v6_addrs=() cidrs=() extras=()
  local route line dynamic=false src c
  REINSTALL_V6_MODE='none' REINSTALL_V6_IFACE='' REINSTALL_V6_ADDR='' REINSTALL_V6_GW='' REINSTALL_V6_EXTRA=''
  mapfile -t v6_routes < <(reinstall_ip -6 route show default | sed '/^[[:space:]]*$/d' || true)
  if (( ${#v6_routes[@]} == 0 )); then
    log '未检测到 IPv6 默认路由，重装后不配置 IPv6'
    return 0
  fi
  (( ${#v6_routes[@]} == 1 )) || reinstall_fail "存在多条 IPv6 默认路由（当前 ${#v6_routes[@]} 条）"
  route=${v6_routes[0]}
  REINSTALL_V6_GW=$(reinstall_route_field via "$route")
  REINSTALL_V6_IFACE=$(reinstall_route_field dev "$route")
  if [[ -z "$REINSTALL_V6_GW" || -z "$REINSTALL_V6_IFACE" ]]; then
    reinstall_fail "无法解析 IPv6 默认路由的网关或网卡（$route）"
  fi
  mapfile -t v6_addrs < <(reinstall_ip -6 -o addr show scope global dev "$REINSTALL_V6_IFACE" |
    grep -Evw 'temporary|deprecated|tentative' | sed '/^[[:space:]]*$/d' || true)
  (( ${#v6_addrs[@]} > 0 )) || reinstall_fail "IPv6 默认网卡 $REINSTALL_V6_IFACE 上没有可用的全局 IPv6 地址"
  for line in "${v6_addrs[@]}"; do
    if grep -qw dynamic <<<"$line"; then dynamic=true; break; fi
  done
  if [[ "$dynamic" == true ]]; then
    REINSTALL_V6_MODE='auto'
    REINSTALL_V6_ADDR=$(awk '{ print $4 }' <<<"${v6_addrs[0]}")
    return 0
  fi
  REINSTALL_V6_MODE='static'
  for line in "${v6_addrs[@]}"; do cidrs+=("$(awk '{ print $4 }' <<<"$line")"); done
  src=$(reinstall_ip -6 route get 2001:4860:4860::8888 2>/dev/null || true)
  src=$(reinstall_route_field src "$src")
  if [[ -n "$src" ]]; then
    for c in "${cidrs[@]}"; do
      if [[ "${c%/*}" == "$src" ]]; then REINSTALL_V6_ADDR=$c; break; fi
    done
  fi
  REINSTALL_V6_ADDR=${REINSTALL_V6_ADDR:-${cidrs[0]}}
  for c in "${cidrs[@]}"; do
    if [[ "$c" != "$REINSTALL_V6_ADDR" ]]; then extras+=("$c"); fi
  done
  if (( ${#extras[@]} > 0 )); then
    REINSTALL_V6_EXTRA=$(printf '%s ' "${extras[@]}")
    REINSTALL_V6_EXTRA=${REINSTALL_V6_EXTRA% }
  fi
}

# 13. 网卡 MAC 与短主机名
reinstall_check_identity() {
  local path="$REINSTALL_SYS_ROOT/class/net/$REINSTALL_V4_IFACE/address"
  [[ -r "$path" ]] || reinstall_fail "无法读取 IPv4 网卡 $REINSTALL_V4_IFACE 的 MAC 地址"
  REINSTALL_V4_MAC=$(tr '[:upper:]' '[:lower:]' <"$path")
  REINSTALL_V6_MAC=''
  if [[ "$REINSTALL_V6_MODE" != none ]]; then
    path="$REINSTALL_SYS_ROOT/class/net/$REINSTALL_V6_IFACE/address"
    [[ -r "$path" ]] || reinstall_fail "无法读取 IPv6 网卡 $REINSTALL_V6_IFACE 的 MAC 地址"
    REINSTALL_V6_MAC=$(tr '[:upper:]' '[:lower:]' <"$path")
  fi
  REINSTALL_HOST=$(hostname -s 2>/dev/null || true)
  [[ -n "$REINSTALL_HOST" ]] || reinstall_fail '无法获取本机短主机名（hostname -s）'
  reinstall_pick_new_hostname
}

# The new system gets the lowercased short hostname when it is a valid label, otherwise "debian".
# Confirmation still asks for the current `hostname -s` as typed.
reinstall_pick_new_hostname() {
  local lower=${REINSTALL_HOST,,}
  if [[ "$lower" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
    REINSTALL_NEW_HOST=$lower
    REINSTALL_HOST_VALID=true
  else
    REINSTALL_NEW_HOST='debian'
    REINSTALL_HOST_VALID=false
  fi
}

# Read-only checks. Unlike preflight, this creates no backup directory or temporary files.
reinstall_preflight() {
  CURRENT_STEP='重装环境检查'
  reinstall_parse_test_mode
  # Same rule as preflight: gpgv may have to be installed through apt_get later.
  if [[ ! "$APT_WAIT_MAX" =~ ^[0-9]+$ ]] || (( APT_WAIT_MAX < 60 )); then die 'VPS_INIT_APT_WAIT 必须是 >=60 的整数秒。'; fi
  (( EUID == 0 )) || reinstall_fail '必须以 root 身份运行'
  reinstall_check_leftover
  CURRENT_STEP='重装环境检查'
  log '开始重装环境检查（只读）...'
  reinstall_check_system
  reinstall_check_virt
  reinstall_check_firmware
  reinstall_check_memory
  reinstall_check_disk
  reinstall_check_grub
  reinstall_check_kexec
  reinstall_check_tools
  reinstall_check_boot_space
  reinstall_check_keys
  reinstall_check_ipv4
  reinstall_check_ipv6
  reinstall_check_identity
  log '重装环境检查全部通过。'
}

# ---- 摘要与确认 --------------------------------------------------------------

reinstall_generate_password() {
  local buf=''
  while (( ${#buf} < 20 )); do
    buf+=$(dd if=/dev/urandom bs=512 count=1 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' || true)
  done
  REINSTALL_ROOT_PASS=${buf:0:20}
  REINSTALL_ROOT_HASH=$(printf '%s' "$REINSTALL_ROOT_PASS" | openssl passwd -6 -stdin)
  [[ "$REINSTALL_ROOT_HASH" == \$6\$* ]] || die '生成 root 密码哈希失败。'
}

reinstall_print_summary() {
  local fp i v4="静态 $REINSTALL_V4_ADDR/$REINSTALL_V4_PREFIX，网关 $REINSTALL_V4_GW"
  if [[ "$REINSTALL_V4_MODE" == dhcp ]]; then v4="DHCP（当前 $REINSTALL_V4_ADDR/$REINSTALL_V4_PREFIX）"; fi
  ui_use_target out
  printf '\n'
  ui_box_top '重装摘要'
  ui_box_line_color "${C_BOLD}${C_RED}" "将清空 /dev/$REINSTALL_DISK（$REINSTALL_DISK_SIZE）上的全部数据"
  ui_box_line "目标系统：Debian 13 ($REINSTALL_SUITE) $REINSTALL_ARCH，BIOS / GPT，无 swap"
  if [[ -n "$REINSTALL_TEST_MODE" ]]; then
    ui_box_line_color "$C_YELLOW" "测试模式：$REINSTALL_TEST_MODE"
  fi
  if [[ "$REINSTALL_HOST_VALID" == true ]]; then
    ui_box_line "主机名：$REINSTALL_NEW_HOST"
  else
    ui_box_line_color "$C_YELLOW" '当前主机名不合法，新系统将使用 debian'
  fi
  if [[ "$REINSTALL_NEED_GPGV" == true ]]; then
    ui_box_line '将先安装 gpgv（Debian 官方包，用于校验安装文件签名）'
  fi
  ui_box_line "IPv4：$v4；MAC $REINSTALL_V4_MAC（当前网卡 $REINSTALL_V4_IFACE）"
  case "$REINSTALL_V6_MODE" in
    none) ui_box_line 'IPv6：不配置' ;;
    auto) ui_box_line "IPv6：自动（SLAAC/RA，当前 $REINSTALL_V6_ADDR）；MAC $REINSTALL_V6_MAC（当前网卡 $REINSTALL_V6_IFACE）" ;;
    *) ui_box_line "IPv6：静态 $REINSTALL_V6_ADDR，网关 $REINSTALL_V6_GW；MAC $REINSTALL_V6_MAC（当前网卡 $REINSTALL_V6_IFACE）" ;;
  esac
  if [[ -n "$REINSTALL_V6_EXTRA" ]]; then ui_box_line "IPv6 附加地址：$REINSTALL_V6_EXTRA"; fi
  ui_box_line "重装后 SSH：端口 22，root 仅公钥登录；公钥 ${#REINSTALL_KEYS[@]} 把（丢弃 $REINSTALL_KEYS_DISCARDED 行）"
  for i in "${!REINSTALL_KEY_FPS[@]}"; do
    fp=${REINSTALL_KEY_FPS[i]}
    if [[ "${REINSTALL_KEY_HAS_OPTS[i]:-false}" == true ]]; then fp+='（带限制选项）'; fi
    ui_box_line "  $fp"
  done
  ui_box_line "root 密码：$REINSTALL_ROOT_PASS" "root 密码：${C_BOLD}${C_YELLOW}${REINSTALL_ROOT_PASS}${C_RESET}"
  ui_box_line '仅用于 VNC 控制台登录，请存进密码管理器；商家面板显示的旧密码会失效'
  ui_box_bottom
}

reinstall_confirm() {
  local answer=''
  CURRENT_STEP='重装确认'
  reinstall_generate_password
  reinstall_print_summary
  read_tty "请输入本机主机名 $REINSTALL_HOST 以确认清空整机并重装：" answer
  if [[ "$answer" != "$REINSTALL_HOST" ]]; then
    log '已取消，未做任何修改'
    exit 0
  fi
  log '主机名确认通过。'
}

# Runs after the hostname confirmation and before anything is written under /boot, so a failure
# leaves no boot entry behind. dry-run installs gpgv as well: the download and signature check
# are part of the dry run.
reinstall_install_gpgv() {
  [[ "$REINSTALL_NEED_GPGV" == true ]] || return 0
  CURRENT_STEP='安装 gpgv'
  log '安装 gpgv（Debian 官方包，用于校验安装文件签名）...'
  # Package lists may be missing (cleared in images) or stale; refresh them first.
  apt_get update || die '更新软件包索引失败，无法安装 gpgv；尚未改动任何启动项。'
  apt_get install -y --no-install-recommends gpgv || die '安装 gpgv 失败；尚未改动任何启动项。'
  command -v gpgv >/dev/null 2>&1 || die '安装后仍找不到 gpgv；尚未改动任何启动项。'
  REINSTALL_NEED_GPGV=false
  log 'gpgv 已安装。'
}

# ---- 下载与校验 --------------------------------------------------------------

# Judge gpgv by its status output, never by the exit code: at least one VALIDSIG; any BADSIG,
# EXPKEYSIG, REVKEYSIG or EXPSIG fails; ERRSIG is tolerated only when its return code field is
# 9 (missing public key) and gpgv also reports NO_PUBKEY for the same key (a newer signing key
# missing from the local keyring). ERRSIG <keyid> <pkalgo> <hashalgo> <class> <time> <rc> [<fpr>]
reinstall_check_gpg_status() {
  local status_file=$1 tag kw keyid err_rc valid=0 k n found
  local -a bad=() errsig=() nopub=() ignored=()
  [[ -r "$status_file" ]] || { warn "无法读取 gpgv 状态输出：$status_file"; return 1; }
  while IFS=' ' read -r tag kw keyid _ _ _ _ err_rc _; do
    [[ "$tag" == '[GNUPG:]' ]] || continue
    case "$kw" in
      VALIDSIG) valid=$((valid + 1)) ;;
      BADSIG|EXPKEYSIG|REVKEYSIG|EXPSIG) bad+=("$kw ${keyid:-?}") ;;
      ERRSIG)
        if [[ "${err_rc:-}" == 9 ]]; then errsig+=("${keyid:-?}"); else bad+=("ERRSIG ${keyid:-?} rc=${err_rc:-?}"); fi ;;
      NO_PUBKEY) nopub+=("${keyid:-?}") ;;
    esac
  done <"$status_file"
  if (( ${#bad[@]} > 0 )); then
    warn "InRelease 签名异常：$(reinstall_join "${bad[@]}")"
    return 1
  fi
  for k in "${errsig[@]}"; do
    found=false
    for n in "${nopub[@]}"; do
      if [[ "$n" == "$k" ]]; then found=true; break; fi
    done
    if [[ "$found" == false ]]; then
      warn "InRelease 签名无法校验（ERRSIG $k，没有对应的 NO_PUBKEY）"
      return 1
    fi
    ignored+=("$k")
  done
  if (( valid < 1 )); then
    warn 'InRelease 没有任何有效签名（VALIDSIG）'
    return 1
  fi
  if (( ${#ignored[@]} > 0 )); then
    log "InRelease 有 ${#ignored[@]} 个签名的公钥不在本机密钥环（$(reinstall_join "${ignored[@]}")），已忽略；其余 $valid 个签名有效"
  fi
}

reinstall_fetch() {
  curl "${REINSTALL_CURL_OPTS[@]}" "$1" -o "$2" || die "下载失败：$1"
}

reinstall_verify_sha256() {
  local expected=$1 file=$2 label=$3 actual
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "$label 的期望 SHA256 格式无效。"
  actual=$(sha256sum -- "$file" | awk '{ print $1 }')
  [[ "$actual" == "$expected" ]] || die "$label SHA256 校验失败（期望 $expected，实际 $actual）。"
  log "$label SHA256 校验通过"
}

reinstall_download_and_verify() {
  local tmp=$REINSTALL_BOOT_TMP_DIR codename sums_hash linux_hash initrd_hash
  local dist="$REINSTALL_MIRROR/dists/$REINSTALL_SUITE"
  local entry="main/installer-$REINSTALL_ARCH/current/images/SHA256SUMS"
  local netboot="$dist/main/installer-$REINSTALL_ARCH/current/images/netboot/debian-installer/$REINSTALL_ARCH"
  CURRENT_STEP='下载并校验安装器'
  log "下载并校验 Debian $REINSTALL_SUITE $REINSTALL_ARCH 官方 netboot..."
  rm -rf -- "$tmp"
  install -d -m 0700 -- "$tmp"

  reinstall_fetch "$dist/InRelease" "$tmp/InRelease"
  gpgv --status-fd 3 --keyring "$REINSTALL_KEYRING" --output "$tmp/Release.verified" "$tmp/InRelease" \
    3>"$tmp/gpgv.status" 2>"$tmp/gpgv.log" || true
  if ! reinstall_check_gpg_status "$tmp/gpgv.status"; then
    cat -- "$tmp/gpgv.log" >&2 || true
    die 'InRelease GPG 签名校验失败。'
  fi
  [[ -s "$tmp/Release.verified" ]] || die 'gpgv 没有输出已验证的 Release 正文。'
  codename=$(awk '$1 == "Codename:" { print $2; exit }' "$tmp/Release.verified")
  [[ "$codename" == "$REINSTALL_SUITE" ]] || die "Release 的 Codename 不是 $REINSTALL_SUITE（实际 ${codename:-空}）。"
  log "InRelease 签名有效，Codename=$codename"

  sums_hash=$(awk -v t="$entry" '
    /^SHA256:/ { in_sha = 1; next }
    /^[^ ]/ { in_sha = 0 }
    in_sha && $3 == t { print $1; exit }
  ' "$tmp/Release.verified")
  [[ -n "$sums_hash" ]] || die "已验证的 Release 中没有 $entry 的 SHA256。"
  reinstall_fetch "$dist/$entry" "$tmp/SHA256SUMS"
  reinstall_verify_sha256 "$sums_hash" "$tmp/SHA256SUMS" 'installer SHA256SUMS'

  linux_hash=$(awk -v p="./netboot/debian-installer/$REINSTALL_ARCH/linux" '$2 == p { print $1; exit }' "$tmp/SHA256SUMS")
  initrd_hash=$(awk -v p="./netboot/debian-installer/$REINSTALL_ARCH/initrd.gz" '$2 == p { print $1; exit }' "$tmp/SHA256SUMS")
  [[ -n "$linux_hash" && -n "$initrd_hash" ]] || die 'SHA256SUMS 中没有 netboot linux 或 initrd.gz。'
  reinstall_fetch "$netboot/linux" "$tmp/linux"
  reinstall_verify_sha256 "$linux_hash" "$tmp/linux" 'netboot linux'
  reinstall_fetch "$netboot/initrd.gz" "$tmp/initrd.gz"
  reinstall_verify_sha256 "$initrd_hash" "$tmp/initrd.gz" 'netboot initrd.gz'

  rm -f -- "$tmp/InRelease" "$tmp/Release.verified" "$tmp/SHA256SUMS" "$tmp/gpgv.status" "$tmp/gpgv.log"
  rm -rf -- "$REINSTALL_BOOT_DIR"
  mv -- "$tmp" "$REINSTALL_BOOT_DIR"
  chmod 0700 -- "$REINSTALL_BOOT_DIR"
  log "下载与三级校验全部通过：$REINSTALL_BOOT_DIR"
}

# ---- preseed 与追加包 --------------------------------------------------------

reinstall_sh_quote() {
  local s=$1
  printf "'%s'" "${s//\'/\'\\\'\'}"
}

reinstall_env_line() {
  printf '%s=%s\n' "$1" "$(reinstall_sh_quote "$2")"
}

reinstall_write_net_env() {
  local out=$1 expected=$REINSTALL_DISK_SECTORS delay=0
  if [[ "$REINSTALL_TEST_MODE" == selfcheck-fail ]]; then
    expected=$((REINSTALL_DISK_SECTORS + 1))
    delay=$REINSTALL_SELFCHECK_TEST_DELAY
  fi
  {
    reinstall_env_line TARGET_DISK "$REINSTALL_DISK"
    reinstall_env_line EXPECTED_SECTORS "$expected"
    reinstall_env_line SELFCHECK_DELAY "$delay"
    reinstall_env_line IPV4_MODE "$REINSTALL_V4_MODE"
    reinstall_env_line IPV4_ADDR "$REINSTALL_V4_ADDR"
    reinstall_env_line IPV4_PREFIX "$REINSTALL_V4_PREFIX"
    reinstall_env_line IPV4_NETMASK "$REINSTALL_V4_NETMASK"
    reinstall_env_line IPV4_GW "$REINSTALL_V4_GW"
    reinstall_env_line IPV4_MAC "$REINSTALL_V4_MAC"
    reinstall_env_line IPV4_IFACE_OLD "$REINSTALL_V4_IFACE"
    reinstall_env_line IPV6_MODE "$REINSTALL_V6_MODE"
    reinstall_env_line IPV6_ADDR "$REINSTALL_V6_ADDR"
    reinstall_env_line IPV6_GW "$REINSTALL_V6_GW"
    reinstall_env_line IPV6_EXTRA_ADDRS "$REINSTALL_V6_EXTRA"
    reinstall_env_line IPV6_MAC "$REINSTALL_V6_MAC"
  } >"$out"
}

reinstall_write_preseed() {
  local out=$1
  {
    cat <<EOF
# Localization & time
d-i debian-installer/language string en
d-i debian-installer/country string US
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
d-i time/zone string UTC
d-i clock-setup/utc boolean true
d-i clock-setup/ntp boolean true

# Early MAC-based NIC selection before netcfg
d-i preseed/early_command string sh /404/early.sh net

# Network (installer stage: IPv4 only)
d-i netcfg/do_not_use_netplan boolean true
d-i netcfg/choose_interface select auto
EOF
    if [[ "$REINSTALL_V4_MODE" == static ]]; then
      cat <<EOF
d-i netcfg/disable_autoconfig boolean true
d-i netcfg/get_ipaddress string $REINSTALL_V4_ADDR
d-i netcfg/get_netmask string $REINSTALL_V4_NETMASK
d-i netcfg/get_gateway string $REINSTALL_V4_GW
d-i netcfg/get_nameservers string 1.1.1.1 8.8.8.8
d-i netcfg/confirm_static boolean true
EOF
    else
      printf '%s\n' 'd-i netcfg/disable_autoconfig boolean false'
    fi
    cat <<EOF
d-i netcfg/get_hostname string $REINSTALL_NEW_HOST
d-i netcfg/get_domain string
d-i netcfg/hostname string $REINSTALL_NEW_HOST
d-i hw-detect/load_firmware boolean true

# Mirror & APT setup
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string
d-i mirror/suite string $REINSTALL_SUITE
d-i apt-setup/non-free-firmware boolean true
d-i apt-setup/contrib boolean false
d-i apt-setup/non-free boolean false
d-i apt-setup/enable-source-repositories boolean false
d-i apt-setup/services-select multiselect security, updates

# Account setup
d-i passwd/root-login boolean true
d-i passwd/make-user boolean false
d-i passwd/root-password-crypted password $REINSTALL_ROOT_HASH

# Pre-partition self-check
d-i partman/early_command string sh /404/early.sh check

# Partitioning (BIOS + GPT, 1M biosgrub + ext4 /, no swap)
d-i partman-auto/disk string /dev/$REINSTALL_DISK
d-i partman-auto/method string regular
d-i partman-partitioning/choose_label string gpt
d-i partman-partitioning/default_label string gpt
d-i partman/default_filesystem string ext4
d-i partman-auto/expert_recipe string \\
    404root :: \\
        1 1 1 free \\
            \$iflabel{ gpt } \\
            \$reusemethod{ } \\
            method{ biosgrub } \\
        . \\
        1024 1024 -1 ext4 \\
            method{ format } \\
            format{ } \\
            use_filesystem{ } \\
            filesystem{ ext4 } \\
            mountpoint{ / } \\
        .
d-i partman-auto/choose_recipe select 404root
d-i partman-basicfilesystems/no_swap boolean false
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman-md/device_remove_md boolean true
d-i partman-md/confirm boolean true
d-i partman-md/confirm_nooverwrite boolean true
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true

# Base system & packages
d-i base-installer/kernel/image string linux-image-$REINSTALL_ARCH
d-i base-installer/install-recommends boolean false
tasksel tasksel/first multiselect ssh-server
d-i pkgsel/include string ifupdown curl ca-certificates systemd-timesyncd
d-i pkgsel/upgrade select safe-upgrade
popularity-contest popularity-contest/participate boolean false

# Bootloader
d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean false
d-i grub-installer/bootdev string /dev/$REINSTALL_DISK
d-i debian-installer/add-kernel-opts string net.ifnames=0 biosdevname=0

# Finish
d-i finish-install/reboot_in_progress note
d-i preseed/late_command string sh /404/late.sh
EOF
  } >"$out"
}

# Shared POSIX sh: locate a NIC by MAC, skipping lo and enslaved (e.g. SR-IOV VF) devices.
reinstall_emit_find_iface_lib() {
  cat <<'EOF'
find_iface_by_mac() {
    target_mac=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    for p in /sys/class/net/*; do
        [ -r "$p/address" ] || continue
        name=${p##*/}
        [ "$name" = "lo" ] && continue
        [ -e "$p/master" ] && continue
        mac=$(tr '[:upper:]' '[:lower:]' < "$p/address")
        if [ "$mac" = "$target_mac" ]; then
            printf '%s\n' "$name"
            return 0
        fi
    done
    return 1
}
EOF
}

# POSIX sh used by late.sh (and the dry-run preview): print /etc/network/interfaces from the
# net.env variables for the given IPv4 and IPv6 interface names.
reinstall_emit_render_lib() {
  cat <<'EOF'
render_interfaces() {
    r_v4_if=$1
    r_v6_if=$2
    printf 'source /etc/network/interfaces.d/*\n\n'
    printf 'auto lo\n'
    printf 'iface lo inet loopback\n\n'
    printf 'auto %s\n' "$r_v4_if"
    if [ "$IPV4_MODE" = "static" ]; then
        printf 'iface %s inet static\n' "$r_v4_if"
        printf '    address %s/%s\n' "$IPV4_ADDR" "$IPV4_PREFIX"
        printf '    gateway %s\n' "$IPV4_GW"
    else
        printf 'iface %s inet dhcp\n' "$r_v4_if"
    fi
    if [ "$IPV6_MODE" != "none" ]; then
        if [ "$r_v6_if" != "$r_v4_if" ]; then
            printf '\nauto %s\n' "$r_v6_if"
        fi
        if [ "$IPV6_MODE" = "static" ]; then
            printf 'iface %s inet6 static\n' "$r_v6_if"
            printf '    address %s\n' "$IPV6_ADDR"
            printf '    gateway %s\n' "$IPV6_GW"
            printf '    accept_ra 0\n'
            printf '    autoconf 0\n'
            if [ -n "$IPV6_EXTRA_ADDRS" ]; then
                for r_extra in $IPV6_EXTRA_ADDRS; do
                    printf '    up ip -6 addr add %s dev %s || true\n' "$r_extra" "$r_v6_if"
                    printf '    down ip -6 addr del %s dev %s || true\n' "$r_extra" "$r_v6_if"
                done
            fi
        else
            printf 'iface %s inet6 auto\n' "$r_v6_if"
        fi
    fi
}
EOF
}

reinstall_write_early_sh() {
  local out=$1
  {
    cat <<'EOF'
#!/bin/sh
set -eu

# shellcheck source=/dev/null
. /404/net.env

log_msg() {
    logger -t 404-reinstall "$*" || true
    printf '404-reinstall: %s\n' "$*" >&2
}

EOF
    reinstall_emit_find_iface_lib
    cat <<'EOF'

abort_and_reboot() {
    log_msg "SELFCHECK FAILED: $1 - rebooting without touching disk"
    if [ "${SELFCHECK_DELAY:-0}" -gt 0 ]; then
        log_msg "test mode: waiting ${SELFCHECK_DELAY}s before reboot"
        sleep "$SELFCHECK_DELAY"
    fi
    sync || true
    reboot || true
    sleep 10
    reboot -f || true
    sleep 60
    exit 1
}

mode=${1:-}
case "$mode" in
    net)
        v4_if=""
        i=0
        while [ "$i" -lt 15 ]; do
            if v4_if=$(find_iface_by_mac "$IPV4_MAC"); then
                break
            fi
            i=$((i + 1))
            sleep 1
        done
        if [ -n "$v4_if" ]; then
            log_msg "early net: matched IPv4 MAC $IPV4_MAC -> $v4_if"
            debconf-set netcfg/choose_interface "$v4_if"
        elif printf '%s\n' "${IPV4_IFACE_OLD:-}" | grep -Eq '^eth[0-9]+$'; then
            log_msg "early net: IPv4 MAC $IPV4_MAC not found after 15s, fallback to old name $IPV4_IFACE_OLD"
            debconf-set netcfg/choose_interface "$IPV4_IFACE_OLD"
        else
            log_msg "early net: IPv4 MAC $IPV4_MAC not found after 15s, old name ${IPV4_IFACE_OLD:-empty} invalid for fallback, keeping auto"
        fi
        ;;
    check)
        if [ ! -r "/sys/block/$TARGET_DISK/size" ]; then
            abort_and_reboot "disk /sys/block/$TARGET_DISK/size missing"
        fi
        actual_sectors=$(cat "/sys/block/$TARGET_DISK/size")
        if [ "$actual_sectors" != "$EXPECTED_SECTORS" ]; then
            abort_and_reboot "disk $TARGET_DISK sectors mismatch: actual=$actual_sectors expected=$EXPECTED_SECTORS"
        fi
        if ! v4_if=$(find_iface_by_mac "$IPV4_MAC"); then
            abort_and_reboot "IPv4 MAC $IPV4_MAC not found"
        fi
        v6_if="none"
        if [ "$IPV6_MODE" != "none" ]; then
            if ! v6_if=$(find_iface_by_mac "$IPV6_MAC"); then
                abort_and_reboot "IPv6 MAC $IPV6_MAC not found"
            fi
        fi
        log_msg "selfcheck OK: disk=$TARGET_DISK sectors=$actual_sectors v4_if=$v4_if v6_if=$v6_if"
        ;;
    *)
        log_msg "unknown mode: $mode"
        exit 1
        ;;
esac
EOF
  } >"$out"
  chmod 0755 -- "$out"
}

reinstall_write_late_sh() {
  local out=$1
  {
    cat <<'EOF'
#!/bin/sh
set -eu

# shellcheck source=/dev/null
. /404/net.env

log_msg() {
    logger -t 404-reinstall "$*" || true
    printf '404-reinstall: %s\n' "$*"
}

EOF
    reinstall_emit_find_iface_lib
    printf '\n'
    reinstall_emit_render_lib
    cat <<'EOF'

v4_if=$(find_iface_by_mac "$IPV4_MAC")
v6_if=""
if [ "$IPV6_MODE" != "none" ]; then
    v6_if=$(find_iface_by_mac "$IPV6_MAC")
fi

log_msg "late.sh: v4_if=$v4_if v6_if=${v6_if:-none}"

# 1. /target/etc/network/interfaces
mkdir -p /target/etc/network /target/etc/network/interfaces.d
render_interfaces "$v4_if" "$v6_if" > /target/etc/network/interfaces

# 2. /target/etc/resolv.conf
{
    printf 'nameserver 1.1.1.1\n'
    printf 'nameserver 8.8.8.8\n'
    if [ "$IPV6_MODE" != "none" ]; then
        printf 'nameserver 2606:4700:4700::1111\n'
    fi
} > /target/etc/resolv.conf

# 3. /target/root/.ssh/authorized_keys
mkdir -p /target/root/.ssh
chmod 700 /target/root/.ssh
cp /404/authorized_keys /target/root/.ssh/authorized_keys
chmod 600 /target/root/.ssh/authorized_keys
chown -R 0:0 /target/root/.ssh

# 4. /target/etc/ssh/sshd_config.d/00-404-reinstall.conf
mkdir -p /target/etc/ssh/sshd_config.d
cat <<'SSHEOF' > /target/etc/ssh/sshd_config.d/00-404-reinstall.conf
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
SSHEOF
chmod 644 /target/etc/ssh/sshd_config.d/00-404-reinstall.conf

# 5. Dump generated files into installer log
log_msg "=== /target/etc/network/interfaces ==="
cat /target/etc/network/interfaces
log_msg "=== /target/etc/resolv.conf ==="
cat /target/etc/resolv.conf
log_msg "=== /target/etc/ssh/sshd_config.d/00-404-reinstall.conf ==="
cat /target/etc/ssh/sshd_config.d/00-404-reinstall.conf
log_msg "=== /target/root/.ssh/authorized_keys ==="
ls -la /target/root/.ssh/authorized_keys
cat /target/root/.ssh/authorized_keys
log_msg "late.sh finished successfully."
EOF
  } >"$out"
  chmod 0755 -- "$out"
}

# finish-install hook, ordered after the installer's 08hw-detect (which adds qemu-guest-agent on
# KVM). in-target sends stdout to syslog unless --pass-stdout is given, so the status query needs
# it. Every step only logs on failure: this hook must never make the installation fail.
reinstall_write_finish_cleanup() {
  local out=$1
  cat <<'EOF' >"$out"
#!/bin/sh
set -u

log_msg() {
    logger -t 404-reinstall "$*" 2>/dev/null || true
}

candidates="qemu-guest-agent os-prober installation-report laptop-detect task-english iamerican ibritish ienglish-common ispell wamerican dictionaries-common emacsen-common"
installed=""
log_msg "finish cleanup: checking installed packages"
for pkg in $candidates; do
    # shellcheck disable=SC2016 # ${Status} is a dpkg-query format field.
    status=$(in-target --pass-stdout dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null) || status=""
    case "$status" in
        *" installed") installed="$installed $pkg" ;;
    esac
done

if [ -n "$installed" ]; then
    log_msg "finish cleanup: purging$installed"
    # shellcheck disable=SC2086 # The package list is split on purpose.
    if in-target apt-get -y purge $installed; then
        log_msg "finish cleanup: purge OK"
    else
        log_msg "finish cleanup: purge failed (rc=$?), continuing"
    fi
else
    log_msg "finish cleanup: nothing to purge"
fi

if in-target apt-get -y autoremove --purge; then
    log_msg "finish cleanup: autoremove OK"
else
    log_msg "finish cleanup: autoremove failed (rc=$?), continuing"
fi

log_msg "finish cleanup: done"
exit 0
EOF
  chmod 0755 -- "$out"
}

reinstall_write_authorized_keys() {
  local out=$1 key
  : >"$out"
  for key in "${REINSTALL_KEYS[@]}"; do printf '%s\n' "$key" >>"$out"; done
  chmod 0600 -- "$out"
}

# Print the interfaces file late.sh would write, using the same POSIX sh renderer.
reinstall_render_interfaces_preview() {
  local net_env=$1 v4_if=$2 v6_if=$3
  # shellcheck disable=SC2016 # Expanded by the inner sh.
  sh -c '. "$1"; eval "$2"; render_interfaces "$3" "$4"' sh "$net_env" "$(reinstall_emit_render_lib)" "$v4_if" "$v6_if"
}

reinstall_build_overlay() {
  local stage overlay="$REINSTALL_BOOT_DIR/overlay.cpio.gz"
  CURRENT_STEP='生成安装应答'
  log '生成 preseed 与追加 cpio 包...'
  REINSTALL_STAGE_DIR=$(mktemp -d "$REINSTALL_BOOT_DIR/overlay.XXXXXX")
  stage=$REINSTALL_STAGE_DIR
  install -d -m 0700 -- "$stage/404"
  # These directories already exist in the installer initrd; the kernel applies the archive's
  # mode to them, so they must stay 0755.
  install -d -m 0755 -- "$stage/usr" "$stage/usr/lib" "$stage/usr/lib/finish-install.d"
  reinstall_write_preseed "$stage/preseed.cfg"
  reinstall_write_net_env "$stage/404/net.env"
  reinstall_write_early_sh "$stage/404/early.sh"
  reinstall_write_late_sh "$stage/404/late.sh"
  reinstall_write_authorized_keys "$stage/404/authorized_keys"
  reinstall_write_finish_cleanup "$stage/usr/lib/finish-install.d/50404-reinstall-cleanup"

  if [[ "$REINSTALL_TEST_MODE" == dry-run ]]; then
    printf '\n'
    log '==================== preseed.cfg ===================='
    cat -- "$stage/preseed.cfg"
    log '==================== 404/net.env ===================='
    cat -- "$stage/404/net.env"
    log '==================== 网卡配置预览（按当前网卡名示意，安装时按 MAC 定位） ===================='
    reinstall_render_interfaces_preview "$stage/404/net.env" "$REINSTALL_V4_IFACE" "${REINSTALL_V6_IFACE:-$REINSTALL_V4_IFACE}"
    log '====================================================='
    printf '\n'
  fi

  (
    cd -- "$stage"
    printf '%s\n' preseed.cfg 404 404/authorized_keys 404/net.env 404/early.sh 404/late.sh \
      usr usr/lib usr/lib/finish-install.d usr/lib/finish-install.d/50404-reinstall-cleanup |
      cpio -o -H newc -R 0:0 --quiet | gzip -9 >"$overlay"
  )
  cat -- "$overlay" >>"$REINSTALL_BOOT_DIR/initrd.gz"
  rm -f -- "$overlay"
  rm -rf -- "$stage"
  REINSTALL_STAGE_DIR=''
  chmod 0600 -- "$REINSTALL_BOOT_DIR/linux" "$REINSTALL_BOOT_DIR/initrd.gz"
  log "已将追加包拼接到 $REINSTALL_BOOT_DIR/initrd.gz"
}

# ---- GRUB 一次性启动与重启 ---------------------------------------------------

# Back up an existing custom.cfg once, drop any older 404-reinstall block and append a new one.
reinstall_write_custom_cfg() {
  local uuid=$1 rel=$2 fs_mod=$3 tmp
  if [[ -f "$REINSTALL_CUSTOM_CFG" ]]; then
    if [[ ! -f "$REINSTALL_CUSTOM_BAK" ]]; then
      cp -a -- "$REINSTALL_CUSTOM_CFG" "$REINSTALL_CUSTOM_BAK"
      log "已备份 $REINSTALL_CUSTOM_CFG 到 $REINSTALL_CUSTOM_BAK"
    fi
    tmp=$(mktemp "$REINSTALL_CUSTOM_CFG.404tmp.XXXXXX")
    reinstall_strip_mark_block "$REINSTALL_CUSTOM_CFG" >"$tmp"
    mv -f -- "$tmp" "$REINSTALL_CUSTOM_CFG"
  fi
  cat <<EOF >>"$REINSTALL_CUSTOM_CFG"
$REINSTALL_MARK_BEGIN
menuentry '404-reinstall Debian 13 installer' --id $REINSTALL_GRUB_ENTRY_ID {
  insmod part_gpt; insmod part_msdos; insmod $fs_mod
  search --no-floppy --fs-uuid --set=root $uuid
  linux $rel/linux auto=true priority=critical lowmem/low=1 net.ifnames=0 biosdevname=0 language=en country=US locale=en_US.UTF-8 keymap=us
  initrd $rel/initrd.gz
}
$REINSTALL_MARK_END
EOF
  chmod 0644 -- "$REINSTALL_CUSTOM_CFG"
}

reinstall_configure_grub() {
  local uuid rel fs_mod=ext2
  CURRENT_STEP='配置 GRUB 一次性启动'
  log '配置 GRUB 一次性启动项...'
  uuid=$(grub-probe --target=fs_uuid "$REINSTALL_BOOT_DIR")
  rel=$(grub-mkrelpath "$REINSTALL_BOOT_DIR")
  [[ -n "$uuid" && -n "$rel" ]] || die "无法计算 $REINSTALL_BOOT_DIR 的文件系统 UUID 或 GRUB 相对路径。"
  if [[ "$REINSTALL_GRUB_FS" == xfs ]]; then fs_mod=xfs; fi
  reinstall_write_custom_cfg "$uuid" "$rel" "$fs_mod"
  grub-reboot "$REINSTALL_GRUB_ENTRY_ID"
  reinstall_next_entry_is_ours || die "grub-editenv 未确认 next_entry=$REINSTALL_GRUB_ENTRY_ID。"
  log "已设置 GRUB next_entry=$REINSTALL_GRUB_ENTRY_ID"
}

reinstall_print_ready() {
  ui_use_target out
  printf '\n'
  ui_box_top '准备就绪'
  ui_box_line "重装完成后登录：ssh -p 22 root@$REINSTALL_V4_ADDR"
  ui_box_line "root 密码：$REINSTALL_ROOT_PASS" "root 密码：${C_BOLD}${C_YELLOW}${REINSTALL_ROOT_PASS}${C_RESET}"
  ui_box_line 'root 密码仅用于 VNC 控制台登录；商家面板显示的旧密码会失效'
  ui_box_line "清除旧主机指纹：ssh-keygen -R $REINSTALL_V4_ADDR"
  ui_box_line '下一步：用 README 的一键命令运行 [1] 快速初始化'
  ui_box_line '安装大约需要 5～20 分钟，安装期间 SSH 连不上属于正常现象'
  ui_box_bottom
}

reinstall_countdown_and_reboot() {
  local sec
  CURRENT_STEP='重启进入安装器'
  log '10 秒后重启进入安装器；按 Ctrl+C 可取消，取消后自动清理。'
  for (( sec = 10; sec >= 1; sec-- )); do
    printf '%s...\n' "$sec"
    sleep 1
  done
  trap '' HUP INT TERM
  REINSTALL_ARMED=false
  log '正在重启...'
  if ! reboot; then
    # Do not leave a one-shot entry that would wipe the disk on some later, unexpected reboot.
    reinstall_cleanup || true
    die 'reboot 执行失败，已清除启动项，系统未改变；可重新运行 [9]'
  fi
}

run_reinstall() {
  reinstall_confirm
  reinstall_install_gpgv
  REINSTALL_ARMED=true
  reinstall_download_and_verify
  reinstall_build_overlay
  if [[ "$REINSTALL_TEST_MODE" == dry-run ]]; then
    reinstall_cleanup
    REINSTALL_ARMED=false
    log 'dry-run 完成：已清理下载文件，未修改 GRUB，未重启。'
    return 0
  fi
  reinstall_configure_grub
  reinstall_print_ready
  if [[ "$REINSTALL_TEST_MODE" == no-reboot ]]; then
    REINSTALL_ARMED=false
    log 'no-reboot 测试模式：启动项已保留，未重启。下次重启会进入安装器；重新运行 [9] 可清除。'
    return 0
  fi
  reinstall_countdown_and_reboot
}

main() {
  parse_args "$@"
  select_install_mode
  if [[ "$INSTALL_MODE" == reinstall ]]; then
    # Not preflight: that creates a backup directory. No ensure_system_dns either.
    reinstall_preflight
    acquire_lock
    run_reinstall
    return 0
  fi
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
  remove_legacy_network_stack_state
  run_safe_cleanup
  check_boot_services
  print_report
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
