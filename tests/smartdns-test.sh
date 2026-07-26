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
    printf '%s\n' "SMARTDNS_RELEASE_BASE='https://github.com/404-git-404/404notfound/releases/download/smartdns-debian-pinned-2026-07'"
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
      [[ "$installer_result" == *'https://github.com/404-git-404/404notfound/releases/download/smartdns-debian-pinned-2026-07/'* ]] ||
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
  local library="$TMP_DIR/render-library.sh"

  {
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' 'die() { printf "%s\n" "$*" >&2; exit 1; }'
    extract_function "$script" write_smartdns_configuration
    printf 'write_smartdns_configuration %q %q\n' "$target" "$variant"
  } >"$library"
  bash "$library"
}

write_expected_common() {
  local target=$1
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

speed-check-mode tcp:443,ping
response-mode first-ping
dualstack-ip-selection yes
dualstack-ip-selection-threshold 10

log-level warn
log-console no
log-syslog yes
audit-enable no

ca-file /etc/ssl/certs/ca-certificates.crt

EXPECTED_COMMON
}

test_configurations() {
  local installer_config
  local updater_config
  local expected_config
  local variant

  for variant in v40 v46; do
    installer_config="$TMP_DIR/installer-$variant.conf"
    updater_config="$TMP_DIR/updater-$variant.conf"
    expected_config="$TMP_DIR/expected-$variant.conf"
    render_configuration "$INSTALLER" "$variant" "$installer_config"
    render_configuration "$UPDATER" "$variant" "$updater_config"
    cmp -s "$installer_config" "$updater_config" ||
      fail "主脚本与更新脚本的 $variant 配置不一致。"
    write_expected_common "$expected_config"
    if [[ "$variant" == v40 ]]; then
      cat >>"$expected_config" <<'EXPECTED_VARIANT'
server-https https://1.1.1.1/dns-query -host-name cloudflare-dns.com -http-host cloudflare-dns.com -tls-host-verify cloudflare-dns.com
server-https https://8.8.8.8/dns-query -host-name dns.google -http-host dns.google -tls-host-verify dns.google
server-https https://9.9.9.10/dns-query -host-name dns.quad9.net -http-host dns.quad9.net -tls-host-verify dns.quad9.net -fallback
EXPECTED_VARIANT
    else
      cat >>"$expected_config" <<'EXPECTED_VARIANT'
server-https https://cloudflare-dns.com/dns-query -host-ip 1.1.1.1
server-https https://dns.google/dns-query -host-ip 8.8.8.8
server-https https://dns.quad9.net/dns-query -host-ip 9.9.9.10 -fallback
EXPECTED_VARIANT
    fi
    cmp -s "$expected_config" "$installer_config" ||
      fail "$variant 配置与要求的精确模板不一致。"
    ! grep -Eq '\\[[:space:]]*$' "$installer_config" ||
      fail "$variant 配置不应使用续行。"
    [[ $(grep -c '^server-https ' "$installer_config") -eq 3 ]] ||
      fail "$variant 配置必须严格包含三条 DoH 上游。"
  done
  assert_file_contains_line "$TMP_DIR/installer-v40.conf" \
    'server-https https://9.9.9.10/dns-query -host-name dns.quad9.net -http-host dns.quad9.net -tls-host-verify dns.quad9.net -fallback'
  assert_file_contains_line "$TMP_DIR/installer-v46.conf" \
    'server-https https://dns.quad9.net/dns-query -host-ip 9.9.9.10 -fallback'
  ((TESTS_RUN += 1))
  log 'v40/v46 精确配置、DoH 参数和无续行测试通过。'
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
    printf 'inactive\n' >"$MOCK_SERVICE_STATE"
    ;;
  restart)
    printf 'active\n' >"$MOCK_SERVICE_STATE"
    ;;
  enable)
    printf 'enabled\n' >"$MOCK_ENABLED_STATE"
    ;;
  disable)
    printf 'disabled\n' >"$MOCK_ENABLED_STATE"
    ;;
  daemon-reload | reset-failed)
    ;;
  is-enabled)
    [[ "$(<"$MOCK_ENABLED_STATE")" == enabled ]] || exit 1
    [[ " $* " == *' --quiet '* ]] || printf 'enabled\n'
    ;;
  is-active)
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

mock_step() {
  printf 'step %s\n' "$1" >>"$MOCK_TRACE"
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
}

check_port_53_conflicts() {
  mock_step check-port-53-conflicts
}

