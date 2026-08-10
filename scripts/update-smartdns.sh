#!/usr/bin/env bash

if (return 0 2>/dev/null); then
  printf '[FAIL] 请执行此脚本，不要 source。\n' >&2
  return 1
fi

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly CONFIG_TARGET='/etc/smartdns/smartdns.conf'
readonly CA_FILE='/etc/ssl/certs/ca-certificates.crt'
readonly SMARTDNS_RELEASE_TAG='smartdns-debian-pinned-2026-07'
readonly SMARTDNS_RELEASE_BASE='https://github.com/404-git-404/404notfound/releases/download/smartdns-debian-pinned-2026-07'
readonly IPV6_DISABLE_CONFIG='/etc/sysctl.d/99-disable-ipv6.conf'
readonly NETWORK_STACK_UNIT='/etc/systemd/system/404-network-stack.service'
readonly NETWORK_STACK_UNIT_NAME='404-network-stack.service'
readonly NETWORK_STACK_HELPER='/usr/local/libexec/404-network-stack'
readonly RESOLV_CONF='/etc/resolv.conf'

TMP_DIR=''
STAGED_CONFIG=''
VALIDATION_CONFIG=''
VALIDATION_LOG=''
BACKUP_DIR=''
START_TIME=''
JOURNAL_FILE=''
OS_VERSION=''
OS_ID=''
ARCH=''
CONFIG_VARIANT=''
ASSET_NAME=''
EXPECTED_VERSION=''
EXPECTED_SHA256=''
DOWNLOAD_URL=''
DEB_PATH=''
SMARTDNS_VERSION_TEXT=''
SMARTDNS_COMMAND=''
SMARTDNS_BINARY_PATH=''
PACKAGE_VERSION=''
ENABLED_STATUS=''
ACTIVE_STATUS=''
SOCKET_OUTPUT=''
IPV4_ANSWER=''
IPV4_ATTEMPTS=0
LAST_DIG_OUTPUT=''
SYSTEM_LOOKUP_OUTPUT=''
CONFIG_PREEXISTED=false
SMARTDNS_WAS_HELD=false
SMARTDNS_WAS_ENABLED=false
SMARTDNS_WAS_ACTIVE=false
BACKUP_READY=false
NETWORK_STACK=${NETWORK_STACK:-ipv4}
IPV6_CONFIG_PREEXISTED=false
NETWORK_STACK_UNIT_PREEXISTED=false
NETWORK_STACK_UNIT_WAS_ENABLED=false
NETWORK_STACK_UNIT_WAS_ACTIVE=false
NETWORK_STACK_HELPER_PREEXISTED=false
RESOLV_CONF_PREEXISTED=false
IPV6_ALL_WAS_DISABLED=''
IPV6_DEFAULT_WAS_DISABLED=''
IPV6_LOOPBACK_WAS_DISABLED=''
SYSTEMD_RESOLVED_WAS_ENABLED=false
SYSTEMD_RESOLVED_WAS_ACTIVE=false
SYSTEMD_RESOLVED_UNIT_PRESENT=false
VIRTUALIZATION='unknown'
CONTAINER_VIRTUALIZATION='none'
ENVIRONMENT_LABEL='Unknown environment'
CONTAINER_ENVIRONMENT=false
KERNEL_IPV6_DISABLED='UNAVAILABLE'
KERNEL_ENFORCEMENT='unavailable'
APPLICATION_IPV4_ONLY='NO'
RESOLV_CONF_STATUS='UNMANAGED'
SYSTEM_RESOLUTION_STATUS='PASS'
RESULT_STATUS='SUCCESS'
WARNING_COUNT=0

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

degrade() {
  warn "$*"
  ((WARNING_COUNT += 1))
  RESULT_STATUS='SUCCESS_WITH_WARNINGS'
}

die() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

usage() {
  printf '用法：bash scripts/update-smartdns.sh [--network-stack ipv4|ipv6|dual]\n'
}

validate_network_stack() {
  case "$NETWORK_STACK" in
    ipv4|ipv6|dual) ;;
    *) die "网络栈必须是 ipv4、ipv6 或 dual，当前值：${NETWORK_STACK:-空}。" ;;
  esac
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --network-stack)
        (($# >= 2)) || die '--network-stack 缺少参数。'
        NETWORK_STACK=$2
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *) die "未知参数：$1。" ;;
    esac
  done
  validate_network_stack
}

shorten_line() {
  local value=${1//$'\n'/ }
  printf '%.300s' "$value"
}

detect_runtime_environment() {
  local detected=''
  local container=''

  detected=$(systemd-detect-virt 2>/dev/null || true)
  container=$(systemd-detect-virt --container 2>/dev/null || true)
  [[ -n "$detected" && "$detected" != none ]] || detected='none'
  [[ -n "$container" && "$container" != none ]] || container='none'
  VIRTUALIZATION=$detected
  CONTAINER_VIRTUALIZATION=$container
  if [[ "$container" != none ]]; then
    CONTAINER_ENVIRONMENT=true
    ENVIRONMENT_LABEL="$container container"
  elif [[ "$detected" == none ]]; then
    CONTAINER_ENVIRONMENT=false
    ENVIRONMENT_LABEL='Bare metal'
  else
    CONTAINER_ENVIRONMENT=false
    ENVIRONMENT_LABEL="$detected virtual machine"
  fi

  log "Virtualization: $VIRTUALIZATION"
  if [[ "$CONTAINER_ENVIRONMENT" == true ]]; then
    log "Container environment detected: $CONTAINER_VIRTUALIZATION."
  else
    log "Environment: $ENVIRONMENT_LABEL."
  fi
}

sysctl_restriction_error() {
  local message=${1,,}
  [[ "$message" == *'permission denied'* ||
    "$message" == *'operation not permitted'* ||
    "$message" == *'read-only file system'* ||
    "$message" == *'readonly file system'* ]]
}

read_ipv6_kernel_state() {
  local all_value=''
  local default_value=''
  local loopback_value=''

  all_value=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null) || return 1
  default_value=$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null) || return 1
  loopback_value=$(sysctl -n net.ipv6.conf.lo.disable_ipv6 2>/dev/null) || return 1
  if [[ "$all_value" == 1 && "$default_value" == 1 && "$loopback_value" == 1 ]]; then
    KERNEL_IPV6_DISABLED='YES'
  elif [[ "$all_value" == 0 && "$default_value" == 0 && "$loopback_value" == 0 ]]; then
    KERNEL_IPV6_DISABLED='NO'
  else
    KERNEL_IPV6_DISABLED='UNAVAILABLE'
  fi
  printf '%s/%s/%s' "$all_value" "$default_value" "$loopback_value"
}

apply_ipv6_sysctl_capability_aware() {
  local desired_value=$1
  local output=''
  local restricted=false
  local scope

  for scope in all default lo; do
    if output=$(sysctl -q -w "net.ipv6.conf.$scope.disable_ipv6=$desired_value" 2>&1); then
      continue
    fi
    if sysctl_restriction_error "$output"; then
      restricted=true
      continue
    fi
    fail_with_recovery "修改 net.ipv6.conf.$scope.disable_ipv6 时发生异常：$(shorten_line "$output")"
  done

  if [[ "$restricted" == true ]]; then
    KERNEL_ENFORCEMENT='unavailable'
    degrade '容器/宿主限制禁止修改 IPv6 sysctl，将继续使用应用层网络栈配置。'
    return 0
  fi
  KERNEL_ENFORCEMENT='enabled'
}

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}

trap cleanup EXIT

require_root_and_debian() {
  ((EUID == 0)) || die '必须以 root 身份执行此脚本。'
  [[ -r /etc/os-release ]] || die '无法读取 /etc/os-release。'

  OS_ID=$(awk -F= '$1 == "ID" { print $2; exit }' /etc/os-release | tr -d '"')
  OS_VERSION=$(awk -F= '$1 == "VERSION_ID" { print $2; exit }' /etc/os-release | tr -d '"')
  command -v dpkg >/dev/null 2>&1 || die '缺少 dpkg。'
  ARCH=$(dpkg --print-architecture)
  validate_smartdns_platform "$OS_ID" "$OS_VERSION" "$ARCH"
}

