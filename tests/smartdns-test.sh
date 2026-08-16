#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly REPO_ROOT
readonly INSTALLER="$REPO_ROOT/404notfound.sh"
readonly UPDATER="$REPO_ROOT/scripts/update-smartdns.sh"

TMP_DIR=''
TESTS_RUN=0

log() {
  printf '[TEST] %s\n' "$*"
}

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}

trap cleanup EXIT

assert_eq() {
  local expected=$1
  local actual=$2
  local message=$3
  [[ "$actual" == "$expected" ]] ||
    fail "$message：expected=[$expected]，actual=[$actual]。"
}

assert_file_contains_line() {
  local file=$1
  local line=$2
  grep -Fqx -- "$line" "$file" ||
    fail "$file 缺少精确行：$line"
}

extract_function() {
  local script=$1
  local function_name=$2

  awk -v signature="$function_name() {" '
    $0 == signature { capture = 1 }
    capture { print }
    capture && $0 == "}" { exit }
  ' "$script"
}

mapping_for() {
  local script=$1
  local os_id=$2
  local os_version=$3
  local architecture=$4
  local output
  local library="$TMP_DIR/mapping-library.sh"

  {
    printf '%s\n' "set -Eeuo pipefail"
    printf '%s\n' "SMARTDNS_RELEASE_BASE='https://github.com/404-git-404/404-vps-tools/releases/download/smartdns-debian-pinned-2026-07'"
    printf '%s\n' "SMARTDNS_EXPECTED_VERSION=''; SMARTDNS_CONFIG_VARIANT=''; SMARTDNS_ASSET_NAME=''; SMARTDNS_EXPECTED_SHA256=''; SMARTDNS_DOWNLOAD_URL=''"
    printf '%s\n' "EXPECTED_VERSION=''; CONFIG_VARIANT=''; ASSET_NAME=''; EXPECTED_SHA256=''; DOWNLOAD_URL=''"
    printf '%s\n' 'die() { printf "%s\n" "$*" >&2; exit 1; }'
    extract_function "$script" select_smartdns_target
    extract_function "$script" validate_smartdns_platform
    printf '%s\n' "validate_smartdns_platform '$os_id' '$os_version' '$architecture'"
    if [[ "$script" == "$INSTALLER" ]]; then
      # shellcheck disable=SC2016
      printf '%s\n' 'printf "%s|%s|%s|%s|%s\n" "$SMARTDNS_EXPECTED_VERSION" "$SMARTDNS_CONFIG_VARIANT" "$SMARTDNS_ASSET_NAME" "$SMARTDNS_EXPECTED_SHA256" "$SMARTDNS_DOWNLOAD_URL"'
    else
      # shellcheck disable=SC2016
      printf '%s\n' 'printf "%s|%s|%s|%s|%s\n" "$EXPECTED_VERSION" "$CONFIG_VARIANT" "$ASSET_NAME" "$EXPECTED_SHA256" "$DOWNLOAD_URL"'
    fi
  } >"$library"
  if ! output=$(bash "$library"); then
    return 1
  fi
  printf '%s' "$output"
}

test_fixed_mapping() {
  local architecture
  local expected
  local invalid_architecture
  local installer_result
  local invalid_case
  local invalid_id
  local invalid_version
  local os_version
  local updater_result

  for os_version in 12 13; do
    for architecture in amd64 arm64; do
      installer_result=$(mapping_for "$INSTALLER" debian "$os_version" "$architecture")
      updater_result=$(mapping_for "$UPDATER" debian "$os_version" "$architecture")
      assert_eq "$installer_result" "$updater_result" \
        "主脚本与更新脚本映射不一致（$os_version/$architecture）"
      case "$os_version:$architecture" in
        12:amd64)
          expected='40+dfsg-1|v40|smartdns_40+dfsg-1_bookworm_amd64.deb|8388fb543f870fc77d17dbaa9874277d2ef37d120ad2ab24af730d7032a80bcb'
          ;;
        12:arm64)
          expected='40+dfsg-1|v40|smartdns_40+dfsg-1_bookworm_arm64.deb|7aadb6fb0e6d2f38d8ce11db60561c2c8c7c9d0aacf1e54f9e27f44a4abfb9ca'
          ;;
        13:amd64)
          expected='46.1+dfsg-1.1~deb13u1|v46|smartdns_46.1+dfsg-1.1.deb13u1_trixie_amd64.deb|d2dfe591dbdabf3655c2ead30975ee20f6720346552bda989b212ccffde5ba4e'
          ;;
        13:arm64)
          expected='46.1+dfsg-1.1~deb13u1|v46|smartdns_46.1+dfsg-1.1.deb13u1_trixie_arm64.deb|d9eeb9050ab6e0c95011de83955f65ca8020779c8c32aba90d708bc54c33823f'
          ;;
      esac
      [[ "$installer_result" == "$expected|"* ]] ||
        fail "固定映射错误（$os_version/$architecture）：$installer_result"
      [[ "$installer_result" == *'https://github.com/404-git-404/404-vps-tools/releases/download/smartdns-debian-pinned-2026-07/'* ]] ||
        fail "固定 Release URL 错误（$os_version/$architecture）。"
    done
  done

  for invalid_case in \
    'debian|11|amd64' \
    'debian|14|amd64' \
    'debian|12|i386' \
    'debian|13|riscv64' \
    'ubuntu|12|amd64' \
    'debian||amd64' \
    'debian|12|'; do
    IFS='|' read -r invalid_id invalid_version invalid_architecture \
      <<<"$invalid_case"
    if mapping_for "$INSTALLER" "$invalid_id" "$invalid_version" \
      "$invalid_architecture" >/dev/null 2>&1; then
      fail "主脚本不应接受平台：$invalid_case"
    fi
    if mapping_for "$UPDATER" "$invalid_id" "$invalid_version" \
      "$invalid_architecture" >/dev/null 2>&1; then
      fail "更新脚本不应接受平台：$invalid_case"
    fi
  done
  ((TESTS_RUN += 1))
  log '四组固定映射、最终资产名、固定 URL 和不支持组合拒绝测试通过。'
}

render_configuration() {
  local script=$1
  local variant=$2
  local target=$3
  local network_stack=$4
  local library="$TMP_DIR/render-library.sh"

  {
    printf '%s\n' 'set -Eeuo pipefail'
    printf 'NETWORK_STACK=%q\n' "$network_stack"
    printf '%s\n' 'die() { printf "%s\n" "$*" >&2; exit 1; }'
    extract_function "$script" write_smartdns_configuration
    printf 'write_smartdns_configuration %q %q %q\n' \
      "$target" "$variant" "$network_stack"
  } >"$library"
  bash "$library"
}

write_expected_common() {
  local target=$1
  local network_stack=$2
  cat >"$target" <<'EXPECTED_COMMON'
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

EXPECTED_COMMON
  case "$network_stack" in
    ipv4) printf '%s\n\n' 'force-AAAA-SOA yes' >>"$target" ;;
    ipv6) printf '%s\n\n' 'force-qtype-SOA 1' >>"$target" ;;
    dual) ;;
  esac
}

