#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly TEST_DIR
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd)
readonly REPO_ROOT
readonly DOMAIN_CHECK_SCRIPT="$REPO_ROOT/domain-check.sh"
readonly WORKFLOW_FILE="$REPO_ROOT/.github/workflows/shellcheck.yml"

export DOMAIN_CHECK_SOURCE_ONLY=1
# The path is anchored to this test file, rather than the caller's directory.
# shellcheck disable=SC1090
source "$DOMAIN_CHECK_SCRIPT"

TEST_COUNT=0
EXTRACTOR_TEST_NUMBER=0
TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/domain-check-tests.XXXXXXXX")
readonly TEST_TEMP_DIR

cleanup_test_files() {
  if [[ -n "$TEST_TEMP_DIR" && "$TEST_TEMP_DIR" == /* &&
    -d "$TEST_TEMP_DIR" ]]; then
    rm -rf -- "$TEST_TEMP_DIR"
  fi
}

trap cleanup_test_files EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_equal() {
  local expected=$1
  local actual=$2
  local description=$3
  (( TEST_COUNT += 1 ))
  [[ "$actual" == "$expected" ]] ||
    fail "$description: expected [$expected], got [$actual]"
}

assert_contains() {
  local expected=$1
  local actual=$2
  local description=$3
  (( TEST_COUNT += 1 ))
  [[ "$actual" == *"$expected"* ]] ||
    fail "$description: missing [$expected]"
}

assert_not_contains() {
  local unexpected=$1
  local actual=$2
  local description=$3
  (( TEST_COUNT += 1 ))
  [[ "$actual" != *"$unexpected"* ]] ||
    fail "$description: unexpectedly contained [$unexpected]"
}

assert_file_contains() {
  local expected=$1
  local file=$2
  local description=$3
  (( TEST_COUNT += 1 ))
  grep -Fq -- "$expected" "$file" ||
    fail "$description: missing [$expected] in $file"
}

assert_extractor() {
  local extractor=$1
  local input=$2
  local expected=$3
  local description=$4
  local input_file
  local actual

  (( EXTRACTOR_TEST_NUMBER += 1 ))
  input_file="$TEST_TEMP_DIR/extractor-$EXTRACTOR_TEST_NUMBER"
  printf '%s' "$input" >"$input_file"
  actual=$("$extractor" "$input_file")
  assert_equal "$expected" "$actual" "$description"
}

assert_parse() {
  local input=$1
  local expected=$2
  local actual
  parse_domain_argument "$input" || fail "valid input rejected: $input"
  actual=$(IFS='/'; printf '%s' "${DOMAIN_INPUTS[*]}")
  assert_equal "$expected" "$actual" "parse $input"
}

assert_invalid() {
  local input=$1
  (( TEST_COUNT += 1 ))
  if parse_domain_argument "$input"; then
    fail "invalid input accepted: $input"
  fi
}

assert_redirect() {
  local domain=$1
  local location=$2
  local expected=$3
  classify_redirect "$domain" "$location"
  assert_equal "$expected" "$REDIRECT_STATUS" \
    "redirect $domain -> $location"
}

assert_redirect_code() {
  local domain=$1
  local location=$2
  local expected=$3
  classify_redirect "$domain" "$location"
  assert_equal "$expected" "$REDIRECT_CODE" \
    "redirect code $domain -> ${location:--}"
}

assert_aggregate() {
  local expected=$1
  shift
  local actual
  if aggregate_exit_code "$@"; then
    actual=0
  else
    actual=$?
  fi
  assert_equal "$expected" "$actual" "aggregate $*"
}

assert_argument_error() {
  local output
  local status
  set +e
  output=$(DOMAIN_CHECK_SOURCE_ONLY=0 bash "$DOMAIN_CHECK_SCRIPT" "$@" 2>&1)
  status=$?
  set -e
  assert_equal '2' "$status" "argument error exit code: $*"
  assert_equal "$USAGE_TEXT" "$output" "argument error usage: $*"
}

assert_repository_has_no_legacy_strings() {
  local legacy_name
  local legacy_command
  legacy_name='Reality''Checker'
  legacy_command='reality''-checker'
  (( TEST_COUNT += 1 ))
  if grep -RniE --exclude-dir=.git \
    "${legacy_name}|${legacy_command}|V2RaySSR/${legacy_name}" \
    "$REPO_ROOT" >/dev/null; then
    fail 'repository contains a legacy project or command string'
  fi
}

assert_parse 'example.com' 'example.com'
assert_parse 'example.com/test.com' 'example.com/test.com'
assert_parse 'EXAMPLE.COM/Test.COM' 'example.com/test.com'
assert_parse 'example.com/example.com/test.com' 'example.com/test.com'

assert_extractor first_ipv4_from_file $'1.2.3.4\n' \
  '1.2.3.4' 'IPv4 extractor accepts a valid address'
assert_extractor first_ipv4_from_file $'255.255.255.255\n' \
  '255.255.255.255' 'IPv4 extractor accepts maximum octets'
assert_extractor first_ipv4_from_file $'256.1.1.1\n' \
  '' 'IPv4 extractor rejects an octet above 255'
assert_extractor first_ipv4_from_file $'1.2.3\n' \
  '' 'IPv4 extractor rejects a short address'
assert_extractor first_ipv4_from_file \
  $'1.2.3.4 STREAM example.com\n1.2.3.4 DGRAM\n1.2.3.4 RAW\n' \
  '1.2.3.4' 'IPv4 extractor accepts getent output'
assert_extractor first_ipv4_from_file \
  $'invalid\n999.1.1.1\n8.8.8.8 STREAM example.com\n1.1.1.1 STREAM example.com\n' \
  '8.8.8.8' 'IPv4 extractor returns the first valid mixed result'
assert_extractor first_ipv6_from_file \
  $'2001:db8::1 STREAM example.com\n' \
  '2001:db8::1' 'IPv6 extractor accepts getent output'
assert_extractor extract_http_code $'000\n301\n200\n' \
  '200' 'HTTP extractor returns the final status'
assert_extractor extract_location \
  $'Location: https://example.com/test\r\n' \
  'https://example.com/test' 'Location extractor handles uppercase and CRLF'
assert_extractor extract_location $'location: /login\r\n' \
  '/login' 'Location extractor handles lowercase and CRLF'

for invalid in \
  'https://example.com' \
  'http://example.com' \
  'example.com:443' \
  'example.com/path' \
  '/example.com' \
  'example.com/' \
  'example.com//test.com' \
  '*.example.com' \
  '1.1.1.1' \
  '2001:db8::1' \
  'example..com' \
  '-example.com' \
  'example-.com' \
  'example.com?query=1' \
  'example.com#fragment' \
  'user@example.com' \
  'example .com'; do
  assert_invalid "$invalid"
done

assert_argument_error
assert_argument_error 'example.com' 'test.com'

assert_redirect 'example.com' 'https://www.example.com/' 'WARN'
assert_redirect 'www.example.com' 'https://example.com/' 'WARN'
assert_redirect 'example.com' '/login' 'WARN'
assert_redirect 'example.com' 'https://example.com/login' 'WARN'
assert_redirect 'example.com' 'https://test.com/' 'FAIL'
assert_redirect 'example.com' 'http://example.com/' 'FAIL'
assert_redirect 'example.com' 'https://login.example.com/' 'FAIL'

assert_redirect_code 'example.com' '' '-'
assert_redirect_code 'example.com' 'https://www.example.com/' 'WWW'
assert_redirect_code 'example.com' 'https://example.com/login' 'SAME'
assert_redirect_code 'example.com' '/login' 'RELATIVE'
assert_redirect_code 'example.com' 'https://test.com/' 'CROSS'
assert_redirect_code 'example.com' 'http://example.com/' 'HTTP'
assert_redirect_code 'example.com' 'https://bad host/' 'INVALID'
analyze_http_redirect 'example.com' true 301 ''
assert_equal 'NO-LOC' "$REDIRECT_CODE" \
  'redirect status without Location uses NO-LOC'

assert_aggregate 0 PASS PASS
assert_aggregate 0 PASS WARN
assert_aggregate 0 WARN WARN
assert_aggregate 1 PASS FAIL
assert_aggregate 1 WARN FAIL

reset_http_retry_state
record_http_attempt 1 true 500 'https://other.example/'
assert_equal 'true' "$HTTP_SHOULD_RETRY" 'first 5xx retries'
record_http_attempt 2 true 200 ''
assert_equal 'true' "$HTTP_REQUEST_OK" 'second 200 is final response'
assert_equal '200' "$HTTP_STATUS" 'second 200 replaces first 500'
assert_equal '200' "$HTTP_CODE" 'second response code is retained'
assert_equal '' "$HTTP_LOCATION" 'second response clears old Location'
analyze_http_redirect \
  'example.com' "$HTTP_REQUEST_OK" "$HTTP_STATUS" "$HTTP_LOCATION"
assert_equal 'PASS' "$REDIRECT_STATUS" \
  'old cross-host Location does not affect final 200'

reset_http_retry_state
record_http_attempt 1 true 500 'https://first.example/'
record_http_attempt 2 true 503 'https://second.example/'
record_http_attempt 3 false '-' ''
assert_equal 'false' "$HTTP_REQUEST_OK" 'third-attempt failure is final'
assert_equal '-' "$HTTP_STATUS" 'third-attempt failure clears old status'
assert_equal '' "$HTTP_CODE" 'third-attempt failure clears old code'
assert_equal '' "$HTTP_LOCATION" 'third-attempt failure clears old Location'
assert_equal '2' "$HTTP_5XX_COUNT" 'failed third attempt is not a third 5xx'
analyze_http_redirect \
  'example.com' "$HTTP_REQUEST_OK" "$HTTP_STATUS" "$HTTP_LOCATION"
assert_equal 'PASS' "$REDIRECT_STATUS" \
  'failed final attempt does not analyze an old Location'
classify_http_result "$HTTP_REQUEST_OK" "$HTTP_STATUS" "$HTTP_5XX_COUNT"
assert_equal 'WARN' "$HTTP_RESULT_STATUS" 'final HTTP failure warns'
assert_equal 'HTTP 请求失败' "$HTTP_RESULT_REASON" \
  'failed third attempt is not reported as three 5xx responses'

reset_http_retry_state
record_http_attempt 1 true 500 ''
record_http_attempt 2 true 503 ''
record_http_attempt 3 true 502 ''
assert_equal 'true' "$HTTP_REQUEST_OK" 'third 5xx is a valid final response'
assert_equal '502' "$HTTP_STATUS" 'third 5xx status is displayed'
assert_equal '3' "$HTTP_5XX_COUNT" 'three 5xx responses are aggregated'
assert_equal 'false' "$HTTP_SHOULD_RETRY" 'third 5xx stops retrying'
classify_http_result "$HTTP_REQUEST_OK" "$HTTP_STATUS" "$HTTP_5XX_COUNT"
assert_equal 'WARN' "$HTTP_RESULT_STATUS" 'three 5xx responses warn'
assert_equal 'HTTP 502（连续 3 次 5xx）' "$HTTP_RESULT_REASON" \
  'three 5xx responses use the third status and aggregate reason'

assert_file_contains "--noproxy '*'" "$DOMAIN_CHECK_SCRIPT" \
  'curl explicitly bypasses environment proxies'

# The sed range intentionally matches the literal shell variable syntax.
# shellcheck disable=SC2016
x25519_block=$(sed -n \
  '/if run_network_command "$x25519_file"/,/x25519_command_ok=true/p' \
  "$DOMAIN_CHECK_SCRIPT")
assert_contains '-tls1_3 -groups X25519' "$x25519_block" \
  'X25519 handshake forces the expected group'
assert_not_contains '-verify_hostname' "$x25519_block" \
  'X25519 handshake does not perform hostname verification'
assert_not_contains '-verify_return_error' "$x25519_block" \
  'X25519 handshake does not fail on certificate verification'

executable_mode_block=$(sed -n \
  '/for executable_script in/,/done/p' "$WORKFLOW_FILE")
assert_contains 'domain-check.sh' "$executable_mode_block" \
  'CI checks the domain tool executable bit'
assert_contains 'tests/domain-check-test.sh' "$executable_mode_block" \
  'CI checks the offline test executable bit'
assert_contains 'scripts/update-smartdns.sh' "$executable_mode_block" \
  'CI checks the standalone SmartDNS updater executable bit'
assert_contains 'tests/smartdns-test.sh' "$executable_mode_block" \
  'CI checks the SmartDNS offline test executable bit'
assert_not_contains '404notfound.sh' "$executable_mode_block" \
  'CI does not require the installer executable bit'
assert_not_contains 'request-cloudflare-certificate.sh' "$executable_mode_block" \
  'CI does not require the certificate tool executable bit'

domain_mode=$(git -C "$REPO_ROOT" ls-files --stage domain-check.sh |
  awk 'NR == 1 { print $1 }')
test_mode=$(git -C "$REPO_ROOT" ls-files --stage tests/domain-check-test.sh |
  awk 'NR == 1 { print $1 }')
assert_equal '100755' "$domain_mode" 'domain-check.sh Git mode'
assert_equal '100755' "$test_mode" 'offline test Git mode'
assert_repository_has_no_legacy_strings

assert_equal '32' "$(color_for_status PASS)" 'PASS color is green'
assert_equal '33' "$(color_for_status WARN)" 'WARN color is yellow'
assert_equal '31' "$(color_for_status FAIL)" 'FAIL color is red'
assert_equal '32' "$(color_for_http 200)" 'HTTP 2xx color is green'
assert_equal '36' "$(color_for_http 301)" 'HTTP 3xx color is cyan'
assert_equal '33' "$(color_for_http 403)" 'HTTP 4xx color is yellow'
assert_equal '31' "$(color_for_http 500)" 'HTTP 5xx color is red'
assert_equal '90' "$(color_for_redirect -)" \
  'no-redirect color is dark gray'
assert_equal '33' "$(color_for_redirect WWW)" \
  'www redirect color is yellow'
assert_equal '31' "$(color_for_redirect CROSS)" \
  'cross-host redirect color is red'

long_domain='this-is-a-very-long-domain-name-that-exceeds-forty-eight-characters.example.com'
ipv6_address='2001:0db8:85a3:0000:0000:8a2e:0370:7334'
truncated_domain=$(truncate_ascii "$long_domain" 48)
assert_equal '48' "${#truncated_domain}" 'long domain is capped at 48 columns'
assert_equal '...' "${truncated_domain: -3}" \
  'long domain uses three ASCII dots'

TEMP_DIR="$TEST_TEMP_DIR"
DOMAIN_INPUTS=("$long_domain" 'second.example.com')
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$long_domain" "$ipv6_address" PASS PASS PASS 125 PASS 200 - PASS - \
  >"$TEMP_DIR/result-0"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  'second.example.com' '1.2.3.4' PASS PASS PASS 25 PASS 301 WWW WARN - \
  >"$TEMP_DIR/result-1"

NO_COLOR=1
export NO_COLOR
initialize_output_style
table_output=$(print_results)
unset NO_COLOR
assert_not_contains $'\033[' "$table_output" \
  'NO_COLOR table output contains no ANSI escapes'
assert_contains "$truncated_domain" "$table_output" \
  'table displays the truncated long domain'
assert_contains "$ipv6_address" "$table_output" \
  'table preserves the complete IPv6 address'
assert_not_contains '┌' "$table_output" \
  'non-TTY table uses ASCII borders'

mapfile -t table_lines <<<"$table_output"
assert_equal '6' "${#table_lines[@]}" \
  'two-row table has borders, header, separator, and data rows'
table_line_width=${#table_lines[0]}
for table_line in "${table_lines[@]}"; do
  assert_equal "$table_line_width" "${#table_line}" \
    'all main table lines have equal width'
done
assert_contains "$truncated_domain" \
  "${table_output%%second.example.com*}" \
  'table preserves input order'

export COLOR_ENABLED=true
NO_COLOR=1
export NO_COLOR
initialize_colors
no_color_cell=$(print_colored_cell PASS 6 32)
unset NO_COLOR
assert_not_contains $'\033[' "$no_color_cell" \
  'NO_COLOR disables cell ANSI escapes'

non_tty_cell=$(
  initialize_colors
  print_colored_cell WARN 6 33
)
assert_not_contains $'\033[' "$non_tty_cell" \
  'non-TTY output disables cell ANSI escapes'

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  'second.example.com' '1.2.3.4' PASS PASS PASS 25 PASS 301 WWW WARN \
  '跳转：www 切换' >"$TEMP_DIR/result-1"
details_output=$(print_results)
assert_contains 'DETAILS' "$details_output" 'details section is shown when needed'
assert_contains 'second.example.com: 跳转：www 切换' "$details_output" \
  'details section includes the domain and reason'

printf 'PASS: %d offline assertions\n' "$TEST_COUNT"