install_dependencies() {
  local package
  local -a missing_packages=()
  local -a required_packages=(curl ca-certificates dnsutils)

  for package in "${required_packages[@]}"; do
    if ! dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null |
      grep -q '^ii'; then
      missing_packages+=("$package")
    fi
  done

  if ((${#missing_packages[@]} > 0)); then
    log "安装缺少的依赖：${missing_packages[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install --yes "${missing_packages[@]}"
  else
    log 'curl、ca-certificates 和 dnsutils 已安装。'
  fi

  [[ -r "$CA_FILE" && -s "$CA_FILE" ]] ||
    die "系统 CA 文件不可读或为空：$CA_FILE。"
}

verify_required_commands() {
  local command_name
  local -a required_commands=(
    apt-get apt-mark awk cat cmp cp curl date dig dpkg dpkg-deb dpkg-query
    findmnt getent grep install ip journalctl kill mktemp mountpoint pgrep pkill
    readlink rm sed sha256sum sleep ss stat sysctl systemctl systemd-detect-virt
    timeout tr
  )

  for command_name in "${required_commands[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 ||
      die "缺少必要命令：$command_name。"
  done
}

select_smartdns_target() {
  local os_version=$1
  local architecture=$2

  case "$os_version:$architecture" in
    12:amd64)
      EXPECTED_VERSION='40+dfsg-1'
      CONFIG_VARIANT='v40'
      ASSET_NAME='smartdns_40+dfsg-1_bookworm_amd64.deb'
      EXPECTED_SHA256='8388fb543f870fc77d17dbaa9874277d2ef37d120ad2ab24af730d7032a80bcb'
      ;;
    12:arm64)
      EXPECTED_VERSION='40+dfsg-1'
      CONFIG_VARIANT='v40'
      ASSET_NAME='smartdns_40+dfsg-1_bookworm_arm64.deb'
      EXPECTED_SHA256='7aadb6fb0e6d2f38d8ce11db60561c2c8c7c9d0aacf1e54f9e27f44a4abfb9ca'
      ;;
    13:amd64)
      EXPECTED_VERSION='46.1+dfsg-1.1~deb13u1'
      CONFIG_VARIANT='v46'
      ASSET_NAME='smartdns_46.1+dfsg-1.1.deb13u1_trixie_amd64.deb'
      EXPECTED_SHA256='d2dfe591dbdabf3655c2ead30975ee20f6720346552bda989b212ccffde5ba4e'
      ;;
    13:arm64)
      EXPECTED_VERSION='46.1+dfsg-1.1~deb13u1'
      CONFIG_VARIANT='v46'
      ASSET_NAME='smartdns_46.1+dfsg-1.1.deb13u1_trixie_arm64.deb'
      EXPECTED_SHA256='d9eeb9050ab6e0c95011de83955f65ca8020779c8c32aba90d708bc54c33823f'
      ;;
    *)
      die "不支持的 Debian/架构组合：Debian $os_version，$architecture；仅支持 Debian 12/13 的 amd64/arm64。"
      ;;
  esac

  DOWNLOAD_URL="$SMARTDNS_RELEASE_BASE/$ASSET_NAME"
}

validate_smartdns_platform() {
  local os_id=$1
  local os_version=$2
  local architecture=$3

  [[ "$os_id" == 'debian' ]] ||
    die "仅支持 Debian，当前系统 ID：${os_id:-未知}。"
  case "$os_version" in
    12|13) ;;
    *) die "仅支持 Debian 12/13，当前版本：${os_version:-未知}。" ;;
  esac
  case "$architecture" in
    amd64|arm64) ;;
    *) die "不支持的 Debian 架构：${architecture:-未知}；仅支持 amd64 和 arm64。" ;;
  esac
  select_smartdns_target "$os_version" "$architecture"
}

select_platform() {
  log "固定目标：Debian $OS_VERSION，$ARCH，$EXPECTED_VERSION，配置 $CONFIG_VARIANT。"
  log "Release 资产：$ASSET_NAME"
}

create_temporary_directory() {
  TMP_DIR=$(mktemp -d /tmp/update-smartdns.XXXXXXXX)
  STAGED_CONFIG="$TMP_DIR/smartdns.conf"
  VALIDATION_CONFIG="$TMP_DIR/smartdns-validation.conf"
  VALIDATION_LOG="$TMP_DIR/smartdns-validation.log"
  JOURNAL_FILE="$TMP_DIR/smartdns-startup.log"
  DEB_PATH="$TMP_DIR/$ASSET_NAME"
}

write_smartdns_configuration() {
  local target=$1
  local variant=$2
  local network_stack=${3:-$NETWORK_STACK}

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

speed-check-mode none
response-mode fastest-response

log-level warn
log-console no
log-syslog yes
audit-enable no

ca-file /etc/ssl/certs/ca-certificates.crt

SMARTDNS_CONFIG_COMMON

  case "$network_stack" in
    ipv4) printf '%s\n\n' 'force-AAAA-SOA yes' >>"$target" ;;
    ipv6) printf '%s\n\n' 'force-qtype-SOA 1' >>"$target" ;;
    dual) ;;
    *) die "未知网络栈：$network_stack。" ;;
  esac

  case "$variant:$network_stack" in
    v40:ipv4|v40:dual)
      cat >>"$target" <<'SMARTDNS_CONFIG_VARIANT'
server-https https://1.1.1.1/dns-query -host-name cloudflare-dns.com -http-host cloudflare-dns.com -tls-host-verify cloudflare-dns.com
server-https https://8.8.8.8/dns-query -host-name dns.google -http-host dns.google -tls-host-verify dns.google
SMARTDNS_CONFIG_VARIANT
      ;;
    v40:ipv6)
      cat >>"$target" <<'SMARTDNS_CONFIG_VARIANT'
server-https https://[2606:4700:4700::1111]/dns-query -host-name cloudflare-dns.com -http-host cloudflare-dns.com -tls-host-verify cloudflare-dns.com
server-https https://[2001:4860:4860::8888]/dns-query -host-name dns.google -http-host dns.google -tls-host-verify dns.google
SMARTDNS_CONFIG_VARIANT
      ;;
    v46:ipv4|v46:dual)
      cat >>"$target" <<'SMARTDNS_CONFIG_VARIANT'
server-https https://cloudflare-dns.com/dns-query -host-ip 1.1.1.1
server-https https://dns.google/dns-query -host-ip 8.8.8.8
SMARTDNS_CONFIG_VARIANT
      ;;
    v46:ipv6)
      cat >>"$target" <<'SMARTDNS_CONFIG_VARIANT'
server-https https://cloudflare-dns.com/dns-query -host-ip 2606:4700:4700::1111
server-https https://dns.google/dns-query -host-ip 2001:4860:4860::8888
SMARTDNS_CONFIG_VARIANT
      ;;
    *)
      die "未知 SmartDNS 配置变体：$variant。"
      ;;
  esac

  [[ -s "$target" ]] || die '生成内嵌 SmartDNS 配置失败。'
}

download_and_verify_package() {
  local actual_sha256
  local deb_architecture
  local deb_package_name
  local deb_package_version

  if ! curl --fail --location --silent --show-error \
    --connect-timeout 10 --max-time 120 --retry 3 --retry-delay 2 \
    --retry-connrefused "$DOWNLOAD_URL" -o "$DEB_PATH"; then
    die "下载固定 SmartDNS Debian 软件包失败：$ASSET_NAME。"
  fi
  [[ -s "$DEB_PATH" ]] || die '下载的 SmartDNS Debian 软件包为空。'

  actual_sha256=$(sha256sum "$DEB_PATH" | awk '{print $1}')
  [[ "$actual_sha256" == "$EXPECTED_SHA256" ]] ||
    die "SmartDNS 软件包 SHA-256 不匹配：期望 $EXPECTED_SHA256，实际 $actual_sha256。"
  printf '%s  %s\n' "$EXPECTED_SHA256" "$DEB_PATH" | sha256sum --check --status ||
    die 'sha256sum 二次校验失败。'

  dpkg-deb --info "$DEB_PATH" >/dev/null ||
    die 'dpkg-deb --info 无法读取下载的软件包。'
  deb_package_name=$(dpkg-deb --field "$DEB_PATH" Package)
  deb_package_version=$(dpkg-deb --field "$DEB_PATH" Version)
  deb_architecture=$(dpkg-deb --field "$DEB_PATH" Architecture)
  [[ "$deb_package_name" == 'smartdns' ]] ||
    die "下载的软件包名称不是 smartdns：$deb_package_name。"
  [[ "$deb_package_version" == "$EXPECTED_VERSION" ]] ||
    die "下载的软件包版本不是 $EXPECTED_VERSION：$deb_package_version。"
  [[ "$deb_architecture" == "$ARCH" ]] ||
    die "下载的软件包架构不是 $ARCH：$deb_architecture。"

  log "下载和元数据验证通过：Package=smartdns，Version=$deb_package_version，Architecture=$deb_architecture。"
  log "SHA-256：$actual_sha256"
}