test_configurations() {
  local installer_config
  local updater_config
  local expected_config
  local network_stack
  local variant

  for variant in v40 v46; do
    for network_stack in ipv4 ipv6 dual; do
    installer_config="$TMP_DIR/installer-$variant-$network_stack.conf"
    updater_config="$TMP_DIR/updater-$variant-$network_stack.conf"
    expected_config="$TMP_DIR/expected-$variant-$network_stack.conf"
    render_configuration "$INSTALLER" "$variant" "$installer_config" "$network_stack"
    render_configuration "$UPDATER" "$variant" "$updater_config" "$network_stack"
    cmp -s "$installer_config" "$updater_config" ||
      fail "主脚本与更新脚本的 $variant/$network_stack 配置不一致。"
    write_expected_common "$expected_config" "$network_stack"
    if [[ "$variant:$network_stack" == 'v40:ipv6' ]]; then
      cat >>"$expected_config" <<'EXPECTED_VARIANT'
server-https https://[2606:4700:4700::1111]/dns-query -host-name cloudflare-dns.com -http-host cloudflare-dns.com -tls-host-verify cloudflare-dns.com
server-https https://[2001:4860:4860::8888]/dns-query -host-name dns.google -http-host dns.google -tls-host-verify dns.google
EXPECTED_VARIANT
    elif [[ "$variant" == v40 ]]; then
      cat >>"$expected_config" <<'EXPECTED_VARIANT'
server-https https://1.1.1.1/dns-query -host-name cloudflare-dns.com -http-host cloudflare-dns.com -tls-host-verify cloudflare-dns.com
server-https https://8.8.8.8/dns-query -host-name dns.google -http-host dns.google -tls-host-verify dns.google
EXPECTED_VARIANT
    elif [[ "$network_stack" == ipv6 ]]; then
      cat >>"$expected_config" <<'EXPECTED_VARIANT'
server-https https://cloudflare-dns.com/dns-query -host-ip 2606:4700:4700::1111
server-https https://dns.google/dns-query -host-ip 2001:4860:4860::8888
EXPECTED_VARIANT
    else
      cat >>"$expected_config" <<'EXPECTED_VARIANT'
server-https https://cloudflare-dns.com/dns-query -host-ip 1.1.1.1
server-https https://dns.google/dns-query -host-ip 8.8.8.8
EXPECTED_VARIANT
    fi
    cmp -s "$expected_config" "$installer_config" ||
      fail "$variant/$network_stack 配置与要求的精确模板不一致。"
    ! grep -Eq '\\[[:space:]]*$' "$installer_config" ||
      fail "$variant 配置不应使用续行。"
    [[ $(grep -c '^server-https ' "$installer_config") -eq 2 ]] ||
      fail "$variant/$network_stack 配置必须严格包含两条 DoH 上游。"
    assert_file_contains_line "$installer_config" 'bind 127.0.0.1:53'
    assert_file_contains_line "$installer_config" 'bind-tcp 127.0.0.1:53'
    ! grep -Eqi 'quad9|9\.9\.9\.9|149\.112\.' "$installer_config" ||
      fail "$variant/$network_stack 配置仍包含 Quad9。"
    done
  done
  ((TESTS_RUN += 1))
  log 'v40/v46 × 三种 NETWORK_STACK 精确配置、DoH 参数、过滤规则和无 Quad9 测试通过。'
}

run_network_switch_case() {
  local target_stack=$1
  local case_dir="$TMP_DIR/network-switch-$target_stack"
  local driver="$case_dir/driver.sh"
  local output

  mkdir -p "$case_dir"
  {
    cat <<'DRIVER'
#!/usr/bin/env bash
set -Eeuo pipefail
IPV6_DISABLE_CONFIG="$CASE_DIR/etc/99-disable-ipv6.conf"
NETWORK_STACK_UNIT="$CASE_DIR/etc/404-network-stack.service"
NETWORK_STACK_UNIT_NAME='404-network-stack.service'
NETWORK_STACK_HELPER="$CASE_DIR/404-network-stack"
TMP_DIR="$CASE_DIR"
NETWORK_STACK='ipv4'
KERNEL_IPV6_DISABLED='UNAVAILABLE'
KERNEL_ENFORCEMENT='unavailable'
APPLICATION_IPV4_ONLY='NO'
WARNING_COUNT=0
printf '0\n' >"$CASE_DIR/all"
printf '0\n' >"$CASE_DIR/default"
printf '0\n' >"$CASE_DIR/lo"
log() { :; }
warn() { :; }
degrade() { KERNEL_ENFORCEMENT='unavailable'; ((WARNING_COUNT += 1)); }
shorten_line() { printf '%s' "$1"; }
fail_with_recovery() { printf '%s\n' "$1" >&2; exit 1; }
install() {
  local source=${*: -2:1}
  local target=${*: -1}
  mkdir -p "$(dirname "$target")"
  cp "$source" "$target"
}
sysctl() {
  local key=''
  local value=''
  if [[ "$1" == '--load' ]]; then
    printf '1\n' >"$CASE_DIR/all"
    printf '1\n' >"$CASE_DIR/default"
    printf '1\n' >"$CASE_DIR/lo"
    return 0
  fi
  if [[ "$1" == '-n' ]]; then
    key=${2##*.}
    [[ "$key" == disable_ipv6 ]] && key=${2#net.ipv6.conf.}
    key=${key%.disable_ipv6}
    cat "$CASE_DIR/$key"
    return 0
  fi
  [[ "$1" == '-q' && "$2" == '-w' ]] || return 2
  key=${3%%=*}
  value=${3#*=}
  key=${key#net.ipv6.conf.}
  key=${key%.disable_ipv6}
  printf '%s\n' "$value" >"$CASE_DIR/$key"
}
restore_ipv6_network_configuration() { :; }
install_ipv4_network_stack_unit() {
  rm -f -- "$IPV6_DISABLE_CONFIG"
  mkdir -p -- "$(dirname "$NETWORK_STACK_UNIT")"
  printf 'managed\n' >"$NETWORK_STACK_UNIT"
  printf '1\n' >"$CASE_DIR/all"
  printf '1\n' >"$CASE_DIR/default"
  printf '1\n' >"$CASE_DIR/lo"
}
remove_ipv4_network_stack_unit() {
  rm -f -- "$NETWORK_STACK_UNIT" "$IPV6_DISABLE_CONFIG"
}
DRIVER
    extract_function "$UPDATER" sysctl_restriction_error
    extract_function "$UPDATER" read_ipv6_kernel_state
    extract_function "$UPDATER" apply_ipv6_sysctl_capability_aware
    extract_function "$UPDATER" configure_network_stack
    cat <<'DRIVER'
configure_network_stack
NETWORK_STACK="$TARGET_STACK"
configure_network_stack
printf '%s|%s|%s|%s\n' \
  "$(<"$CASE_DIR/all")" "$(<"$CASE_DIR/default")" \
  "$(<"$CASE_DIR/lo")" "$([[ -e "$IPV6_DISABLE_CONFIG" ]] && printf present || printf absent)"
DRIVER
  } >"$driver"
  output=$(CASE_DIR="$case_dir" TARGET_STACK="$target_stack" bash "$driver")
  assert_eq '0|0|0|absent' "$output" \
    "IPv4-only -> $target_stack 必须恢复 IPv6 并删除禁用配置"
}

test_ipv6_network_recovery() {
  local case_dir="$TMP_DIR/ipv6-network-recovery"
  local driver="$case_dir/driver.sh"
  local output

  mkdir -p "$case_dir/bin"
  cat >"$case_dir/bin/ip" <<'MOCK_IP'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ -e "$CASE_DIR/ipv6-ready" ]]; then
  if [[ "$*" == '-6 -o addr show scope global' ]]; then
    printf '2: eth0    inet6 2001:db8::10/64 scope global\n'
  elif [[ "$*" == '-6 route show default' ]]; then
    printf 'default via 2001:db8::1 dev eth0\n'
  fi
fi
MOCK_IP
  cat >"$case_dir/bin/ifup" <<'MOCK_IFUP'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >"$CASE_DIR/ifup-args"
touch "$CASE_DIR/ipv6-ready"
MOCK_IFUP
  cat >"$case_dir/bin/sleep" <<'MOCK_SLEEP'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$CASE_DIR/sleeps"
MOCK_SLEEP
  chmod +x "$case_dir/bin/ip" "$case_dir/bin/ifup" "$case_dir/bin/sleep"

  {
    cat <<'DRIVER'
#!/usr/bin/env bash
set -Eeuo pipefail
NETWORK_STACK='dual'
log() { :; }
warn() { :; }
DRIVER
    extract_function "$UPDATER" ipv6_network_ready
    extract_function "$UPDATER" restore_ipv6_network_configuration
    cat <<'DRIVER'
restore_ipv6_network_configuration
ipv6_network_ready
printf '%s\n' "$(<"$CASE_DIR/ifup-args")"
DRIVER
  } >"$driver"

  output=$(CASE_DIR="$case_dir" PATH="$case_dir/bin:$PATH" bash "$driver")
  assert_eq '--force --ignore-errors -a' "$output" \
    'IPv6 地址/路由缺失时必须在不 ifdown 的情况下重新应用 ifupdown 配置'
}

test_delayed_ipv6_disable_unit() {
  local case_dir="$TMP_DIR/delayed-ipv6-disable"
  local driver="$case_dir/driver.sh"
  local output

  mkdir -p "$case_dir"
  {
    cat <<'DRIVER'
#!/usr/bin/env bash
set -Eeuo pipefail
NETWORK_STACK_UNIT="$CASE_DIR/etc/systemd/system/404-network-stack.service"
NETWORK_STACK_UNIT_NAME='404-network-stack.service'
NETWORK_STACK_HELPER="$CASE_DIR/usr/local/libexec/404-network-stack"
IPV6_DISABLE_CONFIG="$CASE_DIR/99-disable-ipv6.conf"
TMP_DIR="$CASE_DIR"
NETWORK_STACK='ipv4'
KERNEL_IPV6_DISABLED='UNAVAILABLE'
KERNEL_ENFORCEMENT='unavailable'
APPLICATION_IPV4_ONLY='NO'
WARNING_COUNT=0
printf '0\n' >"$CASE_DIR/all"
printf '0\n' >"$CASE_DIR/default"
printf '0\n' >"$CASE_DIR/lo"
printf 'disabled\n' >"$CASE_DIR/unit-enabled"
printf 'inactive\n' >"$CASE_DIR/unit-active"
printf 'legacy\n' >"$IPV6_DISABLE_CONFIG"
log() { :; }
warn() { :; }
degrade() { KERNEL_ENFORCEMENT='unavailable'; ((WARNING_COUNT += 1)); }
shorten_line() { printf '%s' "$1"; }
fail_with_recovery() { printf '%s\n' "$1" >&2; exit 1; }
install() {
  local source=${*: -2:1}
  local target=${*: -1}
  mkdir -p "$(dirname "$target")"
  cp "$source" "$target"
}
sysctl() {
  local key
  local value
  if [[ "$1" == '-n' ]]; then
    key=${2#net.ipv6.conf.}
    key=${key%.disable_ipv6}
    cat "$CASE_DIR/$key"
    return 0
  fi
  [[ "$1" == '-q' && "$2" == '-w' ]] || return 2
  key=${3%%=*}
  value=${3#*=}
  key=${key#net.ipv6.conf.}
  key=${key%.disable_ipv6}
  printf '%s\n' "$value" >"$CASE_DIR/$key"
}
systemctl() {
  case "$1" in
    cat) [[ -e "$NETWORK_STACK_UNIT" ]] ;;
    daemon-reload) ;;
    enable) printf 'enabled\n' >"$CASE_DIR/unit-enabled" ;;
    disable)
      printf 'disabled\n' >"$CASE_DIR/unit-enabled"
      [[ " $* " != *' --now '* ]] || printf 'inactive\n' >"$CASE_DIR/unit-active"
      ;;
    restart)
      printf 'active\n' >"$CASE_DIR/unit-active"
      printf '1\n' >"$CASE_DIR/all"
      printf '1\n' >"$CASE_DIR/default"
      printf '1\n' >"$CASE_DIR/lo"
      ;;
    stop) printf 'inactive\n' >"$CASE_DIR/unit-active" ;;
    is-enabled) [[ "$(<"$CASE_DIR/unit-enabled")" == enabled ]] ;;
    is-active) [[ "$(<"$CASE_DIR/unit-active")" == active ]] ;;
    *) return 2 ;;
  esac
}
restore_ipv6_network_configuration() { :; }
write_network_stack_helper() { printf 'helper\n' >"$1"; }
DRIVER
    extract_function "$UPDATER" sysctl_restriction_error
    extract_function "$UPDATER" read_ipv6_kernel_state
    extract_function "$UPDATER" apply_ipv6_sysctl_capability_aware
    extract_function "$UPDATER" install_ipv4_network_stack_unit
    extract_function "$UPDATER" remove_ipv4_network_stack_unit
    extract_function "$UPDATER" configure_network_stack
    cat <<'DRIVER'
