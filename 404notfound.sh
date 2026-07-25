#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

readonly DEFAULT_SSH_PORT='53651'
readonly SSH_MAIN_CONFIG='/etc/ssh/sshd_config'
readonly SSH_DROPIN_DIR='/etc/ssh/sshd_config.d'
readonly SSH_DROPIN="$SSH_DROPIN_DIR/00-hardening.conf"
readonly LEGACY_SSH_DROPIN="$SSH_DROPIN_DIR/00-vps-bootstrap.conf"
readonly AUTHORIZED_KEYS='/root/.ssh/authorized_keys'
readonly CLOUDFLARE_UFW_TOOL='/usr/local/sbin/update-cloudflare-ufw'
readonly DOMAIN_CHECK_SOURCE='https://raw.githubusercontent.com/404-git-404/404notfound/main/domain-check.sh'
readonly DOMAIN_CHECK_TARGET='/usr/local/bin/domain-check'
readonly SAGER_KEY_FINGERPRINT='2C317FBD5D886B4E89BAE8DA6D9152172A2B2F0C'
readonly SMARTDNS_CONFIG_TARGET='/etc/smartdns/smartdns.conf'
readonly SMARTDNS_RELEASE_TAG='smartdns-debian-pinned-2026-07'
readonly SMARTDNS_RELEASE_BASE='https://github.com/404-git-404/404notfound/releases/download/smartdns-debian-pinned-2026-07'

SSH_PORT="$DEFAULT_SSH_PORT"
SING_BOX_VERSION=''
PUBKEY_ARGUMENT=''
PUBKEY_FILE=''
PUBLIC_KEY=''
PUBLIC_KEY_TYPE=''
PUBLIC_KEY_BLOB=''
PUBLIC_KEY_FINGERPRINT=''
SKIP_UPGRADE=false
INSTALL_MODE=''
KEEP_SSH_22=false
OPEN_443_TCP=true
OPEN_443_UDP=true
ENABLE_CF_8443=false
CURRENT_STEP='启动'
TMP_DIR=''
BACKUP_DIR=''
DEBIAN_VERSION=''
CPU_ARCH=''
SMARTDNS_CONFIG_VARIANT=''
SMARTDNS_ASSET_NAME=''
SMARTDNS_EXPECTED_VERSION=''
SMARTDNS_EXPECTED_SHA256=''
SMARTDNS_DOWNLOAD_URL=''
SMARTDNS_PACKAGE_PATH=''
SMARTDNS_IPV4_ANSWER=''
SMARTDNS_IPV4_ATTEMPTS=0
SMARTDNS_LAST_DIG_OUTPUT=''
SMARTDNS_WAS_HELD=false
SMARTDNS_WAS_ENABLED=false
SMARTDNS_WAS_ACTIVE=false
SMARTDNS_TRANSACTION_ACTIVE=false
SSHD_EFFECTIVE=''
SSHD_EFFECTIVE_ROOT=''
SSH_READY=false
SMARTDNS_READY=false
DNS_READY=false
SYSTEM_UPDATE_READY=false
BASE_TOOLS_READY=false
DOMAIN_CHECK_STATE='未安装'
DOMAIN_CHECK_INSTALL_STAGE=''
SSH_ROLLBACK_STATE='未触发'
FAILURE_STEP=''
FAILURE_REASON=''
RESULT_REPORTED=false
LAST_WRITE_CHANGED=false
COLOR_ENABLED=false
HEALTH_BLOCKERS=0
HEALTH_WARNINGS=0
INITIAL_SSH_PORTS=''
declare -a SSH_CHANGED_FILES=()
declare -a HEALTH_STATUSES=()
declare -a HEALTH_LABELS=()
declare -a HEALTH_DETAILS=()

readonly -a BASE_PACKAGES=(
  ca-certificates curl wget git rsync tar unzip xz-utils jq nano gnupg
  openssl socat cron openssh-server ufw dnsutils iproute2 iputils-ping
  netcat-openbsd mtr-tiny traceroute tcpdump procps lsof htop chrony vnstat
  python3 util-linux file
)

usage() {
  cat <<'EOF'
用法：
  bash 404notfound.sh
  bash 404notfound.sh [预设选项]

脚本首先执行完全只读的 VPS 环境体检，然后显示：
  1. 快速安装
  2. 自定义安装
  3. 退出

快速安装固定使用 53651/tcp，关闭 22，开放 443/tcp、443/udp，
并仅向 Cloudflare 地址段开放 8443/tcp。

预设选项（不会跳过体检和菜单）：
  --pubkey "SSH_PUBLIC_KEY"       预先提供一个 OpenSSH 公钥
  --pubkey-file /path/key.pub     从文件读取公钥（优先级更高）
  --sing-box-version VERSION      安装官方 APT 仓库中的指定 sing-box 版本
  --help                          显示帮助

所有交互均从 /dev/tty 读取。无 TTY 时，体检完成后明确退出。
SmartDNS 验证成功后会成为系统唯一 DNS；脚本不执行外部 SSH 登录确认。
EOF
}

timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

log() {
  printf '[%s] [INFO] %s\n' "$(timestamp)" "$*"
}

warn() {
  printf '[%s] [WARN] %s\n' "$(timestamp)" "$*" >&2
}

die() {
  if [[ "${SMARTDNS_TRANSACTION_ACTIVE:-false}" == true ]] &&
    declare -F restore_smartdns_transaction >/dev/null 2>&1; then
    restore_smartdns_transaction || true
  fi
  FAILURE_STEP=$CURRENT_STEP
  FAILURE_REASON=$*
  printf '[%s] [ERROR] 步骤“%s”失败：%s\n' "$(timestamp)" "$CURRENT_STEP" "$*" >&2
  exit 1
}

on_error() {
  local exit_code=$?
  local line_number=$1
  trap - ERR
  if [[ "${SMARTDNS_TRANSACTION_ACTIVE:-false}" == true ]] &&
    declare -F restore_smartdns_transaction >/dev/null 2>&1; then
    restore_smartdns_transaction || true
  fi
  FAILURE_STEP=$CURRENT_STEP
  FAILURE_REASON="第 $line_number 行发生未处理错误（退出码 $exit_code）"
  printf '[%s] [ERROR] 步骤“%s”在第 %s 行失败（退出码 %s）。\n' \
    "$(timestamp)" "$CURRENT_STEP" "$line_number" "$exit_code" >&2
  exit "$exit_code"
}

on_signal() {
  FAILURE_STEP=$CURRENT_STEP
  FAILURE_REASON='收到中断信号'
  warn '收到中断信号，停止执行。'
  exit 130
}

cleanup() {
  local exit_code=$?
  set +e
  if (( exit_code != 0 )) && [[ "$RESULT_REPORTED" == false ]]; then
    print_failure_report >&2
  fi
  if [[ -n "$DOMAIN_CHECK_INSTALL_STAGE" &&
    "$DOMAIN_CHECK_INSTALL_STAGE" == /usr/local/bin/.domain-check.* ]]; then
    rm -f -- "$DOMAIN_CHECK_INSTALL_STAGE"
  fi
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR"
  fi
  trap - EXIT
  exit "$exit_code"
}

trap 'on_error $LINENO' ERR
trap cleanup EXIT
trap on_signal INT TERM

initialize_colors() {
  COLOR_ENABLED=false
  if [[ -t 1 && -t 2 && -z "${NO_COLOR+x}" ]]; then
    COLOR_ENABLED=true
  fi
}

color_text() {
  local color=$1
  local text=$2
  if [[ "$COLOR_ENABLED" == true ]]; then
    printf '\033[%sm%s\033[0m' "$color" "$text"
  else
    printf '%s' "$text"
  fi
}

health_add() {
  local status=$1
  local label=$2
  local detail=$3
  HEALTH_STATUSES+=("$status")
  HEALTH_LABELS+=("$label")
  HEALTH_DETAILS+=("$detail")
  case "$status" in
    FAIL) ((HEALTH_BLOCKERS += 1)) ;;
    WARN) ((HEALTH_WARNINGS += 1)) ;;
  esac
}

health_status_text() {
  local status=$1
  case "$status" in
    OK) color_text '32' '[OK]  ' ;;
    WARN) color_text '33' '[WARN]' ;;
    FAIL) color_text '31' '[FAIL]' ;;
    *) printf '[INFO]' ;;
  esac
}

health_box_line() {
  color_text '38;5;208' '############################################################'
  printf '\n'
}

result_box_line() {
  health_box_line
}

result_status_text() {
  health_status_text "$1"
}

result_safe_text() {
  local text=$1
  text=${text//$'\033'/}
  text=${text//$'\r'/ }
  text=${text//$'\n'/ }
  printf '%s' "$text"
}

result_row() {
  local status=$1
  local label=$2
  local detail
  detail=$(result_safe_text "$3")
  result_status_text "$status"
  printf ' %-18s %s\n' "$label" "$detail"
}

read_tty() {
  local prompt=$1
  local variable_name=$2
  [[ -r /dev/tty && -w /dev/tty ]] ||
    die '当前没有可交互的 /dev/tty，无法安全读取安装选择。'
  printf '%s' "$prompt" >/dev/tty
  IFS= read -r "${variable_name?}" </dev/tty || die '无法从 /dev/tty 读取输入。'
}

ask_yes_no() {
  local prompt=$1
  local default_value=$2
  local answer
  while true; do
    if [[ "$default_value" == true ]]; then
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

shorten_line() {
  local value=$1
  value=${value//$'\n'/; }
  printf '%.160s' "$value"
}

collect_ssh_listener_ports() {
  command -v ss >/dev/null 2>&1 || return 0
  ss -H -ltnp 2>/dev/null | awk '
    /sshd/ {
      endpoint = $4
      sub(/^.*:/, "", endpoint)
      if (endpoint ~ /^[0-9]+$/) {
        ports[endpoint] = 1
      }
    }
    END {
      separator = ""
      for (port in ports) {
        printf "%s%s", separator, port
        separator = ","
      }
    }
  '
}

run_health_check() {
  CURRENT_STEP='启动体检'
  HEALTH_BLOCKERS=0
  HEALTH_WARNINGS=0
  HEALTH_STATUSES=()
  HEALTH_LABELS=()
  HEALTH_DETAILS=()

  local os_id='未知'
  local os_version='未知'
  local os_pretty='无法读取 /etc/os-release'
  if [[ -r /etc/os-release ]]; then
    os_id=$(awk -F= '$1 == "ID" { gsub(/^"|"$/, "", $2); print $2 }' /etc/os-release)
    os_version=$(awk -F= '$1 == "VERSION_ID" { gsub(/^"|"$/, "", $2); print $2 }' /etc/os-release)
    os_pretty=$(awk -F= '$1 == "PRETTY_NAME" { sub(/^[^=]*=/, ""); gsub(/^"|"$/, ""); print }' /etc/os-release)
  fi
  if [[ "$os_id" == debian && "$os_version" =~ ^(12|13)$ ]]; then
    health_add OK '系统版本' "$os_pretty"
  else
    health_add FAIL '系统版本' "$os_pretty；仅支持 Debian 12/13"
  fi

  if (( EUID == 0 )); then
    health_add OK '运行用户' 'root'
  else
    health_add FAIL '运行用户' "UID=$EUID；必须使用 root"
  fi

  local architecture
  architecture=$(dpkg --print-architecture 2>/dev/null || uname -m 2>/dev/null || printf '未知')
  case "$architecture" in
    amd64|arm64) health_add OK 'CPU 架构' "$architecture" ;;
    *) health_add FAIL 'CPU 架构' "$architecture；仅支持 amd64/arm64" ;;
  esac

  if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
    health_add OK 'systemd' '可用'
  else
    health_add FAIL 'systemd' '不可用'
  fi

  if command -v systemctl >/dev/null 2>&1 &&
    systemctl cat ssh.service >/dev/null 2>&1; then
    if systemctl is-active --quiet ssh.service; then
      INITIAL_SSH_PORTS=$(collect_ssh_listener_ports)
      health_add OK 'SSH 服务' "active，监听 ${INITIAL_SSH_PORTS:-未识别}/tcp"
    else
      health_add FAIL 'SSH 服务' 'ssh.service 存在但未运行'
    fi
  else
    health_add FAIL 'SSH 服务' '找不到 ssh.service'
  fi

  local cpu_count='未知'
  local cpu_model='未知'
  command -v nproc >/dev/null 2>&1 && cpu_count=$(nproc)
  [[ -r /proc/cpuinfo ]] &&
    cpu_model=$(awk -F: '/model name|Processor/ { sub(/^[[:space:]]+/, "", $2); print $2; exit }' /proc/cpuinfo)
  health_add INFO 'CPU' "${cpu_count} 核，${cpu_model:-未知型号}"

  local memory='未知'
  [[ -r /proc/meminfo ]] &&
    memory=$(awk '/MemTotal:/ { printf "%.1f GiB", $2 / 1048576 }' /proc/meminfo)
  health_add INFO '内存' "$memory"

  local disk_available_kb=0
  local disk_detail='无法读取'
  if command -v df >/dev/null 2>&1; then
    disk_available_kb=$(df -Pk / | awk 'NR == 2 { print $4 }')
    disk_detail=$(df -Ph / | awk 'NR == 2 { printf "可用 %s，共 %s，已用 %s", $4, $2, $5 }')
  fi
  if (( disk_available_kb < 2097152 )); then
    health_add FAIL '根磁盘' "$disk_detail；至少需要 2 GiB 可用空间"
  else
    health_add OK '根磁盘' "$disk_detail"
  fi

  local ip_detail='ip 命令不可用'
  local route_detail='未发现默认路由'
  if command -v ip >/dev/null 2>&1; then
    ip_detail=$(ip -brief address show scope global 2>/dev/null | awk '{$1=$1; print}' | head -n 4 || true)
    route_detail=$(
      {
        ip -4 route show default 2>/dev/null || true
        ip -6 route show default 2>/dev/null || true
      } | awk 'NR <= 4' || true
    )
  fi
  health_add INFO 'IP 地址' "$(shorten_line "${ip_detail:-无全局地址}")"
  health_add INFO '默认路由' "$(shorten_line "${route_detail:-未发现}")"

  local listener_detail='ss 命令不可用'
  if command -v ss >/dev/null 2>&1; then
    listener_detail=$(ss -H -lntu 2>/dev/null | awk '
      {
        endpoint = $1 ":" $5
        entries[endpoint] = 1
      }
      END {
        separator = ""
        for (endpoint in entries) {
          printf "%s%s", separator, endpoint
          separator = ", "
        }
      }
    ' || true)
  fi
  health_add INFO '监听端口' "$(shorten_line "${listener_detail:-无监听}")"

  if command -v timeout >/dev/null 2>&1 && command -v getent >/dev/null 2>&1 &&
    timeout 4 getent ahosts debian.org >/dev/null 2>&1; then
    health_add OK 'DNS 解析' 'debian.org 解析成功'
  else
    health_add WARN 'DNS 解析' '短时解析测试失败'
  fi

  if command -v timeout >/dev/null 2>&1 && command -v ping >/dev/null 2>&1 &&
    timeout 5 ping -4 -c 1 -W 2 debian.org >/dev/null 2>&1; then
    health_add OK 'IPv4 网络' '可用'
  else
    health_add WARN 'IPv4 网络' '短时连通性测试失败'
  fi
  if command -v timeout >/dev/null 2>&1 && command -v ping >/dev/null 2>&1 &&
    timeout 5 ping -6 -c 1 -W 2 debian.org >/dev/null 2>&1; then
    health_add OK 'IPv6 网络' '可用'
  else
    health_add WARN 'IPv6 网络' '不可用或短时测试失败'
  fi

  if [[ ! -r /var/lib/dpkg/status ]] || ! command -v dpkg >/dev/null 2>&1; then
    health_add FAIL 'dpkg 状态' '状态数据库不可读或 dpkg 缺失'
  else
    local audit_output
    audit_output=$(dpkg --audit 2>&1 || true)
    if [[ -n "$audit_output" ]]; then
      health_add FAIL 'dpkg 状态' "$(shorten_line "$audit_output")"
    else
      health_add OK 'dpkg 状态' '未发现未配置或损坏的软件包'
    fi
  fi
  if ! command -v lslocks >/dev/null 2>&1; then
    health_add WARN 'APT/dpkg 锁' 'lslocks 不可用，安装时将依赖 APT 自身锁等待'
  elif apt_lock_is_held; then
    health_add WARN 'APT/dpkg 锁' '正被其他进程占用；安装时最多等待 300 秒'
  else
    health_add OK 'APT/dpkg 锁' '未占用'
  fi

  local time_detail
  time_detail=$(date --iso-8601=seconds 2>/dev/null || date)
  if command -v timedatectl >/dev/null 2>&1; then
    time_detail+="，同步=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || printf '未知')"
  fi
  health_add INFO '时间同步' "$time_detail"

  if command -v ufw >/dev/null 2>&1; then
    if ufw_is_active; then
      health_add INFO 'UFW 状态' 'installed，active'
    else
      health_add INFO 'UFW 状态' 'installed，inactive'
    fi
  else
    health_add INFO 'UFW 状态' '未安装'
  fi

  health_add INFO 'BBR/qdisc' "$(read_sysctl net.ipv4.tcp_congestion_control) / $(read_sysctl net.core.default_qdisc)"
  if command -v sing-box >/dev/null 2>&1; then
    health_add INFO 'sing-box' "已安装，$(service_state sing-box.service)"
  else
    health_add INFO 'sing-box' '未安装'
  fi
  if command -v smartdns >/dev/null 2>&1; then
    health_add INFO 'SmartDNS' "已安装，$(service_state smartdns.service)"
  else
    health_add INFO 'SmartDNS' '未安装'
  fi

  local virtualization='未知'
  command -v systemd-detect-virt >/dev/null 2>&1 &&
    virtualization=$(systemd-detect-virt 2>/dev/null || printf 'none')
  health_add INFO '虚拟化' "$virtualization"

  print_health_report
}

print_health_report() {
  local index
  printf '\n'
  health_box_line
  color_text '38;5;208' '###                 VPS 环境体检结果                     ###'
  printf '\n'
  health_box_line
  for index in "${!HEALTH_STATUSES[@]}"; do
    health_status_text "${HEALTH_STATUSES[$index]}"
    printf ' %-14s %s\n' "${HEALTH_LABELS[$index]}" "${HEALTH_DETAILS[$index]}"
  done
  if (( HEALTH_BLOCKERS > 0 )); then
    color_text '31' "结论：发现 $HEALTH_BLOCKERS 项阻断问题和 $HEALTH_WARNINGS 项警告，不能进入安装。"
  elif (( HEALTH_WARNINGS > 0 )); then
    color_text '33' "结论：环境符合安装要求，发现 $HEALTH_WARNINGS 项非阻断警告。"
  else
    color_text '32' '结论：环境符合安装要求，未发现阻断问题。'
  fi
  printf '\n'
  health_box_line
}

select_install_mode() {
  local choice
  while true; do
    if (( HEALTH_BLOCKERS > 0 )); then
      printf '\n1. 重新体检\n2. 退出\n' >/dev/tty
      read_tty '请选择 [1-2]: ' choice
      case "$choice" in
        1) run_health_check ;;
        2) exit 1 ;;
        *) printf '无效选择。\n' >/dev/tty ;;
      esac
      continue
    fi

    printf '\n1. 快速安装\n2. 自定义安装\n3. 退出\n' >/dev/tty
    read_tty '请选择 [1-3]: ' choice
    case "$choice" in
      1) INSTALL_MODE='快速安装'; return 0 ;;
      2) INSTALL_MODE='自定义安装'; return 0 ;;
      3) exit 0 ;;
      *) printf '无效选择。\n' >/dev/tty ;;
    esac
  done
}