capture_existing_state() {
  SMARTDNS_WAS_HELD=false
  SMARTDNS_WAS_ENABLED=false
  SMARTDNS_WAS_ACTIVE=false
  NETWORK_STACK_UNIT_WAS_ENABLED=false
  NETWORK_STACK_UNIT_WAS_ACTIVE=false
  SYSTEMD_RESOLVED_WAS_ENABLED=false
  SYSTEMD_RESOLVED_WAS_ACTIVE=false
  SYSTEMD_RESOLVED_UNIT_PRESENT=false
  if apt-mark showhold | grep -Fxq smartdns; then
    SMARTDNS_WAS_HELD=true
  fi
  if systemctl is-enabled --quiet smartdns.service 2>/dev/null; then
    SMARTDNS_WAS_ENABLED=true
  fi
  if systemctl is-active --quiet smartdns.service 2>/dev/null; then
    SMARTDNS_WAS_ACTIVE=true
  fi
  if systemctl is-enabled --quiet "$NETWORK_STACK_UNIT_NAME" 2>/dev/null; then
    NETWORK_STACK_UNIT_WAS_ENABLED=true
  fi
  if systemctl is-active --quiet "$NETWORK_STACK_UNIT_NAME" 2>/dev/null; then
    NETWORK_STACK_UNIT_WAS_ACTIVE=true
  fi
  if systemctl is-enabled --quiet systemd-resolved.service 2>/dev/null; then
    SYSTEMD_RESOLVED_WAS_ENABLED=true
  fi
  if systemctl is-active --quiet systemd-resolved.service 2>/dev/null; then
    SYSTEMD_RESOLVED_WAS_ACTIVE=true
  fi
  if systemctl cat systemd-resolved.service >/dev/null 2>&1; then
    SYSTEMD_RESOLVED_UNIT_PRESENT=true
  fi
  IPV6_ALL_WAS_DISABLED=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null) ||
    IPV6_ALL_WAS_DISABLED='unavailable'
  IPV6_DEFAULT_WAS_DISABLED=$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null) ||
    IPV6_DEFAULT_WAS_DISABLED='unavailable'
  IPV6_LOOPBACK_WAS_DISABLED=$(sysctl -n net.ipv6.conf.lo.disable_ipv6 2>/dev/null) ||
    IPV6_LOOPBACK_WAS_DISABLED='unavailable'
  return 0
}

create_backup() {
  local timestamp

  timestamp=$(date '+%Y%m%d-%H%M%S')
  BACKUP_DIR="/root/smartdns-backup-$timestamp"
  while [[ -e "$BACKUP_DIR" ]]; do
    sleep 1
    timestamp=$(date '+%Y%m%d-%H%M%S')
    BACKUP_DIR="/root/smartdns-backup-$timestamp"
  done
  install -d -o root -g root -m 0700 "$BACKUP_DIR"

  if [[ -e "$CONFIG_TARGET" || -L "$CONFIG_TARGET" ]]; then
    cp -a -- "$CONFIG_TARGET" "$BACKUP_DIR/smartdns.conf"
    CONFIG_PREEXISTED=true
  else
    printf '配置在升级前不存在。\n' >"$BACKUP_DIR/config-was-absent.txt"
  fi
  if [[ -e "$IPV6_DISABLE_CONFIG" || -L "$IPV6_DISABLE_CONFIG" ]]; then
    cp -a -- "$IPV6_DISABLE_CONFIG" "$BACKUP_DIR/99-disable-ipv6.conf"
    IPV6_CONFIG_PREEXISTED=true
  fi
  if [[ -e "$NETWORK_STACK_UNIT" || -L "$NETWORK_STACK_UNIT" ]]; then
    cp -a -- "$NETWORK_STACK_UNIT" "$BACKUP_DIR/404-network-stack.service"
    NETWORK_STACK_UNIT_PREEXISTED=true
  fi
  if [[ -e "$NETWORK_STACK_HELPER" || -L "$NETWORK_STACK_HELPER" ]]; then
    cp -a -- "$NETWORK_STACK_HELPER" "$BACKUP_DIR/404-network-stack"
    NETWORK_STACK_HELPER_PREEXISTED=true
  fi
  if [[ -e "$RESOLV_CONF" || -L "$RESOLV_CONF" ]]; then
    cp -a -- "$RESOLV_CONF" "$BACKUP_DIR/resolv.conf"
    RESOLV_CONF_PREEXISTED=true
  fi

  if command -v smartdns >/dev/null 2>&1; then
    smartdns -v >"$BACKUP_DIR/smartdns-version-before.txt" 2>&1 || true
  else
    printf 'smartdns command not installed\n' >"$BACKUP_DIR/smartdns-version-before.txt"
  fi
  if ! dpkg-query -W smartdns >"$BACKUP_DIR/dpkg-version-before.txt" 2>&1; then
    printf 'smartdns package not installed\n' >"$BACKUP_DIR/dpkg-version-before.txt"
  fi
  printf 'held=%s\nenabled=%s\nactive=%s\n' \
    "$SMARTDNS_WAS_HELD" "$SMARTDNS_WAS_ENABLED" "$SMARTDNS_WAS_ACTIVE" \
    >"$BACKUP_DIR/service-state-before.txt"
  printf 'all=%s\ndefault=%s\nlo=%s\nresolved_present=%s\nresolved_enabled=%s\nresolved_active=%s\n' \
    "$IPV6_ALL_WAS_DISABLED" "$IPV6_DEFAULT_WAS_DISABLED" \
    "$IPV6_LOOPBACK_WAS_DISABLED" "$SYSTEMD_RESOLVED_UNIT_PRESENT" \
    "$SYSTEMD_RESOLVED_WAS_ENABLED" \
    "$SYSTEMD_RESOLVED_WAS_ACTIVE" >"$BACKUP_DIR/network-state-before.txt"
  BACKUP_READY=true
  log "升级前状态已备份到：$BACKUP_DIR"
}