configure_network_stack
first_hash=$(sha256sum "$NETWORK_STACK_UNIT" | awk '{ print $1 }')
grep -Fxq 'After=networking.service' "$NETWORK_STACK_UNIT"
grep -Fxq 'Before=smartdns.service sing-box.service' "$NETWORK_STACK_UNIT"
test ! -e "$IPV6_DISABLE_CONFIG"
configure_network_stack
second_hash=$(sha256sum "$NETWORK_STACK_UNIT" | awk '{ print $1 }')
printf '0\n' >"$CASE_DIR/all"
printf '0\n' >"$CASE_DIR/default"
printf '0\n' >"$CASE_DIR/lo"
printf 'inactive\n' >"$CASE_DIR/unit-active"
if [[ "$(<"$CASE_DIR/unit-enabled")" == enabled ]]; then
  systemctl restart "$NETWORK_STACK_UNIT_NAME"
fi
ipv4_boot="$(<"$CASE_DIR/all")/$(<"$CASE_DIR/default")/$(<"$CASE_DIR/lo")"
NETWORK_STACK='dual'
configure_network_stack
dual_state="$(<"$CASE_DIR/all")/$(<"$CASE_DIR/default")/$(<"$CASE_DIR/lo")"
printf '0\n' >"$CASE_DIR/all"
printf '0\n' >"$CASE_DIR/default"
printf '0\n' >"$CASE_DIR/lo"
if [[ "$(<"$CASE_DIR/unit-enabled")" == enabled ]]; then
  systemctl restart "$NETWORK_STACK_UNIT_NAME"
fi
dual_boot="$(<"$CASE_DIR/all")/$(<"$CASE_DIR/default")/$(<"$CASE_DIR/lo")"
printf '%s|%s|%s|%s|%s|%s\n' \
  "$([[ "$first_hash" == "$second_hash" ]] && printf stable || printf drift)" \
  "$ipv4_boot" "$([[ -e "$NETWORK_STACK_UNIT" ]] && printf present || printf absent)" \
  "$(<"$CASE_DIR/unit-enabled")" "$dual_state" "$dual_boot"
DRIVER
  } >"$driver"

  output=$(CASE_DIR="$case_dir" bash "$driver")
  assert_eq 'stable|1/1/1|absent|disabled|0/0/0|0/0/0' "$output" \
    '延后禁用 unit 必须幂等、IPv4 reboot 重放 1/1/1，并在 dual/reboot 保持清理和 0/0/0'
}

