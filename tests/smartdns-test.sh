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
    count=$(<"$MOCK_APT_MARK_COUNT")
    count=$((count + 1))
    printf '%s\n' "$count" >"$MOCK_APT_MARK_COUNT"
    if [[ ${MOCK_APT_MARK_LOCK_ONCE:-false} == true && "$count" == 1 ]]; then
      printf '%s\n' \
        'E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 21978 (unattended-upgrade)' \
        'E: Sub-process dpkg --set-selections returned an error code (2)' >&2
      exit 2
    fi
    printf 'smartdns\n' >"$MOCK_HOLD_STATE"
    ;;
  unhold)
    count=$(<"$MOCK_APT_MARK_COUNT")
    count=$((count + 1))
    printf '%s\n' "$count" >"$MOCK_APT_MARK_COUNT"
    if [[ ${MOCK_APT_MARK_LOCK_ONCE:-false} == true && "$count" == 1 ]]; then
      printf '%s\n' \
        'E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 21978 (unattended-upgrade)' \
        'E: Sub-process dpkg --set-selections returned an error code (2)' >&2
      exit 2
    fi
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
readonly APT_LOCK_TIMEOUT_SECONDS=300
readonly APT_LOCK_RETRY_INTERVAL_SECONDS=2
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
    extract_function "$UPDATER" apt_mark_error_is_lock
    extract_function "$UPDATER" apt_lock_holder_details
    extract_function "$UPDATER" apt_mark_with_lock_retry
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
  printf '0\n' >"$case_dir/apt-mark-count"
  printf 'nameserver %s\n' "$nameserver" >"$case_dir/resolv.conf"
  write_updater_flow_mocks "$case_dir/bin"
  write_updater_flow_driver "$case_dir/driver.sh"
}

run_updater_flow_case() {
  local case_dir=$1
  local residual=$2
  local output=$3
  local lock_once=${4:-false}

  PATH="$case_dir/bin:$PATH" \
    MOCK_CASE_DIR="$case_dir" \
    MOCK_TRACE="$case_dir/trace" \
    MOCK_SERVICE_STATE="$case_dir/service-state" \
    MOCK_ENABLED_STATE="$case_dir/enabled-state" \
    MOCK_HOLD_STATE="$case_dir/hold-state" \
    MOCK_APT_MARK_COUNT="$case_dir/apt-mark-count" \
    MOCK_APT_MARK_LOCK_ONCE="$lock_once" \
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

run_apt_mark_retry_case() {
  local script=$1
  local scenario=$2
  local action=${3:-hold}
  local case_name
  local count_file
  local driver
  local output
  local output_file
  local status

  case_name="$(basename -- "$script")-$scenario-$action"
  driver="$TMP_DIR/apt-mark-$case_name.sh"
  count_file="$TMP_DIR/apt-mark-$case_name.count"
  output_file="$TMP_DIR/apt-mark-$case_name.output"
  printf '0\n' >"$count_file"
  {
    cat <<'RETRY_DRIVER'
#!/usr/bin/env bash
set -Eeuo pipefail
APT_LOCK_TIMEOUT_SECONDS=4
APT_LOCK_RETRY_INTERVAL_SECONDS=2

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

apt-mark() {
  local count
  count=$(<"$MOCK_COUNT_FILE")
  count=$((count + 1))
  printf '%s\n' "$count" >"$MOCK_COUNT_FILE"
  case "$MOCK_SCENARIO" in
    transient)
      if ((count == 1)); then
        printf '%s\n' \
          'E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 21978 (unattended-upgrade)' \
          'E: Sub-process dpkg --set-selections returned an error code (2)' >&2
        return 2
      fi
      ;;
    persistent)
      printf '%s\n' \
        'E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 21978 (unattended-upgrade)' \
        'E: Sub-process dpkg --set-selections returned an error code (2)' >&2
      return 2
      ;;
    nonlock)
      printf '%s\n' 'dpkg: error: requested operation requires superuser privilege' >&2
      return 2
      ;;
    *)
      return 99
      ;;
  esac
}