restore_previous_state() {
  local restore_entry
  local restore_output
  local restore_scope
  local restore_status=0
  local restore_value

  [[ "$BACKUP_READY" == true ]] || return 1
  warn '正在恢复升级前的 SmartDNS 配置、服务状态和 hold 状态。'
  if [[ "$CONFIG_PREEXISTED" == true ]]; then
    if ! rm -f -- "$CONFIG_TARGET" ||
      ! cp -a -- "$BACKUP_DIR/smartdns.conf" "$CONFIG_TARGET"; then
      restore_status=1
    fi
  else
    rm -f -- "$CONFIG_TARGET" || restore_status=1
  fi
  if systemctl cat "$NETWORK_STACK_UNIT_NAME" >/dev/null 2>&1 ||
    [[ -e "$NETWORK_STACK_UNIT" || -L "$NETWORK_STACK_UNIT" ]]; then
    systemctl disable --now "$NETWORK_STACK_UNIT_NAME" >/dev/null 2>&1 ||
      restore_status=1
  fi
  rm -f -- "$NETWORK_STACK_UNIT" || restore_status=1
  if [[ "$NETWORK_STACK_UNIT_PREEXISTED" == true ]]; then
    cp -a -- "$BACKUP_DIR/404-network-stack.service" "$NETWORK_STACK_UNIT" ||
      restore_status=1
  fi
  rm -f -- "$NETWORK_STACK_HELPER" || restore_status=1
  if [[ "$NETWORK_STACK_HELPER_PREEXISTED" == true ]]; then
    cp -a -- "$BACKUP_DIR/404-network-stack" "$NETWORK_STACK_HELPER" ||
      restore_status=1
  fi
  rm -f -- "$IPV6_DISABLE_CONFIG" || restore_status=1
  if [[ "$IPV6_CONFIG_PREEXISTED" == true ]]; then
    cp -a -- "$BACKUP_DIR/99-disable-ipv6.conf" "$IPV6_DISABLE_CONFIG" ||
      restore_status=1
  fi
  for restore_entry in \
    "all:$IPV6_ALL_WAS_DISABLED" \
    "default:$IPV6_DEFAULT_WAS_DISABLED" \
    "lo:$IPV6_LOOPBACK_WAS_DISABLED"; do
    restore_scope=${restore_entry%%:*}
    restore_value=${restore_entry#*:}
    [[ "$restore_value" == 0 || "$restore_value" == 1 ]] || continue
    if ! restore_output=$(sysctl -q -w \
      "net.ipv6.conf.$restore_scope.disable_ipv6=$restore_value" 2>&1); then
      sysctl_restriction_error "$restore_output" || restore_status=1
    fi
  done

  systemctl daemon-reload >/dev/null 2>&1 || restore_status=1
  systemctl reset-failed "$NETWORK_STACK_UNIT_NAME" >/dev/null 2>&1 || true
  if [[ "$NETWORK_STACK_UNIT_PREEXISTED" == true ]]; then
    if [[ "$NETWORK_STACK_UNIT_WAS_ENABLED" == true ]]; then
      systemctl enable "$NETWORK_STACK_UNIT_NAME" >/dev/null 2>&1 ||
        restore_status=1
    else
      systemctl disable "$NETWORK_STACK_UNIT_NAME" >/dev/null 2>&1 ||
        restore_status=1
    fi
    if [[ "$NETWORK_STACK_UNIT_WAS_ACTIVE" == true ]]; then
      systemctl restart "$NETWORK_STACK_UNIT_NAME" >/dev/null 2>&1 ||
        restore_status=1
    else
      systemctl stop "$NETWORK_STACK_UNIT_NAME" >/dev/null 2>&1 ||
        restore_status=1
    fi
  fi
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
  if [[ "$SYSTEMD_RESOLVED_UNIT_PRESENT" == true ]]; then
    if [[ "$SYSTEMD_RESOLVED_WAS_ENABLED" == true ]]; then
      systemctl enable systemd-resolved.service >/dev/null 2>&1 || restore_status=1
    else
      systemctl disable systemd-resolved.service >/dev/null 2>&1 || restore_status=1
    fi
    if [[ "$SYSTEMD_RESOLVED_WAS_ACTIVE" == true ]]; then
      systemctl start systemd-resolved.service >/dev/null 2>&1 || restore_status=1
    else
      systemctl stop systemd-resolved.service >/dev/null 2>&1 || restore_status=1
    fi
  fi
  if mountpoint -q -- "$RESOLV_CONF" 2>/dev/null; then
    if [[ "$RESOLV_CONF_PREEXISTED" == true ]]; then
      cp -- "$BACKUP_DIR/resolv.conf" "$RESOLV_CONF" 2>/dev/null || true
    fi
  else
    rm -f -- "$RESOLV_CONF" || restore_status=1
    if [[ "$RESOLV_CONF_PREEXISTED" == true ]]; then
      cp -a -- "$BACKUP_DIR/resolv.conf" "$RESOLV_CONF" || restore_status=1
    fi
  fi
  return "$restore_status"
}

capture_start_journal() {
  [[ -n "$START_TIME" ]] || return 1
  journalctl -u smartdns.service --since "$START_TIME" --no-pager >"$JOURNAL_FILE" 2>&1
}

fail_with_recovery() {
  local reason=$1
  local recovery_result='失败'

  capture_start_journal || true
  if restore_previous_state; then
    recovery_result='成功'
  fi

  printf '[FAIL] %s\n' "$reason" >&2
  printf '[INFO] 状态恢复：%s；备份目录：%s\n' "$recovery_result" "$BACKUP_DIR" >&2
  if [[ -s "$JOURNAL_FILE" ]]; then
    printf '%s\n' '----- smartdns 本次启动日志 -----' >&2
    cat "$JOURNAL_FILE" >&2
    printf '%s\n' '----- 日志结束 -----' >&2
  else
    warn '没有取得 SmartDNS 本次启动日志。'
  fi
  exit 1
}

package_is_already_installed() {
  local installed_architecture
  local installed_status
  local installed_version

  installed_status=$(dpkg-query -W -f='${Status}' smartdns 2>/dev/null || true)
  installed_version=$(dpkg-query -W -f='${Version}' smartdns 2>/dev/null || true)
  installed_architecture=$(dpkg-query -W -f='${Architecture}' smartdns 2>/dev/null || true)
  [[ "$installed_status" == *' ok installed' &&
    "$installed_version" == "$EXPECTED_VERSION" &&
    "$installed_architecture" == "$ARCH" ]]
}

install_pinned_package() {
  if package_is_already_installed; then
    log "已安装精确目标版本 $EXPECTED_VERSION；跳过重复安装。"
    return 0
  fi

  apt-mark unhold smartdns >/dev/null 2>&1 ||
    fail_with_recovery '安装前无法取消 smartdns hold。'
  log "安装固定 Debian 软件包：$ASSET_NAME"
  if ! DEBIAN_FRONTEND=noninteractive apt-get \
    -o Dpkg::Options::='--force-confold' install --yes --allow-downgrades \
    "$DEB_PATH"; then
    fail_with_recovery '安装固定 SmartDNS Debian 软件包失败。'
  fi
  hash -r
}

verify_installed_package() {
  local installed_architecture
  local installed_package
  local package_status
  local version_output

  SMARTDNS_COMMAND=$(command -v smartdns) ||
    fail_with_recovery '安装后找不到 smartdns 命令。'
  SMARTDNS_BINARY_PATH=$(readlink -f "$SMARTDNS_COMMAND")
  [[ -n "$SMARTDNS_BINARY_PATH" && -x "$SMARTDNS_BINARY_PATH" ]] ||
    fail_with_recovery "SmartDNS 实际二进制路径无效：$SMARTDNS_BINARY_PATH。"

  if ! version_output=$(smartdns -v 2>&1); then
    fail_with_recovery "smartdns -v 执行失败：$(shorten_line "$version_output")"
  fi
  SMARTDNS_VERSION_TEXT=$(awk 'NF { print; exit }' <<<"$version_output")
  [[ -n "$SMARTDNS_VERSION_TEXT" ]] ||
    fail_with_recovery 'smartdns -v 未返回版本信息。'
  [[ "$SMARTDNS_VERSION_TEXT" == "smartdns $EXPECTED_VERSION" ]] ||
    fail_with_recovery "smartdns -v 与预期版本 $EXPECTED_VERSION 不一致：$SMARTDNS_VERSION_TEXT。"

  package_status=$(dpkg-query -W -f='${Status}' smartdns)
  installed_package=$(dpkg-query -W -f='${Package}' smartdns)
  PACKAGE_VERSION=$(dpkg-query -W -f='${Version}' smartdns)
  installed_architecture=$(dpkg-query -W -f='${Architecture}' smartdns)
  [[ "$package_status" == *' ok installed' ]] ||
    fail_with_recovery "SmartDNS Debian 软件包状态异常：$package_status。"
  [[ "$installed_package" == 'smartdns' ]] ||
    fail_with_recovery "已安装 Debian 软件包名称不是 smartdns：$installed_package。"
  [[ "$PACKAGE_VERSION" == "$EXPECTED_VERSION" ]] ||
    fail_with_recovery "已安装包版本 $PACKAGE_VERSION 与固定版本 $EXPECTED_VERSION 不一致。"
  [[ "$installed_architecture" == "$ARCH" ]] ||
    fail_with_recovery "已安装包架构 $installed_architecture 与目标架构 $ARCH 不一致。"

  log "smartdns -v：$SMARTDNS_VERSION_TEXT"
  log "dpkg-query：smartdns $PACKAGE_VERSION $installed_architecture"
  log "SmartDNS 实际二进制：$SMARTDNS_BINARY_PATH"
}

stop_and_clean_smartdns() {
  systemctl stop smartdns.service >/dev/null 2>&1 || true
  pkill -TERM -x smartdns 2>/dev/null || true
  for _ in {1..5}; do
    pgrep -x smartdns >/dev/null 2>&1 || break
    sleep 1
  done
  if pgrep -x smartdns >/dev/null 2>&1; then
    pkill -KILL -x smartdns 2>/dev/null || true
  fi
  rm -f -- /run/smartdns.pid /var/run/smartdns.pid
  if pgrep -x smartdns >/dev/null 2>&1; then
    fail_with_recovery '清理后仍检测到 SmartDNS 残留进程。'
  fi
  return 0
}

find_validation_port() {
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

validate_configuration_independently() {
  local validation_pid
  local validation_port

  validation_port=$(find_validation_port) ||
    fail_with_recovery '找不到可用于 SmartDNS 配置验证的本地高端口。'
  sed \
    -e "s/^bind 127\\.0\\.0\\.1:53$/bind 127.0.0.1:$validation_port/" \
    -e "s/^bind-tcp 127\\.0\\.0\\.1:53$/bind-tcp 127.0.0.1:$validation_port/" \
    "$STAGED_CONFIG" >"$VALIDATION_CONFIG"

  smartdns -f -x -c "$VALIDATION_CONFIG" -p "$TMP_DIR/validation.pid" \
    >"$VALIDATION_LOG" 2>&1 &
  validation_pid=$!
  sleep 2
  if ! kill -0 "$validation_pid" 2>/dev/null; then
    wait "$validation_pid" 2>/dev/null || true
    fail_with_recovery "SmartDNS 独立配置验证启动失败：$(shorten_line "$(<"$VALIDATION_LOG")")"
  fi
  if ! ss -H -lntu "sport = :$validation_port" 2>/dev/null |
    grep -Fq "127.0.0.1:$validation_port"; then
    kill -TERM "$validation_pid" 2>/dev/null || true
    wait "$validation_pid" 2>/dev/null || true
    fail_with_recovery 'SmartDNS 独立配置验证实例未监听预期端口。'
  fi
  kill -TERM "$validation_pid" 2>/dev/null || true
  wait "$validation_pid" 2>/dev/null || true
  if grep -Eiq \
    'unsupported[[:space:]]+config|configuration[[:space:]]+error|parse[[:space:]]+error|load[[:space:]]+config[[:space:]]+failed' \
    "$VALIDATION_LOG"; then
    fail_with_recovery "SmartDNS 独立配置验证发现错误：$(shorten_line "$(<"$VALIDATION_LOG")")"
  fi
  log "SmartDNS $CONFIG_VARIANT 配置已通过独立端口 $validation_port 的短时启动验证。"
}

check_port_53_conflicts() {
  local conflicts
  local output

  output=$(ss -H -lntup 'sport = :53' 2>/dev/null) ||
    fail_with_recovery '无法检查 53 端口监听状态。'
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
    fail_with_recovery "53 端口存在冲突监听：$(shorten_line "$conflicts")"
}

deploy_configuration() {
  local cache_mode
  local config_mode
  local config_owner
  local etc_mode
  local service_group
  local service_user

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
  if ! rm -f -- "$CONFIG_TARGET" ||
    ! install -o root -g root -m 0644 "$STAGED_CONFIG" "$CONFIG_TARGET"; then
    fail_with_recovery '部署 /etc/smartdns/smartdns.conf 失败。'
  fi
  cmp -s "$STAGED_CONFIG" "$CONFIG_TARGET" ||
    fail_with_recovery '部署后的 SmartDNS 配置与内嵌模板不一致。'

  etc_mode=$(stat -c '%a' /etc/smartdns) ||
    fail_with_recovery '无法读取 /etc/smartdns 权限。'
  cache_mode=$(stat -c '%a' /var/cache/smartdns) ||
    fail_with_recovery '无法读取 /var/cache/smartdns 权限。'
  config_mode=$(stat -c '%a' "$CONFIG_TARGET") ||
    fail_with_recovery '无法读取 SmartDNS 配置权限。'
  config_owner=$(stat -c '%U:%G' "$CONFIG_TARGET") ||
    fail_with_recovery '无法读取 SmartDNS 配置属主。'
  [[ "$etc_mode" == '755' && "$cache_mode" == '750' ]] ||
    fail_with_recovery "SmartDNS 目录权限异常：/etc=$etc_mode，cache=$cache_mode。"
  [[ "$config_mode" == '644' && "$config_owner" == 'root:root' ]] ||
    fail_with_recovery "SmartDNS 配置权限异常：$config_owner $config_mode。"
}

write_network_stack_helper() {
  local target=$1
  local candidate
  local script_dir

  script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)
  for candidate in "$script_dir/404-network-stack" "$script_dir/scripts/404-network-stack"; do
    if [[ -f "$candidate" && -r "$candidate" ]]; then
      cp -- "$candidate" "$target"
      return 0
    fi
  done

  cat >"$target" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly STATUS_FILE='/run/404-network-stack.status'

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }

is_restricted_error() {
  local message=${1,,}
  [[ "$message" == *'permission denied'* ||
    "$message" == *'operation not permitted'* ||
    "$message" == *'read-only file system'* ||
    "$message" == *'readonly file system'* ]]
}

network_stack_main() {
  local mode=${1:-}
  local desired_value
  local detected=''
  local container=''
  local output=''
  local restricted=false
  local scope
  local all_value='unknown'
  local default_value='unknown'
  local loopback_value='unknown'
  local kernel_state='UNAVAILABLE'
  local enforcement='enabled'

  case "$mode" in
    ipv4) desired_value=1 ;;
    ipv6|dual) desired_value=0 ;;
    *) printf '[FAIL] 未知网络栈：%s。\n' "$mode" >&2; return 2 ;;
  esac

  detected=$(systemd-detect-virt 2>/dev/null || true)
  container=$(systemd-detect-virt --container 2>/dev/null || true)
  [[ -n "$detected" && "$detected" != none ]] || detected='none'
  [[ -n "$container" && "$container" != none ]] || container='none'
  info "Virtualization: $detected"
  if [[ "$container" != none ]]; then
    info "Container environment detected: $container."
  fi

  for scope in all default lo; do
    if output=$(sysctl -q -w "net.ipv6.conf.$scope.disable_ipv6=$desired_value" 2>&1); then
      continue
    fi
    if is_restricted_error "$output"; then
      restricted=true
      warn "Kernel IPv6 sysctl net.ipv6.conf.$scope.disable_ipv6 is controlled by the host."
      continue
    fi
    printf '[FAIL] sysctl net.ipv6.conf.%s.disable_ipv6: %s\n' \
      "$scope" "$output" >&2
    return 1
  done

  all_value=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || printf unknown)
  default_value=$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || printf unknown)
  loopback_value=$(sysctl -n net.ipv6.conf.lo.disable_ipv6 2>/dev/null || printf unknown)
  if [[ "$all_value" == 1 && "$default_value" == 1 && "$loopback_value" == 1 ]]; then
    kernel_state='YES'
  elif [[ "$all_value" == 0 && "$default_value" == 0 && "$loopback_value" == 0 ]]; then
    kernel_state='NO'
  fi
  if [[ "$restricted" == true ]]; then
    enforcement='unavailable'
    warn 'Kernel IPv6 sysctl is controlled by host; application-level enforcement remains active.'
  fi
  install -d -m 0755 /run
  printf 'MODE=%s\nKERNEL_ENFORCEMENT=%s\nKERNEL_IPV6_DISABLED=%s\nVIRTUALIZATION=%s\nCONTAINER=%s\n' \
    "$mode" "$enforcement" "$kernel_state" "$detected" "$container" >"$STATUS_FILE"
  info "Kernel IPv6 disabled: $kernel_state"
}