test_network_stack_rollback_cleanup() {
  local case_dir="$TMP_DIR/network-stack-rollback"
  local driver="$case_dir/driver.sh"
  local output

  mkdir -p "$case_dir/backup"
  {
    cat <<'DRIVER'
#!/usr/bin/env bash
set -Eeuo pipefail
BACKUP_READY=true
BACKUP_DIR="$CASE_DIR/backup"
CONFIG_TARGET="$CASE_DIR/smartdns.conf"
IPV6_DISABLE_CONFIG="$CASE_DIR/99-disable-ipv6.conf"
NETWORK_STACK_UNIT="$CASE_DIR/404-network-stack.service"
NETWORK_STACK_UNIT_NAME='404-network-stack.service'
NETWORK_STACK_HELPER="$CASE_DIR/404-network-stack"
RESOLV_CONF="$CASE_DIR/resolv.conf"
CONFIG_PREEXISTED=false
IPV6_CONFIG_PREEXISTED=false
NETWORK_STACK_UNIT_PREEXISTED=false
NETWORK_STACK_UNIT_WAS_ENABLED=false
NETWORK_STACK_UNIT_WAS_ACTIVE=false
NETWORK_STACK_HELPER_PREEXISTED=false
RESOLV_CONF_PREEXISTED=false
SMARTDNS_WAS_ENABLED=false
SMARTDNS_WAS_ACTIVE=false
SMARTDNS_WAS_HELD=false
SYSTEMD_RESOLVED_UNIT_PRESENT=false
SYSTEMD_RESOLVED_WAS_ENABLED=false
SYSTEMD_RESOLVED_WAS_ACTIVE=false
IPV6_ALL_WAS_DISABLED='0'
IPV6_DEFAULT_WAS_DISABLED='0'
IPV6_LOOPBACK_WAS_DISABLED='0'
printf 'unit\n' >"$NETWORK_STACK_UNIT"
printf 'legacy\n' >"$IPV6_DISABLE_CONFIG"
printf '1\n' >"$CASE_DIR/all"
printf '1\n' >"$CASE_DIR/default"
printf '1\n' >"$CASE_DIR/lo"
: >"$CASE_DIR/systemctl-trace"
warn() { :; }
sysctl_restriction_error() { return 1; }
mountpoint() { return 1; }
apt-mark() { :; }
sysctl() {
  local key=${3%%=*}
  local value=${3#*=}
  key=${key#net.ipv6.conf.}
  key=${key%.disable_ipv6}
  printf '%s\n' "$value" >"$CASE_DIR/$key"
}
systemctl() {
  printf '%s\n' "$*" >>"$CASE_DIR/systemctl-trace"
  if [[ "$1" == cat ]]; then
    [[ -e "$NETWORK_STACK_UNIT" ]]
  fi
  return 0
}
DRIVER
    extract_function "$UPDATER" restore_previous_state
    cat <<'DRIVER'
restore_previous_state
printf '%s|%s|%s|%s|%s\n' \
  "$([[ -e "$NETWORK_STACK_UNIT" ]] && printf present || printf absent)" \
  "$([[ -e "$IPV6_DISABLE_CONFIG" ]] && printf present || printf absent)" \
  "$(<"$CASE_DIR/all")/$(<"$CASE_DIR/default")/$(<"$CASE_DIR/lo")" \
  "$(grep -Fxc 'disable --now 404-network-stack.service' "$CASE_DIR/systemctl-trace")" \
  "$(grep -Fxc 'daemon-reload' "$CASE_DIR/systemctl-trace")"
DRIVER
  } >"$driver"

  output=$(CASE_DIR="$case_dir" bash "$driver")
  assert_eq 'absent|absent|0/0/0|1|1' "$output" \
    'rollback 必须停用并删除新建 network-stack unit、早期 sysctl 文件并恢复原 sysctl'
}

test_network_stack_switches() {
  run_network_switch_case dual
  run_network_switch_case ipv6
  test_ipv6_network_recovery
  test_delayed_ipv6_disable_unit
  test_network_stack_rollback_cleanup
  ((TESTS_RUN += 1))
  log '延后 IPv6 禁用、IPv4/dual reboot、幂等、ifupdown 恢复和 rollback 清理测试通过。'
}

write_mock_commands() {
  local mock_bin=$1

  mkdir -p "$mock_bin"
  cat >"$mock_bin/dig" <<'MOCK_DIG'
#!/usr/bin/env bash
set -Eeuo pipefail
count=0
[[ ! -f "$MOCK_COUNT_FILE" ]] || count=$(<"$MOCK_COUNT_FILE")
((count += 1))
printf '%s\n' "$count" >"$MOCK_COUNT_FILE"
case "$MOCK_SCENARIO" in
  third_success)
    case "$count" in
      1) printf ';; temporary failure\n' >&2; exit 9 ;;
      2) printf 'not-an-address\n'; exit 0 ;;
      *) printf 'noise\n999.1.1.1\n104.16.132.229\n104.16.133.229\n'; exit 0 ;;
    esac
    ;;
  first_success)
    printf '104.16.132.229\n'
    ;;
  tenth_success)
    if ((count < 10)); then
      printf ';; temporary failure\n' >&2
      exit 9
    fi
    printf '104.16.132.229\n'
    ;;
  immediate_multiline)
    printf 'garbage\n1.2.3.4\n5.6.7.8\n'
    ;;
  always_failure)
    printf ';; no servers could be reached\n' >&2
    exit 9
    ;;
  empty_output)
    exit 0
    ;;
  timeout)
    printf ';; communications error: timed out\n' >&2
    exit 9
    ;;
  servfail)
    printf ';; ->>HEADER<<- opcode: QUERY, status: SERVFAIL\n' >&2
    exit 9
    ;;
  illegal_ipv4)
    printf '999.1.1.1\n1.2.3.999\n-1.2.3.4\n'
    ;;
  *)
    exit 2
    ;;
esac
MOCK_DIG
  cat >"$mock_bin/sleep" <<'MOCK_SLEEP'
#!/usr/bin/env bash
set -Eeuo pipefail
count=0
[[ ! -f "$MOCK_SLEEP_FILE" ]] || count=$(<"$MOCK_SLEEP_FILE")
((count += 1))
printf '%s\n' "$count" >"$MOCK_SLEEP_FILE"
MOCK_SLEEP
  chmod +x "$mock_bin/dig" "$mock_bin/sleep"
}

run_retry_case() {
  local script=$1
  local scenario=$2
  local expected_status=$3
  local expected_attempts=$4
  local expected_sleeps=$5
  local expected_answer=$6
  local case_dir
  local driver
  local output
  local actual_sleeps=0
  local status

  case_dir="$TMP_DIR/retry-$(basename "$script")-$scenario"
  driver="$case_dir/driver.sh"

  mkdir -p "$case_dir"
  write_mock_commands "$case_dir/bin"
  {
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' "SMARTDNS_IPV4_ANSWER=''; SMARTDNS_IPV4_ATTEMPTS=0; SMARTDNS_LAST_DIG_OUTPUT=''"
    printf '%s\n' "IPV4_ANSWER=''; IPV4_ATTEMPTS=0; LAST_DIG_OUTPUT=''"
    extract_function "$script" first_valid_ipv4
    extract_function "$script" query_smartdns_ipv4
    printf '%s\n' 'set +e'
    printf '%s\n' 'query_smartdns_ipv4'
    printf '%s\n' 'status=$?'
    printf '%s\n' 'set -e'
    if [[ "$script" == "$INSTALLER" ]]; then
      # shellcheck disable=SC2016
      printf '%s\n' 'printf "%s|%s|%s|%s\n" "$status" "$SMARTDNS_IPV4_ATTEMPTS" "$SMARTDNS_IPV4_ANSWER" "$SMARTDNS_LAST_DIG_OUTPUT"'
    else
      # shellcheck disable=SC2016
      printf '%s\n' 'printf "%s|%s|%s|%s\n" "$status" "$IPV4_ATTEMPTS" "$IPV4_ANSWER" "$LAST_DIG_OUTPUT"'
    fi
  } >"$driver"

  : >"$case_dir/count"
  : >"$case_dir/sleeps"
  output=$(
    PATH="$case_dir/bin:$PATH" \
      MOCK_SCENARIO="$scenario" \
      MOCK_COUNT_FILE="$case_dir/count" \
      MOCK_SLEEP_FILE="$case_dir/sleeps" \
      bash "$driver"
  )
  IFS='|' read -r status actual_attempts actual_answer _ <<<"$output"
  assert_eq "$expected_status" "$status" "$script $scenario 返回状态错误"
  assert_eq "$expected_attempts" "$actual_attempts" "$script $scenario 尝试次数错误"
  assert_eq "$expected_answer" "$actual_answer" "$script $scenario IPv4 结果错误"
  [[ ! -s "$case_dir/sleeps" ]] || actual_sleeps=$(<"$case_dir/sleeps")
  assert_eq "$expected_sleeps" "$actual_sleeps" "$script $scenario sleep 次数错误"
}