require_option_value() {
  local option=$1
  local count=$2
  (( count >= 2 )) || die "$option 缺少参数。"
}

parse_args() {
  CURRENT_STEP='解析参数'

  while (( $# > 0 )); do
    case "$1" in
      --pubkey)
        require_option_value "$1" "$#"
        PUBKEY_ARGUMENT=$2
        shift 2
        ;;
      --pubkey-file)
        require_option_value "$1" "$#"
        PUBKEY_FILE=$2
        shift 2
        ;;
      --sing-box-version)
        require_option_value "$1" "$#"
        SING_BOX_VERSION=${2#v}
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "未知参数：$1。使用 --help 查看帮助。"
        ;;
    esac
  done

  validate_ssh_port "$SSH_PORT"
  if [[ -n "$SING_BOX_VERSION" ]]; then
    [[ "$SING_BOX_VERSION" =~ ^[0-9A-Za-z.+:~_-]+$ ]] ||
      die 'sing-box 版本包含不允许的字符。'
  fi
}

validate_ssh_port() {
  local port=$1
  [[ "$port" =~ ^[0-9]+$ ]] || die 'SSH 端口必须是数字。'
  (( ${#port} <= 5 )) || die 'SSH 端口长度无效。'
  (( 10#$port >= 1 && 10#$port <= 65535 )) ||
    die 'SSH 端口必须在 1 到 65535 之间。'
  (( 10#$port != 22 )) ||
    die '新 SSH 端口不能是 22；如需继续使用 22，请选择“保留 SSH 22/tcp”。'
  case "$port" in
    53|80|443|8443) die "$port 是已知 DNS/Web/代理业务端口，不能用作 SSH 端口。" ;;
  esac
}

ssh_port_has_conflict() {
  local port=$1
  local listeners
  listeners=$(ss -H -ltnp "sport = :$port" 2>/dev/null || true)
  [[ -z "$listeners" ]] && return 1
  grep -qv 'sshd' <<<"$listeners"
}

choose_custom_ssh_port() {
  local choice
  local candidate
  while true; do
    printf '\nSSH 端口：\n1. 使用默认端口 53651\n2. 输入自定义端口\n' >/dev/tty
    read_tty '请选择 [1-2]: ' choice
    case "$choice" in
      1) candidate=$DEFAULT_SSH_PORT ;;
      2) read_tty '请输入新的 SSH 端口: ' candidate ;;
      *) printf '无效选择。\n' >/dev/tty; continue ;;
    esac
    if ! [[ "$candidate" =~ ^[0-9]+$ ]] || (( ${#candidate} > 5 )) ||
      (( 10#$candidate < 1 || 10#$candidate > 65535 )); then
      printf '端口必须是 1–65535 之间的数字。\n' >/dev/tty
      continue
    fi
    if (( 10#$candidate == 22 )); then
      printf '22 不能作为“新端口”；稍后可单独选择是否保留 22/tcp。\n' >/dev/tty
      continue
    fi
    case "$candidate" in
      53|80|443|8443)
        printf '%s 是已知业务端口，请选择其他 SSH 端口。\n' "$candidate" >/dev/tty
        continue
        ;;
    esac
    if ssh_port_has_conflict "$candidate"; then
      printf '%s/tcp 已被非 sshd 进程监听，请选择其他端口。\n' "$candidate" >/dev/tty
      continue
    fi
    SSH_PORT=$candidate
    return 0
  done
}

configure_quick_choices() {
  SSH_PORT=$DEFAULT_SSH_PORT
  SKIP_UPGRADE=false
  KEEP_SSH_22=false
  OPEN_443_TCP=true
  OPEN_443_UDP=true
  ENABLE_CF_8443=true
}

configure_custom_network_choices() {
  choose_custom_ssh_port
  if ask_yes_no '是否保留 SSH 22/tcp？' false; then
    KEEP_SSH_22=true
  else
    KEEP_SSH_22=false
  fi
  if ask_yes_no '是否放行 443/tcp？' true; then
    OPEN_443_TCP=true
  else
    OPEN_443_TCP=false
  fi
  if ask_yes_no '是否放行 443/udp？' true; then
    OPEN_443_UDP=true
  else
    OPEN_443_UDP=false
  fi
  if ask_yes_no '是否仅允许 Cloudflare IP 访问 8443/tcp？' false; then
    ENABLE_CF_8443=true
  else
    ENABLE_CF_8443=false
  fi
}

select_smartdns_target() {
  local debian_version=$1
  local architecture=$2

  case "$debian_version:$architecture" in
    12:amd64)
      SMARTDNS_EXPECTED_VERSION='40+dfsg-1'
      SMARTDNS_CONFIG_VARIANT='v40'
      SMARTDNS_ASSET_NAME='smartdns_40+dfsg-1_bookworm_amd64.deb'
      SMARTDNS_EXPECTED_SHA256='8388fb543f870fc77d17dbaa9874277d2ef37d120ad2ab24af730d7032a80bcb'
      ;;
    12:arm64)
      SMARTDNS_EXPECTED_VERSION='40+dfsg-1'
      SMARTDNS_CONFIG_VARIANT='v40'
      SMARTDNS_ASSET_NAME='smartdns_40+dfsg-1_bookworm_arm64.deb'
      SMARTDNS_EXPECTED_SHA256='7aadb6fb0e6d2f38d8ce11db60561c2c8c7c9d0aacf1e54f9e27f44a4abfb9ca'
      ;;
    13:amd64)
      SMARTDNS_EXPECTED_VERSION='46.1+dfsg-1.1~deb13u1'
      SMARTDNS_CONFIG_VARIANT='v46'
      SMARTDNS_ASSET_NAME='smartdns_46.1+dfsg-1.1.deb13u1_trixie_amd64.deb'
      SMARTDNS_EXPECTED_SHA256='d2dfe591dbdabf3655c2ead30975ee20f6720346552bda989b212ccffde5ba4e'
      ;;
    13:arm64)
      SMARTDNS_EXPECTED_VERSION='46.1+dfsg-1.1~deb13u1'
      SMARTDNS_CONFIG_VARIANT='v46'
      SMARTDNS_ASSET_NAME='smartdns_46.1+dfsg-1.1.deb13u1_trixie_arm64.deb'
      SMARTDNS_EXPECTED_SHA256='d9eeb9050ab6e0c95011de83955f65ca8020779c8c32aba90d708bc54c33823f'
      ;;
    *)
      die "不支持的 Debian/架构组合：Debian $debian_version，$architecture；仅支持 Debian 12/13 的 amd64/arm64。"
      ;;
  esac
  SMARTDNS_DOWNLOAD_URL="$SMARTDNS_RELEASE_BASE/$SMARTDNS_ASSET_NAME"
}

validate_smartdns_platform() {
  local os_id=$1
  local debian_version=$2
  local architecture=$3

  [[ "$os_id" == 'debian' ]] ||
    die "仅支持 Debian，当前系统 ID=${os_id:-未知}。"
  case "$debian_version" in
    12|13) ;;
    *) die "仅支持 Debian 12 或 Debian 13，当前 VERSION_ID=${debian_version:-未知}。" ;;
  esac
  case "$architecture" in
    amd64|arm64) ;;
    *) die "仅支持 amd64 或 arm64，当前架构为 ${architecture:-未知}。" ;;
  esac
  select_smartdns_target "$debian_version" "$architecture"
}

preflight() {
  CURRENT_STEP='运行环境预检'
  local os_id
  (( EUID == 0 )) || die '必须以 root 身份运行。'
  [[ -r /etc/os-release ]] || die '无法读取 /etc/os-release。'

  command -v dpkg >/dev/null 2>&1 || die '缺少 dpkg。'
  os_id=$(awk -F= '$1 == "ID" { print $2; exit }' /etc/os-release | tr -d '"')
  DEBIAN_VERSION=$(awk -F= '$1 == "VERSION_ID" { print $2; exit }' \
    /etc/os-release | tr -d '"')
  CPU_ARCH=$(dpkg --print-architecture)
  validate_smartdns_platform "$os_id" "$DEBIAN_VERSION" "$CPU_ARCH"

  [[ -d /run/systemd/system ]] || die '此脚本要求 systemd 正在运行。'
  command -v systemctl >/dev/null 2>&1 || die '缺少 systemctl。'
  command -v apt-get >/dev/null 2>&1 || die '缺少 apt-get。'
  command -v mktemp >/dev/null 2>&1 || die '缺少 mktemp。'
  command -v base64 >/dev/null 2>&1 || die '缺少 base64。'
  TMP_DIR=$(mktemp -d -t 404notfound-bootstrap.XXXXXXXX)
  BACKUP_DIR="/var/backups/404notfound-bootstrap/$(date -u '+%Y%m%dT%H%M%SZ')-$$"
  log "环境预检通过：Debian $DEBIAN_VERSION，$CPU_ARCH；SmartDNS 固定版本 $SMARTDNS_EXPECTED_VERSION（$SMARTDNS_CONFIG_VARIANT）。"
}