network_stack_main "$@"
EOF
}

install_ipv4_network_stack_unit() {
  local staged_helper="$TMP_DIR/404-network-stack"
  local staged_unit="$TMP_DIR/404-network-stack.service"

  write_network_stack_helper "$staged_helper"

  cat >"$staged_unit" <<'EOF'
[Unit]
Description=Apply 404notfound IPv4-only network stack
After=networking.service
Before=smartdns.service sing-box.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/libexec/404-network-stack ipv4

[Install]
WantedBy=multi-user.target
EOF

  rm -f -- "$IPV6_DISABLE_CONFIG" ||
    fail_with_recovery "无法删除早期 IPv6 禁用配置：$IPV6_DISABLE_CONFIG。"
  install -D -o root -g root -m 0755 "$staged_helper" "$NETWORK_STACK_HELPER" ||
    fail_with_recovery '无法安装 network-stack 兼容 helper。'
  cmp -s "$staged_helper" "$NETWORK_STACK_HELPER" ||
    fail_with_recovery 'network-stack helper 部署后内容不一致。'
  if ! install -D -o root -g root -m 0644 "$staged_unit" "$NETWORK_STACK_UNIT"; then
    fail_with_recovery '无法安装 IPv4-only network-stack unit。'
  fi
  cmp -s "$staged_unit" "$NETWORK_STACK_UNIT" ||
    fail_with_recovery 'IPv4-only network-stack unit 部署后内容不一致。'
  systemctl daemon-reload ||
    fail_with_recovery 'network-stack unit daemon-reload 失败。'
  systemctl enable "$NETWORK_STACK_UNIT_NAME" ||
    fail_with_recovery '无法启用 IPv4-only network-stack unit。'
  systemctl restart "$NETWORK_STACK_UNIT_NAME" ||
    fail_with_recovery '无法执行 IPv4-only network-stack unit。'
  systemctl is-enabled --quiet "$NETWORK_STACK_UNIT_NAME" ||
    fail_with_recovery 'IPv4-only network-stack unit 未设置为 enabled。'
  systemctl is-active --quiet "$NETWORK_STACK_UNIT_NAME" ||
    fail_with_recovery 'IPv4-only network-stack unit 未处于 active 状态。'
}