test_retry_logic() {
  local script

  for script in "$INSTALLER" "$UPDATER"; do
    run_retry_case "$script" first_success 0 1 0 '104.16.132.229'
    run_retry_case "$script" third_success 0 3 2 '104.16.132.229'
    run_retry_case "$script" tenth_success 0 10 9 '104.16.132.229'
    run_retry_case "$script" immediate_multiline 0 1 0 '1.2.3.4'
    run_retry_case "$script" always_failure 1 10 9 ''
    run_retry_case "$script" empty_output 1 10 9 ''
    run_retry_case "$script" timeout 1 10 9 ''
    run_retry_case "$script" servfail 1 10 9 ''
    run_retry_case "$script" illegal_ipv4 1 10 9 ''
  done
  ((TESTS_RUN += 1))
  log '主脚本与更新脚本的首次/第 3/第 10 次成功、空输出、timeout、SERVFAIL、非法/多行 IPv4 和 sleep 边界测试通过。'
}

write_updater_flow_mocks() {
  local mock_bin=$1

  mkdir -p "$mock_bin"
  cat >"$mock_bin/apt-get" <<'MOCK_APT_GET'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'apt-get %s\n' "$*" >>"$MOCK_TRACE"
MOCK_APT_GET
  cat >"$mock_bin/apt-mark" <<'MOCK_APT_MARK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'apt-mark %s\n' "$*" >>"$MOCK_TRACE"
case "$1" in
  showhold)
    [[ ! -s "$MOCK_HOLD_STATE" ]] || cat "$MOCK_HOLD_STATE"
    ;;
  hold)
    printf 'smartdns\n' >"$MOCK_HOLD_STATE"
    ;;
  unhold)
    : >"$MOCK_HOLD_STATE"
    ;;
  *)
    exit 2
    ;;
esac
MOCK_APT_MARK
  cat >"$mock_bin/dpkg-query" <<'MOCK_DPKG_QUERY'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'dpkg-query %s\n' "$*" >>"$MOCK_TRACE"
case "$*" in
  *'${Status}'*)
    printf 'hold ok installed'
    ;;
  *'${Version}'*)
    printf '40+dfsg-1'
    ;;
  *'${Architecture}'*)
    printf 'amd64'
    ;;
  *'${Package}'*)
    printf 'smartdns'
    ;;
  *)
    exit 2
    ;;
esac
MOCK_DPKG_QUERY
  cat >"$mock_bin/systemctl" <<'MOCK_SYSTEMCTL'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'systemctl %s\n' "$*" >>"$MOCK_TRACE"
case "$1" in
  stop)
    [[ " $* " == *' systemd-resolved.service '* ]] && exit 0
    printf 'inactive\n' >"$MOCK_SERVICE_STATE"
    ;;
  start)
    [[ " $* " == *' systemd-resolved.service '* ]] && exit 0
    printf 'active\n' >"$MOCK_SERVICE_STATE"
    ;;
  restart)
    printf 'active\n' >"$MOCK_SERVICE_STATE"
    ;;
  enable)
    [[ " $* " == *' systemd-resolved.service '* ]] && exit 0
    printf 'enabled\n' >"$MOCK_ENABLED_STATE"
    ;;
  disable)
    [[ " $* " == *' systemd-resolved.service '* ]] && exit 0
    printf 'disabled\n' >"$MOCK_ENABLED_STATE"
    ;;
  daemon-reload)
    ;;
  reset-failed)
    exit "${MOCK_RESET_FAILED_RC:-0}"
    ;;
  is-enabled)
    if [[ " $* " == *' systemd-resolved.service '* ]]; then exit 1; fi
    if [[ " $* " == *' 404-network-stack.service '* ]]; then exit 1; fi
    [[ "$(<"$MOCK_ENABLED_STATE")" == enabled ]] || exit 1
    [[ " $* " == *' --quiet '* ]] || printf 'enabled\n'
    ;;
  is-active)
    if [[ " $* " == *' systemd-resolved.service '* ]]; then exit 1; fi
    if [[ " $* " == *' 404-network-stack.service '* ]]; then exit 1; fi
    [[ "$(<"$MOCK_SERVICE_STATE")" == active ]] || exit 1
    [[ " $* " == *' --quiet '* ]] || printf 'active\n'
    ;;
  *)
    exit 2
    ;;
esac
MOCK_SYSTEMCTL
  cat >"$mock_bin/pgrep" <<'MOCK_PGREP'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'pgrep %s\n' "$*" >>"$MOCK_TRACE"
if [[ "${MOCK_RESIDUAL:-false}" == true ]]; then
  exit 0
fi
[[ "$(<"$MOCK_SERVICE_STATE")" == active ]]
MOCK_PGREP
  cat >"$mock_bin/pkill" <<'MOCK_PKILL'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'pkill %s\n' "$*" >>"$MOCK_TRACE"
MOCK_PKILL
  cat >"$mock_bin/journalctl" <<'MOCK_JOURNALCTL'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'journalctl %s\n' "$*" >>"$MOCK_TRACE"
printf 'smartdns started normally\n'
MOCK_JOURNALCTL
  cat >"$mock_bin/ss" <<'MOCK_SS'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'ss %s\n' "$*" >>"$MOCK_TRACE"
printf '%s\n' \
  'udp UNCONN 0 0 127.0.0.1:53 0.0.0.0:* users:(("smartdns",pid=123,fd=3))' \
  'tcp LISTEN 0 128 127.0.0.1:53 0.0.0.0:* users:(("smartdns",pid=123,fd=4))'
MOCK_SS
  cat >"$mock_bin/dig" <<'MOCK_FLOW_DIG'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'dig %s\n' "$*" >>"$MOCK_TRACE"
if [[ " $* " == *' AAAA '* ]]; then
  printf ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\n'
else
  printf '104.16.132.229\n'
fi
MOCK_FLOW_DIG
  cat >"$mock_bin/getent" <<'MOCK_GETENT'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'getent %s\n' "$*" >>"$MOCK_TRACE"
printf '104.16.132.229 STREAM cloudflare.com\n'
MOCK_GETENT
  cat >"$mock_bin/smartdns" <<'MOCK_SMARTDNS'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'smartdns 40+dfsg-1\n'
MOCK_SMARTDNS
  cat >"$mock_bin/sleep" <<'MOCK_FLOW_SLEEP'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'sleep %s\n' "$*" >>"$MOCK_TRACE"