collect_public_key() {
  CURRENT_STEP='取得 SSH 公钥'
  if [[ -n "$PUBKEY_FILE" ]]; then
    [[ -f "$PUBKEY_FILE" && -r "$PUBKEY_FILE" ]] ||
      die '无法读取 --pubkey-file 指定的文件。'
    PUBLIC_KEY=$(<"$PUBKEY_FILE")
    log '已从 --pubkey-file 读取公钥（内容不会写入日志）。'
  elif [[ -n "$PUBKEY_ARGUMENT" ]]; then
    PUBLIC_KEY=$PUBKEY_ARGUMENT
    log '已从 --pubkey 取得公钥（内容不会写入日志）。'
  elif [[ -r /dev/tty && -w /dev/tty ]]; then
    printf '请粘贴一个 OpenSSH 公钥并按回车（输入不会回显到日志）： ' >/dev/tty
    if ! IFS= read -r PUBLIC_KEY </dev/tty; then
      die '无法从 /dev/tty 读取公钥。'
    fi
  else
    die '未提供公钥，且没有可交互的 /dev/tty；尚未修改 SSH。'
  fi

  PUBLIC_KEY=${PUBLIC_KEY%$'\r'}
  [[ -n "$PUBLIC_KEY" ]] || die '公钥不能为空。'
  [[ "$PUBLIC_KEY" != *$'\n'* && "$PUBLIC_KEY" != *$'\r'* ]] ||
    die '一次只能提供一行 OpenSSH 公钥。'

  IFS=$' \t' read -r PUBLIC_KEY_TYPE PUBLIC_KEY_BLOB _ <<<"$PUBLIC_KEY"
  case "$PUBLIC_KEY_TYPE" in
    ssh-ed25519|ssh-rsa|ecdsa-sha2-*|sk-ssh-ed25519@openssh.com) ;;
    *) die '不支持或无法识别该 OpenSSH 公钥类型。' ;;
  esac
  [[ -n "$PUBLIC_KEY_BLOB" ]] || die '公钥数据缺失。'
  printf '%s' "$PUBLIC_KEY_BLOB" | base64 --decode >/dev/null 2>&1 ||
    die '公钥的 Base64 数据无效。'
}

apt_lock_is_held() {
  local locks
  local lock_path
  command -v lslocks >/dev/null 2>&1 || return 1
  locks=$(lslocks --noheadings --raw --output PATH 2>/dev/null || true)
  for lock_path in \
    /var/lib/dpkg/lock \
    /var/lib/dpkg/lock-frontend \
    /var/lib/apt/lists/lock \
    /var/cache/apt/archives/lock; do
    if grep -Fqx -- "$lock_path" <<<"$locks"; then
      return 0
    fi
  done
  return 1
}

wait_for_apt_locks() {
  local deadline=$((SECONDS + 300))
  local announced=false
  if ! command -v lslocks >/dev/null 2>&1; then
    warn 'lslocks 不可用；将依赖 apt/dpkg 自身的 300 秒锁等待机制。'
    return 0
  fi
  while apt_lock_is_held; do
    if [[ "$announced" == false ]]; then
      log '检测到 apt/dpkg 锁，最多等待 300 秒；不会删除锁文件。'
      announced=true
    fi
    (( SECONDS < deadline )) || die '等待 apt/dpkg 锁超时。'
    sleep 2
  done
}

apt_get() {
  wait_for_apt_locks
  apt-get -o DPkg::Lock::Timeout=300 "$@"
}

find_mismatched_debian_suites() {
  local expected=$1
  local source_file
  local -a source_files=()
  [[ -f /etc/apt/sources.list ]] && source_files+=(/etc/apt/sources.list)
  shopt -s nullglob
  source_files+=(/etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources)
  shopt -u nullglob
  for source_file in "${source_files[@]}"; do
    awk -v expected="$expected" -v source_file="$source_file" '
      function allowed(suite) {
        return suite == expected || index(suite, expected "-") == 1
      }
      function check_deb822(  count, i, suites_array) {
        if (official && suites != "") {
          count = split(suites, suites_array, /[[:space:]]+/)
          for (i = 1; i <= count; i++) {
            if (suites_array[i] != "" && !allowed(suites_array[i])) {
              print source_file ":" suites_array[i]
            }
          }
        }
        official = 0
        suites = ""
      }
      /^[[:space:]]*#/ { next }
      $1 == "deb" || $1 == "deb-src" {
        uri_index = 0
        for (i = 2; i <= NF; i++) {
          if ($i ~ /^https?:\/\//) {
            uri_index = i
            break
          }
        }
        if (uri_index > 0 &&
            $(uri_index) ~ /(deb\.debian\.org\/debian|security\.debian\.org)/ &&
            !allowed($(uri_index + 1))) {
          print source_file ":" $(uri_index + 1)
        }
        next
      }
      /^URIs:[[:space:]]*/ {
        official = ($0 ~ /(deb\.debian\.org\/debian|security\.debian\.org)/)
        next
      }
      /^Suites:[[:space:]]*/ {
        suites = $0
        sub(/^Suites:[[:space:]]*/, "", suites)
        next
      }
      /^[[:space:]]*$/ { check_deb822(); next }
      END { check_deb822() }
    ' "$source_file"
  done
}

validate_current_debian_release_sources() {
  local expected_codename
  local mismatches
  case "$DEBIAN_VERSION" in
    12) expected_codename='bookworm' ;;
    13) expected_codename='trixie' ;;
    *) die '无法确定当前 Debian 大版本对应的 APT 代号。' ;;
  esac
  mismatches=$(find_mismatched_debian_suites "$expected_codename")
  [[ -z "$mismatches" ]] ||
    die "官方 Debian APT 源不是当前大版本 $expected_codename，拒绝 full-upgrade：$mismatches"
}

validate_current_debian_apt_policy() {
  local expected_codename
  local policy_result
  case "$DEBIAN_VERSION" in
    12) expected_codename='bookworm' ;;
    13) expected_codename='trixie' ;;
    *) die '无法确定当前 Debian 大版本对应的 APT 代号。' ;;
  esac
  policy_result=$(apt-cache policy | awk -v expected="$expected_codename" '
    /^[[:space:]]*release[[:space:]]/ && /(^|,)o=Debian(,|$)/ {
      line = $0
      sub(/^[[:space:]]*release[[:space:]]+/, "", line)
      count = split(line, fields, /,/)
      suite = ""
      for (i = 1; i <= count; i++) {
        if (fields[i] ~ /^n=/) {
          suite = fields[i]
          sub(/^n=/, "", suite)
        }
      }
      if (suite == expected || index(suite, expected "-") == 1) {
        found_expected = 1
      } else if (suite != "") {
        mismatches[suite] = 1
      }
    }
    END {
      for (suite in mismatches) {
        print "MISMATCH:" suite
      }
      if (!found_expected) {
        print "MISSING:" expected
      }
    }
  ')
  [[ -z "$policy_result" ]] ||
    die "APT 元数据未限定在当前 Debian 大版本，拒绝 full-upgrade：$policy_result"
}

update_system() {
  CURRENT_STEP='更新系统'
  if [[ "$SKIP_UPGRADE" == false ]]; then
    validate_current_debian_release_sources
  fi
  log '刷新 APT 软件包索引。'
  apt_get update
  if [[ "$SKIP_UPGRADE" == true ]]; then
    log '自定义模式已选择跳过 full-upgrade。'
  else
    validate_current_debian_apt_policy
    log '执行非交互式 full-upgrade；不会自动重启。'
    apt_get full-upgrade -y
  fi
  SYSTEM_UPDATE_READY=true
}

install_base_packages() {
  CURRENT_STEP='安装基础软件包'
  log '安装基础工具、OpenSSH、UFW、chrony 和 vnStat。'
  apt_get install -y "${BASE_PACKAGES[@]}"

  local -a required_commands=(
    curl wget git rsync tar unzip xz jq nano gpg openssl socat cron
    crontab ssh sshd ssh-keygen ufw dig ip ss ping nc mtr traceroute
    tcpdump ps pgrep pkill lsof htop chronyd chronyc vnstat python3 flock file
  )
  local command_name
  for command_name in "${required_commands[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 ||
      die "安装后仍找不到关键命令：$command_name。"
  done
  BASE_TOOLS_READY=true
  log '基础软件包及关键命令验证通过。'
}

validate_public_key() {
  CURRENT_STEP='验证 SSH 公钥'
  local key_file
  key_file=$(mktemp "$TMP_DIR/public-key.XXXXXXXX")
  printf '%s\n' "$PUBLIC_KEY" >"$key_file"
  ssh-keygen -l -f "$key_file" >/dev/null 2>&1 ||
    die 'ssh-keygen 无法验证该 OpenSSH 公钥。'
  PUBLIC_KEY_FINGERPRINT=$(
    ssh-keygen -l -f "$key_file" | awk 'NR == 1 { print $2 }'
  )
  [[ -n "$PUBLIC_KEY_FINGERPRINT" ]] || die '无法取得公钥指纹。'
  log 'OpenSSH 公钥验证通过（公钥和指纹均未写入日志）。'
}

backup_file() {
  local source_path=$1
  local backup_path="$BACKUP_DIR$source_path"
  local absent_marker="$backup_path.absent"
  if [[ -e "$backup_path" || -e "$absent_marker" ]]; then
    return 0
  fi
  mkdir -p -- "$(dirname "$backup_path")"
  if [[ -e "$source_path" || -L "$source_path" ]]; then
    cp -a -- "$source_path" "$backup_path"
  else
    : >"$absent_marker"
  fi
}

restore_file() {
  local target_path=$1
  local backup_path="$BACKUP_DIR$target_path"
  if [[ -e "$backup_path.absent" ]]; then
    rm -f -- "$target_path"
  elif [[ -e "$backup_path" || -L "$backup_path" ]]; then
    mkdir -p -- "$(dirname "$target_path")"
    cp -a -- "$backup_path" "$target_path"
  else
    warn "找不到 $target_path 的本轮备份，无法自动恢复。"
    return 1
  fi
}

write_managed_file() {
  local target_path=$1
  local mode=$2
  local owner=$3
  local group=$4
  local staged_file
  [[ ! -L "$target_path" ]] || die "$target_path 是符号链接，拒绝覆盖。"
  LAST_WRITE_CHANGED=false
  staged_file=$(mktemp "$TMP_DIR/managed.XXXXXXXX")
  cat >"$staged_file"
  if [[ -f "$target_path" ]] && cmp -s -- "$staged_file" "$target_path"; then
    backup_file "$target_path"
    chmod "$mode" "$target_path"
    chown "$owner:$group" "$target_path"
    return 0
  fi
  backup_file "$target_path"
  install -D -o "$owner" -g "$group" -m "$mode" "$staged_file" "$target_path"
  LAST_WRITE_CHANGED=true
}

configure_chrony() {
  CURRENT_STEP='配置时间同步'
  systemctl enable --now chrony.service
  chronyc makestep || warn 'chronyc makestep 暂时失败；chrony 将继续在后台同步。'
  log 'timedatectl 状态：'
  timedatectl status || warn 'timedatectl 暂时无法返回完整状态。'
  log 'chrony 跟踪状态：'
  chronyc tracking || warn 'chrony 首次同步可能尚未完成。'
  log 'chrony 时间源：'
  chronyc sources || warn 'chrony 暂时没有可用时间源。'
  systemctl is-active --quiet chrony.service ||
    die 'chrony 服务未处于 active 状态。'
}

install_authorized_key() {
  CURRENT_STEP='安装 root SSH 公钥'
  local existing_fingerprints
  [[ ! -L /root/.ssh && ! -L "$AUTHORIZED_KEYS" ]] ||
    die '拒绝通过符号链接写入 root SSH 密钥目录或 authorized_keys。'
  install -d -o root -g root -m 0700 /root/.ssh
  backup_file "$AUTHORIZED_KEYS"
  touch "$AUTHORIZED_KEYS"
  chown root:root "$AUTHORIZED_KEYS"
  chmod 0600 "$AUTHORIZED_KEYS"

  existing_fingerprints=$(
    ssh-keygen -l -f "$AUTHORIZED_KEYS" 2>/dev/null |
      awk '{ print $2 }' || true
  )
  if grep -Fqx -- "$PUBLIC_KEY_FINGERPRINT" <<<"$existing_fingerprints"; then
    log 'authorized_keys 已包含相同公钥，未重复追加。'
  else
    printf '%s\n' "$PUBLIC_KEY" >>"$AUTHORIZED_KEYS"
    log '公钥已添加到 /root/.ssh/authorized_keys（内容未写入日志）。'
  fi

  chown root:root /root/.ssh "$AUTHORIZED_KEYS"
  chmod 0700 /root/.ssh
  chmod 0600 "$AUTHORIZED_KEYS"
  ssh-keygen -l -f "$AUTHORIZED_KEYS" >/dev/null 2>&1 ||
    die 'authorized_keys 中没有可由 ssh-keygen 识别的有效公钥。'
}

record_ssh_change() {
  local path=$1
  local existing
  for existing in "${SSH_CHANGED_FILES[@]}"; do
    [[ "$existing" == "$path" ]] && return 0
  done
  SSH_CHANGED_FILES+=("$path")
}