deploy_configuration() {
  mock_step deploy-configuration
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
    extract_function "$UPDATER" valid_system_ipv4_answer
    extract_function "$UPDATER" start_and_validate_service
    # shellcheck disable=SC2016
    extract_function "$UPDATER" report_system_dns_mismatch |
      sed 's#/etc/resolv\.conf#"$MOCK_RESOLV_CONF"#g'
    # shellcheck disable=SC2016
    extract_function "$UPDATER" check_debian_system_dns |
      sed 's#/etc/resolv\.conf#"$MOCK_RESOLV_CONF"#g'
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
  printf 'nameserver %s\n' "$nameserver" >"$case_dir/resolv.conf"
  write_updater_flow_mocks "$case_dir/bin"
  write_updater_flow_driver "$case_dir/driver.sh"
}

run_updater_flow_case() {
  local case_dir=$1
  local residual=$2
  local output=$3

  PATH="$case_dir/bin:$PATH" \
    MOCK_CASE_DIR="$case_dir" \
    MOCK_TRACE="$case_dir/trace" \
    MOCK_SERVICE_STATE="$case_dir/service-state" \
    MOCK_ENABLED_STATE="$case_dir/enabled-state" \
    MOCK_HOLD_STATE="$case_dir/hold-state" \
    MOCK_RESOLV_CONF="$case_dir/resolv.conf" \
    MOCK_RESIDUAL="$residual" \
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
    printf '%s\n' 'apt-mark() { return 1; }'
    printf '%s\n' 'systemctl() { return 1; }'
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
  local bad_dns_case="$TMP_DIR/updater-flow-bad-dns"
  local bad_dns_output="$bad_dns_case/output"
  local residual_case="$TMP_DIR/updater-flow-residual"
  local residual_output="$residual_case/output"
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
  assert_trace_order "$success_case/trace" \
    'systemctl is-active --quiet smartdns.service' \
    'step create-backup' \
    'systemctl stop smartdns.service' \
    'step validate-configuration-independently' \
    'step check-port-53-conflicts' \
    'step deploy-configuration' \
    'systemctl restart smartdns.service' \
    'ss -H -lntup sport = :53' \
    'dig @127.0.0.1 cloudflare.com A +short +time=4 +tries=1' \
    'dig @127.0.0.1 cloudflare.com AAAA +time=4 +tries=1' \
    'apt-mark hold smartdns' \
    'getent ahostsv4 cloudflare.com'
  grep -Fq '127.0.0.1:53 的 TCP 和 UDP 监听验证通过。' "$success_output" ||
    fail '成功路径缺少 TCP/UDP 53 验证。'
  grep -Fq 'IPv4 查询第 1 次成功：104.16.132.229' "$success_output" ||
    fail '成功路径缺少 IPv4 验证。'
  grep -Fq 'AAAA 查询状态：NOERROR' "$success_output" ||
    fail '成功路径缺少 AAAA 验证。'
  grep -Fq 'Debian 系统 DNS 验证通过：仅 127.0.0.1。' "$success_output" ||
    fail '成功路径缺少 Debian 系统 DNS 验证。'
  grep -Fq 'SmartDNS 更新成功' "$success_output" ||
    fail '成功路径没有执行 print_summary。'
  assert_eq 'active' "$(<"$success_case/service-state")" \
    '成功后 smartdns.service 应保持 active'
  assert_eq 'enabled' "$(<"$success_case/enabled-state")" \
    '成功后 smartdns.service 应保持 enabled'
  assert_eq 'smartdns' "$(<"$success_case/hold-state")" \
    '成功后 smartdns 应保持 hold'

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

  prepare_updater_flow_case "$bad_dns_case" '8.8.8.8'
  set +e
  run_updater_flow_case "$bad_dns_case" false "$bad_dns_output"
  status=$?
  set -e
  [[ "$status" -ne 0 ]] ||
    fail '系统 DNS 不仅为 127.0.0.1 时更新流程必须失败。'
  grep -Fq 'Debian 系统 DNS 未指向 127.0.0.1' "$bad_dns_output" ||
    fail '系统 DNS 不匹配没有明确报错。'
  grep -Fq 'apt-mark hold smartdns' "$bad_dns_case/trace" ||
    fail '系统 DNS 检查前必须完成服务健康检查和 hold。'
  ! grep -Fq 'SmartDNS 更新成功' "$bad_dns_output" ||
    fail '系统 DNS 不匹配时不应输出成功摘要。'
  assert_eq 'active' "$(<"$bad_dns_case/service-state")" \
    '系统 DNS 检查失败时服务仍应为 active'

  ((TESTS_RUN += 1))
  log 'Debian 12 已安装且 hold 的完整更新路径、停止返回值、服务健康检查、系统 DNS、成功摘要和失败恢复回归测试通过。'
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
  test_retry_logic
  test_updater_full_regression_flow
  test_static_safety_guards
  printf '[PASS] %s 组 SmartDNS 离线测试全部通过。\n' "$TESTS_RUN"
}

main "$@"