MOCK_FLOW_SLEEP
  chmod +x "$mock_bin"/*
}

write_updater_flow_driver() {
  local driver=$1

  {
    cat <<'DRIVER_PREAMBLE'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly CONFIG_TARGET="$MOCK_CASE_DIR/etc/smartdns/smartdns.conf"
readonly IPV6_DISABLE_CONFIG="$MOCK_CASE_DIR/etc/sysctl.d/99-disable-ipv6.conf"
readonly NETWORK_STACK_UNIT="$MOCK_CASE_DIR/etc/systemd/system/404-network-stack.service"
readonly NETWORK_STACK_UNIT_NAME='404-network-stack.service'
readonly NETWORK_STACK_HELPER="$MOCK_CASE_DIR/usr/local/libexec/404-network-stack"
readonly RESOLV_CONF="$MOCK_RESOLV_CONF"
readonly SMARTDNS_RELEASE_TAG='smartdns-debian-pinned-2026-07'
TMP_DIR="$MOCK_CASE_DIR/work"
STAGED_CONFIG="$TMP_DIR/smartdns.conf"
VALIDATION_CONFIG="$TMP_DIR/validation.conf"
VALIDATION_LOG="$TMP_DIR/validation.log"
BACKUP_DIR="$MOCK_CASE_DIR/backup"
START_TIME=''
JOURNAL_FILE="$TMP_DIR/journal.log"
OS_VERSION='12'
OS_ID='debian'
ARCH='amd64'
CONFIG_VARIANT='v40'
ASSET_NAME='smartdns_40+dfsg-1_bookworm_amd64.deb'
EXPECTED_VERSION='40+dfsg-1'
EXPECTED_SHA256='unused-in-offline-flow'
DOWNLOAD_URL='unused-in-offline-flow'
DEB_PATH="$TMP_DIR/smartdns.deb"
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
NETWORK_STACK='ipv4'
IPV6_CONFIG_PREEXISTED=false
NETWORK_STACK_UNIT_PREEXISTED=false
NETWORK_STACK_UNIT_WAS_ENABLED=false
NETWORK_STACK_UNIT_WAS_ACTIVE=false
NETWORK_STACK_HELPER_PREEXISTED=false
RESOLV_CONF_PREEXISTED=false
IPV6_ALL_WAS_DISABLED='0'
IPV6_DEFAULT_WAS_DISABLED='0'
IPV6_LOOPBACK_WAS_DISABLED='0'
SYSTEMD_RESOLVED_WAS_ENABLED=false
SYSTEMD_RESOLVED_WAS_ACTIVE=false
SYSTEMD_RESOLVED_UNIT_PRESENT=false
VIRTUALIZATION='none'
CONTAINER_VIRTUALIZATION='none'
ENVIRONMENT_LABEL='Bare metal'
KERNEL_IPV6_DISABLED='YES'
KERNEL_ENFORCEMENT='enabled'
APPLICATION_IPV4_ONLY='YES'
RESOLV_CONF_STATUS='MANAGED'
SYSTEM_RESOLUTION_STATUS='PASS'
RESULT_STATUS='SUCCESS'
WARNING_COUNT=0

mock_step() {
  printf 'step %s\n' "$1" >>"$MOCK_TRACE"
}

parse_args() {
  mock_step parse-args
}

sysctl() {
  [[ "${1:-}" == '-n' ]] && printf '0\n'
  return 0
}

require_root_and_debian() {
  mock_step require-root-and-debian
}

install_dependencies() {
  mock_step install-dependencies
}

verify_required_commands() {
  mock_step verify-required-commands
}

detect_runtime_environment() {
  mock_step detect-runtime-environment
}

select_platform() {
  mock_step select-platform
}

create_temporary_directory() {
  mkdir -p "$TMP_DIR" "$(dirname -- "$CONFIG_TARGET")"
  mock_step create-temporary-directory
}

write_smartdns_configuration() {
  printf 'bind 127.0.0.1:53\n' >"$1"
  mock_step write-configuration
}

download_and_verify_package() {
  mock_step download-and-verify-package
}

create_backup() {
  mkdir -p "$BACKUP_DIR"
  BACKUP_READY=true
  CONFIG_PREEXISTED=false
  mock_step create-backup
}

validate_configuration_independently() {
  mock_step validate-configuration-independently
  if [[ "${MOCK_CONFIG_FAILURE:-false}" == true ]]; then
    fail_with_recovery 'SmartDNS 配置验证失败。'
  fi
}

check_port_53_conflicts() {
  mock_step check-port-53-conflicts
}

deploy_configuration() {
  mock_step deploy-configuration
}

configure_network_stack() {
  mock_step configure-network-stack
}

validate_network_stack_health() {
  mock_step validate-network-stack-health
}

configure_system_resolver() {
  printf 'nameserver 127.0.0.1\noptions timeout:2 attempts:2\n' >"$TMP_DIR/resolv.conf"
  cp "$TMP_DIR/resolv.conf" "$MOCK_RESOLV_CONF"
  RESOLV_CONF_STATUS='MANAGED'
  mock_step configure-system-resolver
}
DRIVER_PREAMBLE
    extract_function "$UPDATER" log
    extract_function "$UPDATER" warn
    extract_function "$UPDATER" die
    extract_function "$UPDATER" shorten_line
    extract_function "$UPDATER" capture_existing_state
    extract_function "$UPDATER" restore_previous_state
    extract_function "$UPDATER" capture_start_journal
    extract_function "$UPDATER" fail_with_recovery
    extract_function "$UPDATER" package_is_already_installed
    extract_function "$UPDATER" install_pinned_package
    extract_function "$UPDATER" verify_installed_package
    extract_function "$UPDATER" stop_and_clean_smartdns
    extract_function "$UPDATER" listener_present
    extract_function "$UPDATER" first_valid_ipv4
    extract_function "$UPDATER" query_smartdns_ipv4
    extract_function "$UPDATER" start_and_validate_service
    extract_function "$UPDATER" check_debian_system_dns
    extract_function "$UPDATER" print_summary
    extract_function "$UPDATER" main
    printf '%s\n' 'main "$@"'
  } >"$driver"
  chmod +x "$driver"
}

prepare_updater_flow_case() {
  local case_dir=$1
  local nameserver=$2

  mkdir -p "$case_dir"
  : >"$case_dir/trace"
  printf 'active\n' >"$case_dir/service-state"
  printf 'enabled\n' >"$case_dir/enabled-state"
  printf 'smartdns\n' >"$case_dir/hold-state"
  printf 'nameserver %s\noptions timeout:2 attempts:2\n' "$nameserver" >"$case_dir/resolv.conf"
  write_updater_flow_mocks "$case_dir/bin"
  write_updater_flow_driver "$case_dir/driver.sh"
}

run_updater_flow_case() {
  local case_dir=$1
  local residual=$2
  local output=$3
  local config_failure=${4:-false}
  local reset_failed_rc=${5:-0}

  PATH="$case_dir/bin:$PATH" \
    MOCK_CASE_DIR="$case_dir" \
    MOCK_TRACE="$case_dir/trace" \
    MOCK_SERVICE_STATE="$case_dir/service-state" \
    MOCK_ENABLED_STATE="$case_dir/enabled-state" \
    MOCK_HOLD_STATE="$case_dir/hold-state" \
    MOCK_RESOLV_CONF="$case_dir/resolv.conf" \
    MOCK_RESIDUAL="$residual" \
    MOCK_CONFIG_FAILURE="$config_failure" \
    MOCK_RESET_FAILED_RC="$reset_failed_rc" \
    bash "$case_dir/driver.sh" >"$output" 2>&1
}

assert_trace_order() {
  local trace=$1
  shift
  local entry
  local line
  local previous=0

  for entry in "$@"; do
    line=$(awk -v expected="$entry" '$0 == expected { print NR; exit }' "$trace")
    [[ -n "$line" ]] || fail "执行轨迹缺少：$entry"
    ((line > previous)) ||
      fail "执行轨迹顺序错误：$entry"
    previous=$line
  done
}

test_capture_state_false_returns_success() {
  local driver="$TMP_DIR/capture-state-false.sh"
  local output

  {
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' 'SMARTDNS_WAS_HELD=true; SMARTDNS_WAS_ENABLED=true; SMARTDNS_WAS_ACTIVE=true'
    printf '%s\n' "NETWORK_STACK_UNIT_NAME='404-network-stack.service'"
    printf '%s\n' 'NETWORK_STACK_UNIT_WAS_ENABLED=true; NETWORK_STACK_UNIT_WAS_ACTIVE=true'
    printf '%s\n' 'apt-mark() { return 1; }'
    printf '%s\n' 'systemctl() { return 1; }'
    printf '%s\n' 'sysctl() { printf "0\n"; }'
    extract_function "$UPDATER" capture_existing_state
    printf '%s\n' 'capture_existing_state'
    # shellcheck disable=SC2016
    printf '%s\n' 'printf "%s|%s|%s\n" "$SMARTDNS_WAS_HELD" "$SMARTDNS_WAS_ENABLED" "$SMARTDNS_WAS_ACTIVE"'
  } >"$driver"
  output=$(bash "$driver")
  assert_eq 'false|false|false' "$output" \
    '正常 false 状态不应成为 capture_existing_state 的失败返回值'
}

test_updater_full_regression_flow() {
  local bad_config_case="$TMP_DIR/updater-flow-bad-config"
  local bad_config_output="$bad_config_case/output"
  local residual_case="$TMP_DIR/updater-flow-residual"
  local residual_output="$residual_case/output"
  local reset_failed_case="$TMP_DIR/updater-flow-reset-failed"
  local reset_failed_output="$reset_failed_case/output"
  local status
  local success_case="$TMP_DIR/updater-flow-success"
  local success_output="$success_case/output"

  test_capture_state_false_returns_success

  prepare_updater_flow_case "$success_case" '127.0.0.1'
  if ! run_updater_flow_case "$success_case" false "$success_output"; then
    cat "$success_output" >&2
    fail '已安装且 hold 的 SmartDNS 更新主流程应成功。'
  fi
  grep -Fq '已安装精确目标版本 40+dfsg-1；跳过重复安装。' "$success_output" ||
    fail '精确版本且 hold 时没有跳过重复安装。'
  ! grep -Fq 'apt-get ' "$success_case/trace" ||
    fail '精确版本且 hold 时不应调用 apt-get 安装 SmartDNS。'
  ! grep -Fq 'step download-and-verify-package' "$success_case/trace" ||
    fail '精确版本已安装时不应依赖外部下载后才能切换网络栈。'
  assert_trace_order "$success_case/trace" \
    'systemctl is-active --quiet smartdns.service' \
    'step create-backup' \
    'systemctl stop smartdns.service' \
    'step validate-configuration-independently' \
    'step check-port-53-conflicts' \
    'step deploy-configuration' \
    'step configure-network-stack' \
    'systemctl restart smartdns.service' \
    'ss -H -lntup sport = :53' \
    'step validate-network-stack-health' \
    'apt-mark hold smartdns' \
    'step configure-system-resolver' \
    'getent hosts cloudflare.com'
  grep -Fq '127.0.0.1:53 的 TCP 和 UDP 监听验证通过。' "$success_output" ||
    fail '成功路径缺少 TCP/UDP 53 验证。'
  grep -Fq '网络栈健康检查：ipv4。' "$success_output" ||
    fail '成功路径缺少网络栈验证。'
  grep -Fq 'Debian 系统 DNS 验证通过：仅 127.0.0.1，systemd-resolved inactive。' "$success_output" ||
    fail '成功路径缺少 Debian 系统 DNS 验证。'
  grep -Fq 'SmartDNS 更新成功' "$success_output" ||
    fail '成功路径没有执行 print_summary。'
  assert_eq 'active' "$(<"$success_case/service-state")" \
    '成功后 smartdns.service 应保持 active'
  assert_eq 'enabled' "$(<"$success_case/enabled-state")" \
    '成功后 smartdns.service 应保持 enabled'
  assert_eq 'smartdns' "$(<"$success_case/hold-state")" \
    '成功后 smartdns 应保持 hold'

  prepare_updater_flow_case "$reset_failed_case" '127.0.0.1'
  if ! run_updater_flow_case \
    "$reset_failed_case" false "$reset_failed_output" false 1; then
    cat "$reset_failed_output" >&2
    fail '普通 inactive unit 没有 failed 状态时，不应因 reset-failed 非零而中止更新。'
  fi
  grep -Fq 'systemctl restart smartdns.service' "$reset_failed_case/trace" ||
    fail 'reset-failed 非零后没有继续严格启动 SmartDNS。'
  assert_eq 'active' "$(<"$reset_failed_case/service-state")" \
    'reset-failed 非零后 smartdns.service 应通过 restart 进入 active'

  prepare_updater_flow_case "$residual_case" '127.0.0.1'
  set +e
  run_updater_flow_case "$residual_case" true "$residual_output"
  status=$?
  set -e
  [[ "$status" -ne 0 ]] ||
    fail '存在残留 SmartDNS 进程时更新流程必须失败。'
  grep -Fq '清理后仍检测到 SmartDNS 残留进程。' "$residual_output" ||
    fail '残留进程失败没有明确报错。'
  grep -Fq '状态恢复：成功' "$residual_output" ||
    fail '残留进程失败没有执行成功恢复。'
  ! grep -Fq 'step validate-configuration-independently' "$residual_case/trace" ||
    fail '残留进程失败后不应继续配置验证。'
  ! grep -Fq 'SmartDNS 更新成功' "$residual_output" ||
    fail '残留进程失败后不应输出成功摘要。'
  assert_eq 'active' "$(<"$residual_case/service-state")" \
    '残留进程失败恢复后服务应恢复为 active'

  prepare_updater_flow_case "$bad_config_case" '127.0.0.1'
  set +e
  run_updater_flow_case "$bad_config_case" false "$bad_config_output" true
  status=$?
  set -e
  [[ "$status" -ne 0 ]] ||
    fail 'SmartDNS 配置验证失败时更新流程必须失败。'
  grep -Fq 'SmartDNS 配置验证失败。' "$bad_config_output" ||
    fail '配置验证失败没有明确报错。'
  grep -Fq '状态恢复：成功' "$bad_config_output" ||
    fail '配置验证失败没有执行 rollback。'
  ! grep -Fq 'step deploy-configuration' "$bad_config_case/trace" ||
    fail '配置验证失败后不应部署 staged config。'
  ! grep -Fq 'SmartDNS 更新成功' "$bad_config_output" ||
    fail '配置验证失败时不应输出成功摘要。'
  assert_eq 'active' "$(<"$bad_config_case/service-state")" \
    '配置验证失败 rollback 后服务应恢复为 active'

  ((TESTS_RUN += 1))
  log 'Debian 12 已安装且 hold 的完整更新路径、三模式接入、resolver、配置失败 rollback 和服务恢复测试通过。'
}

test_capability_aware_sysctl() {
  local case_dir="$TMP_DIR/capability-aware-sysctl"
  local driver="$case_dir/driver.sh"
  local output
  local status

  mkdir -p "$case_dir"
  {
    cat <<'DRIVER'
#!/usr/bin/env bash
set -Eeuo pipefail
KERNEL_ENFORCEMENT='enabled'
WARNING_COUNT=0
degrade() { KERNEL_ENFORCEMENT='unavailable'; ((WARNING_COUNT += 1)); }
shorten_line() { printf '%s' "$1"; }
fail_with_recovery() { printf 'FATAL:%s\n' "$1" >&2; exit 91; }
sysctl() {
  if [[ "$1" == '-q' && "$2" == '-w' ]]; then
    if [[ "$SYSCTL_MODE" == restricted ]]; then
      printf 'sysctl: permission denied on key "%s"\n' "${3%%=*}" >&2
    else
      printf 'sysctl: invalid argument on key "%s"\n' "${3%%=*}" >&2
    fi
    return 1
  fi
  return 2
}
DRIVER
    extract_function "$UPDATER" sysctl_restriction_error
    extract_function "$UPDATER" apply_ipv6_sysctl_capability_aware
    cat <<'DRIVER'
apply_ipv6_sysctl_capability_aware 1
printf '%s|%s\n' "$KERNEL_ENFORCEMENT" "$WARNING_COUNT"
DRIVER
  } >"$driver"

  output=$(SYSCTL_MODE=restricted bash "$driver")
  assert_eq 'unavailable|1' "$output" \
    'permission denied sysctl 必须降级为 unavailable 且继续成功'
  set +e
  SYSCTL_MODE=unexpected bash "$driver" >"$case_dir/unexpected-output" 2>&1
  status=$?
  set -e
  assert_eq '91' "$status" '真正异常的 sysctl 错误必须进入 fatal 恢复路径'
  grep -Fq 'FATAL:修改 net.ipv6.conf.all.disable_ipv6 时发生异常' \
    "$case_dir/unexpected-output" || fail '异常 sysctl 缺少明确 fatal 诊断。'
  ((TESTS_RUN += 1))
  log 'capability-aware sysctl 的受限降级与真正异常 fatal 分类测试通过。'
}

test_virtualization_detection() {
  local driver="$TMP_DIR/virtualization-detection.sh"
  local output

  {
    cat <<'DRIVER'
#!/usr/bin/env bash
set -Eeuo pipefail
VIRTUALIZATION='unknown'
CONTAINER_VIRTUALIZATION='none'
ENVIRONMENT_LABEL='Unknown environment'
CONTAINER_ENVIRONMENT=false
log() { :; }
systemd-detect-virt() {
  if [[ "${1:-}" == --container ]]; then
    [[ "$DETECTED_CONTAINER" != none ]] || return 1
    printf '%s\n' "$DETECTED_CONTAINER"
  else
    [[ "$DETECTED_VIRT" != none ]] || return 1
    printf '%s\n' "$DETECTED_VIRT"
  fi
}
DRIVER
    extract_function "$UPDATER" detect_runtime_environment
    cat <<'DRIVER'
detect_runtime_environment
printf '%s|%s|%s|%s\n' "$VIRTUALIZATION" "$CONTAINER_VIRTUALIZATION" \
  "$ENVIRONMENT_LABEL" "$CONTAINER_ENVIRONMENT"
DRIVER
  } >"$driver"

  output=$(DETECTED_VIRT=kvm DETECTED_CONTAINER=none bash "$driver")
  assert_eq 'kvm|none|kvm virtual machine|false' "$output" \
    'KVM 必须识别为完整虚拟机而非容器'
  output=$(DETECTED_VIRT=podman DETECTED_CONTAINER=podman bash "$driver")
  assert_eq 'podman|podman|podman container|true' "$output" \
    'Podman 必须通过通用 container 检测路径识别'
  output=$(DETECTED_VIRT=none DETECTED_CONTAINER=none bash "$driver")
  assert_eq 'none|none|Bare metal|false' "$output" \
    '无虚拟化标记必须识别为 bare metal'
  ((TESTS_RUN += 1))
  log 'bare metal、KVM 与 Podman 的统一虚拟化检测测试通过。'
}

run_resolv_conf_case() {
  local mode=$1
  local case_dir="$TMP_DIR/resolv-$mode"
  local driver="$case_dir/driver.sh"
  local output

  mkdir -p "$case_dir/work"
  case "$mode" in
    symlink)
      printf 'nameserver 192.0.2.1\n' >"$case_dir/runtime-resolv.conf"
      ln -s runtime-resolv.conf "$case_dir/resolv.conf"
      ;;
    *) printf 'nameserver 192.0.2.1\n' >"$case_dir/resolv.conf" ;;
  esac
  {
    cat <<'DRIVER'
#!/usr/bin/env bash
set -Eeuo pipefail
TMP_DIR="$CASE_DIR/work"
RESOLV_CONF="$CASE_DIR/resolv.conf"
RESOLV_CONF_STATUS='UNMANAGED'
SYSTEM_RESOLUTION_STATUS='PASS'
WARNING_COUNT=0
log() { :; }
degrade() { ((WARNING_COUNT += 1)); }
fail_with_recovery() { printf 'FATAL:%s\n' "$1" >&2; exit 92; }
systemctl() {
  [[ "$1" != is-active ]]
}
mountpoint() {
  [[ "$RESOLV_MODE" == rw-mount || "$RESOLV_MODE" == ro-mount ]]
}
findmnt() {
  if [[ " $* " == *' -M '* ]]; then
    mountpoint
    return
  fi
  if [[ " $* " == *' OPTIONS '* ]]; then
    [[ "$RESOLV_MODE" == ro-mount ]] && printf 'ro\n' || printf 'rw\n'
  else
    printf 'runtime tmpfs rw\n'
  fi
}
install() {
  local source=${*: -2:1}
  local target=${*: -1}
  cp -- "$source" "$target"
}
DRIVER
    extract_function "$UPDATER" resolv_conf_is_mountpoint
    extract_function "$UPDATER" resolv_conf_mount_is_read_only
    extract_function "$UPDATER" configure_system_resolver
    cat <<'DRIVER'
configure_system_resolver
content=$(tr '\n' ';' <"$RESOLV_CONF")
printf '%s|%s|%s|%s\n' "$RESOLV_CONF_STATUS" "$WARNING_COUNT" \
  "$content" "$([[ -L "$RESOLV_CONF" ]] && printf symlink || printf regular)"
DRIVER
  } >"$driver"
  output=$(CASE_DIR="$case_dir" RESOLV_MODE="$mode" bash "$driver")
  printf '%s' "$output"
}

test_resolv_conf_types() {
  assert_eq 'MANAGED|0|nameserver 127.0.0.1;options timeout:2 attempts:2;|regular' \
    "$(run_resolv_conf_case ordinary)" '普通 resolv.conf 必须原子替换为受管文件'
  assert_eq 'MANAGED|0|nameserver 127.0.0.1;options timeout:2 attempts:2;|regular' \
    "$(run_resolv_conf_case symlink)" 'symlink resolv.conf 必须安全解析后替换为受管文件'
  assert_eq 'CONTAINER_MANAGED_IN_PLACE|1|nameserver 127.0.0.1;options timeout:2 attempts:2;|regular' \
    "$(run_resolv_conf_case rw-mount)" 'rw mount point 必须原地更新并报告非持久 warning'
  assert_eq 'CONTAINER_MANAGED_UNCHANGED|1|nameserver 192.0.2.1;|regular' \
    "$(run_resolv_conf_case ro-mount)" 'ro mount point 必须保留内容且不得 fatal'
  ((TESTS_RUN += 1))
  log '普通文件、symlink、rw/ro mount point 的 resolv.conf 分流测试通过。'
}

test_static_safety_guards() {
  local script

  for script in "$INSTALLER" "$UPDATER"; do
    grep -Fq -- '--connect-timeout 10 --max-time 120 --retry 3 --retry-delay 2' "$script" ||
      fail "$script 缺少固定下载超时/重试参数。"
    grep -Fq -- '--retry-connrefused' "$script" ||
      fail "$script 缺少 --retry-connrefused。"
    grep -Fq 'dpkg-deb --info' "$script" ||
      fail "$script 缺少 dpkg-deb --info 校验。"
    grep -Fq 'sha256sum --check --status' "$script" ||
      fail "$script 缺少 sha256sum 校验。"
    grep -Fq 'apt-mark unhold smartdns' "$script" ||
      fail "$script 缺少安装前 unhold。"
    grep -Fq 'apt-mark hold smartdns' "$script" ||
      fail "$script 缺少成功后的 hold。"
    grep -Fq 'smartdns -f -x -c ' "$script" ||
      fail "$script 缺少独立配置启动验证。"
    ! grep -Fq 'https://api.github.com/repos/pymumu/smartdns/releases/latest' "$script" ||
      fail "$script 仍依赖上游 latest Release API。"
    ! grep -Fq 'install -y ca-certificates dnsutils smartdns' "$script" ||
      fail "$script 仍直接安装 Debian Candidate。"
  done
  grep -Fq 'restore_smartdns_transaction' "$INSTALLER" ||
    fail '主脚本缺少失败恢复事务。'
  grep -Fq 'restore_previous_state' "$UPDATER" ||
    fail '更新脚本缺少失败恢复事务。'
  grep -Fq "OS_VERSION=''" "$UPDATER" ||
    fail '更新脚本没有记录 Debian 大版本。'
  grep -Fq 'Debian / 架构' "$UPDATER" ||
    fail '更新脚本成功摘要缺少 Debian/架构。'
  grep -Fq "installed_status=\$(dpkg-query -W -f='\${Status}' smartdns" "$UPDATER" ||
    fail '更新脚本没有按完整 Debian Status 判断已安装且 hold 的软件包。'
  grep -Fq 'if pgrep -x smartdns >/dev/null 2>&1; then' "$UPDATER" ||
    fail '更新脚本没有显式判断清理后的 SmartDNS 残留进程。'
  ((TESTS_RUN += 1))
  log '下载、元数据、配置验证、hold 和失败恢复静态安全检查通过。'
}

main() {
  TMP_DIR=$(mktemp -d)
  test_fixed_mapping
  test_configurations
  test_network_stack_switches
  test_capability_aware_sysctl
  test_virtualization_detection
  test_resolv_conf_types
  test_retry_logic
  test_updater_full_regression_flow
  test_static_safety_guards
  printf '[PASS] %s 组 SmartDNS 离线测试全部通过。\n' "$TESTS_RUN"
}

main "$@"