neutralize_ssh_conflicts() {
  local config_file=$1
  local staged_file
  [[ -f "$config_file" ]] || return 0
  if [[ -L "$config_file" ]]; then
    warn "跳过符号链接 SSH 配置：$config_file；最终 sshd -T 将检查其影响。"
    return 0
  fi

  staged_file=$(mktemp "$TMP_DIR/ssh-conflict.XXXXXXXX")
  awk '
    BEGIN {
      global_scope = 1
      blocked["port"] = 1
      blocked["permitrootlogin"] = 1
      blocked["allowusers"] = 1
      blocked["allowgroups"] = 1
      blocked["denyusers"] = 1
      blocked["denygroups"] = 1
      blocked["pubkeyauthentication"] = 1
      blocked["authenticationmethods"] = 1
      blocked["passwordauthentication"] = 1
      blocked["kbdinteractiveauthentication"] = 1
      blocked["challengeresponseauthentication"] = 1
      blocked["permitemptypasswords"] = 1
      blocked["usepam"] = 1
      blocked["x11forwarding"] = 1
    }
    {
      trimmed = $0
      sub(/^[[:space:]]+/, "", trimmed)
      split(trimmed, fields, /[[:space:]]+/)
      keyword = tolower(fields[1])
      if (keyword == "match") {
        global_scope = 0
      }
      if (global_scope && blocked[keyword]) {
        print "# Disabled by 404notfound bootstrap: " $0
        next
      }
      print
    }
  ' "$config_file" >"$staged_file"

  if ! cmp -s -- "$config_file" "$staged_file"; then
    backup_file "$config_file"
    install -o root -g root -m 0644 "$staged_file" "$config_file"
    record_ssh_change "$config_file"
  fi
}

ensure_standard_ssh_dropin_include() {
  local staged_file
  local wildcard_path="$SSH_DROPIN_DIR/*.conf"
  [[ -f "$SSH_MAIN_CONFIG" && ! -L "$SSH_MAIN_CONFIG" ]] ||
    die "$SSH_MAIN_CONFIG 必须是普通文件。"

  staged_file=$(mktemp "$TMP_DIR/sshd-main-stage.XXXXXXXX")
  awk -v wildcard_path="$wildcard_path" -v managed_path="$SSH_DROPIN" '
    BEGIN {
      global_scope = 1
    }
    function keep(line) {
      lines[++line_count] = line
    }
    $0 == "# BEGIN 404NOTFOUND BOOTSTRAP INCLUDE" { skipping = 1; next }
    $0 == "# END 404NOTFOUND BOOTSTRAP INCLUDE" {
      skipping = 0
      next
    }
    skipping { next }
    {
      trimmed = $0
      sub(/^[[:space:]]+/, "", trimmed)
      body = trimmed
      sub(/[[:space:]]+#.*$/, "", body)
      field_count = split(body, fields, /[[:space:]]+/)
      keyword = tolower(fields[1])
      if (keyword == "match") {
        global_scope = 0
      }
      if (keyword == "include") {
        target_found = 0
        keep_wildcard = 0
        other_count = 0
        for (other_index in other_fields) {
          delete other_fields[other_index]
        }
        for (field = 2; field <= field_count; field++) {
          if (fields[field] == managed_path) {
            target_found = 1
            continue
          }
          if (fields[field] == wildcard_path) {
            target_found = 1
            if (global_scope && !wildcard_seen) {
              keep_wildcard = 1
            }
            continue
          }
          other_fields[++other_count] = fields[field]
        }
        if (target_found) {
          if (keep_wildcard) {
            keep("Include " wildcard_path)
            wildcard_seen = 1
          }
          if (other_count > 0) {
            rebuilt = "Include"
            for (field = 1; field <= other_count; field++) {
              rebuilt = rebuilt " " other_fields[field]
            }
            keep(rebuilt)
          }
          next
        }
      }
      keep($0)
    }
    END {
      if (!wildcard_seen) {
        print "Include " wildcard_path
      }
      for (line = 1; line <= line_count; line++) {
        print lines[line]
      }
    }
  ' "$SSH_MAIN_CONFIG" >"$staged_file"

  if ! cmp -s -- "$SSH_MAIN_CONFIG" "$staged_file"; then
    backup_file "$SSH_MAIN_CONFIG"
    install -o root -g root -m 0644 "$staged_file" "$SSH_MAIN_CONFIG"
    record_ssh_change "$SSH_MAIN_CONFIG"
  fi
}

write_ssh_dropin() {
  [[ ! -L "$SSH_DROPIN" ]] || die "$SSH_DROPIN 不能是符号链接。"
  local staged_content
  staged_content=$(mktemp "$TMP_DIR/ssh-hardening.XXXXXXXX")
  {
    printf '%s\n' \
      '# Managed by 404notfound/404notfound.sh.' \
      '# Proxy application configuration intentionally does not belong here.'
    if [[ "$KEEP_SSH_22" == true ]]; then
      printf '%s\n' 'Port 22'
    fi
    cat <<EOF
Port $SSH_PORT
PermitRootLogin prohibit-password
AllowUsers root
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
UsePAM yes
X11Forwarding no
EOF
  } >"$staged_content"
  write_managed_file "$SSH_DROPIN" 0644 root root <"$staged_content"
  if [[ "$LAST_WRITE_CHANGED" == true ]]; then
    record_ssh_change "$SSH_DROPIN"
  fi
}

prepare_ssh_configuration() {
  local config_file
  local -a dropin_files=()
  mkdir -p "$SSH_DROPIN_DIR"
  write_ssh_dropin
  ensure_standard_ssh_dropin_include
  if [[ -e "$LEGACY_SSH_DROPIN" || -L "$LEGACY_SSH_DROPIN" ]]; then
    backup_file "$LEGACY_SSH_DROPIN"
    rm -f -- "$LEGACY_SSH_DROPIN"
    record_ssh_change "$LEGACY_SSH_DROPIN"
  fi
  neutralize_ssh_conflicts "$SSH_MAIN_CONFIG"

  shopt -s nullglob
  dropin_files=("$SSH_DROPIN_DIR"/*.conf)
  shopt -u nullglob
  for config_file in "${dropin_files[@]}"; do
    [[ "$config_file" == "$SSH_DROPIN" ]] && continue
    neutralize_ssh_conflicts "$config_file"
  done
}

sshd_value_is() {
  local config=$1
  local key=$2
  local expected=$3
  awk -v key="$key" -v expected="$expected" \
    '$1 == key && $2 == expected { found = 1 } END { exit !found }' <<<"$config"
}

validate_effective_sshd_config() {
  local port
  local port_count=0
  local found_new_port=false
  local found_port_22=false
  SSHD_EFFECTIVE=''
  SSHD_EFFECTIVE_ROOT=''
  SSHD_EFFECTIVE=$(sshd -T 2>/dev/null) || return 1
  SSHD_EFFECTIVE_ROOT=$(sshd -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null) ||
    return 1

  while IFS= read -r port; do
    [[ -n "$port" ]] || continue
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    ((port_count += 1))
    case "$port" in
      "$SSH_PORT") found_new_port=true ;;
      22) found_port_22=true ;;
      *) return 1 ;;
    esac
  done < <(awk '$1 == "port" { print $2 }' <<<"$SSHD_EFFECTIVE" | sort -nu)
  [[ "$found_new_port" == true ]] || return 1
  if [[ "$KEEP_SSH_22" == true ]]; then
    [[ "$found_port_22" == true ]] || return 1
    (( port_count == 2 )) || return 1
  else
    [[ "$found_port_22" == false ]] || return 1
    (( port_count == 1 )) || return 1
  fi

  if ! sshd_value_is "$SSHD_EFFECTIVE_ROOT" permitrootlogin prohibit-password &&
    ! sshd_value_is "$SSHD_EFFECTIVE_ROOT" permitrootlogin without-password; then
    return 1
  fi
  awk '$1 == "allowusers" && NF == 2 && $2 == "root" { found = 1 }
    END { exit !found }' <<<"$SSHD_EFFECTIVE_ROOT" || return 1
  sshd_value_is "$SSHD_EFFECTIVE_ROOT" pubkeyauthentication yes || return 1
  sshd_value_is "$SSHD_EFFECTIVE_ROOT" authenticationmethods publickey || return 1
  sshd_value_is "$SSHD_EFFECTIVE_ROOT" passwordauthentication no || return 1
  sshd_value_is "$SSHD_EFFECTIVE_ROOT" kbdinteractiveauthentication no || return 1
  sshd_value_is "$SSHD_EFFECTIVE_ROOT" permitemptypasswords no || return 1
  sshd_value_is "$SSHD_EFFECTIVE_ROOT" usepam yes || return 1
  sshd_value_is "$SSHD_EFFECTIVE_ROOT" x11forwarding no || return 1
}

print_effective_sshd_diagnostics() {
  local key
  local config
  local value
  warn 'sshd -T 策略验证失败；回滚前记录以下实际有效值：'
  for key in \
    port \
    permitrootlogin \
    allowusers \
    pubkeyauthentication \
    authenticationmethods \
    passwordauthentication \
    kbdinteractiveauthentication \
    permitemptypasswords \
    usepam \
    x11forwarding; do
    config=$SSHD_EFFECTIVE_ROOT
    if [[ "$key" == 'port' ]]; then
      config=$SSHD_EFFECTIVE
      value=$(
        awk '$1 == "port" { print $2 }' <<<"$config" |
          sort -nu |
          awk 'BEGIN { separator = "" }
            { output = output separator $0; separator = "," }
            END { print output }'
      )
    else
      value=$(
        awk -v key="$key" '
          $1 == key {
            $1 = ""
            sub(/^[[:space:]]+/, "")
            if (!seen[$0]++) {
              output = output separator $0
              separator = ","
            }
          }
          END { print output }
        ' <<<"$config"
      )
    fi
    printf '[WARN] sshd -T %-30s %s\n' "$key" "${value:-<missing>}" >&2
  done
}

rollback_ssh_configuration() {
  local index
  local restore_failed=false
  SSH_ROLLBACK_STATE='回滚处理中'
  warn '正在恢复本轮修改过的 SSH 配置文件；当前 SSH 会话不会被主动断开。'
  set +e
  for (( index=${#SSH_CHANGED_FILES[@]} - 1; index >= 0; index-- )); do
    restore_file "${SSH_CHANGED_FILES[$index]}" || restore_failed=true
  done
  if [[ "$restore_failed" == false ]] && sshd -t >/dev/null 2>&1 &&
    systemctl is-active --quiet ssh.service && systemctl reload ssh.service; then
    SSH_ROLLBACK_STATE='已回滚'
  else
    SSH_ROLLBACK_STATE='已尝试回滚，但未完全确认'
    warn '旧 SSH 配置未能自动 reload；当前已有 sshd 进程和会话保持不动。'
  fi
  set -e
}

is_tcp_port_listening() {
  local port=$1
  [[ -n "$(ss -H -ltn "sport = :$port" 2>/dev/null)" ]]
}

ufw_is_active() {
  local status_output
  status_output=$(ufw status 2>/dev/null || true)
  grep -q '^Status: active$' <<<"$status_output"
}

ufw_allows_port() {
  local port_protocol=$1
  local status_output
  status_output=$(ufw status 2>/dev/null || true)
  awk -v target="$port_protocol" \
    '$1 == target && toupper($2) == "ALLOW" { found = 1 } END { exit !found }' \
    <<<"$status_output"
}

backup_ufw_configuration() {
  local path
  for path in \
    /etc/default/ufw \
    /etc/ufw/ufw.conf \
    /etc/ufw/user.rules \
    /etc/ufw/user6.rules; do
    backup_file "$path"
  done
}

preauthorize_active_ufw() {
  if ufw_is_active && ! ufw_allows_port "$SSH_PORT/tcp"; then
    backup_ufw_configuration
    log "UFW 原本已启用；先保留现有规则并预放行 $SSH_PORT/tcp。"
    ufw allow "$SSH_PORT/tcp"
  fi
}

configure_ssh() {
  CURRENT_STEP='配置并验证 SSH'
  systemctl is-active --quiet ssh.service ||
    die 'ssh.service 当前未运行；为避免锁死，脚本不会尝试替换现有连接方式。'
  if systemctl is-active --quiet ssh.socket; then
    die '检测到 ssh.socket 套接字激活；第一版不会自动转换它，以免锁死。请先改用 ssh.service。'
  fi

  prepare_ssh_configuration
  if ! sshd -t; then
    rollback_ssh_configuration
    die 'sshd -t 失败，已尝试恢复本轮 SSH 配置。'
  fi
  if ! validate_effective_sshd_config; then
    print_effective_sshd_diagnostics
    rollback_ssh_configuration
    die 'sshd -T 的最终端口或认证策略不符合目标，已尝试恢复。'
  fi
  ssh-keygen -l -f "$AUTHORIZED_KEYS" >/dev/null 2>&1 || {
    rollback_ssh_configuration
    die 'authorized_keys 最终验证失败，未 reload SSH。'
  }

  preauthorize_active_ufw
  if ! systemctl reload ssh.service; then
    rollback_ssh_configuration
    die 'reload ssh.service 失败，已尝试恢复旧配置。'
  fi

  for _ in {1..10}; do
    is_tcp_port_listening "$SSH_PORT" && break
    sleep 1
  done
  if ! is_tcp_port_listening "$SSH_PORT"; then
    rollback_ssh_configuration
    die "$SSH_PORT/tcp 未开始监听；未启用或收紧 UFW。"
  fi
  if [[ "$KEEP_SSH_22" == true ]] && ! is_tcp_port_listening 22; then
    rollback_ssh_configuration
    die '已选择保留 22/tcp，但 reload 后该端口未监听；未启用或收紧 UFW。'
  fi
  if [[ "$KEEP_SSH_22" == false ]] && is_tcp_port_listening 22; then
    rollback_ssh_configuration
    die '22/tcp 仍在监听；未启用或收紧 UFW。'
  fi
  if ! validate_effective_sshd_config; then
    print_effective_sshd_diagnostics
    rollback_ssh_configuration
    die 'reload 后 sshd 最终策略验证失败；未启用或收紧 UFW。'
  fi

  SSH_READY=true
  if [[ "$KEEP_SSH_22" == true ]]; then
    log "SSH 已通过 sshd -t、sshd -T 和监听检查：22/tcp 与 $SSH_PORT/tcp。"
  else
    log "SSH 已通过 sshd -t、sshd -T 和监听检查：仅目标端口 $SSH_PORT/tcp。"
  fi
}

ensure_ufw_ipv6() {
  local target='/etc/default/ufw'
  local staged_file
  [[ -f "$target" && ! -L "$target" ]] || die "$target 必须是普通文件。"
  staged_file=$(mktemp "$TMP_DIR/ufw-default.XXXXXXXX")
  awk '
    BEGIN { replaced = 0 }
    /^IPV6=/ {
      print "IPV6=yes"
      replaced = 1
      next
    }
    { print }
    END {
      if (!replaced) {
        print "IPV6=yes"
      }
    }
  ' "$target" >"$staged_file"
  if ! cmp -s -- "$target" "$staged_file"; then
    backup_file "$target"
    install -o root -g root -m 0644 "$staged_file" "$target"
  fi
}

find_any_ufw_allow_rule() {
  local target=$1
  ufw status numbered 2>/dev/null | awk -v target="$target" '
    {
      original = $0
      sub(/^\[[[:space:]]*[0-9]+\][[:space:]]*/, "", $0)
      field = 2
      if ($2 == "(v6)") {
        field = 3
      }
      if ($1 == target && toupper($(field)) == "ALLOW" &&
          toupper($(field + 1)) == "IN") {
        number = original
        sub(/^\[[[:space:]]*/, "", number)
        sub(/\].*$/, "", number)
        print number
      }
    }
  '
}