remove_ipv4_network_stack_unit() {
  if systemctl cat "$NETWORK_STACK_UNIT_NAME" >/dev/null 2>&1 ||
    [[ -e "$NETWORK_STACK_UNIT" || -L "$NETWORK_STACK_UNIT" ]]; then
    systemctl disable --now "$NETWORK_STACK_UNIT_NAME" ||
      fail_with_recovery '无法停用 IPv4-only network-stack unit。'
  fi
  rm -f -- "$NETWORK_STACK_UNIT" ||
    fail_with_recovery '无法删除 IPv4-only network-stack unit。'
  rm -f -- "$NETWORK_STACK_HELPER" ||
    fail_with_recovery '无法删除 network-stack helper。'
  rm -f -- "$IPV6_DISABLE_CONFIG" ||
    fail_with_recovery "无法删除早期 IPv6 禁用配置：$IPV6_DISABLE_CONFIG。"
  systemctl daemon-reload ||
    fail_with_recovery '删除 network-stack unit 后 daemon-reload 失败。'
  systemctl reset-failed "$NETWORK_STACK_UNIT_NAME" >/dev/null 2>&1 || true
  [[ ! -e "$NETWORK_STACK_UNIT" && ! -L "$NETWORK_STACK_UNIT" ]] ||
    fail_with_recovery 'IPv4-only network-stack unit 删除后仍然存在。'
}

ipv6_network_ready() {
  ip -6 -o addr show scope global 2>/dev/null | grep -q ' inet6 ' &&
    ip -6 route show default 2>/dev/null | grep -q '^default[[:space:]]'
}

restore_ipv6_network_configuration() {
  local attempt

  [[ "$NETWORK_STACK" != ipv4 ]] || return 0
  ipv6_network_ready && return 0

  if command -v ifup >/dev/null 2>&1; then
    log '重新应用 ifupdown 配置以恢复 IPv6；保留现有 IPv4 和 SSH 会话。'
    # Do not run ifdown: the current IPv4 SSH path must remain available.
    # Existing IPv4 entries may report EEXIST, so let ifup continue to the
    # inet6 stanza and rely on the strict network health gate below.
    if ! ifup --force --ignore-errors -a; then
      warn 'ifupdown 重新应用返回失败；将等待网络自行恢复并继续严格验证。'
    fi
  else
    warn '未找到 ifup；将等待网络管理器自行恢复 IPv6。'
  fi

  for attempt in {1..10}; do
    ipv6_network_ready && return 0
    ((attempt == 10)) || sleep 1
  done
  warn 'IPv6 global 地址或 default route 尚未恢复；后续健康检查将决定是否回滚。'
}

configure_network_stack() {
  local kernel_values=''

  case "$NETWORK_STACK" in
    ipv4)
      install_ipv4_network_stack_unit
      apply_ipv6_sysctl_capability_aware 1
      APPLICATION_IPV4_ONLY='YES'
      ;;
    ipv6|dual)
      remove_ipv4_network_stack_unit
      apply_ipv6_sysctl_capability_aware 0
      APPLICATION_IPV4_ONLY='NO'
      restore_ipv6_network_configuration
      ;;
  esac

  if ! kernel_values=$(read_ipv6_kernel_state); then
    KERNEL_ENFORCEMENT='unavailable'
    KERNEL_IPV6_DISABLED='UNAVAILABLE'
    degrade '无法读取内核 IPv6 sysctl；继续使用应用层网络栈配置。'
    return 0
  fi
  case "$kernel_values" in
    1/1/1) KERNEL_IPV6_DISABLED='YES' ;;
    0/0/0) KERNEL_IPV6_DISABLED='NO' ;;
    *) KERNEL_IPV6_DISABLED='UNAVAILABLE' ;;
  esac
  if [[ "$NETWORK_STACK" == ipv4 ]]; then
    if [[ "$KERNEL_IPV6_DISABLED" != YES && "$KERNEL_ENFORCEMENT" != unavailable ]]; then
      fail_with_recovery 'IPv4-only 验证失败：all/default/lo 的 disable_ipv6 未全部设为 1。'
    fi
    [[ ! -e "$IPV6_DISABLE_CONFIG" && ! -L "$IPV6_DISABLE_CONFIG" ]] ||
      fail_with_recovery "IPv4-only 验证失败：仍残留早期配置 $IPV6_DISABLE_CONFIG。"
  else
    if [[ "$KERNEL_IPV6_DISABLED" != NO && "$KERNEL_ENFORCEMENT" != unavailable ]]; then
      fail_with_recovery "$NETWORK_STACK 验证失败：all/default/lo 的 disable_ipv6 未全部恢复为 0。"
    fi
    [[ ! -e "$IPV6_DISABLE_CONFIG" && ! -L "$IPV6_DISABLE_CONFIG" ]] ||
      fail_with_recovery "$NETWORK_STACK 验证失败：IPv6 禁用配置仍存在。"
  fi
  log "网络栈已应用：$NETWORK_STACK，disable_ipv6=$kernel_values。"
  log "Kernel IPv6 disabled: $KERNEL_IPV6_DISABLED"
  log "Application IPv4-only: $APPLICATION_IPV4_ONLY"
}

