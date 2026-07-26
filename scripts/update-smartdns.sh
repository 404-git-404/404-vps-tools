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
AAAA_QUERY_OUTPUT=''
SYSTEM_LOOKUP_OUTPUT=''
CONFIG_PREEXISTED=false
SMARTDNS_WAS_HELD=false
SMARTDNS_WAS_ENABLED=false
SMARTDNS_WAS_ACTIVE=false
BACKUP_READY=false

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

shorten_line() {
  local value=${1//$'\n'/ }
  printf '%.300s' "$value"
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
    getent grep install journalctl kill mktemp pgrep pkill readlink rm sed
    sha256sum sleep ss stat systemctl timeout tr
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
  if apt-mark showhold | grep -Fxq smartdns; then
    SMARTDNS_WAS_HELD=true
  fi
  if systemctl is-enabled --quiet smartdns.service 2>/dev/null; then
    SMARTDNS_WAS_ENABLED=true
  fi
  if systemctl is-active --quiet smartdns.service 2>/dev/null; then
    SMARTDNS_WAS_ACTIVE=true
  fi
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
  BACKUP_READY=true
  log "升级前状态已备份到：$BACKUP_DIR"
}

restore_previous_state() {
  local restore_status=0

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

valid_system_ipv4_answer() {
  first_valid_ipv4 <<<"$SYSTEM_LOOKUP_OUTPUT" >/dev/null
}

start_and_validate_service() {
  START_TIME="@$(date +%s)"

  systemctl daemon-reload ||
    fail_with_recovery 'systemctl daemon-reload 失败。'
  systemctl reset-failed smartdns.service ||
    fail_with_recovery '无法重置 SmartDNS 服务失败状态。'
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

  if ! query_smartdns_ipv4; then
    fail_with_recovery "SmartDNS IPv4 查询连续 $IPV4_ATTEMPTS 次未返回合法 IPv4；最后输出：$(shorten_line "$LAST_DIG_OUTPUT")"
  fi
  if ! AAAA_QUERY_OUTPUT=$(dig @127.0.0.1 cloudflare.com AAAA +time=4 +tries=1 2>&1); then
    fail_with_recovery "SmartDNS AAAA 查询执行失败：$(shorten_line "$AAAA_QUERY_OUTPUT")"
  fi
  if ! grep -Eq 'status:[[:space:]]*NOERROR([,[:space:]]|$)' <<<"$AAAA_QUERY_OUTPUT"; then
    fail_with_recovery "SmartDNS AAAA 查询状态不是 NOERROR：$(shorten_line "$AAAA_QUERY_OUTPUT")"
  fi

  apt-mark hold smartdns >/dev/null ||
    fail_with_recovery '健康检查通过后无法 hold smartdns。'
  apt-mark showhold | grep -Fxq smartdns ||
    fail_with_recovery 'apt-mark 未确认 smartdns 处于 hold 状态。'

  log "systemctl is-enabled smartdns：$ENABLED_STATUS"
  log "systemctl is-active smartdns：$ACTIVE_STATUS"
  log '本次启动日志未发现 unsupported config、启动或配置解析错误。'
  log '127.0.0.1:53 的 TCP 和 UDP 监听验证通过。'
  log "IPv4 查询第 $IPV4_ATTEMPTS 次成功：$IPV4_ANSWER"
  log 'AAAA 查询状态：NOERROR（允许 ANSWER 为 0）。'
  log 'smartdns 已设置为 hold。'
}

report_system_dns_mismatch() {
  local nameserver_text=$1

  printf '[FAIL] SmartDNS 已更新并正常运行，但 Debian 系统 DNS 未指向 127.0.0.1。\n' >&2
  printf '[INFO] 当前有效 nameserver：%s\n' "$nameserver_text" >&2
  printf '[INFO] 请检查 /etc/resolv.conf；脚本不会自动修改系统 DNS。\n' >&2
  exit 1
}

check_debian_system_dns() {
  local index
  local nameserver_text='（无）'
  local -a nameservers=()

  if [[ ! -e /etc/resolv.conf || ! -r /etc/resolv.conf ]]; then
    report_system_dns_mismatch '（/etc/resolv.conf 不存在或不可读）'
  fi
  mapfile -t nameservers < <(
    awk '
      /^[[:space:]]*($|[;#])/ { next }
      $1 == "nameserver" && NF >= 2 && $2 !~ /^[;#]/ { print $2 }
    ' /etc/resolv.conf
  )
  if ((${#nameservers[@]} > 0)); then
    nameserver_text=${nameservers[0]}
    for ((index = 1; index < ${#nameservers[@]}; index++)); do
      nameserver_text+=", ${nameservers[index]}"
    done
  fi
  if ((${#nameservers[@]} != 1)) || [[ "${nameservers[0]:-}" != '127.0.0.1' ]]; then
    report_system_dns_mismatch "$nameserver_text"
  fi
  if ! SYSTEM_LOOKUP_OUTPUT=$(getent ahostsv4 cloudflare.com 2>&1) ||
    ! valid_system_ipv4_answer; then
    die 'Debian 系统默认解析失败；脚本未修改系统 DNS。'
  fi
  log 'Debian 系统 DNS 验证通过：仅 127.0.0.1。'
  log 'Debian 系统默认解析验证通过。'
}

print_summary() {
  printf '\nSmartDNS 更新成功\n'
  printf '固定 Release：%s\n' "$SMARTDNS_RELEASE_TAG"
  printf 'Debian / 架构：%s / %s\n' "$OS_VERSION" "$ARCH"
  printf '配置变体：%s\n' "$CONFIG_VARIANT"
  printf 'Release 资产：%s\n' "$ASSET_NAME"
  printf 'SmartDNS 当前版本：%s\n' "$SMARTDNS_VERSION_TEXT"
  printf 'Debian 软件包版本：%s\n' "$PACKAGE_VERSION"
  printf 'SmartDNS 二进制路径：%s\n' "$SMARTDNS_BINARY_PATH"
  printf '配置文件路径：%s\n' "$CONFIG_TARGET"
  printf '开机启动状态：%s\n' "$ENABLED_STATUS"
  printf '当前运行状态：%s\n' "$ACTIVE_STATUS"
  printf 'TCP 53：正常\n'
  printf 'UDP 53：正常\n'
  printf 'IPv4 查询：第 %s 次成功，%s\n' "$IPV4_ATTEMPTS" "$IPV4_ANSWER"
  printf 'AAAA 查询：NOERROR（允许空答案）\n'
  printf 'APT hold：smartdns\n'
  printf '系统 DNS：仅 127.0.0.1\n'
  printf '系统解析：正常\n'
  printf '旧配置备份路径：%s\n' "$BACKUP_DIR"
}

main() {
  require_root_and_debian
  install_dependencies
  verify_required_commands
  select_platform
  create_temporary_directory
  write_smartdns_configuration "$STAGED_CONFIG" "$CONFIG_VARIANT"
  download_and_verify_package
  capture_existing_state
  create_backup
  install_pinned_package
  verify_installed_package
  stop_and_clean_smartdns
  validate_configuration_independently
  check_port_53_conflicts
  deploy_configuration
  start_and_validate_service
  check_debian_system_dns
  print_summary
}

main "$@"