find_unmanaged_8443_rule() {
  ufw status numbered 2>/dev/null | awk '
    {
      original = $0
      sub(/^\[[[:space:]]*[0-9]+\][[:space:]]*/, "", $0)
      field = 2
      if ($2 == "(v6)") {
        field = 3
      }
      if ($1 == "8443/tcp" && toupper($(field)) == "ALLOW" &&
          toupper($(field + 1)) == "IN" && original !~ /# Cloudflare-8443/) {
        number = original
        sub(/^\[[[:space:]]*/, "", number)
        sub(/\].*$/, "", number)
        print number
      }
    }
  '
}

delete_ufw_rule_numbers() {
  local rule_number
  local count=0
  while IFS= read -r rule_number; do
    [[ -n "$rule_number" ]] || continue
    ((count += 1))
    (( count <= 200 )) || die '清理 UFW 规则超过安全上限。'
    ufw --force delete "$rule_number"
  done < <(sort -rn)
}

remove_all_ufw_allows() {
  local target=$1
  local rule_number
  while rule_number=$(find_any_ufw_allow_rule "$target") &&
    [[ -n "$rule_number" ]]; do
    printf '%s\n' "$rule_number" | delete_ufw_rule_numbers
  done
}

remove_unmanaged_8443_allows() {
  local rule_number
  while rule_number=$(find_unmanaged_8443_rule) && [[ -n "$rule_number" ]]; do
    printf '%s\n' "$rule_number" | delete_ufw_rule_numbers
  done
}

ufw_has_comment() {
  local comment=$1
  ufw status 2>/dev/null | grep -Fq -- "# $comment"
}

verify_ufw() {
  ufw_is_active || return 1
  ufw_allows_port "$SSH_PORT/tcp" || return 1
  if [[ "$KEEP_SSH_22" == true ]]; then
    ufw_allows_port '22/tcp' || return 1
  else
    [[ -z "$(find_any_ufw_allow_rule '22/tcp')" ]] || return 1
    [[ -z "$(find_any_ufw_allow_rule 'OpenSSH')" ]] || return 1
  fi
  if [[ "$OPEN_443_TCP" == true ]]; then
    ufw_allows_port '443/tcp' || return 1
  else
    [[ -z "$(find_any_ufw_allow_rule '443/tcp')" ]] || return 1
  fi
  if [[ "$OPEN_443_UDP" == true ]]; then
    ufw_allows_port '443/udp' || return 1
  else
    [[ -z "$(find_any_ufw_allow_rule '443/udp')" ]] || return 1
  fi
  if [[ "$ENABLE_CF_8443" == true ]]; then
    ufw_has_comment 'Cloudflare-8443' || return 1
    [[ -z "$(find_unmanaged_8443_rule)" ]] || return 1
  else
    ! ufw_has_comment 'Cloudflare-8443' || return 1
    [[ -z "$(find_any_ufw_allow_rule '8443/tcp')" ]] || return 1
  fi
}

install_cloudflare_ufw_tool() {
  CURRENT_STEP='安装 Cloudflare 8443 UFW 更新工具'
  write_managed_file "$CLOUDFLARE_UFW_TOOL" 0755 root root <<'CLOUDFLARE_UFW_TOOL'
#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
export LC_ALL=C

readonly PORT='8443'
readonly COMMENT='Cloudflare-8443'
readonly LOCK_FILE='/run/lock/404notfound-cloudflare-ufw.lock'

TMP_DIR=''
BACKUP_DIR=''

cleanup() {
  local exit_code=$?
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR"
  fi
  exit "$exit_code"
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

trap cleanup EXIT
trap 'printf "[ERROR] Cloudflare UFW 更新在第 %s 行失败。\n" "$LINENO" >&2' ERR
trap 'printf "[WARN] 收到中断信号，停止更新。\n" >&2; exit 130' INT TERM

(( EUID == 0 )) || die '必须以 root 身份运行。'
command -v curl >/dev/null 2>&1 || die '缺少 curl。'
command -v flock >/dev/null 2>&1 || die '缺少 flock。'
command -v python3 >/dev/null 2>&1 || die '缺少 python3，无法严格校验 CIDR。'
command -v ufw >/dev/null 2>&1 || die '缺少 ufw。'

mkdir -p -- "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
flock -n 9 || die '已有另一个 Cloudflare UFW 更新正在运行。'

TMP_DIR=$(mktemp -d -t cloudflare-ufw.XXXXXXXX)

ufw status | grep -q '^Status: active$' ||
  die 'UFW 必须处于 active 状态，才能可靠更新并核对 Cloudflare 规则。'

BACKUP_DIR="/var/backups/404notfound-cloudflare-ufw/$(date -u '+%Y%m%dT%H%M%SZ')-$$"
install -d -o root -g root -m 0700 "$BACKUP_DIR/etc/ufw"
for ufw_file in /etc/ufw/user.rules /etc/ufw/user6.rules; do
  if [[ -e "$ufw_file" ]]; then
    cp -a -- "$ufw_file" "$BACKUP_DIR$ufw_file"
  fi
done

ufw_ipv6_enabled() {
  [[ -r /etc/default/ufw ]] && grep -Eq '^IPV6=yes([[:space:]]*)$' /etc/default/ufw
}

download_cidr_list() {
  local url=$1
  local destination=$2
  curl --fail --silent --show-error --location \
    --connect-timeout 5 --max-time 30 --retry 3 --retry-delay 1 \
    "$url" --output "$destination"
  [[ -s "$destination" ]] || die "下载结果为空：$url"
}

validate_cidr_file() {
  local family=$1
  local path=$2
  python3 - "$family" "$path" <<'PY'
import ipaddress
import pathlib
import sys

family = int(sys.argv[1])
path = pathlib.Path(sys.argv[2])
lines = [line.strip() for line in path.read_text(encoding="ascii").splitlines() if line.strip()]
if not lines:
    raise SystemExit("CIDR list is empty")
for line in lines:
    network = ipaddress.ip_network(line, strict=True)
    if network.version != family:
        raise SystemExit(f"unexpected IPv{network.version} CIDR: {line}")
PY
}

managed_rule_numbers() {
  ufw status numbered | awk -v comment="$COMMENT" '
    index($0, "# " comment) {
      number = $0
      sub(/^\[[[:space:]]*/, "", number)
      sub(/\].*$/, "", number)
      print number
    }
  '
}

global_8443_rule_numbers() {
  ufw status numbered | awk -v port="$PORT/tcp" '
    {
      original = $0
      sub(/^\[[[:space:]]*[0-9]+\][[:space:]]*/, "", $0)
      field = 2
      if ($2 == "(v6)") {
        field = 3
      }
      if ($1 == port && toupper($(field)) == "ALLOW" &&
          toupper($(field + 1)) == "IN" && $(field + 2) == "Anywhere") {
        number = original
        sub(/^\[[[:space:]]*/, "", number)
        sub(/\].*$/, "", number)
        print number
      }
    }
  '
}

delete_rule_numbers() {
  local number
  while IFS= read -r number; do
    [[ -n "$number" ]] || continue
    ufw --force delete "$number"
  done < <(sort -rn)
}

remove_managed_rules() {
  managed_rule_numbers | delete_rule_numbers
}

if [[ "${1:-}" == '--remove' ]]; then
  remove_managed_rules
  global_8443_rule_numbers | delete_rule_numbers
  (( $(managed_rule_numbers | wc -l) == 0 )) || die 'Cloudflare-8443 规则未完全删除。'
  printf 'Cloudflare 8443 规则已删除。备份：%s\n' "$BACKUP_DIR"
  exit 0
fi
(( $# == 0 )) || die '唯一支持的参数是 --remove。'

download_cidr_list 'https://www.cloudflare.com/ips-v4' "$TMP_DIR/v4"
download_cidr_list 'https://www.cloudflare.com/ips-v6' "$TMP_DIR/v6"
validate_cidr_file 4 "$TMP_DIR/v4"
validate_cidr_file 6 "$TMP_DIR/v6"

awk 'NF { print }' "$TMP_DIR/v4" >"$TMP_DIR/desired"
if ufw_ipv6_enabled; then
  awk 'NF { print }' "$TMP_DIR/v6" >>"$TMP_DIR/desired"
fi

# Add the complete new set first. UFW ignores exact duplicates, so the old
# allow-list remains effective until every new source has been prepared.
while IFS= read -r cidr; do
  [[ -n "$cidr" ]] || continue
  ufw allow proto tcp from "$cidr" to any port "$PORT" comment "$COMMENT"
done <"$TMP_DIR/desired"

# Remove stale and duplicate managed rules only after the new set exists.
ufw status numbered | awk -v comment="$COMMENT" -v desired="$TMP_DIR/desired" '
  BEGIN {
    while ((getline line < desired) > 0) {
      wanted[line] = 1
    }
    close(desired)
  }
  index($0, "# " comment) {
    original = $0
    sub(/^\[[[:space:]]*[0-9]+\][[:space:]]*/, "", $0)
    field = 2
    if ($2 == "(v6)") {
      field = 3
    }
    source = $(field + 2)
    number = original
    sub(/^\[[[:space:]]*/, "", number)
    sub(/\].*$/, "", number)
    if (!wanted[source] || seen[source]++) {
      print number
    }
  }
' | delete_rule_numbers

# A global allow would defeat the source allow-list; remove only exact
# Anywhere rules for this port and leave unrelated restricted rules alone.
global_8443_rule_numbers | delete_rule_numbers

expected=$(awk 'NF { count++ } END { print count + 0 }' "$TMP_DIR/desired")
actual=$(managed_rule_numbers | wc -l)

printf '\nCloudflare 规则：%s/%s\n\n' "$actual" "$expected"
ufw status numbered
(( actual == expected )) || die 'Cloudflare 规则实际数量与预期不一致。'
printf '\n更新完成，规则数量正常，8443/tcp 未向全网开放。\n'
printf 'UFW 规则备份：%s\n' "$BACKUP_DIR"
CLOUDFLARE_UFW_TOOL

  bash -n "$CLOUDFLARE_UFW_TOOL" || die '内嵌 Cloudflare UFW 工具语法检查失败。'
  [[ $(stat -c '%U:%G:%a' "$CLOUDFLARE_UFW_TOOL") == 'root:root:755' ]] ||
    die 'Cloudflare UFW 工具所有者或权限验证失败。'
  log "Cloudflare UFW 更新工具已安装并验证：$CLOUDFLARE_UFW_TOOL"
}

configure_ufw() {
  CURRENT_STEP='配置 UFW'
  [[ "$SSH_READY" == true ]] || die 'SSH 安全门禁未通过，拒绝配置 UFW。'
  backup_ufw_configuration
  ensure_ufw_ipv6

  ufw default deny incoming
  ufw default allow outgoing
  remove_all_ufw_allows 'OpenSSH'

  local old_port
  local -a old_ports=()
  IFS=',' read -r -a old_ports <<<"$INITIAL_SSH_PORTS"
  for old_port in "${old_ports[@]}"; do
    [[ -n "$old_port" && "$old_port" != "$SSH_PORT" ]] || continue
    if [[ "$old_port" == 22 && "$KEEP_SSH_22" == true ]]; then
      continue
    fi
    remove_all_ufw_allows "$old_port/tcp"
  done

  ufw allow "$SSH_PORT/tcp"
  if [[ "$KEEP_SSH_22" == true ]]; then
    ufw allow 22/tcp
  else
    remove_all_ufw_allows '22/tcp'
  fi
  if [[ "$OPEN_443_TCP" == true ]]; then
    ufw allow 443/tcp
  else
    remove_all_ufw_allows '443/tcp'
  fi
  if [[ "$OPEN_443_UDP" == true ]]; then
    ufw allow 443/udp
  else
    remove_all_ufw_allows '443/udp'
  fi

  remove_unmanaged_8443_allows
  ufw --force enable
  if [[ "$ENABLE_CF_8443" == true ]]; then
    "$CLOUDFLARE_UFW_TOOL"
  else
    "$CLOUDFLARE_UFW_TOOL" --remove
  fi

  verify_ufw || die 'UFW 最终规则验证失败；请保持当前 SSH 会话并人工检查。'
  ufw status verbose
  ufw status numbered
  log 'UFW 最终规则已按安装模式验证；8443/tcp 未向全网开放。'
}

read_sysctl() {
  local key=$1
  sysctl -n "$key" 2>/dev/null || printf '不可用'
}

configure_bbr() {
  CURRENT_STEP='配置 BBR'
  local available_before
  local available_after
  local current_control
  local current_qdisc

  log "当前内核：$(uname -r)"
  available_before=$(read_sysctl net.ipv4.tcp_available_congestion_control)
  current_control=$(read_sysctl net.ipv4.tcp_congestion_control)
  current_qdisc=$(read_sysctl net.core.default_qdisc)
  log "配置前可用拥塞算法：$available_before"
  log "配置前当前拥塞算法：$current_control；默认 qdisc：$current_qdisc"

  if command -v modinfo >/dev/null 2>&1; then
    if modinfo tcp_bbr >/dev/null 2>&1; then
      log '内核提供 tcp_bbr 模块。'
    else
      warn 'modinfo 未找到 tcp_bbr；将尝试 modprobe 并以 sysctl 结果为准。'
    fi
  fi

  if [[ " $available_before " != *' bbr '* ]]; then
    if ! command -v modprobe >/dev/null 2>&1 || ! modprobe tcp_bbr; then
      warn '当前云厂商内核无法加载 tcp_bbr；不会宣称 BBR 已启用。'
      return 0
    fi
  fi

  available_after=$(read_sysctl net.ipv4.tcp_available_congestion_control)
  if [[ " $available_after " != *' bbr '* ]]; then
    warn "加载后可用拥塞算法仍不包含 bbr：$available_after"
    return 0
  fi

  write_managed_file /etc/modules-load.d/bbr.conf 0644 root root <<'EOF'
tcp_bbr
EOF
write_managed_file /etc/sysctl.d/99-bbr.conf 0644 root root <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

  if ! sysctl --system; then
    warn 'sysctl --system 返回失败；将报告实际内核状态并继续。'
  fi
  sysctl net.ipv4.tcp_available_congestion_control || true
  sysctl net.ipv4.tcp_congestion_control || true
  sysctl net.core.default_qdisc || true

  current_control=$(read_sysctl net.ipv4.tcp_congestion_control)
  current_qdisc=$(read_sysctl net.core.default_qdisc)
  if [[ "$current_control" == 'bbr' && "$current_qdisc" == 'fq' ]]; then
    log 'BBR 已验证启用，默认 qdisc 为 fq。'
  else
    warn "BBR 未达到目标状态：拥塞算法=$current_control，qdisc=$current_qdisc。"
  fi
}

configure_sagernet_repository() {
  local downloaded_key
  local fingerprints
  downloaded_key=$(mktemp "$TMP_DIR/sagernet-key.XXXXXXXX")
  curl --fail --silent --show-error --location \
    https://sing-box.app/gpg.key --output "$downloaded_key"
  [[ -s "$downloaded_key" ]] || die '下载的 SagerNet 签名密钥为空。'

  fingerprints=$(gpg --batch --with-colons --show-keys "$downloaded_key" 2>/dev/null |
    awk -F: '$1 == "fpr" { print $10 }')
  grep -Fqx "$SAGER_KEY_FINGERPRINT" <<<"$fingerprints" ||
    die 'SagerNet 签名密钥指纹不符合脚本内置值。'

  [[ ! -L /etc/apt/keyrings/sagernet.asc ]] ||
    die 'SagerNet APT 密钥路径不能是符号链接。'
  backup_file /etc/apt/keyrings/sagernet.asc
  install -D -o root -g root -m 0644 \
    "$downloaded_key" /etc/apt/keyrings/sagernet.asc
  write_managed_file /etc/apt/sources.list.d/sagernet.sources 0644 root root <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
}

sing_box_version_text() {
  local output
  output=$(sing-box version 2>&1 || true)
  printf '%s' "${output%%$'\n'*}"
}

install_sing_box() {
  CURRENT_STEP='安装 sing-box'
  configure_sagernet_repository
  apt_get update

  if [[ -n "$SING_BOX_VERSION" ]]; then
    if ! apt-cache madison sing-box | awk '{ print $3 }' |
      grep -Fqx -- "$SING_BOX_VERSION"; then
      die "官方 APT 仓库中找不到 sing-box 版本 $SING_BOX_VERSION。"
    fi
    apt_get install -y --allow-downgrades "sing-box=$SING_BOX_VERSION"
  else
    apt_get install -y sing-box
  fi

  command -v sing-box >/dev/null 2>&1 || die '安装后找不到 sing-box。'
  [[ -n "$(sing_box_version_text)" ]] || die 'sing-box version 验证失败。'
  install -d -o root -g root -m 0755 /etc/sing-box
  systemctl disable --now sing-box.service
  if systemctl is-active --quiet sing-box.service; then
    die 'sing-box 服务仍在运行。'
  fi
  log "sing-box 已安装但未运行：$(sing_box_version_text)"
}

smartdns_version_text() {
  local output
  if ! output=$(smartdns -v 2>&1); then
    return 1
  fi
  grep -qi 'invalid option' <<<"$output" && return 1
  output=$(awk 'NF { print; exit }' <<<"$output")
  [[ -n "$output" ]] || return 1
  printf '%s' "$output"
}

write_smartdns_configuration() {
  local target=$1
  local variant=$2

  cat >"$target" <<'SMARTDNS_CONFIG_COMMON'
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
dualstack-ip-selection yes
dualstack-ip-selection-threshold 10

log-level warn
log-console no
log-syslog yes
audit-enable no

ca-file /etc/ssl/certs/ca-certificates.crt

SMARTDNS_CONFIG_COMMON

  case "$variant" in
    v40)
      cat >>"$target" <<'SMARTDNS_CONFIG_VARIANT'
server-https https://1.1.1.1/dns-query -host-name cloudflare-dns.com -http-host cloudflare-dns.com -tls-host-verify cloudflare-dns.com
server-https https://8.8.8.8/dns-query -host-name dns.google -http-host dns.google -tls-host-verify dns.google
server-https https://9.9.9.10/dns-query -host-name dns.quad9.net -http-host dns.quad9.net -tls-host-verify dns.quad9.net -fallback
SMARTDNS_CONFIG_VARIANT
      ;;
    v46)
      cat >>"$target" <<'SMARTDNS_CONFIG_VARIANT'
server-https https://cloudflare-dns.com/dns-query -host-ip 1.1.1.1
server-https https://dns.google/dns-query -host-ip 8.8.8.8
server-https https://dns.quad9.net/dns-query -host-ip 9.9.9.10 -fallback
SMARTDNS_CONFIG_VARIANT
      ;;
    *)
      die "未知 SmartDNS 配置变体：$variant。"
      ;;
  esac
  [[ -s "$target" ]] || die '生成 SmartDNS 配置失败。'
}