sleep() {
  printf 'sleep %s\n' "$1" >>"$MOCK_SLEEP_FILE"
  SECONDS=$((SECONDS + $1))
}
RETRY_DRIVER
    extract_function "$script" apt_mark_error_is_lock
    extract_function "$script" apt_lock_holder_details
    extract_function "$script" apt_mark_with_lock_retry
    cat <<'RETRY_RUN'
set +e
apt_mark_with_lock_retry "$MOCK_ACTION" smartdns
status=$?
set -e
printf '__STATUS__=%s\n' "$status"
RETRY_RUN
  } >"$driver"
  : >"$TMP_DIR/apt-mark-$case_name.sleeps"
  MOCK_SCENARIO="$scenario" \
    MOCK_ACTION="$action" \
    MOCK_COUNT_FILE="$count_file" \
    MOCK_SLEEP_FILE="$TMP_DIR/apt-mark-$case_name.sleeps" \
    bash "$driver" >"$output_file" 2>&1
  output=$(<"$output_file")
  status=$(sed -n 's/^__STATUS__=//p' "$output_file")

  case "$scenario" in
    transient)
      assert_eq '0' "$status" "$script 瞬时锁竞争后应成功"
      assert_eq '2' "$(<"$count_file")" "$script 瞬时锁应只重试一次"
      grep -Fq 'apt-mark 遇到锁竞争' "$output_file" ||
        fail "$script 瞬时锁没有输出等待信息。"
      grep -Fq 'PID=21978 COMMAND=unattended-upgrade' "$output_file" ||
        fail "$script 锁等待信息缺少 PID 或命令。"
      grep -Fq "apt/dpkg 锁已释放；继续执行命令：apt-mark $action smartdns" \
        "$output_file" ||
        fail "$script 锁释放后没有继续执行原 apt-mark 命令。"
      ;;
    persistent)
      assert_eq '2' "$status" "$script 持续锁超时应保留 apt-mark 退出码"
      assert_eq '3' "$(<"$count_file")" "$script 持续锁应重试到测试超时"
      grep -Fq 'apt-mark 锁等待超时（4 秒）' "$output_file" ||
        fail "$script 持续锁没有明确超时报错。"
      grep -Fq 'PID=21978 COMMAND=unattended-upgrade' "$output_file" ||
        fail "$script 超时报错缺少占锁进程。"
      ;;
    nonlock)
      assert_eq '2' "$status" "$script 非锁错误应保留原退出码"
      assert_eq '1' "$(<"$count_file")" "$script 非锁错误不得重试"
      grep -Fq 'requested operation requires superuser privilege' "$output_file" ||
        fail "$script 非锁错误没有保留原始输出。"
      [[ "$output" != *'apt-mark 遇到锁竞争'* ]] ||
        fail "$script 非锁错误被错误识别为锁竞争。"
      ;;
  esac
}

test_apt_mark_lock_retry() {
  local script

  for script in "$INSTALLER" "$UPDATER"; do
    run_apt_mark_retry_case "$script" transient hold
    run_apt_mark_retry_case "$script" transient unhold
    run_apt_mark_retry_case "$script" persistent
    run_apt_mark_retry_case "$script" nonlock
  done
  ((TESTS_RUN += 1))
  log '主脚本与 updater 的 apt-mark hold/unhold 瞬时锁、持续锁超时及非锁错误测试通过。'
}

