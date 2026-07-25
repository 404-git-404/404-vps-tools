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
  ((TESTS_RUN += 1))
  log '下载、元数据、配置验证、hold 和失败恢复静态安全检查通过。'
}

main() {
  TMP_DIR=$(mktemp -d)
  test_fixed_mapping
  test_configurations
  test_retry_logic
  test_static_safety_guards
  printf '[PASS] %s 组 SmartDNS 离线测试全部通过。\n' "$TESTS_RUN"
}

main "$@"