download_and_verify_smartdns_package() {
  local actual_sha256
  local package_architecture
  local package_name
  local package_version

  SMARTDNS_PACKAGE_PATH="$TMP_DIR/$SMARTDNS_ASSET_NAME"
  if ! curl --fail --location --silent --show-error \
    --connect-timeout 10 --max-time 120 --retry 3 --retry-delay 2 \
    --retry-connrefused "$SMARTDNS_DOWNLOAD_URL" -o "$SMARTDNS_PACKAGE_PATH"; then
    die "下载固定 SmartDNS Debian 软件包失败：$SMARTDNS_ASSET_NAME。"
  fi
  [[ -s "$SMARTDNS_PACKAGE_PATH" ]] || die '下载的 SmartDNS Debian 软件包为空。'

  actual_sha256=$(sha256sum "$SMARTDNS_PACKAGE_PATH" | awk '{print $1}')
  [[ "$actual_sha256" == "$SMARTDNS_EXPECTED_SHA256" ]] ||
    die "SmartDNS 软件包 SHA-256 不匹配：期望 $SMARTDNS_EXPECTED_SHA256，实际 $actual_sha256。"
  printf '%s  %s\n' "$SMARTDNS_EXPECTED_SHA256" "$SMARTDNS_PACKAGE_PATH" |
    sha256sum --check --status || die 'sha256sum 二次校验失败。'

  dpkg-deb --info "$SMARTDNS_PACKAGE_PATH" >/dev/null ||
    die 'dpkg-deb --info 无法读取下载的软件包。'
  package_name=$(dpkg-deb --field "$SMARTDNS_PACKAGE_PATH" Package)
  package_version=$(dpkg-deb --field "$SMARTDNS_PACKAGE_PATH" Version)
  package_architecture=$(dpkg-deb --field "$SMARTDNS_PACKAGE_PATH" Architecture)
  [[ "$package_name" == 'smartdns' ]] ||
    die "下载的软件包名称不是 smartdns：$package_name。"
  [[ "$package_version" == "$SMARTDNS_EXPECTED_VERSION" ]] ||
    die "下载的软件包版本不是 $SMARTDNS_EXPECTED_VERSION：$package_version。"
  [[ "$package_architecture" == "$CPU_ARCH" ]] ||
    die "下载的软件包架构不是 $CPU_ARCH：$package_architecture。"
  log "固定 Release 资产验证通过：$SMARTDNS_ASSET_NAME，SHA-256=$actual_sha256。"
}

capture_smartdns_transaction_state() {
  SMARTDNS_WAS_HELD=false
  SMARTDNS_WAS_ENABLED=false
  SMARTDNS_WAS_ACTIVE=false
  if apt-mark showhold | grep -Fxq smartdns; then
    SMARTDNS_WAS_HELD=true
  fi
  if systemctl is-enabled --quiet smartdns.service 2>/dev/null; then
    SMARTDNS_WAS_ENABLED=true
  fi
  if systemctl is-active --quiet smartdns.service 2>/dev/null; then
    SMARTDNS_WAS_ACTIVE=true
  fi
  backup_file "$SMARTDNS_CONFIG_TARGET"
  mkdir -p -- "$BACKUP_DIR/smartdns-state"
  printf 'held=%s\nenabled=%s\nactive=%s\n' \
    "$SMARTDNS_WAS_HELD" "$SMARTDNS_WAS_ENABLED" "$SMARTDNS_WAS_ACTIVE" \
    >"$BACKUP_DIR/smartdns-state/before.txt"
  dpkg-query -W smartdns >"$BACKUP_DIR/smartdns-state/package-before.txt" 2>&1 ||
    printf 'smartdns package not installed\n' \
      >"$BACKUP_DIR/smartdns-state/package-before.txt"
}

restore_smartdns_transaction() {
  local restore_status=0

  SMARTDNS_TRANSACTION_ACTIVE=false
  set +e
  warn '正在恢复 SmartDNS 原配置、服务状态和 hold 状态。'
  rm -f -- "$SMARTDNS_CONFIG_TARGET" || restore_status=1
  restore_file "$SMARTDNS_CONFIG_TARGET" || restore_status=1
  systemctl daemon-reload >/dev/null 2>&1 || restore_status=1
  if [[ "$SMARTDNS_WAS_ENABLED" == true ]]; then
    systemctl enable smartdns.service >/dev/null 2>&1 || restore_status=1
  else
    systemctl disable smartdns.service >/dev/null 2>&1 || restore_status=1
  fi
  if [[ "$SMARTDNS_WAS_ACTIVE" == true ]]; then
    systemctl restart smartdns.service >/dev/null 2>&1 || restore_status=1
  else
    systemctl stop smartdns.service >/dev/null 2>&1 || restore_status=1
  fi
  if [[ "$SMARTDNS_WAS_HELD" == true ]]; then
    apt-mark hold smartdns >/dev/null 2>&1 || restore_status=1
  else
    apt-mark unhold smartdns >/dev/null 2>&1 || restore_status=1
  fi
  if ((restore_status == 0)); then
    warn 'SmartDNS 原配置、服务状态和 hold 状态已恢复。'
  else
    warn "SmartDNS 自动恢复未完全成功；请检查备份目录：$BACKUP_DIR。"
  fi
  return "$restore_status"
}

print_smartdns_recent_journal() {
  warn 'SmartDNS 健康检查失败；以下是 smartdns.service 最近 50 行日志：'
  journalctl -u smartdns.service -n 50 --no-pager >&2 ||
    warn '无法读取 smartdns.service journal。'
}

smartdns_health_fail() {
  local reason=$1
  print_smartdns_recent_journal
  die "$reason"
}

stop_and_clean_smartdns() {
  if ! systemctl stop smartdns.service; then
    warn '停止 smartdns.service 失败；将继续清理残留 SmartDNS 进程。'
  fi

  pkill -TERM -x smartdns 2>/dev/null || true
  for _ in {1..5}; do
    pgrep -x smartdns >/dev/null 2>&1 || break
    sleep 1
  done

  if pgrep -x smartdns >/dev/null 2>&1; then
    warn 'SmartDNS 残留进程未响应 TERM，改用 KILL 清理。'
    pkill -KILL -x smartdns 2>/dev/null || true
  fi

  rm -f -- /run/smartdns.pid /var/run/smartdns.pid
  for _ in {1..5}; do
    pgrep -x smartdns >/dev/null 2>&1 || break
    sleep 1
  done

  pgrep -x smartdns >/dev/null 2>&1 &&
    die '清理后仍检测到 SmartDNS 残留进程，拒绝继续配置。'
  systemctl is-active --quiet smartdns.service &&
    die '停止后 smartdns.service 仍处于 active 状态，拒绝继续配置。'
  log 'SmartDNS 服务已停止，残留进程和 PID 文件已清理。'
}

smartdns_package_is_current() {
  local installed_architecture
  local installed_status
  local installed_version

  installed_status=$(dpkg-query -W -f='${db:Status-Abbrev}' smartdns 2>/dev/null || true)
  installed_version=$(dpkg-query -W -f='${Version}' smartdns 2>/dev/null || true)
  installed_architecture=$(dpkg-query -W -f='${Architecture}' smartdns 2>/dev/null || true)
  [[ "$installed_status" == ii* &&
    "$installed_version" == "$SMARTDNS_EXPECTED_VERSION" &&
    "$installed_architecture" == "$CPU_ARCH" ]]
}

find_smartdns_validation_port() {
  local port
  local socket_output

  for ((port = 6053; port <= 6152; port++)); do
    socket_output=$(ss -H -lntu "sport = :$port" 2>/dev/null || true)
    if [[ -z "$socket_output" ]]; then
      printf '%s' "$port"
      return 0
    fi
  done
  return 1
}