test_apt_get_lock_timeout() {
  local driver
  local output
  local script

  for script in "$INSTALLER" "$UPDATER"; do
    driver="$TMP_DIR/apt-get-$(basename -- "$script").sh"
    {
      printf '%s\n' 'set -Eeuo pipefail'
      printf '%s\n' 'APT_LOCK_TIMEOUT_SECONDS=300'
      if [[ "$script" == "$INSTALLER" ]]; then
        printf '%s\n' 'wait_for_apt_locks() { :; }'
      fi
      printf '%s\n' 'apt-get() { printf "%s\n" "$*"; }'
      extract_function "$script" apt_get
      printf '%s\n' 'apt_get install --yes smartdns'
    } >"$driver"
    output=$(bash "$driver")
    assert_eq '-o DPkg::Lock::Timeout=300 install --yes smartdns' "$output" \
      "$script apt-get 缺少 300 秒 dpkg 锁等待"
  done
  ((TESTS_RUN += 1))
  log '主脚本与 updater 的 apt-get DPkg::Lock::Timeout=300 测试通过。'
}

test_installer_hold_status_and_downstream_flow() {
  local count_file="$TMP_DIR/installer-downstream.count"
  local driver="$TMP_DIR/installer-downstream.sh"
  local status_driver="$TMP_DIR/installer-status.sh"
  local trace="$TMP_DIR/installer-downstream.trace"

  printf '0\n' >"$count_file"
  : >"$trace"
  {
    cat <<'INSTALLER_FLOW'
#!/usr/bin/env bash
set -Eeuo pipefail
APT_LOCK_TIMEOUT_SECONDS=300
APT_LOCK_RETRY_INTERVAL_SECONDS=2

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

apt-mark() {
  local count
  count=$(<"$MOCK_COUNT_FILE")
  count=$((count + 1))
  printf '%s\n' "$count" >"$MOCK_COUNT_FILE"
  printf 'apt-mark %s\n' "$*" >>"$MOCK_TRACE"
  if ((count == 1)); then
    printf '%s\n' \
      'dpkg: error: dpkg frontend lock was locked by another process with pid 21978' \
      'E: Sub-process dpkg --set-selections returned an error code (2)' >&2
    return 2
  fi
}

sleep() {
  printf 'sleep %s\n' "$1" >>"$MOCK_TRACE"
}

mock_step() {
  printf '%s\n' "$1" >>"$MOCK_TRACE"
}

install_cloudflare_ufw_tool() { mock_step cloudflare-ufw-tool; }
configure_chrony() { mock_step chrony; }
configure_bbr() { mock_step bbr; }
install_sing_box() { mock_step sing-box; }
configure_system_dns() { mock_step system-dns; }
install_domain_check() { mock_step domain-check; }
configure_ssh() { mock_step ssh; }
configure_ufw() { mock_step ufw; }
print_final_report() { mock_step final-summary; }
INSTALLER_FLOW
    extract_function "$INSTALLER" apt_mark_error_is_lock
    extract_function "$INSTALLER" apt_lock_holder_details
    extract_function "$INSTALLER" apt_mark_with_lock_retry
    cat <<'INSTALL_SMARTDNS'
install_smartdns() {
  apt_mark_with_lock_retry hold smartdns
  mock_step smartdns
}
INSTALL_SMARTDNS
    extract_function "$INSTALLER" run_remaining_initialization
    printf '%s\n' 'run_remaining_initialization'
  } >"$driver"
  MOCK_COUNT_FILE="$count_file" MOCK_TRACE="$trace" bash "$driver" \
    >"$TMP_DIR/installer-downstream.output" 2>&1 ||
    fail '主安装流程不应因瞬时 apt-mark 锁停止。'
  assert_eq '2' "$(<"$count_file")" \
    '主安装流程 apt-mark 应在瞬时锁后重试一次'
  assert_trace_order "$trace" \
    'cloudflare-ufw-tool' \
    'chrony' \
    'bbr' \
    'sing-box' \
    'apt-mark hold smartdns' \
    'smartdns' \
    'system-dns' \
    'domain-check' \
    'ssh' \
    'ufw' \
    'final-summary'

  {
    cat <<'STATUS_DRIVER'
#!/usr/bin/env bash
set -Eeuo pipefail
SMARTDNS_EXPECTED_VERSION='40+dfsg-1'
CPU_ARCH='amd64'
dpkg-query() {
  case "$*" in
    *'${Status}'*) printf 'hold ok installed' ;;
    *'${Version}'*) printf '40+dfsg-1' ;;
    *'${Architecture}'*) printf 'amd64' ;;
    *) return 2 ;;
  esac
}
STATUS_DRIVER
    extract_function "$INSTALLER" smartdns_package_is_current
    cat <<'STATUS_CHECKS'