listener_present() {
  local protocol=$1

  awk -v protocol="$protocol" '
    $1 == protocol &&
    $5 ~ /^127\.0\.0\.1(%[^:[:space:]]+)?:53$/ &&
    $0 ~ /users:\(\("smartdns"/ { found = 1 }
    END { exit !found }
  ' <<<"$SOCKET_OUTPUT"
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

  IPV4_ANSWER=''
  IPV4_ATTEMPTS=0
  LAST_DIG_OUTPUT=''
  for attempt in {1..10}; do
    IPV4_ATTEMPTS=$attempt
    if output=$(dig @127.0.0.1 cloudflare.com A +short +time=4 +tries=1 2>&1); then
      query_status=0
    else
      query_status=$?
    fi
    LAST_DIG_OUTPUT=$output
    candidate=$(first_valid_ipv4 <<<"$output" || true)
    if ((query_status == 0)) && [[ -n "$candidate" ]]; then
      IPV4_ANSWER=$candidate
      return 0
    fi
    if ((attempt < 10)); then
      sleep 2
    fi
  done
  return 1
}

first_valid_ipv6() {
  awk '
    $1 ~ /^[0-9A-Fa-f:]+$/ && index($1, ":") > 0 {
      print $1
      found = 1
      exit
    }
    END { exit !found }
  '
}

query_smartdns_short() {
  local qtype=$1
  local attempt
  local output=''

  for attempt in {1..10}; do
    if output=$(dig @127.0.0.1 cloudflare.com "$qtype" +short +time=4 +tries=1 2>&1); then
      printf '%s' "$output"
      return 0
    fi
    ((attempt == 10)) || sleep 2
  done
  printf '%s' "$output"
  return 1
}

validate_network_stack_health() {
  local a_output=''
  local aaaa_output=''
  local disable_ipv6

  if ! disable_ipv6=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null); then
    disable_ipv6='unknown'
    KERNEL_ENFORCEMENT='unavailable'
    KERNEL_IPV6_DISABLED='UNAVAILABLE'
    degrade '无法读取 net.ipv6.conf.all.disable_ipv6；跳过内核级健康检查。'
  fi
  if [[ "$NETWORK_STACK" == ipv6 ]]; then
    a_output=$(query_smartdns_short A) ||
      fail_with_recovery "SmartDNS A 查询失败：$(shorten_line "$a_output")"
  else
    query_smartdns_ipv4 ||
      fail_with_recovery "SmartDNS A 查询连续 $IPV4_ATTEMPTS 次失败：$(shorten_line "$LAST_DIG_OUTPUT")"
    a_output=$IPV4_ANSWER
  fi
  aaaa_output=$(query_smartdns_short AAAA) ||
    fail_with_recovery "SmartDNS AAAA 查询失败：$(shorten_line "$aaaa_output")"

  case "$NETWORK_STACK" in
    ipv4)
      [[ "$disable_ipv6" == 1 || "$KERNEL_ENFORCEMENT" == unavailable ]] ||
        fail_with_recovery 'IPv4-only 健康检查失败：disable_ipv6 不是 1。'
      first_valid_ipv4 <<<"$a_output" >/dev/null ||
        fail_with_recovery "IPv4-only 健康检查失败：A 没有结果：$(shorten_line "$a_output")"
      [[ -z "$aaaa_output" ]] ||
        fail_with_recovery "IPv4-only 健康检查失败：AAAA 应为空：$(shorten_line "$aaaa_output")"
      curl -4 --fail --silent --show-error --output /dev/null \
        --connect-timeout 8 --max-time 20 https://www.cloudflare.com/cdn-cgi/trace ||
        fail_with_recovery 'IPv4-only 健康检查失败：curl -4 HTTPS 失败。'
      ;;
    ipv6)
      [[ "$disable_ipv6" == 0 || "$KERNEL_ENFORCEMENT" == unavailable ]] ||
        fail_with_recovery 'IPv6-only 健康检查失败：disable_ipv6 不是 0。'
      [[ -z "$a_output" ]] ||
        fail_with_recovery "IPv6-only 健康检查失败：A 应为空：$(shorten_line "$a_output")"
      first_valid_ipv6 <<<"$aaaa_output" >/dev/null ||
        fail_with_recovery "IPv6-only 健康检查失败：AAAA 没有结果：$(shorten_line "$aaaa_output")"
      ip -6 route show default | grep -q '^default' ||
        fail_with_recovery 'IPv6-only 健康检查失败：没有可用 IPv6 default route。'
      curl -6 --fail --silent --show-error --output /dev/null \
        --connect-timeout 8 --max-time 20 https://www.cloudflare.com/cdn-cgi/trace ||
        fail_with_recovery 'IPv6-only 健康检查失败：curl -6 HTTPS 失败。'
      ;;
    dual)
      [[ "$disable_ipv6" == 0 || "$KERNEL_ENFORCEMENT" == unavailable ]] ||
        fail_with_recovery 'Dual-stack 健康检查失败：disable_ipv6 不是 0。'
      first_valid_ipv4 <<<"$a_output" >/dev/null ||
        fail_with_recovery "Dual-stack 健康检查失败：A 没有结果：$(shorten_line "$a_output")"
      first_valid_ipv6 <<<"$aaaa_output" >/dev/null ||
        fail_with_recovery "Dual-stack 健康检查失败：AAAA 没有结果：$(shorten_line "$aaaa_output")"
      curl -4 --fail --silent --show-error --output /dev/null \
        --connect-timeout 8 --max-time 20 https://www.cloudflare.com/cdn-cgi/trace ||
        fail_with_recovery 'Dual-stack 健康检查失败：curl -4 HTTPS 失败。'
      curl -6 --fail --silent --show-error --output /dev/null \
        --connect-timeout 8 --max-time 20 https://www.cloudflare.com/cdn-cgi/trace ||
        fail_with_recovery 'Dual-stack 健康检查失败：curl -6 HTTPS 失败。'
      ;;
  esac
  if [[ "$KERNEL_ENFORCEMENT" == unavailable ]]; then
    log "$NETWORK_STACK 的应用层 DNS、路由与 HTTPS 健康检查通过；内核 sysctl 不可用。"
  else
    log "$NETWORK_STACK 的 DNS 记录、sysctl、路由与 HTTPS 健康检查通过。"
  fi
}

valid_system_ipv4_answer() {
  first_valid_ipv4 <<<"$SYSTEM_LOOKUP_OUTPUT" >/dev/null
}

start_and_validate_service() {
  START_TIME="@$(date +%s)"

  systemctl daemon-reload ||
    fail_with_recovery 'systemctl daemon-reload 失败。'
  # Debian's systemctl may return non-zero when an inactive unit has no failed
  # state to clear. Restart and the strict service checks below are decisive.
  systemctl reset-failed smartdns.service >/dev/null 2>&1 || true
  systemctl enable smartdns.service ||
    fail_with_recovery '无法设置 SmartDNS 开机启动。'
  systemctl restart smartdns.service ||
    fail_with_recovery '无法启动或重启 SmartDNS。'

  ENABLED_STATUS=$(systemctl is-enabled smartdns.service 2>&1) ||
    fail_with_recovery "无法取得 SmartDNS 开机启动状态：$ENABLED_STATUS"
  ACTIVE_STATUS=$(systemctl is-active smartdns.service 2>&1) ||
    fail_with_recovery "无法取得 SmartDNS 当前运行状态：$ACTIVE_STATUS"
  [[ "$ENABLED_STATUS" == 'enabled' ]] ||
    fail_with_recovery "SmartDNS 开机启动状态不是 enabled：$ENABLED_STATUS。"
  [[ "$ACTIVE_STATUS" == 'active' ]] ||
    fail_with_recovery "SmartDNS 当前运行状态不是 active：$ACTIVE_STATUS。"
  pgrep -x smartdns >/dev/null 2>&1 ||
    fail_with_recovery '未找到运行中的 SmartDNS 进程。'
  if [[ ! -s /run/smartdns.pid && ! -s /var/run/smartdns.pid ]]; then
    warn '未找到 SmartDNS PID 文件；进程与服务状态正常，因此不单独判定失败。'
  fi

  if ! capture_start_journal; then
    fail_with_recovery '无法读取 SmartDNS 本次启动日志。'
  fi
  if grep -Eiq \
    'unsupported[[:space:]]+config|failed[[:space:]]+to[[:space:]]+start|configuration[[:space:]]+error|parse[[:space:]]+error|failed[[:space:]]+to[[:space:]]+parse' \
    "$JOURNAL_FILE"; then
    fail_with_recovery 'SmartDNS 本次启动日志包含配置或启动错误。'
  fi

  for _ in {1..10}; do
    SOCKET_OUTPUT=$(ss -H -lntup 'sport = :53' 2>/dev/null || true)
    if listener_present udp && listener_present tcp; then
      break
    fi
    sleep 1
  done
  listener_present udp ||
    fail_with_recovery 'SmartDNS 未在 127.0.0.1:53/udp 监听。'
  listener_present tcp ||
    fail_with_recovery 'SmartDNS 未在 127.0.0.1:53/tcp 监听。'

  validate_network_stack_health

  apt-mark hold smartdns >/dev/null ||
    fail_with_recovery '健康检查通过后无法 hold smartdns。'
  apt-mark showhold | grep -Fxq smartdns ||
    fail_with_recovery 'apt-mark 未确认 smartdns 处于 hold 状态。'

  log "systemctl is-enabled smartdns：$ENABLED_STATUS"
  log "systemctl is-active smartdns：$ACTIVE_STATUS"
  log '本次启动日志未发现 unsupported config、启动或配置解析错误。'
  log '127.0.0.1:53 的 TCP 和 UDP 监听验证通过。'
  log "网络栈健康检查：$NETWORK_STACK。"
  log 'smartdns 已设置为 hold。'
}

resolv_conf_is_mountpoint() {
  mountpoint -q -- "$RESOLV_CONF" 2>/dev/null ||
    findmnt -rn -M "$RESOLV_CONF" >/dev/null 2>&1
}

resolv_conf_mount_is_read_only() {
  local options=''

  options=$(findmnt -rn -T "$RESOLV_CONF" -o OPTIONS 2>/dev/null || true)
  [[ ",$options," == *,ro,* ]]
}