validate_smartdns_configuration() {
  local staged_config=$1
  local validation_config
  local validation_log
  local validation_pid
  local validation_port

  validation_port=$(find_smartdns_validation_port) ||
    die '找不到可用于 SmartDNS 配置验证的本地高端口。'
  validation_config=$(mktemp "$TMP_DIR/smartdns-validation.conf.XXXXXXXX")
  validation_log=$(mktemp "$TMP_DIR/smartdns-validation.log.XXXXXXXX")
  sed \
    -e "s/^bind 127\\.0\\.0\\.1:53$/bind 127.0.0.1:$validation_port/" \
    -e "s/^bind-tcp 127\\.0\\.0\\.1:53$/bind-tcp 127.0.0.1:$validation_port/" \
    "$staged_config" >"$validation_config"

  smartdns -f -x -c "$validation_config" -p "$TMP_DIR/smartdns-validation.pid" \
    >"$validation_log" 2>&1 &
  validation_pid=$!
  sleep 2
  if ! kill -0 "$validation_pid" 2>/dev/null; then
    wait "$validation_pid" 2>/dev/null || true
    die "SmartDNS 独立配置验证启动失败：$(shorten_line "$(<"$validation_log")")"
  fi
  if ! ss -H -lntu "sport = :$validation_port" 2>/dev/null |
    grep -Fq "127.0.0.1:$validation_port"; then
    kill -TERM "$validation_pid" 2>/dev/null || true
    wait "$validation_pid" 2>/dev/null || true
    die 'SmartDNS 独立配置验证实例未监听预期端口。'
  fi
  kill -TERM "$validation_pid" 2>/dev/null || true
  wait "$validation_pid" 2>/dev/null || true
  if grep -Eiq \
    'unsupported[[:space:]]+config|configuration[[:space:]]+error|parse[[:space:]]+error|load[[:space:]]+config[[:space:]]+failed' \
    "$validation_log"; then
    die "SmartDNS 独立配置验证发现错误：$(shorten_line "$(<"$validation_log")")"
  fi
  log "SmartDNS $SMARTDNS_CONFIG_VARIANT 配置已通过独立端口 $validation_port 的短时启动验证。"
}