smartdns_package_is_current
CPU_ARCH='arm64'
if smartdns_package_is_current; then
  exit 1
fi
STATUS_CHECKS
  } >"$status_driver"
  bash "$status_driver" ||
    fail '主脚本应接受 hold ok installed，并继续严格验证版本和架构。'

  ((TESTS_RUN += 1))
  log '主脚本 hold 状态判断及 SmartDNS、系统 DNS、domain-check、SSH、UFW、最终摘要连续路径测试通过。'
}

test_real_debian12_dpkg_lock_container() {
  local build_log="$TMP_DIR/debian12-lock-build.log"
  local container_name="smartdns-dpkg-lock-$$"
  local container_script="$TMP_DIR/debian12-lock-test.sh"
  local image_name="smartdns-dpkg-lock-test:$$"
  local run_output="$TMP_DIR/debian12-lock-run.log"
  local state=''
  local status

  if ! command -v docker >/dev/null 2>&1 ||
    ! docker info >/dev/null 2>&1; then
    log '当前环境没有可用 Docker；真实 Debian 12 systemd 锁竞争测试留给 GitHub Actions runner。'
    return 0
  fi

  {
    cat <<'REAL_LOCK_PREAMBLE'
#!/usr/bin/env bash
set -Eeuo pipefail
APT_LOCK_TIMEOUT_SECONDS=300
APT_LOCK_RETRY_INTERVAL_SECONDS=2
holder_pid=''

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}
REAL_LOCK_PREAMBLE
    extract_function "$UPDATER" apt_mark_error_is_lock
    extract_function "$UPDATER" apt_lock_holder_details
    extract_function "$UPDATER" apt_mark_with_lock_retry
    cat <<'REAL_LOCK_BODY'
cleanup_real_lock_test() {
  local cleanup_status=0
  set +e
  if [[ -n "$holder_pid" ]]; then
    wait "$holder_pid" || cleanup_status=1
  fi
  /usr/bin/apt-mark unhold codex-lock-target >/dev/null 2>&1
  dpkg --remove codex-lock-holder codex-lock-target >/dev/null 2>&1
  return "$cleanup_status"
}
trap cleanup_real_lock_test EXIT

install -d /tmp/target-pkg/DEBIAN /tmp/holder-pkg/DEBIAN /tmp/lock-bin
cat >/tmp/target-pkg/DEBIAN/control <<'EOF'
Package: codex-lock-target
Version: 1.0
Architecture: all
Maintainer: Offline Test <test@example.invalid>
Description: disposable apt-mark lock target
EOF
cat >/tmp/holder-pkg/DEBIAN/control <<'EOF'
Package: codex-lock-holder
Version: 1.0
Architecture: all
Maintainer: Offline Test <test@example.invalid>
Description: disposable dpkg frontend lock holder
EOF
cat >/tmp/holder-pkg/DEBIAN/preinst <<'EOF'
#!/bin/sh
set -eu
: >/tmp/dpkg-lock-holder-started
sleep 6
EOF
chmod 0755 /tmp/holder-pkg/DEBIAN/preinst
dpkg-deb --build /tmp/target-pkg /tmp/target.deb >/dev/null
dpkg-deb --build /tmp/holder-pkg /tmp/holder.deb >/dev/null
dpkg --install /tmp/target.deb >/dev/null

cat >/tmp/lock-bin/apt-mark <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>/tmp/apt-mark-attempts
exec /usr/bin/apt-mark "$@"
EOF
chmod 0755 /tmp/lock-bin/apt-mark
: >/tmp/apt-mark-attempts
frontend_lock_inode_before=$(stat -c '%i' /var/lib/dpkg/lock-frontend)

dpkg --install /tmp/holder.deb >/tmp/holder-install.log 2>&1 &
holder_pid=$!
for _ in {1..50}; do
  [[ -e /tmp/dpkg-lock-holder-started ]] && break
  sleep 0.1
done
[[ -e /tmp/dpkg-lock-holder-started ]] ||
  { printf '[FAIL] dpkg holder preinst did not start.\n' >&2; exit 1; }

PATH="/tmp/lock-bin:$PATH" apt_mark_with_lock_retry hold codex-lock-target \
  > /tmp/apt-mark-retry.log 2>&1
cat /tmp/apt-mark-retry.log
wait "$holder_pid"
holder_pid=''

attempt_count=$(wc -l </tmp/apt-mark-attempts)
((attempt_count >= 2)) ||
  { printf '[FAIL] real apt-mark did not encounter the dpkg lock.\n' >&2; exit 1; }
grep -Fq 'apt-mark 遇到锁竞争' /tmp/apt-mark-retry.log
grep -Fq "PID=" /tmp/apt-mark-retry.log
grep -Fq "COMMAND=dpkg" /tmp/apt-mark-retry.log
grep -Fq 'apt/dpkg 锁已释放；继续执行命令：apt-mark hold codex-lock-target' \
  /tmp/apt-mark-retry.log
/usr/bin/apt-mark showhold | grep -Fxq codex-lock-target
frontend_lock_inode_after=$(stat -c '%i' /var/lib/dpkg/lock-frontend)
[[ "$frontend_lock_inode_after" == "$frontend_lock_inode_before" ]]
printf '[PASS] real Debian 12 POSIX dpkg frontend lock retry succeeded.\n'
REAL_LOCK_BODY
  } >"$container_script"
  chmod +x "$container_script"

  cat >"$TMP_DIR/Dockerfile.debian12-lock" <<'DOCKERFILE'
