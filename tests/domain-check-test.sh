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

assert_file_not_contains() {
  local unexpected=$1
  local file=$2
  local description=$3
  (( TEST_COUNT += 1 ))
  if grep -Fq -- "$unexpected" "$file"; then
    fail "$description: unexpectedly contained [$unexpected] in $file"
  fi
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
metrics_file="$TEST_TEMP_DIR/curl-metrics"
printf 'DOMAIN_CHECK_METRICS\t200\t0.005\t0.0126\n' >"$metrics_file"
assert_equal '0.005' "$(extract_curl_metric "$metrics_file" 3)" \
  'time_connect is parsed from curl write-out'
assert_equal '0.0126' "$(extract_curl_metric "$metrics_file" 4)" \
  'time_appconnect is parsed from curl write-out'

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
assert_redirect 'example.com' 'https://test.com/' 'WARN'
assert_redirect 'example.com' 'http://example.com/' 'WARN'
assert_redirect 'example.com' 'https://login.example.com/' 'WARN'

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
assert_equal 'false' "$HTTP_FINALIZED" 'first 5xx keeps HTTP selection open'
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
assert_equal 'true' "$HTTP_FINALIZED" 'third 5xx finalizes HTTP selection'
classify_http_result "$HTTP_REQUEST_OK" "$HTTP_STATUS" "$HTTP_5XX_COUNT"
assert_equal 'WARN' "$HTTP_RESULT_STATUS" 'three 5xx responses warn'
assert_equal 'HTTP 502（连续 3 次 5xx）' "$HTTP_RESULT_REASON" \
  'three 5xx responses use the third status and aggregate reason'

reset_http_retry_state
record_http_attempt 1 true 200 '' '/tmp/final-header'
record_http_attempt 2 true 500 'https://stale.example/' '/tmp/stale-header'
record_http_attempt 3 false '-' '' ''
assert_equal '200' "$HTTP_STATUS" \
  'first non-5xx HTTP response cannot be overwritten by later samples'
assert_equal '' "$HTTP_LOCATION" \
  'later sampling cannot introduce a stale redirect'
assert_equal '/tmp/final-header' "$HTTP_HEADER_FILE" \
  'only the final valid HTTP response header is retained'

assert_equal '13' "$(seconds_to_milliseconds 0.0126)" \
  'curl seconds are rounded to milliseconds'
assert_equal '0' "$(seconds_to_milliseconds 0.0004)" \
  'sub-millisecond curl timing rounds to zero'
aggregate_handshake_samples 10 30 20
assert_equal '3' "$HANDSHAKE_SAMPLE_COUNT" 'three timing samples are counted'
assert_equal '20' "$HANDSHAKE_MS" 'three timing samples use the median'
aggregate_handshake_samples 10 21
assert_equal '2' "$HANDSHAKE_SAMPLE_COUNT" 'two timing samples are counted'
assert_equal '16' "$HANDSHAKE_MS" 'two timing samples use the rounded average'
aggregate_handshake_samples 17
assert_equal '1' "$HANDSHAKE_SAMPLE_COUNT" 'one timing sample is counted'
assert_equal '17' "$HANDSHAKE_MS" 'one timing sample is displayed directly'
aggregate_handshake_samples
assert_equal '0' "$HANDSHAKE_SAMPLE_COUNT" 'zero timing samples are counted'
assert_equal '-' "$HANDSHAKE_MS" 'zero timing samples display a dash'

assert_equal '203.0.113.10:443' \
  "$(openssl_target_for_ip 203.0.113.10)" \
  'OpenSSL IPv4 target is fixed'
assert_equal '[2001:db8::10]:443' \
  "$(openssl_target_for_ip 2001:db8::10)" \
  'OpenSSL IPv6 target uses brackets'
assert_equal 'example.com:443:203.0.113.10' \
  "$(curl_resolve_for_ip example.com 203.0.113.10)" \
  'curl IPv4 resolve entry is fixed'
assert_equal 'example.com:443:[2001:db8::10]' \
  "$(curl_resolve_for_ip example.com 2001:db8::10)" \
  'curl IPv6 resolve entry uses brackets'

evaluate_certificate_expiry $(( 1000000 + 31 * 86400 )) 1000000
assert_equal '31' "$CERTIFICATE_DAYS" '31 certificate days are green-range data'
assert_equal '' "$CERTIFICATE_WARNING" '31 certificate days do not warn'
evaluate_certificate_expiry $(( 1000000 + 30 * 86400 )) 1000000
assert_equal '30' "$CERTIFICATE_DAYS" '30 certificate days are retained'
assert_equal '' "$CERTIFICATE_WARNING" '30 certificate days do not warn'
evaluate_certificate_expiry $(( 1000000 + 8 * 86400 )) 1000000
assert_equal '8' "$CERTIFICATE_DAYS" '8 certificate days are retained'
assert_equal '' "$CERTIFICATE_WARNING" '8 certificate days do not warn'
evaluate_certificate_expiry $(( 1000000 + 7 * 86400 )) 1000000
assert_equal '7' "$CERTIFICATE_DAYS" '7 certificate days are retained'
assert_contains '仅剩 7' "$CERTIFICATE_WARNING" \
  '7 certificate days produce a warning'
evaluate_certificate_expiry 1000000 1000000
assert_equal '0' "$CERTIFICATE_DAYS" 'same-day expiry displays zero days'
assert_contains '仅剩 0' "$CERTIFICATE_WARNING" \
  'same-day expiry produces a warning'
evaluate_certificate_expiry 999999 1000000
assert_equal 'FAIL' "$CERTIFICATE_EXPIRY_STATUS" \
  'expired certificate is a hard failure'
assert_equal 'FAIL' "$CERTIFICATE_DAYS" \
  'expired certificate displays failure instead of remaining days'
assert_equal '证书已过期' "$CERTIFICATE_WARNING" \
  'expired certificate has an explicit reason'
evaluate_certificate_expiry
assert_equal '-' "$CERTIFICATE_DAYS" \
  'verified certificate without expiry displays a dash'
assert_contains '无法提取到期日' "$CERTIFICATE_WARNING" \
  'verified certificate without expiry warns'

cdn_header_file="$TEST_TEMP_DIR/cdn-headers"
printf 'CF-Ray: abc-SIN\r\n' >"$cdn_header_file"
detect_cdn '' "$cdn_header_file"
assert_equal 'HIGH' "$CDN_STATUS" 'CF-Ray is high-confidence Cloudflare'
assert_contains 'Cloudflare' "$CDN_DETAIL" 'Cloudflare evidence is explained'
printf 'x-amz-cf-pop: SIN2-P1\r\n' >"$cdn_header_file"
detect_cdn '' "$cdn_header_file"
assert_equal 'HIGH' "$CDN_STATUS" 'CloudFront header is high confidence'
printf 'x-akamai-transformed: 9 0 pmb=mRUM,2\r\n' >"$cdn_header_file"
detect_cdn '' "$cdn_header_file"
assert_equal 'HIGH' "$CDN_STATUS" 'Akamai header is high confidence'
printf 'x-azure-ref: ref\r\n' >"$cdn_header_file"
detect_cdn '' "$cdn_header_file"
assert_equal 'HIGH' "$CDN_STATUS" 'Azure header is high confidence'
printf 'x-served-by: cache-sin\r\nx-cache: HIT\r\n' >"$cdn_header_file"
detect_cdn '' "$cdn_header_file"
assert_equal 'HIGH' "$CDN_STATUS" 'Fastly header combination is high confidence'
printf 'x-served-by: cache-sin\r\n' >"$cdn_header_file"
detect_cdn '' "$cdn_header_file"
assert_equal 'MED' "$CDN_STATUS" 'single Fastly-specific header is medium confidence'
printf 'Via: 1.1 proxy\r\nX-Cache: HIT\r\n' >"$cdn_header_file"
detect_cdn '' "$cdn_header_file"
assert_equal 'MED' "$CDN_STATUS" 'generic cache header combination is medium confidence'
printf 'Via: 1.1 proxy\r\n' >"$cdn_header_file"
detect_cdn '' "$cdn_header_file"
assert_equal '-' "$CDN_STATUS" 'single Via header is not CDN evidence'
printf 'X-Cache: HIT\r\n' >"$cdn_header_file"
detect_cdn '' "$cdn_header_file"
assert_equal '-' "$CDN_STATUS" 'single X-Cache header is not CDN evidence'
printf 'Server: nginx\r\n' >"$cdn_header_file"
detect_cdn '' "$cdn_header_file"
assert_equal '-' "$CDN_STATUS" 'generic Server header is not CDN evidence'
printf '%s\r\n' \
  'NS: ns1.cloudflare.com' \
  "Issuer: Let's Encrypt" \
  'Server: AmazonS3' >"$cdn_header_file"
detect_cdn '' "$cdn_header_file"
assert_equal '-' "$CDN_STATUS" \
  'NS, certificate issuer, and generic Server do not imply CDN'
detect_cdn 'asset.cloudfront.net' "$cdn_header_file"
assert_equal 'HIGH' "$CDN_STATUS" 'CloudFront CNAME is high confidence'
detect_cdn 'edge.fastly.net' "$cdn_header_file"
assert_equal 'HIGH' "$CDN_STATUS" 'Fastly CNAME is high confidence'

assert_file_contains "--noproxy '*'" "$DOMAIN_CHECK_SCRIPT" \
  'curl explicitly bypasses environment proxies'
literal_curl_resolve="--resolve \"\$curl_resolve\""
literal_openssl_target="-connect \"\$openssl_target\""
assert_file_contains "$literal_curl_resolve" "$DOMAIN_CHECK_SCRIPT" \
  'curl pins every connection to the selected address'
assert_file_contains "$literal_openssl_target" "$DOMAIN_CHECK_SCRIPT" \
  'OpenSSL connects to the selected address'
assert_file_not_contains '/dev/tcp' "$DOMAIN_CHECK_SCRIPT" \
  'the separate Bash TCP probe was removed'
assert_file_not_contains 'EPOCHREALTIME' "$DOMAIN_CHECK_SCRIPT" \
  'OpenSSL wall-clock timing was removed'
assert_file_not_contains 'DOMAIN_CHECK_SAMPLE' "$DOMAIN_CHECK_SCRIPT" \
  'there is no environment variable for changing sample count'
assert_file_not_contains 'TLS_SAMPLES' "$DOMAIN_CHECK_SCRIPT" \
  'there is no alternate TLS sample-count control'
assert_equal '8' "$MAX_CONCURRENCY" 'worker concurrency remains capped at eight'
assert_file_contains 'trap handle_interrupt INT TERM' "$DOMAIN_CHECK_SCRIPT" \
  'worker signal cleanup path remains installed'
assert_file_contains 'terminate_workers' "$DOMAIN_CHECK_SCRIPT" \
  'worker termination cleanup remains available'

# The sed range intentionally matches the literal shell variable syntax.
# shellcheck disable=SC2016
x25519_block=$(sed -n \
  '/run_network_command "$x25519_file"/,/-tls1_3 -groups X25519 || :/p' \
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
assert_equal '33' "$(color_for_redirect CROSS)" \
  'cross-host redirect color is yellow'
assert_equal '32' "$(color_for_certificate_days 31)" \
  'certificate with at least 31 days is green'
assert_equal '33' "$(color_for_certificate_days 30)" \
  'certificate with 8-30 days is yellow'
assert_equal '31' "$(color_for_certificate_days 7)" \
  'certificate with 0-7 days is red'

long_domain='this-is-a-very-long-domain-name-that-exceeds-forty-eight-characters.example.com'
ipv6_address='2001:0db8:85a3:0000:0000:8a2e:0370:7334'
truncated_domain=$(truncate_ascii "$long_domain" 48)
assert_equal '48' "${#truncated_domain}" 'long domain is capped at 48 columns'
assert_equal '...' "${truncated_domain: -3}" \
  'long domain uses three ASCII dots'

TEMP_DIR="$TEST_TEMP_DIR"
DOMAIN_INPUTS=("$long_domain" 'second.example.com')
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$long_domain" "$ipv6_address" PASS PASS PASS 125 45 HIGH 200 - PASS - \
  >"$TEMP_DIR/result-0"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  'second.example.com' '1.2.3.4' PASS PASS PASS 25 20 - 301 WWW WARN - \
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
assert_contains 'HS(ms)' "$table_output" \
  'table uses the curl handshake timing header'
assert_contains 'CERT(d)' "$table_output" \
  'table displays certificate remaining days'
assert_contains 'CDN' "$table_output" \
  'table includes the informational CDN column'
assert_not_contains '┌' "$table_output" \
  'non-TTY table uses ASCII borders'

mapfile -t table_lines <<<"$table_output"
table_header_order=$(IFS=' '; printf '%s' "${TABLE_HEADERS[*]}")
assert_equal \
  'DOMAIN IP TLS1.3 X25519 H2 HS(ms) CERT(d) CDN HTTP REDIRECT RESULT' \
  "$table_header_order" 'table header order is exact'
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

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  'second.example.com' '1.2.3.4' PASS PASS PASS 25 20 - 301 WWW WARN \
  '跳转：www 切换' >"$TEMP_DIR/result-1"
details_output=$(print_results)
assert_contains 'DETAILS' "$details_output" 'details section is shown when needed'
assert_contains 'second.example.com: 跳转：www 切换' "$details_output" \
  'details section includes the domain and reason'
mapfile -t details_lines <<<"$details_output"
assert_equal "${#details_lines[0]}" \
  "${#details_lines[${#details_lines[@]} - 1]}" \
  'DETAILS bottom border matches the main table width'

MOCK_BIN="$TEST_TEMP_DIR/mock-bin"
MOCK_LOG_DIR="$TEST_TEMP_DIR/mock-log"
mkdir -p "$MOCK_BIN" "$MOCK_LOG_DIR"

cat >"$MOCK_BIN/timeout" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
while (( $# > 0 )) && [[ "$1" == --* ]]; do
  shift
done
[[ ${1:-} =~ ^[0-9]+$ ]] && shift
printf '<%s>' "$@" >>"$MOCK_LOG_DIR/timeout.log"
printf '\n' >>"$MOCK_LOG_DIR/timeout.log"
"$@"
EOF

cat >"$MOCK_BIN/dig" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '<%s>' "$@" >>"$MOCK_LOG_DIR/dig.log"
printf '\n' >>"$MOCK_LOG_DIR/dig.log"
if [[ ${MOCK_DNS_FAIL:-0} == 1 ]]; then
  exit 1
fi
case " $* " in
  *' A '*) printf '%s\n' '203.0.113.10' ;;
  *' AAAA '*) printf '%s\n' '2001:db8::10' ;;
  *' CNAME '*) [[ -z ${MOCK_CNAME:-} ]] || printf '%s\n' "$MOCK_CNAME" ;;
esac
EOF

cat >"$MOCK_BIN/getent" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exit 1
EOF

cat >"$MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
counter_file="$MOCK_LOG_DIR/curl.count"
counter=$(<"$counter_file")
counter=$(( counter + 1 ))
printf '%s\n' "$counter" >"$counter_file"
printf '<%s>' "$@" >>"$MOCK_LOG_DIR/curl.log"
printf '\n' >>"$MOCK_LOG_DIR/curl.log"

header_file=''
while (( $# > 0 )); do
  case "$1" in
    --dump-header)
      shift
      header_file=$1
      ;;
  esac
  shift
done

IFS='|' read -r -a codes <<<"$MOCK_HTTP_CODES"
IFS='|' read -r -a connect_times <<<"$MOCK_CONNECT_TIMES"
IFS='|' read -r -a appconnect_times <<<"$MOCK_APPCONNECT_TIMES"
IFS='|' read -r -a exit_codes <<<"$MOCK_CURL_EXITS"
IFS='|' read -r -a locations <<<"$MOCK_LOCATIONS"
code=${codes[counter - 1]:-000}
connect_time=${connect_times[counter - 1]:-0}
appconnect_time=${appconnect_times[counter - 1]:-0}
exit_code=${exit_codes[counter - 1]:-0}
location=${locations[counter - 1]:-}

: >"$header_file"
printf 'HTTP/1.1 %s Mock\r\n' "$code" >>"$header_file"
[[ -z "$location" ]] ||
  printf 'Location: %s\r\n' "$location" >>"$header_file"
[[ -z ${MOCK_RESPONSE_HEADER:-} ]] ||
  printf '%b\r\n' "$MOCK_RESPONSE_HEADER" >>"$header_file"
printf '\r\n' >>"$header_file"
printf 'DOMAIN_CHECK_METRICS\t%s\t%s\t%s\n' \
  "$code" "$connect_time" "$appconnect_time"
exit "$exit_code"
EOF

cat >"$MOCK_BIN/openssl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ${1:-} == x509 ]]; then
  printf 'notAfter=Aug 30 00:00:00 2026 GMT\n'
  exit 0
fi

printf '<%s>' "$@" >>"$MOCK_LOG_DIR/openssl.log"
printf '\n' >>"$MOCK_LOG_DIR/openssl.log"
if [[ " $* " == *' -groups X25519 '* ]]; then
  if [[ ${MOCK_X25519_COMPLETE:-1} == 1 ]]; then
    printf '%s\n' \
      'Protocol  : TLSv1.3' \
      'Peer Temp Key: X25519, 253 bits'
  else
    printf '%s\n' 'CONNECTED'
  fi
  exit "${MOCK_X25519_EXIT:-1}"
fi

if [[ ${MOCK_NORMAL_COMPLETE:-1} == 1 ]]; then
  printf '%s\n' \
    'Protocol  : TLSv1.3' \
    'ALPN protocol: h2' \
    '-----BEGIN CERTIFICATE-----' \
    'offline-fixture' \
    '-----END CERTIFICATE-----' \
    'Verify return code: 0 (ok)'
else
  printf '%s\n' 'CONNECTED'
fi
exit "${MOCK_NORMAL_EXIT:-1}"
EOF

cat >"$MOCK_BIN/date" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '<%s>' "$@" >>"$MOCK_LOG_DIR/date.log"
printf '\n' >>"$MOCK_LOG_DIR/date.log"
if [[ " $* " == *' -d '* ]]; then
  printf '%s\n' "${MOCK_EXPIRY_EPOCH:-2000000000}"
else
  printf '%s\n' "${MOCK_CURRENT_EPOCH:-1900000000}"
fi
EOF

chmod +x "$MOCK_BIN"/*

run_mocked_domain_check() {
  local codes=$1
  local appconnect_times=$2
  local curl_exits=$3
  local locations=$4
  local normal_complete=${5:-1}
  local response_header=${6:-}
  local connect_times=${7:-0.005|0.006|0.007}
  local x25519_complete=${8:-1}
  local dns_fail=${9:-0}
  local expiry_epoch=${10:-2000000000}
  local current_epoch=${11:-1900000000}

  mkdir -p "$TEST_TEMP_DIR/worker-tmp"
  printf '0\n' >"$MOCK_LOG_DIR/curl.count"
  : >"$MOCK_LOG_DIR/curl.log"
  : >"$MOCK_LOG_DIR/openssl.log"
  : >"$MOCK_LOG_DIR/timeout.log"
  : >"$MOCK_LOG_DIR/dig.log"
  : >"$MOCK_LOG_DIR/date.log"
  set +e
  MOCK_RUN_OUTPUT=$(
    PATH="$MOCK_BIN:$PATH" \
      MOCK_LOG_DIR="$MOCK_LOG_DIR" \
      MOCK_HTTP_CODES="$codes" \
      MOCK_CONNECT_TIMES="$connect_times" \
      MOCK_APPCONNECT_TIMES="$appconnect_times" \
      MOCK_CURL_EXITS="$curl_exits" \
      MOCK_LOCATIONS="$locations" \
      MOCK_NORMAL_COMPLETE="$normal_complete" \
      MOCK_X25519_COMPLETE="$x25519_complete" \
      MOCK_DNS_FAIL="$dns_fail" \
      MOCK_NORMAL_EXIT=1 \
      MOCK_X25519_EXIT=1 \
      MOCK_RESPONSE_HEADER="$response_header" \
      MOCK_EXPIRY_EPOCH="$expiry_epoch" \
      MOCK_CURRENT_EPOCH="$current_epoch" \
      TMPDIR="$TEST_TEMP_DIR/worker-tmp" \
      DOMAIN_CHECK_SOURCE_ONLY=0 \
      bash "$DOMAIN_CHECK_SCRIPT" example.com 2>&1
  )
  MOCK_RUN_STATUS=$?
  set -e
}

run_mocked_domain_check \
  '500|200|503' \
  '0.010|0.030|0.020' \
  '0|0|0' \
  'https://other.example/||https://later.example/' \
  1 \
  'CF-Ray: offline-SIN'
assert_equal '0' "$MOCK_RUN_STATUS" \
  'complete parsed OpenSSL evidence succeeds despite nonzero command exits'
assert_equal '3' "$(<"$MOCK_LOG_DIR/curl.count")" \
  'worker always completes exactly three curl connections'
assert_contains 'HS(ms)' "$MOCK_RUN_OUTPUT" \
  'high-fidelity worker output uses the handshake header'
assert_contains '20' "$MOCK_RUN_OUTPUT" \
  'worker displays the median of three curl TLS timings'
assert_contains '200' "$MOCK_RUN_OUTPUT" \
  'first non-5xx HTTP response remains final'
assert_not_contains 'CROSS' "$MOCK_RUN_OUTPUT" \
  'old or later Location headers do not affect the final HTTP result'
assert_contains 'HIGH' "$MOCK_RUN_OUTPUT" \
  'CDN evidence is displayed without causing failure'
assert_contains 'Cloudflare' "$MOCK_RUN_OUTPUT" \
  'CDN provider and evidence appear in DETAILS'
assert_contains 'CDN HIGH: Cloudflare（CF-Ray）' "$MOCK_RUN_OUTPUT" \
  'DETAILS identifies the exact CDN evidence'
assert_contains '1157' "$MOCK_RUN_OUTPUT" \
  'high-fidelity worker displays calculated certificate days'
assert_contains '203.0.113.10' "$MOCK_RUN_OUTPUT" \
  'table IP matches the address used by every network command'
assert_contains 'PASS' "$MOCK_RUN_OUTPUT" \
  'CDN HIGH does not change an otherwise passing result'

openssl_log=$(<"$MOCK_LOG_DIR/openssl.log")
timeout_log=$(<"$MOCK_LOG_DIR/timeout.log")
assert_equal '3' \
  "$(grep -Fc '<--resolve><example.com:443:203.0.113.10>' \
    "$MOCK_LOG_DIR/curl.log")" \
  'all curl samples pin the same preferred IPv4 address'
assert_equal '3' \
  "$(grep -Fc '<--noproxy><*>' "$MOCK_LOG_DIR/curl.log")" \
  'all curl samples bypass environment proxies'
assert_equal '3' \
  "$(grep -Fc '<https://example.com/>' "$MOCK_LOG_DIR/curl.log")" \
  'all curl samples preserve the original URL and Host'
assert_equal '2' \
  "$(grep -Fc '<-connect><203.0.113.10:443>' \
    "$MOCK_LOG_DIR/openssl.log")" \
  'both OpenSSL handshakes use the selected address'
assert_equal '2' \
  "$(grep -Fc '<-servername><example.com>' \
    "$MOCK_LOG_DIR/openssl.log")" \
  'both OpenSSL handshakes preserve the original SNI'
assert_not_contains '<-connect><example.com:443>' "$openssl_log" \
  'OpenSSL never re-resolves the domain after address selection'
assert_contains '<dig>' "$timeout_log" \
  'high-fidelity worker runs DNS commands through timeout'
assert_contains '<curl>' "$timeout_log" \
  'high-fidelity worker runs curl commands through timeout'
assert_contains '<openssl>' "$timeout_log" \
  'high-fidelity worker runs OpenSSL commands through timeout'
assert_contains '<A><example.com>' "$(<"$MOCK_LOG_DIR/dig.log")" \
  'worker performs the mocked IPv4 lookup'
assert_contains '<AAAA><example.com>' "$(<"$MOCK_LOG_DIR/dig.log")" \
  'worker performs the mocked IPv6 lookup'
assert_contains '<-u><-d>' "$(<"$MOCK_LOG_DIR/date.log")" \
  'worker parses certificate expiry with the mocked GNU date path'

run_mocked_domain_check \
  '200|200|200' \
  '0.010|0.020|0.030' \
  '0|0|0' \
  '||' \
  0
assert_equal '1' "$MOCK_RUN_STATUS" \
  'incomplete OpenSSL evidence produces a hard failure'
assert_contains 'TLS 1.3 握手失败' "$MOCK_RUN_OUTPUT" \
  'incomplete TLS evidence has a distinct TLS failure reason'
assert_contains 'FAIL    | -' "$MOCK_RUN_OUTPUT" \
  'certificate verification failure displays FAIL in CERT(d)'
assert_not_contains 'TCP 443 不可达' "$MOCK_RUN_OUTPUT" \
  'successful curl TCP evidence is not mislabeled as a TCP failure'

run_mocked_domain_check \
  '200|200|200' \
  '0.010|0|0' \
  '0|35|35' \
  '||' \
  1
assert_equal '0' "$MOCK_RUN_STATUS" \
  'timing sample insufficiency is warning-only'
assert_contains 'TLS 握手计时样本不足（1/3）' "$MOCK_RUN_OUTPUT" \
  'one valid timing sample produces an explicit warning'
assert_contains 'WARN' "$MOCK_RUN_OUTPUT" \
  'timing insufficiency changes the row to WARN'

run_mocked_domain_check \
  '000|000|000' \
  '0|0|0' \
  '7|7|7' \
  '||' \
  0 \
  '' \
  '0|0|0' \
  0
assert_equal '1' "$MOCK_RUN_STATUS" \
  'TCP 443 failure is a hard failure'
assert_contains 'TCP 443 不可达' "$MOCK_RUN_OUTPUT" \
  'TCP 443 failure has a distinct reason'
assert_not_contains 'DNS 无法解析' "$MOCK_RUN_OUTPUT" \
  'resolved address is not mislabeled as DNS failure'

run_mocked_domain_check \
  '000|000|000' \
  '0|0|0' \
  '7|7|7' \
  '||' \
  0 \
  '' \
  '0|0|0' \
  0 \
  1
assert_equal '1' "$MOCK_RUN_STATUS" 'DNS failure is a hard failure'
assert_contains 'DNS 无法解析' "$MOCK_RUN_OUTPUT" \
  'DNS failure has a distinct reason'
assert_not_contains 'TCP 443 不可达' "$MOCK_RUN_OUTPUT" \
  'DNS failure is not duplicated as a TCP failure'
assert_equal '0' "$(<"$MOCK_LOG_DIR/curl.count")" \
  'DNS failure does not start curl connections without a selected address'

run_mocked_domain_check \
  '301|503|503' \
  '0.010|0.020|0.030' \
  '0|0|0' \
  'http://other.example/||' \
  1
assert_equal '0' "$MOCK_RUN_STATUS" \
  'HTTP downgrade redirect is warning-only'
assert_contains 'HTTP' "$MOCK_RUN_OUTPUT" \
  'HTTP downgrade retains its redirect code'
assert_contains 'WARN' "$MOCK_RUN_OUTPUT" \
  'HTTP downgrade produces a warning result'

run_mocked_domain_check \
  '200|200|200' \
  '0.010|0.020|0.030' \
  '0|0|0' \
  '||' \
  1 \
  '' \
  '0.005|0.006|0.007' \
  1 \
  0 \
  1604800 \
  1000000
assert_equal '0' "$MOCK_RUN_STATUS" \
  'certificate with seven full days is warning-only'
assert_contains '证书仅剩 7 个完整日' "$MOCK_RUN_OUTPUT" \
  'near-expiry certificate warning is shown'
assert_contains 'WARN' "$MOCK_RUN_OUTPUT" \
  'near-expiry certificate changes the result to WARN'

run_mocked_domain_check \
  '200|200|200' \
  '0.010|0.020|0.030' \
  '0|0|0' \
  '||' \
  1 \
  '' \
  '0.005|0.006|0.007' \
  1 \
  0 \
  999999 \
  1000000
assert_equal '1' "$MOCK_RUN_STATUS" \
  'expired certificate produces a hard failure'
assert_contains '证书已过期' "$MOCK_RUN_OUTPUT" \
  'expired certificate has an explicit worker reason'
assert_contains 'FAIL' "$MOCK_RUN_OUTPUT" \
  'expired certificate is displayed as FAIL'

worker_temp_count=$(
  find "$TEST_TEMP_DIR/worker-tmp" -mindepth 1 -maxdepth 1 \
    -name 'domain-check.*' -print | wc -l | awk '{ print $1 }'
)
assert_equal '0' "$worker_temp_count" \
  'main removes worker temporary directories after every run'

printf 'PASS: %d offline assertions\n' "$TEST_COUNT"