check_smartdns_port_53_conflicts() {
  local conflicts
  local output

  output=$(ss -H -lntup 'sport = :53' 2>/dev/null) ||
    die '无法检查 53 端口监听状态，拒绝继续配置 SmartDNS。'
  conflicts=$(awk '
    {
      endpoint = $5
      if ($0 ~ /users:\(\("smartdns"/) {
        next
      }
      is_systemd_resolved = ($0 ~ /users:\(\("systemd-resolve(d)?"/)
      if (endpoint ~ /^127\.0\.0\.(53|54)(%[^:[:space:]]+)?:53$/) {
        if (!is_systemd_resolved) {
          print
        }
        next
      }
      if (endpoint ~ /^127\.0\.0\.1(%[^:[:space:]]+)?:53$/ ||
          endpoint == "0.0.0.0:53" || endpoint == "*:53" ||
          endpoint == "[::]:53" || endpoint == "[::1]:53") {
        print
      }
    }
  ' <<<"$output")
  [[ -z "$conflicts" ]] ||
    die "53 端口存在冲突监听，拒绝覆盖：$(shorten_line "$conflicts")"
}

smartdns_listener_present() {
  local protocol=$1
  local socket_output=$2

  awk -v protocol="$protocol" '
    $1 == protocol &&
    $5 ~ /^127\.0\.0\.1(%[^:[:space:]]+)?:53$/ &&
    $0 ~ /users:\(\("smartdns"/ { found = 1 }
    END { exit !found }
  ' <<<"$socket_output"
}

first_valid_ipv4() {
  awk '
    {
      candidate = $1
      if (split(candidate, octets, /\./) != 4) {
        next
      }
      valid = 1
      for (i = 1; i <= 4; i++) {
        if (octets[i] !~ /^[0-9]+$/ || octets[i] < 0 || octets[i] > 255) {
          valid = 0
        }
      }
      if (valid) {
        print candidate
        exit
      }
    }
    END { exit !valid }
  '
}

query_smartdns_ipv4() {
  local attempt
  local candidate
  local output
  local query_status

  SMARTDNS_IPV4_ANSWER=''
  SMARTDNS_IPV4_ATTEMPTS=0
  SMARTDNS_LAST_DIG_OUTPUT=''
  for attempt in {1..10}; do
    SMARTDNS_IPV4_ATTEMPTS=$attempt
    if output=$(dig @127.0.0.1 cloudflare.com A +short +time=4 +tries=1 2>&1); then
      query_status=0
    else
      query_status=$?
    fi
    SMARTDNS_LAST_DIG_OUTPUT=$output
    candidate=$(first_valid_ipv4 <<<"$output" || true)
    if ((query_status == 0)) && [[ -n "$candidate" ]]; then
      SMARTDNS_IPV4_ANSWER=$candidate
      return 0
    fi
    if ((attempt < 10)); then
      sleep 2
    fi
  done
  return 1
}

install_smartdns() {
  CURRENT_STEP='安装并配置 SmartDNS'
  local aaaa_output=''
  local installed_architecture
  local installed_package
  local installed_version
  local smartdns_version
  local socket_output=''
  local staged_config
  local service_user
  local service_group

  apt_get install -y ca-certificates dnsutils
  command -v curl >/dev/null 2>&1 || die '缺少 curl。'
  command -v dig >/dev/null 2>&1 || die '安装 dnsutils 后仍找不到 dig。'
  command -v dpkg-deb >/dev/null 2>&1 || die '缺少 dpkg-deb。'
  command -v sha256sum >/dev/null 2>&1 || die '缺少 sha256sum。'
  [[ -r /etc/ssl/certs/ca-certificates.crt && -s /etc/ssl/certs/ca-certificates.crt ]] ||
    die '系统 CA 文件不可读或为空：/etc/ssl/certs/ca-certificates.crt。'

  staged_config=$(mktemp "$TMP_DIR/smartdns.conf.XXXXXXXX")
  write_smartdns_configuration "$staged_config" "$SMARTDNS_CONFIG_VARIANT"
  log "使用固定 SmartDNS Release：$SMARTDNS_RELEASE_TAG。"
  download_and_verify_smartdns_package
  capture_smartdns_transaction_state
  SMARTDNS_TRANSACTION_ACTIVE=true

  stop_and_clean_smartdns
  if smartdns_package_is_current; then
    log "已安装精确目标版本 $SMARTDNS_EXPECTED_VERSION；跳过重复安装。"
  else
    apt-mark unhold smartdns >/dev/null 2>&1 ||
      die '安装前无法取消 smartdns hold。'
    apt_get -o Dpkg::Options::='--force-confold' install -y \
      --allow-downgrades "$SMARTDNS_PACKAGE_PATH"
    hash -r
    stop_and_clean_smartdns
  fi

  command -v smartdns >/dev/null 2>&1 || die '安装后找不到 smartdns。'
  smartdns_version=$(smartdns_version_text) || die 'SmartDNS 版本验证失败。'
  [[ "$smartdns_version" == "smartdns $SMARTDNS_EXPECTED_VERSION" ]] ||
    die "smartdns -v 与预期版本 $SMARTDNS_EXPECTED_VERSION 不一致：$smartdns_version。"
  installed_package=$(dpkg-query -W -f='${Package}' smartdns)
  installed_version=$(dpkg-query -W -f='${Version}' smartdns)
  installed_architecture=$(dpkg-query -W -f='${Architecture}' smartdns)
  [[ "$installed_package" == 'smartdns' ]] ||
    die "已安装 Debian 软件包名称不是 smartdns：$installed_package。"
  [[ "$installed_version" == "$SMARTDNS_EXPECTED_VERSION" ]] ||
    die "已安装 SmartDNS 版本不是 $SMARTDNS_EXPECTED_VERSION：$installed_version。"
  [[ "$installed_architecture" == "$CPU_ARCH" ]] ||
    die "已安装 SmartDNS 架构不是 $CPU_ARCH：$installed_architecture。"

  service_user=$(systemctl show smartdns.service -p User --value 2>/dev/null || true)
  [[ -n "$service_user" ]] || service_user='root'
  if id "$service_user" >/dev/null 2>&1; then
    service_group=$(id -gn "$service_user")
  else
    service_user='root'
    service_group='root'
  fi

  install -d -o root -g root -m 0755 /etc/smartdns
  install -d -o "$service_user" -g "$service_group" -m 0750 /var/cache/smartdns
  validate_smartdns_configuration "$staged_config"
  check_smartdns_port_53_conflicts
  write_managed_file "$SMARTDNS_CONFIG_TARGET" 0644 root root <"$staged_config"

  systemctl reset-failed smartdns.service ||
    smartdns_health_fail '无法重置 SmartDNS 服务失败状态。'
  systemctl enable smartdns.service ||
    smartdns_health_fail '无法启用 SmartDNS 服务。'
  systemctl restart smartdns.service ||
    smartdns_health_fail '无法重启 SmartDNS 服务。'
  systemctl is-active --quiet smartdns.service ||
    smartdns_health_fail 'SmartDNS 服务未处于 active 状态。'
  systemctl is-enabled --quiet smartdns.service ||
    smartdns_health_fail 'SmartDNS 服务未设置为 enabled。'
  pgrep -x smartdns >/dev/null 2>&1 ||
    smartdns_health_fail '未找到运行中的 SmartDNS 进程。'
  if [[ ! -s /run/smartdns.pid && ! -s /var/run/smartdns.pid ]]; then
    warn '未找到 SmartDNS PID 文件；进程与服务状态正常，因此不单独判定失败。'
  fi

  for _ in {1..10}; do
    socket_output=$(ss -H -lntup 'sport = :53' 2>/dev/null || true)
    if smartdns_listener_present udp "$socket_output" &&
      smartdns_listener_present tcp "$socket_output"; then
      break
    fi
    sleep 1
  done
  smartdns_listener_present udp "$socket_output" ||
    smartdns_health_fail 'SmartDNS 未在 127.0.0.1:53/udp 监听。'
  smartdns_listener_present tcp "$socket_output" ||
    smartdns_health_fail 'SmartDNS 未在 127.0.0.1:53/tcp 监听。'
  if ! query_smartdns_ipv4; then
    smartdns_health_fail "SmartDNS IPv4 查询连续 $SMARTDNS_IPV4_ATTEMPTS 次未返回合法 IPv4；最后输出：$(shorten_line "$SMARTDNS_LAST_DIG_OUTPUT")"
  fi
  if ! aaaa_output=$(dig @127.0.0.1 cloudflare.com AAAA +time=4 +tries=1 2>&1); then
    smartdns_health_fail "SmartDNS AAAA 查询执行失败：$(shorten_line "$aaaa_output")"
  fi
  grep -Eq 'status:[[:space:]]*NOERROR([,[:space:]]|$)' <<<"$aaaa_output" ||
    smartdns_health_fail "SmartDNS AAAA 查询状态不是 NOERROR：$(shorten_line "$aaaa_output")"

  apt-mark hold smartdns >/dev/null ||
    smartdns_health_fail '健康检查通过后无法 hold smartdns。'
  apt-mark showhold | grep -Fxq smartdns ||
    smartdns_health_fail 'apt-mark 未确认 smartdns 处于 hold 状态。'

  SMARTDNS_READY=true
  SMARTDNS_TRANSACTION_ACTIVE=false
  log "SmartDNS 已安装并验证：Debian $DEBIAN_VERSION/$CPU_ARCH，$installed_version，$SMARTDNS_CONFIG_VARIANT。"
  log "smartdns -v：$smartdns_version；127.0.0.1:53/udp+tcp。"
  log "IPv4 查询第 $SMARTDNS_IPV4_ATTEMPTS 次成功：$SMARTDNS_IPV4_ANSWER；AAAA 状态 NOERROR。"
  log 'smartdns 已设置为 hold。'
}

restore_resolv_conf() {
  rm -f -- /etc/resolv.conf
  restore_file /etc/resolv.conf
}

configure_system_dns() {
  CURRENT_STEP='切换系统唯一 DNS'
  [[ "$SMARTDNS_READY" == true ]] || die 'SmartDNS 未通过验证，拒绝修改 /etc/resolv.conf。'
  [[ ! -d /etc/resolv.conf ]] || die '/etc/resolv.conf 不能是目录。'

  local staged_resolv
  staged_resolv=$(mktemp "$TMP_DIR/resolv.conf.XXXXXXXX")
  cat >"$staged_resolv" <<'EOF'
nameserver 127.0.0.1
options timeout:2
options attempts:2
EOF

  backup_file /etc/resolv.conf
  if [[ -L /etc/resolv.conf ]]; then
    log "检测到 /etc/resolv.conf 软链接：$(readlink /etc/resolv.conf)；已备份后替换为受管普通文件。"
  fi
  rm -f -- /etc/resolv.conf
  install -o root -g root -m 0644 "$staged_resolv" /etc/resolv.conf

  if ! timeout 6 getent ahosts debian.org >/dev/null 2>&1; then
    warn '系统默认 DNS 测试失败，正在恢复原来的 /etc/resolv.conf。'
    restore_resolv_conf || true
    die '切换到 SmartDNS 后系统解析失败，原 resolv.conf 已尝试恢复。'
  fi
  [[ ! -L /etc/resolv.conf ]] || die '最终 /etc/resolv.conf 不应是软链接。'
  [[ $(grep -Ec '^nameserver[[:space:]]+' /etc/resolv.conf) -eq 1 ]] ||
    die '/etc/resolv.conf 必须只包含一个 nameserver。'
  grep -Eq '^nameserver[[:space:]]+127\.0\.0\.1$' /etc/resolv.conf ||
    die '/etc/resolv.conf 未指向 127.0.0.1。'
  DNS_READY=true
  log '系统 DNS 已验证仅使用 127.0.0.1；未配置任何备用 nameserver。'
}

install_domain_check() {
  CURRENT_STEP='安装 domain-check'
  local downloaded_file
  local first_line=''
  local installed_metadata=''

  DOMAIN_CHECK_STATE='安装失败'
  downloaded_file=$(mktemp "$TMP_DIR/domain-check.XXXXXXXX")
  curl --fail --silent --show-error --location \
    --connect-timeout 5 --max-time 60 --retry 3 --retry-delay 1 \
    --retry-connrefused \
    "$DOMAIN_CHECK_SOURCE" --output "$downloaded_file" ||
    die '下载 domain-check.sh 失败。'
  [[ -s "$downloaded_file" ]] || die '下载的 domain-check.sh 为空。'
  IFS= read -r first_line <"$downloaded_file" ||
    die '无法读取下载的 domain-check.sh。'
  [[ "$first_line" == '#!/usr/bin/env bash' ]] ||
    die '下载的 domain-check.sh 没有有效的 Bash shebang。'
  bash -n "$downloaded_file" ||
    die '下载的 domain-check.sh 未通过 bash -n。'

  DOMAIN_CHECK_INSTALL_STAGE=$(mktemp /usr/local/bin/.domain-check.XXXXXXXX) ||
    die '无法在 /usr/local/bin 创建 domain-check 临时安装文件。'
  install -o root -g root -m 0755 \
    "$downloaded_file" "$DOMAIN_CHECK_INSTALL_STAGE" ||
    die '无法准备 domain-check 原子安装文件。'
  backup_file "$DOMAIN_CHECK_TARGET"
  if ! mv -f -- "$DOMAIN_CHECK_INSTALL_STAGE" "$DOMAIN_CHECK_TARGET"; then
    restore_file "$DOMAIN_CHECK_TARGET" || true
    die '无法将 domain-check 原子安装到正式路径。'
  fi
  DOMAIN_CHECK_INSTALL_STAGE=''

  installed_metadata=$(stat -c '%U:%G:%a' "$DOMAIN_CHECK_TARGET" 2>/dev/null || true)
  if [[ ! -x "$DOMAIN_CHECK_TARGET" ]] ||
    [[ "$installed_metadata" != 'root:root:755' ]] ||
    ! bash -n "$DOMAIN_CHECK_TARGET"; then
    restore_file "$DOMAIN_CHECK_TARGET" || true
    die 'domain-check 正式安装文件或权限验证失败，已尝试恢复。'
  fi
  DOMAIN_CHECK_STATE='已安装'
  log "domain-check 已安装并验证：$DOMAIN_CHECK_TARGET"
}

service_state() {
  local unit=$1
  local state
  state=$(systemctl is-active "$unit" 2>/dev/null || true)
  printf '%s' "${state:-unknown}"
}

system_pretty_name() {
  local pretty_name=''
  if [[ -r /etc/os-release ]]; then
    pretty_name=$(awk -F= '$1 == "PRETTY_NAME" {
      sub(/^[^=]*=/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }' /etc/os-release 2>/dev/null || true)
  fi
  printf '%s' "${pretty_name:-Debian ${DEBIAN_VERSION:-未知}}"
}

current_ufw_state() {
  local status_output
  if ! command -v ufw >/dev/null 2>&1; then
    printf '未安装'
    return 1
  fi
  status_output=$(ufw status 2>/dev/null || true)
  if grep -q '^Status: active$' <<<"$status_output"; then
    printf 'active'
    return 0
  fi
  if grep -q '^Status: inactive$' <<<"$status_output"; then
    printf 'inactive'
  else
    printf 'unknown'
  fi
  return 1
}

current_smartdns_state() {
  local state
  local udp_ready=false
  local tcp_ready=false
  if ! command -v smartdns >/dev/null 2>&1; then
    printf '未安装'
    return 1
  fi
  state=$(service_state smartdns.service)
  if command -v ss >/dev/null 2>&1; then
    ss -H -lun 'sport = :53' 2>/dev/null | grep -q '127\.0\.0\.1:53' && udp_ready=true
    ss -H -ltn 'sport = :53' 2>/dev/null | grep -q '127\.0\.0\.1:53' && tcp_ready=true
  fi
  if [[ "$state" == 'active' && "$udp_ready" == true && "$tcp_ready" == true ]]; then
    printf 'active，127.0.0.1:53/udp+tcp'
    return 0
  fi
  if [[ "$state" == 'active' ]]; then
    printf 'active，本地 UDP/TCP 监听未完整'
  else
    printf '%s' "$state"
  fi
  return 1
}

current_system_dns_state() {
  local nameserver_count=0
  if [[ -f /etc/resolv.conf ]]; then
    nameserver_count=$(grep -Ec '^nameserver[[:space:]]+' /etc/resolv.conf 2>/dev/null || true)
    if (( nameserver_count == 1 )) &&
      grep -Eq '^nameserver[[:space:]]+127\.0\.0\.1$' /etc/resolv.conf; then
      printf '仅 127.0.0.1'
      return 0
    fi
  fi
  printf '未验证为仅 127.0.0.1'
  return 1
}

current_backup_state() {
  if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
    printf '%s' "$BACKUP_DIR"
  elif [[ -n "$BACKUP_DIR" ]]; then
    printf '%s（尚未创建）' "$BACKUP_DIR"
  else
    printf '未创建'
  fi
}

print_ufw_port_result() {
  local label=$1
  local target=$2
  local expected=$3
  if [[ "$expected" == true ]]; then
    if ufw_allows_port "$target"; then
      result_row OK "$label" '已开放'
    else
      result_row FAIL "$label" '应开放但实际规则未通过验证'
    fi
  elif [[ -z "$(find_any_ufw_allow_rule "$target")" ]]; then
    result_row OK "$label" '未开放'
  else
    result_row FAIL "$label" '发现非预期放行规则'
  fi
}

print_failure_report() {
  local failure_step=${FAILURE_STEP:-${CURRENT_STEP:-未知}}
  local failure_reason=${FAILURE_REASON:-未知错误}
  local ufw_state=''
  local smartdns_state=''
  local dns_state=''
  RESULT_REPORTED=true

  printf '\n'
  result_box_line
  color_text '38;5;208' '###                 VPS 初始化失败                       ###'
  printf '\n'
  result_box_line
  result_row FAIL '失败步骤' "$failure_step"
  result_row FAIL '错误原因' "$failure_reason"
  case "$SSH_ROLLBACK_STATE" in
    已回滚) result_row OK 'SSH 回滚' "$SSH_ROLLBACK_STATE" ;;
    未触发) result_row INFO 'SSH 回滚' "$SSH_ROLLBACK_STATE" ;;
    *) result_row WARN 'SSH 回滚' "$SSH_ROLLBACK_STATE" ;;
  esac
  if ufw_state=$(current_ufw_state); then
    result_row OK 'UFW' "$ufw_state"
  else
    result_row WARN 'UFW' "$ufw_state"
  fi
  if smartdns_state=$(current_smartdns_state); then
    result_row OK 'SmartDNS' "$smartdns_state"
  else
    result_row WARN 'SmartDNS' "$smartdns_state"
  fi
  if dns_state=$(current_system_dns_state); then
    result_row OK '系统 DNS' "$dns_state"
  else
    result_row WARN '系统 DNS' "$dns_state"
  fi
  result_row INFO '备份目录' "$(current_backup_state)"
  result_box_line
}

print_final_report() {
  CURRENT_STEP='输出最终报告'
  local reboot_required='否'
  local update_state='已完成 full-upgrade'
  local bbr_control
  local bbr_qdisc
  local chrony_state
  local ufw_state=''
  local smartdns_state=''
  local dns_state=''
  local domain_check_metadata=''
  local sing_enabled
  local sing_active
  [[ -e /var/run/reboot-required ]] &&
    reboot_required='是'
  [[ "$SKIP_UPGRADE" == true ]] && update_state='已跳过 full-upgrade（已执行 apt-get update）'
  chrony_state=$(service_state chrony.service)
  bbr_control=$(read_sysctl net.ipv4.tcp_congestion_control)
  bbr_qdisc=$(read_sysctl net.core.default_qdisc)
  sing_enabled=$(systemctl is-enabled sing-box.service 2>/dev/null || true)
  sing_active=$(service_state sing-box.service)

  printf '\n'
  result_box_line
  color_text '38;5;208' '###                 VPS 初始化完成                       ###'
  printf '\n'
  result_box_line
  result_row INFO '安装模式' "$INSTALL_MODE"
  result_row OK '系统版本' "$(system_pretty_name)"
  if [[ "$SYSTEM_UPDATE_READY" == true ]]; then
    result_row OK '系统更新' "$update_state"
  else
    result_row FAIL '系统更新' '未完成验证'
  fi
  if [[ "$BASE_TOOLS_READY" == true ]]; then
    result_row OK '基础工具' '已安装并验证'
  else
    result_row FAIL '基础工具' '未完成验证'
  fi
  if [[ "$chrony_state" == 'active' ]]; then
    result_row OK 'chrony' "$chrony_state"
  else
    result_row FAIL 'chrony' "$chrony_state"
  fi
  if [[ "$bbr_control" == 'bbr' && "$bbr_qdisc" == 'fq' ]]; then
    result_row OK 'BBR' "$bbr_control / $bbr_qdisc"
  else
    result_row WARN 'BBR' "$bbr_control / $bbr_qdisc"
  fi
  if [[ "$SSH_READY" == true ]] && is_tcp_port_listening "$SSH_PORT"; then
    result_row OK 'SSH 端口' "$SSH_PORT/tcp"
  else
    result_row FAIL 'SSH 端口' "$SSH_PORT/tcp 未通过监听验证"
  fi
  if [[ "$KEEP_SSH_22" == true ]]; then
    if is_tcp_port_listening 22; then
      result_row OK 'SSH 22' '已保留'
    else
      result_row FAIL 'SSH 22' '应保留但未监听'
    fi
  elif is_tcp_port_listening 22; then
    result_row FAIL 'SSH 22' '仍在监听'
  else
    result_row OK 'SSH 22' '已关闭'
  fi
  if [[ "$SSH_READY" == true ]]; then
    result_row OK 'root 登录' '仅允许公钥'
  else
    result_row FAIL 'root 登录' '最终策略未通过验证'
  fi
  print_ufw_port_result '443/tcp' '443/tcp' "$OPEN_443_TCP"
  print_ufw_port_result '443/udp' '443/udp' "$OPEN_443_UDP"
  if [[ "$ENABLE_CF_8443" == true ]]; then
    if ufw_has_comment 'Cloudflare-8443' && [[ -z "$(find_unmanaged_8443_rule)" ]]; then
      result_row OK '8443/tcp' 'Cloudflare-only'
    else
      result_row FAIL '8443/tcp' 'Cloudflare-only 规则未通过验证'
    fi
  elif ! ufw_has_comment 'Cloudflare-8443' &&
    [[ -z "$(find_any_ufw_allow_rule '8443/tcp')" ]]; then
    result_row OK '8443/tcp' '未开放'
  else
    result_row FAIL '8443/tcp' '发现非预期放行规则'
  fi
  if ufw_state=$(current_ufw_state); then
    result_row OK 'UFW' "$ufw_state"
  else
    result_row FAIL 'UFW' "$ufw_state"
  fi
  if [[ -x "$CLOUDFLARE_UFW_TOOL" ]] &&
    [[ $(stat -c '%U:%G:%a' "$CLOUDFLARE_UFW_TOOL" 2>/dev/null || true) == 'root:root:755' ]]; then
    result_row OK 'Cloudflare UFW 工具' "$CLOUDFLARE_UFW_TOOL"
  else
    result_row FAIL 'Cloudflare UFW 工具' '文件或权限未通过验证'
  fi
  if command -v sing-box >/dev/null 2>&1 &&
    [[ "$sing_enabled" == 'disabled' && "$sing_active" == 'inactive' ]]; then
    result_row OK 'sing-box' "installed，$sing_enabled，$sing_active"
  else
    result_row WARN 'sing-box' "${sing_enabled:-未安装}，$sing_active"
  fi
  if smartdns_state=$(current_smartdns_state); then
    result_row OK 'SmartDNS' "$smartdns_state"
  else
    result_row FAIL 'SmartDNS' "$smartdns_state"
  fi
  if [[ "$DNS_READY" == true ]] && dns_state=$(current_system_dns_state); then
    result_row OK '系统 DNS' "$dns_state"
  else
    [[ -n "$dns_state" ]] || dns_state='未通过安装流程验证'
    result_row FAIL '系统 DNS' "$dns_state"
  fi
  domain_check_metadata=$(
    stat -c '%U:%G:%a' "$DOMAIN_CHECK_TARGET" 2>/dev/null || true
  )
  if [[ "$DOMAIN_CHECK_STATE" == '已安装' && -x "$DOMAIN_CHECK_TARGET" ]] &&
    [[ "$domain_check_metadata" == 'root:root:755' ]]; then
    result_row OK 'domain-check' "$DOMAIN_CHECK_STATE：$DOMAIN_CHECK_TARGET"
  else
    result_row FAIL 'domain-check' "$DOMAIN_CHECK_STATE：$DOMAIN_CHECK_TARGET"
  fi
  result_row INFO '备份目录' "$(current_backup_state)"
  result_row INFO '建议重启' "$reboot_required"
  result_row WARN 'SSH 外部确认' '未执行；请保持当前会话并自行验证新端口'
  result_box_line
  RESULT_REPORTED=true
}

custom_phase_one() {
  if ask_yes_no '是否执行 apt full-upgrade？' true; then
    SKIP_UPGRADE=false
  else
    SKIP_UPGRADE=true
  fi
  update_system
  install_base_packages

  local choice
  while true; do
    printf '\n基础工具已经安装完成。\n1. 继续完整初始化\n2. 退出，用于测试 IP、线路和基础环境\n' >/dev/tty
    read_tty '请选择 [1-2]: ' choice
    case "$choice" in
      1) return 0 ;;
      2)
        printf '\n已在基础工具阶段停止：软件包保留；未修改 SSH、UFW、BBR、SmartDNS 或系统 DNS，也未安装 Cloudflare UFW 工具、sing-box 或 domain-check。\n'
        exit 0
        ;;
      *) printf '无效选择。\n' >/dev/tty ;;
    esac
  done
}

run_remaining_initialization() {
  install_cloudflare_ufw_tool
  configure_chrony
  configure_bbr
  install_sing_box
  install_smartdns
  configure_system_dns
  install_domain_check
  configure_ssh
  configure_ufw
  print_final_report
}

main() {
  initialize_colors
  parse_args "$@"
  run_health_check
  [[ -r /dev/tty && -w /dev/tty ]] ||
    die '体检已完成，但当前没有交互式 /dev/tty；未执行任何安装或配置修改。'
  select_install_mode
  preflight

  if [[ "$INSTALL_MODE" == '快速安装' ]]; then
    configure_quick_choices
    ssh_port_has_conflict "$SSH_PORT" &&
      die "$SSH_PORT/tcp 已被非 sshd 进程监听，无法执行快速安装。"
    collect_public_key
    validate_public_key
    install_authorized_key
    update_system
    install_base_packages
  else
    custom_phase_one
    collect_public_key
    validate_public_key
    install_authorized_key
    configure_custom_network_choices
  fi

  run_remaining_initialization
}

main "$@"