FROM debian:12
ENV container=docker
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install --yes \
      systemd systemd-sysv util-linux && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
DOCKERFILE

  if ! docker build \
    --file "$TMP_DIR/Dockerfile.debian12-lock" \
    --tag "$image_name" "$TMP_DIR" >"$build_log" 2>&1; then
    cat "$build_log" >&2
    fail '无法构建一次性 Debian 12 systemd 锁竞争测试容器。'
  fi
  if ! docker run --detach --privileged --cgroupns=host \
    --name "$container_name" --tmpfs /run --tmpfs /run/lock \
    --volume /sys/fs/cgroup:/sys/fs/cgroup:rw \
    "$image_name" >/dev/null; then
    docker image rm "$image_name" >/dev/null
    fail '无法启动一次性 Debian 12 systemd 锁竞争测试容器。'
  fi

  for _ in {1..30}; do
    if state=$(docker exec "$container_name" \
      systemctl is-system-running 2>/dev/null); then
      [[ "$state" == running || "$state" == degraded ]] && break
    elif [[ "$state" == degraded ]]; then
      break
    fi
    sleep 1
  done
  if ! docker cp "$container_script" \
    "$container_name:/root/debian12-lock-test.sh"; then
    status=1
  elif docker exec "$container_name" \
    bash /root/debian12-lock-test.sh >"$run_output" 2>&1; then
    status=0
  else
    status=$?
  fi

  docker stop --time 15 "$container_name" >/dev/null
  docker rm "$container_name" >/dev/null
  docker image rm "$image_name" >/dev/null
  if ((status != 0)); then
    [[ ! -s "$run_output" ]] || cat "$run_output" >&2
    fail '真实 Debian 12 POSIX dpkg frontend 锁竞争测试失败。'
  fi
  grep -Fq \
    '[PASS] real Debian 12 POSIX dpkg frontend lock retry succeeded.' \
    "$run_output" ||
    fail '真实 Debian 12 锁竞争测试缺少成功标记。'

  ((TESTS_RUN += 1))
  log '一次性 Debian 12 systemd 容器真实 POSIX dpkg frontend 锁竞争测试通过。'
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
  if ! run_updater_flow_case "$success_case" false "$success_output" true; then
    cat "$success_output" >&2
    fail '已安装且 hold 的 SmartDNS 更新主流程应成功。'
  fi
  grep -Fq 'apt-mark 遇到锁竞争' "$success_output" ||
    fail '预检后瞬时 apt-mark 锁竞争没有进入精准重试。'
  grep -Fq 'PID=21978 COMMAND=unattended-upgrade' "$success_output" ||
    fail '锁等待输出缺少占锁 PID 和命令。'
  grep -Fq 'apt/dpkg 锁已释放；继续执行命令：apt-mark hold smartdns' \
    "$success_output" ||
    fail '锁释放后没有继续执行 hold。'
  assert_eq '2' "$(<"$success_case/apt-mark-count")" \
    '瞬时锁竞争后 apt-mark hold 应重试一次'
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
  run_updater_flow_case "$residual_case" true "$residual_output" true
  status=$?
  set -e
  [[ "$status" -ne 0 ]] ||
    fail '存在残留 SmartDNS 进程时更新流程必须失败。'
  grep -Fq '清理后仍检测到 SmartDNS 残留进程。' "$residual_output" ||
    fail '残留进程失败没有明确报错。'
  grep -Fq '状态恢复：成功' "$residual_output" ||
    fail '残留进程失败没有执行成功恢复。'
  grep -Fq 'apt/dpkg 锁已释放；继续执行命令：apt-mark hold smartdns' \
    "$residual_output" ||
    fail '恢复路径遇到瞬时锁后没有重试并恢复 hold。'
  assert_eq '2' "$(<"$residual_case/apt-mark-count")" \
    '恢复路径 apt-mark hold 应在瞬时锁后重试一次'
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
  local apt_get_wrapper_literal
  local installer_restore
  local script
  local updater_restore

  apt_get_wrapper_literal="apt-get -o \"DPkg::Lock::Timeout=\$APT_LOCK_TIMEOUT_SECONDS\""

  for script in "$INSTALLER" "$UPDATER"; do
    grep -Fq -- '--connect-timeout 10 --max-time 120 --retry 3 --retry-delay 2' "$script" ||
      fail "$script 缺少固定下载超时/重试参数。"
    grep -Fq -- '--retry-connrefused' "$script" ||
      fail "$script 缺少 --retry-connrefused。"
    grep -Fq 'dpkg-deb --info' "$script" ||
      fail "$script 缺少 dpkg-deb --info 校验。"
    grep -Fq 'sha256sum --check --status' "$script" ||
      fail "$script 缺少 sha256sum 校验。"
    grep -Fq 'apt_mark_with_lock_retry unhold smartdns' "$script" ||
      fail "$script 缺少带精准锁重试的安装前 unhold。"
    grep -Fq 'apt_mark_with_lock_retry hold smartdns' "$script" ||
      fail "$script 缺少带精准锁重试的成功后 hold。"
    grep -Fq 'APT_LOCK_TIMEOUT_SECONDS=300' "$script" ||
      fail "$script 的包管理锁等待不是固定 300 秒。"
    grep -Fq 'APT_LOCK_RETRY_INTERVAL_SECONDS=2' "$script" ||
      fail "$script 的 apt-mark 锁重试间隔不是固定 2 秒。"
    grep -Fq 'apt-mark "$@"' "$script" ||
      fail "$script 的 apt-mark 调用没有集中经过重试包装。"
    if grep -Eq '^[[:space:]]*apt-mark[[:space:]]+(hold|unhold)' "$script"; then
      fail "$script 仍存在绕过锁重试包装的 apt-mark 状态修改。"
    fi
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
  installer_restore=$(extract_function "$INSTALLER" restore_smartdns_transaction)
  updater_restore=$(extract_function "$UPDATER" restore_previous_state)
  [[ "$installer_restore" == *'apt_mark_with_lock_retry hold smartdns'* &&
    "$installer_restore" == *'apt_mark_with_lock_retry unhold smartdns'* ]] ||
    fail '主脚本 SmartDNS 回滚路径没有保护 hold/unhold。'
  [[ "$updater_restore" == *'apt_mark_with_lock_retry hold smartdns'* &&
    "$updater_restore" == *'apt_mark_with_lock_retry unhold smartdns'* ]] ||
    fail '更新脚本恢复路径没有保护 hold/unhold。'
  grep -Fq "installed_status=\$(dpkg-query -W -f='\${Status}' smartdns" \
    "$INSTALLER" ||
    fail '主脚本没有按完整 Debian Status 判断已安装且 hold 的软件包。'
  ! grep -Fq "installed_status=\$(dpkg-query -W -f='\${db:Status-Abbrev}' smartdns" \
    "$INSTALLER" ||
    fail '主脚本仍使用 Status-Abbrev 判断 SmartDNS 已安装状态。'
  grep -Fq "$apt_get_wrapper_literal" "$UPDATER" ||
    fail '更新脚本 apt-get 缺少 300 秒 dpkg 锁等待包装。'
  if grep -Eq \
    'DEBIAN_FRONTEND=noninteractive[[:space:]]+apt-get' "$UPDATER"; then
    fail '更新脚本仍存在绕过 300 秒锁等待包装的 apt-get。'
  fi
  grep -Fq "OS_VERSION=''" "$UPDATER" ||
    fail '更新脚本没有记录 Debian 大版本。'
  grep -Fq 'Debian / 架构' "$UPDATER" ||
    fail '更新脚本成功摘要缺少 Debian/架构。'
  grep -Fq "installed_status=\$(dpkg-query -W -f='\${Status}' smartdns" "$UPDATER" ||
    fail '更新脚本没有按完整 Debian Status 判断已安装且 hold 的软件包。'
  grep -Fq 'if pgrep -x smartdns >/dev/null 2>&1; then' "$UPDATER" ||
    fail '更新脚本没有显式判断清理后的 SmartDNS 残留进程。'
  if grep -Eq \
    'rm[[:space:]].*(/var/lib/dpkg/lock|/var/lib/dpkg/lock-frontend|/var/lib/apt/lists/lock|/var/cache/apt/archives/lock)' \
    "$INSTALLER" "$UPDATER"; then
    fail '脚本不得删除 apt/dpkg 锁文件。'
  fi
  if grep -Eqi \
    '(kill|pkill|killall)[^#]*(apt-get|apt|dpkg|unattended-upgrade)' \
    "$INSTALLER" "$UPDATER"; then
    fail '脚本不得终止 apt、dpkg 或 unattended-upgrade 进程。'
  fi
  ((TESTS_RUN += 1))
  log '下载、元数据、配置验证、hold 和失败恢复静态安全检查通过。'
}

main() {
  TMP_DIR=$(mktemp -d)
  test_fixed_mapping
  test_configurations
  test_retry_logic
  test_apt_mark_lock_retry
  test_apt_get_lock_timeout
  test_installer_hold_status_and_downstream_flow
  test_real_debian12_dpkg_lock_container
  test_updater_full_regression_flow
  test_static_safety_guards
  printf '[PASS] %s 组 SmartDNS 离线测试全部通过。\n' "$TESTS_RUN"
}

main "$@"