configure_system_resolver() {
  local mount_description=''
  local resolved_stop_failed=false
  local staged_resolv="$TMP_DIR/resolv.conf"

  cat >"$staged_resolv" <<'EOF'
nameserver 127.0.0.1
options timeout:2 attempts:2
EOF
  if ! systemctl disable --now systemd-resolved.service >/dev/null 2>&1 &&
    systemctl is-active --quiet systemd-resolved.service; then
    resolved_stop_failed=true
  fi

  if resolv_conf_is_mountpoint; then
    mount_description=$(findmnt -rn -T "$RESOLV_CONF" \
      -o SOURCE,FSTYPE,OPTIONS 2>/dev/null || true)
    log "/etc/resolv.conf mount: ${mount_description:-unknown}."
    [[ "$resolved_stop_failed" == false ]] ||
      degrade 'systemd-resolved 仍处于 active；容器运行时管理 resolv.conf，将继续。'
    if resolv_conf_mount_is_read_only; then
      RESOLV_CONF_STATUS='CONTAINER_MANAGED_UNCHANGED'
      degrade '/etc/resolv.conf 是只读的容器/运行时挂载点；已保留原内容，未能持久接管。'
      return 0
    fi
    if cp -- "$staged_resolv" "$RESOLV_CONF" 2>/dev/null &&
      cmp -s -- "$staged_resolv" "$RESOLV_CONF"; then
      RESOLV_CONF_STATUS='CONTAINER_MANAGED_IN_PLACE'
      degrade '/etc/resolv.conf 是容器管理的挂载点；已原地更新，但容器重启后可能被运行时重新生成。'
      return 0
    fi
    RESOLV_CONF_STATUS='CONTAINER_MANAGED_UNCHANGED'
    degrade '/etc/resolv.conf 由容器运行时管理且无法原地覆盖；已保留原内容，SmartDNS 不回滚。'
    return 0
  fi

  [[ "$resolved_stop_failed" == false ]] ||
    fail_with_recovery '无法停止 systemd-resolved，拒绝切换 /etc/resolv.conf。'
  if [[ -L "$RESOLV_CONF" ]]; then
    log "/etc/resolv.conf symlink: $(readlink "$RESOLV_CONF") -> $(readlink -f "$RESOLV_CONF" 2>/dev/null || printf unknown)."
  fi
  rm -f -- "$RESOLV_CONF" ||
    fail_with_recovery '无法移除旧 /etc/resolv.conf。'
  install -o root -g root -m 0644 "$staged_resolv" "$RESOLV_CONF" ||
    fail_with_recovery '无法部署受管 /etc/resolv.conf。'
  [[ ! -L "$RESOLV_CONF" ]] ||
    fail_with_recovery '/etc/resolv.conf 仍是符号链接。'
  cmp -s -- "$staged_resolv" "$RESOLV_CONF" ||
    fail_with_recovery '/etc/resolv.conf 内容验证失败。'
  RESOLV_CONF_STATUS='MANAGED'
  log 'systemd-resolved 已停用；/etc/resolv.conf 已切换为 SmartDNS 受管普通文件。'
}

check_debian_system_dns() {
  local expected_resolv="$TMP_DIR/resolv.conf"

  if [[ "$RESOLV_CONF_STATUS" == MANAGED ]]; then
    [[ -f "$RESOLV_CONF" && ! -L "$RESOLV_CONF" ]] ||
      fail_with_recovery '/etc/resolv.conf 不是普通文件。'
    cmp -s -- "$expected_resolv" "$RESOLV_CONF" ||
      fail_with_recovery '/etc/resolv.conf 不是要求的 SmartDNS 两行配置。'
    systemctl is-active --quiet systemd-resolved.service &&
      fail_with_recovery 'systemd-resolved 健康检查失败：服务仍 active。'
  elif [[ "$RESOLV_CONF_STATUS" == CONTAINER_MANAGED_IN_PLACE ]]; then
    cmp -s -- "$expected_resolv" "$RESOLV_CONF" ||
      degrade '容器管理的 /etc/resolv.conf 在验证前已变化；运行时可能已重新生成。'
  fi
  dig @127.0.0.1 cloudflare.com +time=4 +tries=1 >/dev/null 2>&1 ||
    fail_with_recovery '通过 127.0.0.1 的 dig 健康检查失败。'
  if SYSTEM_LOOKUP_OUTPUT=$(getent hosts cloudflare.com 2>&1); then
    log 'Debian 系统默认解析验证通过。'
  elif [[ "$RESOLV_CONF_STATUS" == MANAGED ]]; then
    fail_with_recovery "Debian 系统默认解析失败：$(shorten_line "$SYSTEM_LOOKUP_OUTPUT")"
  else
    SYSTEM_RESOLUTION_STATUS='DEGRADED'
    degrade "容器管理的系统 resolver 当前解析失败；SmartDNS 本地查询正常：$(shorten_line "$SYSTEM_LOOKUP_OUTPUT")"
  fi
  if [[ "$RESOLV_CONF_STATUS" == MANAGED ]]; then
    log 'Debian 系统 DNS 验证通过：仅 127.0.0.1，systemd-resolved inactive。'
  fi
  log "SmartDNS configuration validation: PASS"
  log "SmartDNS service: ACTIVE"
}

print_summary() {
  printf '\nSmartDNS 更新成功\n'
  printf '固定 Release：%s\n' "$SMARTDNS_RELEASE_TAG"
  printf 'Debian / 架构：%s / %s\n' "$OS_VERSION" "$ARCH"
  printf '配置变体：%s\n' "$CONFIG_VARIANT"
  printf '网络栈：%s\n' "$NETWORK_STACK"
  printf 'Environment: %s\n' "$ENVIRONMENT_LABEL"
  printf 'Virtualization: %s\n' "$VIRTUALIZATION"
  printf 'Container: %s\n' "$CONTAINER_VIRTUALIZATION"
  printf 'Requested mode: %s\n' "$NETWORK_STACK"
  printf 'Kernel enforcement: %s\n' "$KERNEL_ENFORCEMENT"
  printf 'Kernel IPv6 disabled: %s\n' "$KERNEL_IPV6_DISABLED"
  printf 'Application IPv4-only: %s\n' "$APPLICATION_IPV4_ONLY"
  printf 'Release 资产：%s\n' "$ASSET_NAME"
  printf 'SmartDNS 当前版本：%s\n' "$SMARTDNS_VERSION_TEXT"
  printf 'Debian 软件包版本：%s\n' "$PACKAGE_VERSION"
  printf 'SmartDNS 二进制路径：%s\n' "$SMARTDNS_BINARY_PATH"
  printf '配置文件路径：%s\n' "$CONFIG_TARGET"
  printf '开机启动状态：%s\n' "$ENABLED_STATUS"
  printf '当前运行状态：%s\n' "$ACTIVE_STATUS"
  printf 'TCP 53：正常\n'
  printf 'UDP 53：正常\n'
  printf '网络栈 DNS / HTTPS：正常\n'
  printf 'APT hold：smartdns\n'
  case "$RESOLV_CONF_STATUS" in
    MANAGED) printf '系统 DNS：仅 127.0.0.1（持久受管）\n' ;;
    CONTAINER_MANAGED_IN_PLACE)
      printf '系统 DNS：容器运行时管理；本次已原地更新，重启后可能重建\n'
      ;;
    *) printf '系统 DNS：容器运行时管理，未能持久接管\n' ;;
  esac
  printf '系统解析：%s\n' "$SYSTEM_RESOLUTION_STATUS"
  printf 'Warnings: %d\n' "$WARNING_COUNT"
  printf 'Result: %s\n' "$RESULT_STATUS"
  printf '旧配置备份路径：%s\n' "$BACKUP_DIR"
}

main() {
  parse_args "$@"
  require_root_and_debian
  install_dependencies
  verify_required_commands
  detect_runtime_environment
  select_platform
  create_temporary_directory
  write_smartdns_configuration "$STAGED_CONFIG" "$CONFIG_VARIANT"
  if package_is_already_installed; then
    log "已安装精确目标版本 $EXPECTED_VERSION；无需下载重复软件包。"
  else
    download_and_verify_package
  fi
  capture_existing_state
  create_backup
  install_pinned_package
  verify_installed_package
  stop_and_clean_smartdns
  validate_configuration_independently
  check_port_53_conflicts
  deploy_configuration
  configure_network_stack
  start_and_validate_service
  configure_system_resolver
  check_debian_system_dns
  print_summary
}

main "$@"
