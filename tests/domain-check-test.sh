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
TEST_MAIN_BASHPID=$BASHPID
readonly TEST_MAIN_BASHPID
TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/domain-check-tests.XXXXXXXX")
readonly TEST_TEMP_DIR
readonly TEST_LOG_HOME="$TEST_TEMP_DIR/log-home"
mkdir -p "$TEST_LOG_HOME"

cleanup_test_files() {
  if [[ "$BASHPID" != "$TEST_MAIN_BASHPID" ]]; then
    return 0
  fi
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

assert_less_or_equal() {
  local maximum=$1
  local actual=$2
  local description=$3
  (( TEST_COUNT += 1 ))
  (( actual <= maximum )) ||
    fail "$description: expected at most [$maximum], got [$actual]"
}

assert_greater_or_equal() {
  local minimum=$1
  local actual=$2
  local description=$3
  (( TEST_COUNT += 1 ))
  (( actual >= minimum )) ||
    fail "$description: expected at least [$minimum], got [$actual]"
}

assert_in_order() {
  local actual=$1
  local description=$2
  shift 2
  local expected
  local remaining=$actual

  (( TEST_COUNT += 1 ))
  for expected in "$@"; do
    [[ "$remaining" == *"$expected"* ]] ||
      fail "$description: missing or out of order [$expected]"
    remaining=${remaining#*"$expected"}
  done
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

assert_evidence() {
  local predicate=$1
  local input=$2
  local expected=$3
  local description=$4
  local input_file
  local actual='FAIL'

  (( EXTRACTOR_TEST_NUMBER += 1 ))
  input_file="$TEST_TEMP_DIR/evidence-$EXTRACTOR_TEST_NUMBER"
  printf '%s' "$input" >"$input_file"
  if "$predicate" "$input_file"; then
    actual='PASS'
  fi
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

test_cleanup_process_isolation() {
  local cleanup_worker_pid
  local main_cleanup_probe

  sleep 30 &
  cleanup_worker_pid=$!
  kill -TERM "$cleanup_worker_pid"
  wait "$cleanup_worker_pid" 2>/dev/null || :
  assert_equal 'true' "$(if [[ -d "$TEST_TEMP_DIR" ]]; then
    printf true
  else
    printf false
  fi)" 'background EXIT trap does not remove the main test temporary directory'

  main_cleanup_probe=$(mktemp -d \
    "$TEST_TEMP_DIR/main-cleanup-probe.XXXXXXXX")
  export -f cleanup_test_files
  env TEST_TEMP_DIR="$main_cleanup_probe" bash -c \
    "TEST_MAIN_BASHPID=\$BASHPID; cleanup_test_files"
  export -n -f cleanup_test_files
  assert_equal 'false' "$(if [[ -d "$main_cleanup_probe" ]]; then
    printf true
  else
    printf false
  fi)" 'main test shell cleanup removes its temporary directory'
}

test_cleanup_process_isolation

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
aggregate_ready_samples 10 30 20
assert_equal '3' "$READY_SAMPLE_COUNT" 'three READY timing samples are counted'
assert_equal '20' "$READY_MS" 'three READY timing samples use the median'
aggregate_ready_samples 10 21
assert_equal '2' "$READY_SAMPLE_COUNT" 'two READY timing samples are counted'
assert_equal '16' "$READY_MS" 'two READY timing samples use the rounded average'
aggregate_ready_samples 17
assert_equal '1' "$READY_SAMPLE_COUNT" 'one READY timing sample is counted'
assert_equal '17' "$READY_MS" 'one READY timing sample is displayed directly'
aggregate_ready_samples
assert_equal '0' "$READY_SAMPLE_COUNT" 'zero READY timing samples are counted'
assert_equal '-' "$READY_MS" 'zero READY timing samples display a dash'

for deterministic_curl_exit in 1 2 3 4 35 51 58 59 60 77 90 91; do
  (( TEST_COUNT += 1 ))
  curl_failure_is_deterministic "$deterministic_curl_exit" ||
    fail "curl exit $deterministic_curl_exit should fail fast"
done
for retryable_curl_exit in 0 5 6 7 18 28 52 55 56 92; do
  (( TEST_COUNT += 1 ))
  if curl_failure_is_deterministic "$retryable_curl_exit"; then
    fail "curl exit $retryable_curl_exit should remain retryable"
  fi
done

assert_evidence tls13_evidence_present $'Protocol  : TLSv1.3\n' PASS \
  'TLS1.3 evidence accepts the spaced OpenSSL Protocol form'
assert_evidence tls13_evidence_present $'Protocol: TLSv1.3\n' PASS \
  'TLS1.3 evidence accepts the compact OpenSSL Protocol form'
assert_evidence tls13_evidence_present \
  $'New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384\n' PASS \
  'TLS1.3 evidence accepts the OpenSSL New comma-delimited form'
assert_evidence tls13_evidence_present $'Protocol  : TLSv1.2\n' FAIL \
  'TLS1.2 is not accepted as TLS1.3 evidence'
assert_evidence tls13_evidence_present $'Protocol  : TLSv1.30\n' FAIL \
  'TLSv1.30 is not accepted as TLSv1.3 evidence'
assert_evidence tls13_evidence_present $'Protocol  : TLSv1.3x\n' FAIL \
  'TLSv1.3x is not accepted as TLSv1.3 evidence'
assert_evidence x25519_evidence_present \
  $'New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384\nPeer Temp Key: X25519, 253 bits\n' \
  PASS 'TLS1.3 with an explicit X25519 temporary key passes'
assert_evidence x25519_evidence_present \
  $'New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384\n' FAIL \
  'TLS1.3 without an X25519 temporary key fails'
assert_evidence x25519_evidence_present \
  $'Protocol  : TLSv1.2\ndebug text: X25519, 253 bits\n' FAIL \
  'unrelated X25519 text without valid TLS1.3 evidence fails'
assert_evidence x25519_evidence_present \
  $'Protocol  : TLSv1.3\ndebug text: X25519, 253 bits\n' FAIL \
  'unrelated X25519 text is not temporary-key evidence'

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

assert_extractor first_cname_from_file \
  $'origin.example.net.\nasset.b-cdn.net.\n' \
  'asset.b-cdn.net' \
  'CNAME extractor recognizes and preserves the Bunny CDN suffix'
assert_extractor first_cname_from_file \
  $'origin.example.net.\n123456.gcdn.co.\n' \
  '123456.gcdn.co' \
  'CNAME extractor recognizes and preserves the Gcore suffix'

cdn_header_file="$TEST_TEMP_DIR/cdn-headers"
printf 'CF-Ray: abc-SIN\r\n' >"$cdn_header_file"
detect_cdn '' "$cdn_header_file"
assert_equal 'HIGH' "$CDN_STATUS" 'CF-Ray is high-confidence Cloudflare'
assert_contains 'Cloudflare' "$CDN_DETAIL" 'Cloudflare evidence is explained'
printf 'CF-Cache-Status: HIT\r\n' >"$cdn_header_file"
detect_cdn '' "$cdn_header_file"
assert_equal 'HIGH' "$CDN_STATUS" \
  'CF-Cache-Status remains high-confidence Cloudflare evidence'
assert_equal 'Cloudflare（CF-Cache-Status）' "$CDN_DETAIL" \
  'Cloudflare cache-status evidence is explicit'
printf 'x-amz-cf-pop: SIN2-P1\r\n' >"$cdn_header_file"
detect_cdn '' "$cdn_header_file"
assert_equal 'HIGH' "$CDN_STATUS" 'CloudFront header is high confidence'
assert_contains 'CloudFront' "$CDN_DETAIL" 'CloudFront fixture names its provider'
printf 'x-akamai-transformed: 9 0 pmb=mRUM,2\r\n' >"$cdn_header_file"
detect_cdn '' "$cdn_header_file"
assert_equal 'HIGH' "$CDN_STATUS" 'Akamai header is high confidence'
assert_contains 'Akamai' "$CDN_DETAIL" 'Akamai fixture names its provider'
printf 'x-azure-ref: ref\r\n' >"$cdn_header_file"
detect_cdn '' "$cdn_header_file"
assert_equal 'HIGH' "$CDN_STATUS" 'Azure header is high confidence'
assert_contains 'Azure Front Door' "$CDN_DETAIL" \
  'Azure Front Door fixture names its provider'
printf 'x-served-by: cache-sin\r\nx-cache: HIT\r\n' >"$cdn_header_file"
detect_cdn '' "$cdn_header_file"
assert_equal 'HIGH' "$CDN_STATUS" 'Fastly header combination is high confidence'
assert_contains 'Fastly' "$CDN_DETAIL" 'Fastly fixture names its provider'
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
printf 'Server: cloudflare\r\n' >"$cdn_header_file"
detect_cdn '' "$cdn_header_file"
assert_equal '-' "$CDN_STATUS" \
  'Server cloudflare alone is not CDN evidence'
assert_equal '' "$CDN_DETAIL" \
  'Server cloudflare alone does not claim a provider'
printf 'Server: cloudflare\r\nCF-Ray: combined-SIN\r\n' >"$cdn_header_file"
detect_cdn '' "$cdn_header_file"
assert_equal 'HIGH' "$CDN_STATUS" \
  'Server cloudflare plus CF-Ray is high-confidence Cloudflare'
assert_equal 'Cloudflare（CF-Ray）' "$CDN_DETAIL" \
  'combined Cloudflare fixture derives evidence from CF-Ray'
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
detect_cdn 'asset.b-cdn.net' "$cdn_header_file"
assert_equal 'HIGH' "$CDN_STATUS" 'Bunny CDN CNAME is high confidence'
assert_contains 'Bunny CDN' "$CDN_DETAIL" \
  'Bunny CDN CNAME fixture names its provider'
detect_cdn '123456.gcdn.co' "$cdn_header_file"
assert_equal 'HIGH' "$CDN_STATUS" 'Gcore CNAME is high confidence'
assert_contains 'Gcore' "$CDN_DETAIL" \
  'Gcore CNAME fixture names its provider'

assert_file_contains "--noproxy '*'" "$DOMAIN_CHECK_SCRIPT" \
  'curl explicitly bypasses environment proxies'
literal_curl_resolve="--resolve \"\$curl_resolve\""
literal_openssl_target="-connect \"\$openssl_target\""
assert_file_contains "$literal_curl_resolve" "$DOMAIN_CHECK_SCRIPT" \
  'curl pins every connection to the selected address'
assert_file_contains "$literal_openssl_target" "$DOMAIN_CHECK_SCRIPT" \
  'OpenSSL connects to the selected address'
# This is the literal positional parameter evaluated by the child Bash.
# shellcheck disable=SC2016
literal_tcp_path='/dev/tcp/$1/443'
assert_file_contains '/dev/tcp/' "$DOMAIN_CHECK_SCRIPT" \
  'TCP 443 reachability uses the Bash built-in socket path'
assert_file_not_contains 'netcat' "$DOMAIN_CHECK_SCRIPT" \
  'independent TCP probing does not add a netcat dependency'
assert_file_not_contains 'tcp_evidence' "$DOMAIN_CHECK_SCRIPT" \
  'TCP reachability evidence uses the final TCP status directly'
assert_file_not_contains 'EPOCHREALTIME' "$DOMAIN_CHECK_SCRIPT" \
  'OpenSSL wall-clock timing was removed'
assert_file_not_contains 'DOMAIN_CHECK_SAMPLE' "$DOMAIN_CHECK_SCRIPT" \
  'there is no environment variable for changing sample count'
assert_file_not_contains 'TLS_SAMPLES' "$DOMAIN_CHECK_SCRIPT" \
  'there is no alternate TLS sample-count control'
assert_equal '8' "$MAX_CONCURRENCY" \
  'domain workers use the fixed eight-worker limit'
assert_equal '4' "$TLS_TIMEOUT" \
  'TLS and X25519 probes use the four-second qualification timeout'
assert_file_contains 'trap handle_interrupt INT TERM' "$DOMAIN_CHECK_SCRIPT" \
  'worker signal cleanup path remains installed'
assert_file_contains 'terminate_workers' "$DOMAIN_CHECK_SCRIPT" \
  'worker termination cleanup remains available'

scheduler_driver="$TEST_TEMP_DIR/concurrent-scheduler-driver.sh"
scheduler_progress="$TEST_TEMP_DIR/concurrent-scheduler-progress"
scheduler_lock="$TEST_TEMP_DIR/concurrent-scheduler-lock"
scheduler_active="$TEST_TEMP_DIR/concurrent-scheduler-active"
scheduler_max="$TEST_TEMP_DIR/concurrent-scheduler-max"
{
  printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail'
  printf '%s\n' 'export DOMAIN_CHECK_SOURCE_ONLY=1'
  printf 'source %q\n' "$DOMAIN_CHECK_SCRIPT"
  printf 'readonly SCHEDULER_LOCK_DIR=%q\n' "$scheduler_lock"
  printf 'readonly SCHEDULER_ACTIVE_FILE=%q\n' "$scheduler_active"
  printf 'readonly SCHEDULER_MAX_FILE=%q\n' "$scheduler_max"
  cat <<'SCHEDULER_DRIVER'
parse_domain_argument() {
  local domain
  local number
  DOMAIN_INPUTS=()
  for (( number = 1; number <= 45; number += 1 )); do
    printf -v domain 'd%02d.example.com' "$number"
    DOMAIN_INPUTS+=("$domain")
  done
}

check_dependencies() {
  :
}

initialize_output_style() {
  COLOR_ENABLED=false
}

check_domain() {
  local index=$1
  local domain=$2
  local active_count
  local maximum_count

  while ! mkdir "$SCHEDULER_LOCK_DIR" 2>/dev/null; do
    sleep 0.01
  done
  active_count=$(<"$SCHEDULER_ACTIVE_FILE")
  maximum_count=$(<"$SCHEDULER_MAX_FILE")
  (( active_count += 1 ))
  printf '%s\n' "$active_count" >"$SCHEDULER_ACTIVE_FILE"
  if (( active_count > maximum_count )); then
    printf '%s\n' "$active_count" >"$SCHEDULER_MAX_FILE"
  fi
  rmdir "$SCHEDULER_LOCK_DIR"

  sleep 0.12
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$domain" 203.0.113.10 PASS PASS PASS 20 30 - 200 - PASS - \
    >"$TEMP_DIR/result-$index"

  while ! mkdir "$SCHEDULER_LOCK_DIR" 2>/dev/null; do
    sleep 0.01
  done
  active_count=$(<"$SCHEDULER_ACTIVE_FILE")
  (( active_count -= 1 ))
  printf '%s\n' "$active_count" >"$SCHEDULER_ACTIVE_FILE"
  rmdir "$SCHEDULER_LOCK_DIR"
}

print_results() {
  local index
  local domain
  RESULT_STATUSES=()
  for index in "${!DOMAIN_INPUTS[@]}"; do
    IFS=$'\t' read -r domain _ <"$TEMP_DIR/result-$index"
    printf '%s\n' "$domain"
    RESULT_STATUSES+=(PASS)
  done
}

main ignored.example.com
SCHEDULER_DRIVER
} >"$scheduler_driver"
printf '0\n' >"$scheduler_active"
printf '0\n' >"$scheduler_max"
scheduler_output=$(HOME="$TEST_LOG_HOME/scheduler" \
  bash "$scheduler_driver" 2>"$scheduler_progress")
assert_less_or_equal '8' "$(<"$scheduler_max")" \
  '45-domain scheduler never exceeds eight concurrent workers'
assert_greater_or_equal '2' "$(<"$scheduler_max")" \
  '45-domain scheduler actually runs domain workers concurrently'
assert_equal '45' \
  "$(grep -Ec '^\[[0-9]+/45\] d[0-9]{2}[.]example[.]com$' \
    "$scheduler_progress")" \
  'parent reports one completion progress line for every domain'
scheduler_expected_domains=()
for (( scheduler_number = 1; scheduler_number <= 45; scheduler_number += 1 )); do
  printf -v scheduler_domain 'd%02d.example.com' "$scheduler_number"
  scheduler_expected_domains+=("$scheduler_domain")
done
assert_in_order "$scheduler_output" \
  '45-domain final output preserves input order' \
  "${scheduler_expected_domains[@]}"

sleep 30 &
cleanup_worker_pid=$!
WORKER_PIDS=("$cleanup_worker_pid")
terminate_workers
assert_equal '0' "${#WORKER_PIDS[@]}" \
  'worker cleanup empties the tracked PID list'
set +e
kill -0 "$cleanup_worker_pid" 2>/dev/null
cleanup_worker_status=$?
set -e
assert_equal '1' "$cleanup_worker_status" \
  'worker cleanup terminates and reaps the active worker'

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
acquire_ready_sample_lock
assert_equal 'true' \
  "$([[ -d "$TEMP_DIR/ready-sample-lock" ]] && printf true || printf false)" \
  'READY lock exists while a sample owns it'
release_ready_sample_lock
assert_equal 'false' \
  "$([[ -d "$TEMP_DIR/ready-sample-lock" ]] && printf true || printf false)" \
  'READY lock is removed immediately after an individual sample'
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
assert_contains 'READY(ms)' "$table_output" \
  'NO_COLOR table names the full time_appconnect timing'
assert_not_contains 'HS(ms)' "$table_output" \
  'NO_COLOR table removes the ambiguous handshake header'
assert_contains 'CERT(d)' "$table_output" \
  'table displays certificate remaining days'
assert_contains 'CDN' "$table_output" \
  'table includes the informational CDN column'
assert_not_contains '┌' "$table_output" \
  'non-TTY table uses ASCII borders'

mapfile -t table_lines <<<"$table_output"
table_header_order=$(IFS=' '; printf '%s' "${TABLE_HEADERS[*]}")
assert_equal \
  'DOMAIN IP TLS1.3 X25519 H2 READY(ms) CERT(d) CDN HTTP REDIRECT RESULT' \
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

COLOR_ENABLED=true
colored_table_output=$(print_results)
COLOR_ENABLED=false
assert_contains 'READY(ms)' "$colored_table_output" \
  'colored table names the full time_appconnect timing'
assert_not_contains 'HS(ms)' "$colored_table_output" \
  'colored table removes the ambiguous handshake header'

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

html_hostile_reason='remote & <tag> "quote" '\''apostrophe'\'''
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  'second.example.com' '1.2.3.4' PASS PASS PASS 25 20 HIGH 301 WWW WARN \
  "跳转：www 切换; $html_hostile_reason" >"$TEMP_DIR/result-1"
html_output=$(render_html_report '2026-08-12 12:34:56 UTC')
assert_contains '<!doctype html>' "$html_output" \
  'HTML report has a document type'
assert_contains '<meta charset="utf-8">' "$html_output" \
  'HTML report declares UTF-8'
assert_contains '<style>' "$html_output" \
  'HTML report embeds its stylesheet'
assert_contains '@media (prefers-color-scheme:light)' "$html_output" \
  'HTML report supports the light color scheme'
assert_contains '@media (prefers-color-scheme:dark)' "$html_output" \
  'HTML report supports the dark color scheme'
assert_contains '<h1>Domain Check Report</h1>' "$html_output" \
  'HTML report has its heading'
assert_contains '<dt>Time</dt><dd>2026-08-12 12:34:56 UTC</dd>' \
  "$html_output" 'HTML report includes its generation time'
assert_contains "<dt>Input</dt><dd>$long_domain/second.example.com</dd>" \
  "$html_output" 'HTML report includes slash-separated input targets'
assert_contains '<span>Targets</span><strong>2</strong>' "$html_output" \
  'HTML report includes the target count'
assert_contains '<span>PASS</span><strong>1</strong>' "$html_output" \
  'HTML report includes the PASS count'
assert_contains '<span>WARN</span><strong>1</strong>' "$html_output" \
  'HTML report includes the WARN count'
assert_contains '<span>FAIL</span><strong>0</strong>' "$html_output" \
  'HTML report includes the FAIL count'
assert_contains \
  '<thead><tr><th>DOMAIN</th><th>IP</th><th>TLS1.3</th><th>X25519</th><th>H2</th><th>READY(ms)</th><th>CERT(d)</th><th>CDN</th><th>HTTP</th><th>REDIRECT</th><th>RESULT</th></tr></thead>' \
  "$html_output" 'HTML table contains every terminal result field'
assert_contains '<td class="status status-pass">PASS</td>' "$html_output" \
  'HTML table applies the PASS status class'
assert_contains '<td class="result status-warn">WARN</td>' "$html_output" \
  'HTML table applies the WARN result class'
assert_contains '<td class="status status-high">HIGH</td>' "$html_output" \
  'HTML table applies the HIGH status class'
assert_contains '<td class="http http-2xx">200</td>' "$html_output" \
  'HTML table applies the 2xx HTTP class'
assert_contains '<td class="http http-3xx">301</td>' "$html_output" \
  'HTML table applies the 3xx HTTP class'
set_http_css_class 403
assert_equal 'http http-4xx' "$HTML_CSS_CLASS" \
  'HTML table maps 4xx responses to the warning class'
set_http_css_class 503
assert_equal 'http http-5xx' "$HTML_CSS_CLASS" \
  'HTML table maps 5xx responses to the failure class'
assert_contains '<section class="details"><h2>DETAILS</h2>' "$html_output" \
  'HTML report contains a DETAILS section'
assert_contains '<article class="detail-card"><h3>second.example.com</h3>' \
  "$html_output" 'HTML DETAILS identifies its domain'
assert_contains '<li class="detail-warn">跳转：www 切换</li>' "$html_output" \
  'HTML DETAILS applies the warning class'
assert_contains \
  'remote &amp; &lt;tag&gt; &quot;quote&quot; &#39;apostrophe&#39;' \
  "$html_output" 'HTML escapes all special characters in remote details'
assert_not_contains 'remote & <tag>' "$html_output" \
  'HTML never emits an unescaped hostile detail'
assert_not_contains $'\033[' "$html_output" \
  'HTML report never contains terminal ANSI escapes'
html_escape_input='&<>"'\'''
assert_equal '&amp;&lt;&gt;&quot;&#39;' "$(escape_html "$html_escape_input")" \
  'HTML escape helper handles ampersand, angles, quotes, and apostrophes'

html_log_stderr=$(HOME="$TEST_LOG_HOME/render" write_html_log 2>&1)
html_log_path=${html_log_stderr#HTML log: }
assert_equal 'true' \
  "$([[ "$html_log_path" == "$TEST_LOG_HOME"/render/domain-check-logs/domain-check-*.html &&
    -s "$html_log_path" ]] && printf true || printf false)" \
  'automatic HTML log is written below the configured home directory'
assert_file_contains '<h1>Domain Check Report</h1>' "$html_log_path" \
  'automatic HTML log contains the rendered report'
html_second_stderr=$(HOME="$TEST_LOG_HOME/render" write_html_log 2>&1)
html_second_path=${html_second_stderr#HTML log: }
assert_equal 'true' \
  "$([[ -s "$html_second_path" && "$html_second_path" != "$html_log_path" ]] &&
    printf true || printf false)" \
  'automatic HTML logs reserve unique files without overwriting'
assert_equal '0' \
  "$(find "$TEST_LOG_HOME/render/domain-check-logs" -maxdepth 1 \
    -type f -name '*.md' | wc -l)" \
  'automatic logging no longer creates legacy .md files'

html_failure_home="$TEST_TEMP_DIR/html-home-file"
printf '%s\n' 'not a directory' >"$html_failure_home"
set +e
html_failure_warning=$(HOME="$html_failure_home" write_html_log 2>&1)
html_failure_status=$?
set -e
assert_equal '0' "$html_failure_status" \
  'HTML log failure does not change the detector status'
assert_contains 'WARN: unable to create HTML log directory' \
  "$html_failure_warning" 'HTML log failure emits an explicit warning'

html_render_failure_warning=$(
  # Called indirectly by write_html_log in this isolated subshell.
  # shellcheck disable=SC2317,SC2329
  render_html_report() { return 1; }
  HOME="$TEST_LOG_HOME/render-failure" write_html_log 2>&1
)
assert_contains 'WARN: unable to write HTML log' \
  "$html_render_failure_warning" 'HTML render failure emits an explicit warning'
assert_equal '0' \
  "$(find "$TEST_LOG_HOME/render-failure/domain-check-logs" -maxdepth 1 \
    -type f -name '*.html' | wc -l)" \
  'failed HTML render removes its incomplete reserved file'

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
if [[ ${1:-} == bash && ${2:-} == -c &&
  ${3:-} == *'/dev/tcp/'* ]]; then
  exit "${MOCK_TCP_EXIT:-0}"
fi
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
global_counter_file="$MOCK_LOG_DIR/curl.count"
global_counter_lock="$MOCK_LOG_DIR/curl-count-lock"
while ! mkdir "$global_counter_lock" 2>/dev/null; do
  sleep 0.01
done
global_counter=$(<"$global_counter_file")
global_counter=$(( global_counter + 1 ))
printf '%s\n' "$global_counter" >"$global_counter_file"
rmdir "$global_counter_lock"
printf '<%s>' "$@" >>"$MOCK_LOG_DIR/curl.log"
printf '\n' >>"$MOCK_LOG_DIR/curl.log"

header_file=''
request_url=''
insecure=false
while (( $# > 0 )); do
  case "$1" in
    --dump-header)
      shift
      header_file=$1
      ;;
    --insecure|-k)
      insecure=true
      ;;
    https://*)
      request_url=$1
      ;;
  esac
  shift
done

request_domain=${request_url#https://}
request_domain=${request_domain%/}
safe_domain=${request_domain//[^a-zA-Z0-9]/_}
if [[ "$insecure" == true ]]; then
  counter_file="$MOCK_LOG_DIR/curl-ready-domain-$safe_domain.count"
else
  counter_file="$MOCK_LOG_DIR/curl-http-domain-$safe_domain.count"
fi
counter=0
[[ ! -r "$counter_file" ]] || counter=$(<"$counter_file")
counter=$(( counter + 1 ))
printf '%s\n' "$counter" >"$counter_file"

IFS='|' read -r -a codes <<<"$MOCK_HTTP_CODES"
IFS='|' read -r -a connect_times <<<"$MOCK_CONNECT_TIMES"
IFS='|' read -r -a appconnect_times <<<"$MOCK_APPCONNECT_TIMES"
if [[ "$insecure" == true ]]; then
  curl_exit_values=${MOCK_READY_CURL_EXITS:-$MOCK_CURL_EXITS}
else
  curl_exit_values=${MOCK_HTTP_CURL_EXITS:-$MOCK_CURL_EXITS}
fi
IFS='|' read -r -a exit_codes <<<"$curl_exit_values"
IFS='|' read -r -a locations <<<"$MOCK_LOCATIONS"
code=${codes[counter - 1]:-000}
connect_time=${connect_times[counter - 1]:-0}
appconnect_time=${appconnect_times[counter - 1]:-0}
exit_code=${exit_codes[counter - 1]:-0}
location=${locations[counter - 1]:-}

if [[ -n "$header_file" ]]; then
  : >"$header_file"
  printf 'HTTP/1.1 %s Mock\r\n' "$code" >>"$header_file"
  [[ -z "$location" ]] ||
    printf 'Location: %s\r\n' "$location" >>"$header_file"
  [[ -z ${MOCK_RESPONSE_HEADER:-} ]] ||
    printf '%b\r\n' "$MOCK_RESPONSE_HEADER" >>"$header_file"
  printf '\r\n' >>"$header_file"
fi
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
      'New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384' \
      'Peer Temp Key: X25519, 253 bits'
  else
    printf '%s\n' 'CONNECTED'
  fi
  exit "${MOCK_X25519_EXIT:-1}"
fi

if [[ ${MOCK_NORMAL_COMPLETE:-1} == 1 ]]; then
  printf '%s\n' \
    'New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384' \
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
case " $* " in
  *' +%Y%m%d-%H%M%S '*) printf '%s\n' '20300101-000000' ;;
  *' +%Y-%m-%d %H:%M:%S UTC '*) printf '%s\n' '2030-01-01 00:00:00 UTC' ;;
  *' -d '*) printf '%s\n' "${MOCK_EXPIRY_EPOCH:-2000000000}" ;;
  *) printf '%s\n' "${MOCK_CURRENT_EPOCH:-1900000000}" ;;
esac
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
  local normal_exit=${12:-0}
  local x25519_exit=${13:-0}
  local domain_argument=${14:-example.com}
  local tcp_exit=${15:-0}
  local ready_curl_exits=${16:-$curl_exits}
  local http_curl_exits=${17:-$curl_exits}

  mkdir -p "$TEST_TEMP_DIR/worker-tmp"
  rm -rf -- "$TEST_LOG_HOME/mock/domain-check-logs"
  printf '0\n' >"$MOCK_LOG_DIR/curl.count"
  rm -f -- "$MOCK_LOG_DIR"/curl-*-domain-*.count
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
      MOCK_READY_CURL_EXITS="$ready_curl_exits" \
      MOCK_HTTP_CURL_EXITS="$http_curl_exits" \
      MOCK_LOCATIONS="$locations" \
      MOCK_NORMAL_COMPLETE="$normal_complete" \
      MOCK_X25519_COMPLETE="$x25519_complete" \
      MOCK_DNS_FAIL="$dns_fail" \
      MOCK_NORMAL_EXIT="$normal_exit" \
      MOCK_X25519_EXIT="$x25519_exit" \
      MOCK_TCP_EXIT="$tcp_exit" \
      MOCK_RESPONSE_HEADER="$response_header" \
      MOCK_EXPIRY_EPOCH="$expiry_epoch" \
      MOCK_CURRENT_EPOCH="$current_epoch" \
      HOME="$TEST_LOG_HOME/mock" \
      TMPDIR="$TEST_TEMP_DIR/worker-tmp" \
      DOMAIN_CHECK_SOURCE_ONLY=0 \
      bash "$DOMAIN_CHECK_SCRIPT" "$domain_argument" 2>&1
  )
  MOCK_RUN_STATUS=$?
  set -e
}

run_mocked_domain_check \
  '500|200|503' \
  '0.111|0.333|0.222' \
  '0|0|0' \
  'https://other.example/||https://later.example/' \
  1 \
  'CF-Ray: offline-SIN' \
  '0.100|0.200|0.050'
assert_equal '0' "$MOCK_RUN_STATUS" \
  'successful OpenSSL commands with complete parsed evidence pass'
mock_html_log=$(find "$TEST_LOG_HOME/mock/domain-check-logs" \
  -maxdepth 1 -type f -name 'domain-check-*.html' -print -quit)
assert_equal 'true' \
  "$([[ -n "$mock_html_log" && -s "$mock_html_log" ]] &&
    printf true || printf false)" \
  'successful detector run writes one complete HTML log'
assert_contains "HTML log: $mock_html_log" "$MOCK_RUN_OUTPUT" \
  'detector reports the absolute HTML log path on stderr'
assert_file_contains \
  '<span class="summary-item status-pass"><span>PASS</span><strong>1</strong></span>' \
  "$mock_html_log" 'successful HTML log contains the PASS summary'
assert_equal '0' \
  "$(find "$TEST_LOG_HOME/mock/domain-check-logs" -maxdepth 1 \
    -type f -name '*.md' | wc -l)" \
  'successful detector run creates no legacy .md log'
assert_equal '5' "$(<"$MOCK_LOG_DIR/curl.count")" \
  'worker uses three READY connections and two strict HTTP attempts'
assert_contains 'READY(ms)' "$MOCK_RUN_OUTPUT" \
  'high-fidelity worker output uses the connection-ready header'
assert_not_contains 'HS(ms)' "$MOCK_RUN_OUTPUT" \
  'high-fidelity worker output removes the ambiguous handshake header'
assert_contains '| 222       |' "$MOCK_RUN_OUTPUT" \
  'worker displays the median of three complete time_appconnect samples'
assert_not_contains '| 133       |' "$MOCK_RUN_OUTPUT" \
  'worker does not subtract time_connect from time_appconnect'
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
assert_not_contains 'TCP 443 不可达' "$MOCK_RUN_OUTPUT" \
  'successful TCP and TLS1.3 probes do not report a TCP failure'

openssl_log=$(<"$MOCK_LOG_DIR/openssl.log")
timeout_log=$(<"$MOCK_LOG_DIR/timeout.log")
assert_equal '5' \
  "$(grep -Fc '<--resolve><example.com:443:203.0.113.10>' \
    "$MOCK_LOG_DIR/curl.log")" \
  'all curl requests pin the same preferred IPv4 address'
assert_equal '5' \
  "$(grep -Fc '<--noproxy><*>' "$MOCK_LOG_DIR/curl.log")" \
  'all curl requests bypass environment proxies'
assert_equal '5' \
  "$(grep -Fc '<https://example.com/>' "$MOCK_LOG_DIR/curl.log")" \
  'all curl requests preserve the original URL and Host'
assert_equal '5' \
  "$(grep -Fc '<--ipv4>' "$MOCK_LOG_DIR/curl.log")" \
  'all curl requests explicitly use IPv4 for an IPv4 target'
assert_equal '3' \
  "$(grep -Fc '<--insecure>' "$MOCK_LOG_DIR/curl.log")" \
  'only the three READY timing samples skip certificate verification'
assert_equal '3' \
  "$(grep -Fc '<--head>' "$MOCK_LOG_DIR/curl.log")" \
  'all three READY timing samples use HEAD without a response body'
assert_equal '3' \
  "$(grep -Ec '<--insecure>.*<--head>|<--head>.*<--insecure>' \
    "$MOCK_LOG_DIR/curl.log")" \
  'HEAD is scoped to the three insecure READY timing samples'
assert_equal '2' \
  "$(grep -Fc '<--dump-header>' "$MOCK_LOG_DIR/curl.log")" \
  'strict HTTP retries capture response headers without extra final attempts'
assert_equal '0' \
  "$(grep -Ec '<--dump-header>.*<--insecure>|<--insecure>.*<--dump-header>' \
    "$MOCK_LOG_DIR/curl.log" || :)" \
  'strict HTTP requests never inherit READY certificate bypass'
assert_equal '0' \
  "$(grep -Ec '<--dump-header>.*<--head>|<--head>.*<--dump-header>' \
    "$MOCK_LOG_DIR/curl.log" || :)" \
  'strict HTTP probes remain normal GET requests after READY switches to HEAD'
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
assert_equal '1' \
  "$(grep -Fc "$literal_tcp_path" "$MOCK_LOG_DIR/timeout.log")" \
  'resolved domain performs exactly one independent TCP 443 probe'
assert_contains '<bash><203.0.113.10>' "$timeout_log" \
  'independent TCP probe uses the same selected IPv4 address'
assert_in_order "$timeout_log" \
  'independent TCP probe completes before TLS and HTTP checks start' \
  "$literal_tcp_path" '<openssl>' '<curl>'
assert_contains '<A><example.com>' "$(<"$MOCK_LOG_DIR/dig.log")" \
  'worker performs the mocked IPv4 lookup'
assert_contains '<AAAA><example.com>' "$(<"$MOCK_LOG_DIR/dig.log")" \
  'worker performs the mocked IPv6 lookup'
assert_contains '<-u><-d>' "$(<"$MOCK_LOG_DIR/date.log")" \
  'worker parses certificate expiry with the mocked GNU date path'

ready_loop_block=$(sed -n \
  '/# a failing target cannot monopolize it across three timeouts[.]/,/# HTTP checks use strict certificate verification/p' \
  "$DOMAIN_CHECK_SCRIPT")
assert_in_order "$ready_loop_block" \
  'READY acquires and releases the global lock around each individual sample' \
  'for attempt in 1 2 3' 'acquire_ready_sample_lock' \
  'run_network_command' 'curl --insecure --head' 'release_ready_sample_lock' \
  'curl_failure_is_deterministic'

run_mocked_domain_check \
  '405|403|404' \
  '0.041|0.019|0.027' \
  '0|0|0' \
  '||' \
  1 '' '0.005|0.006|0.007' 1 0 2000000000 1900000000 \
  0 0 example.com 0 \
  '35|22|92' '0|0|0'
assert_equal '0' "$MOCK_RUN_STATUS" \
  'HEAD HTTP status and late curl errors do not invalidate completed TLS timing'
assert_contains '| 27        |' "$MOCK_RUN_OUTPUT" \
  'positive time_appconnect samples retain the existing median aggregation'
assert_not_contains '连接就绪计时样本不足' "$MOCK_RUN_OUTPUT" \
  'positive READY samples survive 403, 404, 405, and later curl errors'
assert_equal '3' \
  "$(grep -Fc '<--head>' "$MOCK_LOG_DIR/curl.log")" \
  'HTTP status compatibility path still performs exactly three READY HEAD samples'
assert_equal '1' \
  "$(grep -Fc '<--dump-header>' "$MOCK_LOG_DIR/curl.log")" \
  'HTTP status compatibility path still performs its independent strict GET probe'
assert_equal '0' \
  "$(grep -Ec '<--dump-header>.*<--head>|<--head>.*<--dump-header>' \
    "$MOCK_LOG_DIR/curl.log" || :)" \
  'strict HTTP GET remains isolated from READY HEAD compatibility handling'

run_mocked_domain_check \
  '200|200|200|200|200|200|200|200|200' \
  '0.111|0.333|0.222|0.444|0.666|0.555|0.777|0.999|0.888' \
  '0|0|0|0|0|0|0|0|0' \
  '||||||||' \
  1 \
  'CF-Ray: concurrent-SIN' \
  '0.100|0.200|0.050|0.300|0.400|0.250|0.500|0.600|0.450' \
  1 \
  0 \
  2000000000 \
  1900000000 \
  0 \
  0 \
  'first.example.com/second.example.com/third.example.com'
assert_equal '0' "$MOCK_RUN_STATUS" \
  'three-domain high-fidelity concurrent run succeeds'
assert_equal '12' "$(<"$MOCK_LOG_DIR/curl.count")" \
  'three domains each perform three READY samples and one strict HTTP request'
for concurrent_domain in \
  first.example.com second.example.com third.example.com; do
  assert_equal '4' \
    "$(grep -Fc "<https://$concurrent_domain/>" "$MOCK_LOG_DIR/curl.log")" \
    "$concurrent_domain performs three READY samples and one HTTP request"
done
assert_in_order "$MOCK_RUN_OUTPUT" \
  'three-domain output preserves input order' \
  first.example.com second.example.com third.example.com
assert_contains '| 222       |' "$MOCK_RUN_OUTPUT" \
  'first domain READY is the median of its full time_appconnect samples'
assert_equal '3' \
  "$(grep -Fc '| 222       |' <<<"$MOCK_RUN_OUTPUT")" \
  'every concurrent domain keeps the median of its own three samples'
assert_equal '3' \
  "$(grep -Fc \
    '| PASS   | PASS   | PASS | 222       | 1157    | HIGH | 200  | -        | PASS   |' \
    <<<"$MOCK_RUN_OUTPUT")" \
  'concurrent rows preserve TLS, X25519, H2, certificate, CDN, HTTP, redirect, and result'

BATCH_SCRIPT="$TEST_TEMP_DIR/domain-check-batch-timeout.sh"
BATCH_DRIVER="$TEST_TEMP_DIR/domain-check-batch-driver.sh"
BATCH_BIN="$TEST_TEMP_DIR/batch-mock-bin"
BATCH_LOG_DIR="$TEST_TEMP_DIR/batch-mock-log"
BATCH_BLOCK_PID_DIR="$BATCH_LOG_DIR/block-pids"
BATCH_COUNTER_LOCK="$BATCH_LOG_DIR/curl-counter-lock"
BATCH_CURL_ACTIVE="$BATCH_LOG_DIR/curl-active"
BATCH_CURL_MAX="$BATCH_LOG_DIR/curl-max"
BATCH_STDOUT="$TEST_TEMP_DIR/batch-stdout"
BATCH_STDERR="$TEST_TEMP_DIR/batch-stderr"
mkdir -p "$BATCH_BIN" "$BATCH_BLOCK_PID_DIR" \
  "$TEST_TEMP_DIR/batch-worker-tmp"
sed \
  -e 's/^readonly DOMAIN_HARD_TIMEOUT=90$/readonly DOMAIN_HARD_TIMEOUT=4/' \
  -e 's/^readonly DOMAIN_TERMINATE_GRACE=2$/readonly DOMAIN_TERMINATE_GRACE=1/' \
  -e 's/^readonly DNS_TIMEOUT=6$/readonly DNS_TIMEOUT=1/' \
  -e 's/^readonly TLS_TIMEOUT=4$/readonly TLS_TIMEOUT=1/' \
  -e 's/^readonly HTTP_TIMEOUT=10$/readonly HTTP_TIMEOUT=1/' \
  "$DOMAIN_CHECK_SCRIPT" >"$BATCH_SCRIPT"
chmod +x "$BATCH_SCRIPT"

{
  printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail'
  printf '%s\n' 'export DOMAIN_CHECK_SOURCE_ONLY=1'
  printf 'source %q\n' "$BATCH_SCRIPT"
  cat <<'EOF'
eval "$(declare -f check_domain |
  sed '1s/^check_domain /original_check_domain /')"
check_domain() {
  local index=$1
  local domain=$2
  case "$domain" in
    dig-block.example.com|openssl-block.example.com|curl-block.example.com|hard-timeout.example.com)
      original_check_domain "$index" "$domain"
      ;;
    d0[5-8].example.com)
      ACTIVE_PID_FILE="$TEMP_DIR/active-pid-$index"
      READY_SAMPLE_LOCK_HELD=false
      for sample_number in 1 2 3; do
        acquire_ready_sample_lock
        run_network_command "$TEMP_DIR/sample-$index-$sample_number" \
          "$HTTP_TIMEOUT" curl --insecure \
          "https://$domain/" || :
        release_ready_sample_lock
      done
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$domain" 203.0.113.45 PASS PASS PASS 20 30 - 200 - PASS - \
        >"$TEMP_DIR/result-$index"
      ;;
    *)
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$domain" 203.0.113.45 PASS PASS PASS 20 30 - 200 - PASS - \
        >"$TEMP_DIR/result-$index"
      ;;
  esac
}
main "$@"
EOF
} >"$BATCH_DRIVER"
chmod +x "$BATCH_DRIVER"

cat >"$BATCH_BIN/timeout" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ " $* " == *' hard-timeout.example.com '* ]]; then
  printf '%s\n' "$$" >"$BATCH_BLOCK_PID_DIR/hard-timeout.pid"
  exec sleep 300
fi
if [[ " $* " == *'/dev/tcp/'* ]]; then
  exit 0
fi
exec "$REAL_TIMEOUT" "$@"
EOF

cat >"$BATCH_BIN/dig" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
domain=${*: -1}
if [[ "$domain" == dig-block.example.com ]]; then
  printf '%s\n' "$$" >"$BATCH_BLOCK_PID_DIR/dig.pid"
  exec sleep 300
fi
if [[ "$domain" =~ ^d(0[9]|[1-3][0-9]|4[0-5])[.]example[.]com$ ]]; then
  exit 0
fi
case " $* " in
  *' A '*) printf '%s\n' '203.0.113.45' ;;
esac
EOF

cat >"$BATCH_BIN/getent" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exit 1
EOF

cat >"$BATCH_BIN/openssl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ${1:-} == x509 ]]; then
  printf 'notAfter=Aug 30 00:00:00 2026 GMT\n'
  exit 0
fi
if [[ " $* " == *' openssl-block.example.com '* ]]; then
  printf '%s\n' "$$" >"$BATCH_BLOCK_PID_DIR/openssl.pid"
  exec sleep 300
fi
if [[ " $* " == *' -groups X25519 '* ]]; then
  printf '%s\n' \
    'New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384' \
    'Peer Temp Key: X25519, 253 bits'
else
  printf '%s\n' \
    'New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384' \
    'ALPN protocol: h2' \
    '-----BEGIN CERTIFICATE-----' \
    'offline-fixture' \
    '-----END CERTIFICATE-----' \
    'Verify return code: 0 (ok)'
fi
EOF

cat >"$BATCH_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
header_file=''
request_url=''
insecure=false
while (( $# > 0 )); do
  case "$1" in
    --dump-header)
      shift
      header_file=$1
      ;;
    --insecure|-k)
      insecure=true
      ;;
    https://*)
      request_url=$1
      ;;
  esac
  shift
done

if [[ "$request_url" == 'https://curl-block.example.com/' ]]; then
  printf '%s\n' "$$" >"$BATCH_BLOCK_PID_DIR/curl.pid"
  exec sleep 300
fi

if [[ "$insecure" != true ]]; then
  : >"$header_file"
  printf 'HTTP/1.1 200 Mock\r\n\r\n' >"$header_file"
  printf 'DOMAIN_CHECK_METRICS\t200\t0.005\t0.020\n'
  exit 0
fi

while ! mkdir "$BATCH_COUNTER_LOCK" 2>/dev/null; do
  sleep 0.01
done
active=$(<"$BATCH_CURL_ACTIVE")
maximum=$(<"$BATCH_CURL_MAX")
(( active += 1 ))
printf '%s\n' "$active" >"$BATCH_CURL_ACTIVE"
if (( active > maximum )); then
  printf '%s\n' "$active" >"$BATCH_CURL_MAX"
fi
rmdir "$BATCH_COUNTER_LOCK"

sleep 0.02
printf 'DOMAIN_CHECK_METRICS\t200\t0.005\t0.020\n'

while ! mkdir "$BATCH_COUNTER_LOCK" 2>/dev/null; do
  sleep 0.01
done
active=$(<"$BATCH_CURL_ACTIVE")
(( active -= 1 ))
printf '%s\n' "$active" >"$BATCH_CURL_ACTIVE"
rmdir "$BATCH_COUNTER_LOCK"
EOF

cat >"$BATCH_BIN/date" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case " $* " in
  *' +%Y%m%d-%H%M%S '*) printf '%s\n' '20300101-000000' ;;
  *' +%Y-%m-%d %H:%M:%S UTC '*) printf '%s\n' '2030-01-01 00:00:00 UTC' ;;
  *' -d '*) printf '%s\n' '2000000000' ;;
  *) printf '%s\n' '1900000000' ;;
esac
EOF

chmod +x "$BATCH_BIN"/*
printf '0\n' >"$BATCH_CURL_ACTIVE"
printf '0\n' >"$BATCH_CURL_MAX"
batch_domains=(
  dig-block.example.com
  openssl-block.example.com
  curl-block.example.com
  hard-timeout.example.com
)
for (( batch_number = 5; batch_number <= 45; batch_number += 1 )); do
  printf -v batch_domain 'd%02d.example.com' "$batch_number"
  batch_domains+=("$batch_domain")
done
printf -v batch_argument '%s/' "${batch_domains[@]}"
batch_argument=${batch_argument%/}
real_timeout=$(command -v timeout)
batch_started=$SECONDS
set +e
PATH="$BATCH_BIN:$PATH" \
  HOME="$TEST_LOG_HOME/batch" \
  REAL_TIMEOUT="$real_timeout" \
  BATCH_BLOCK_PID_DIR="$BATCH_BLOCK_PID_DIR" \
  BATCH_COUNTER_LOCK="$BATCH_COUNTER_LOCK" \
  BATCH_CURL_ACTIVE="$BATCH_CURL_ACTIVE" \
  BATCH_CURL_MAX="$BATCH_CURL_MAX" \
  TMPDIR="$TEST_TEMP_DIR/batch-worker-tmp" \
  DOMAIN_CHECK_SOURCE_ONLY=0 \
  "$real_timeout" 20 bash "$BATCH_DRIVER" "$batch_argument" \
  >"$BATCH_STDOUT" 2>"$BATCH_STDERR"
batch_status=$?
set -e
batch_elapsed=$(( SECONDS - batch_started ))
batch_output=$(<"$BATCH_STDOUT")
batch_progress=$(<"$BATCH_STDERR")

assert_equal '1' "$batch_status" \
  '45-domain blocked-command run finishes with domain failures, not a batch timeout'
assert_less_or_equal '19' "$batch_elapsed" \
  '45-domain blocked-command run completes within the deterministic outer limit'
assert_equal '1' "$(<"$BATCH_CURL_MAX")" \
  'only the three READY curl samples are serialized across domain workers'
assert_equal '45' \
  "$(grep -Ec '^\[[0-9]+/45\] ' "$BATCH_STDERR")" \
  '45-domain blocked-command run reports every completion'
assert_contains '[45/45]' "$batch_progress" \
  'completion progress reaches the full domain count'
assert_contains '单域名检测超时（4 秒）' "$batch_output" \
  'hard-timeout domain receives an explicit complete timeout result'
assert_not_contains 'worker failed' "$batch_progress" \
  'a timed-out domain never aborts the complete batch'
assert_in_order "$batch_output" \
  'blocked-command final table preserves all 45 domains in input order' \
  "${batch_domains[@]}"
for batch_domain in "${batch_domains[@]}"; do
  escaped_batch_domain=${batch_domain//./[.]}
  assert_equal '1' \
    "$(grep -Ec \
      "^\\|[[:space:]]+${escaped_batch_domain}[[:space:]]+\\|" \
      "$BATCH_STDOUT")" \
    "$batch_domain has exactly one complete result row"
done

batch_orphans=0
shopt -s nullglob
for blocker_pid_file in "$BATCH_BLOCK_PID_DIR"/*.pid; do
  blocker_pid=$(<"$blocker_pid_file")
  if kill -0 "$blocker_pid" 2>/dev/null; then
    (( batch_orphans += 1 ))
    kill -KILL "$blocker_pid" 2>/dev/null || :
  fi
done
shopt -u nullglob
assert_equal '0' "$batch_orphans" \
  'blocked dig, OpenSSL, curl, timeout, and their children leave no orphan process'

main_block=$(sed -n '/^main() {/,/^}/p' "$DOMAIN_CHECK_SCRIPT")
# The first marker intentionally contains literal shell variable syntax.
# shellcheck disable=SC2016
assert_in_order "$main_block" \
  'progress, terminal results, and HTML logging keep their required order' \
  'while (( ${#WORKER_PIDS[@]} > 0 ))' 'clear_progress' 'print_results' \
  'write_html_log' 'exit "$final_exit_code"'

rm -f -- "$BATCH_BLOCK_PID_DIR"/*.pid
INTERRUPT_OUTPUT="$TEST_TEMP_DIR/interrupt-output"
set +e
PATH="$BATCH_BIN:$PATH" \
  HOME="$TEST_LOG_HOME/interrupt" \
  REAL_TIMEOUT="$real_timeout" \
  BATCH_BLOCK_PID_DIR="$BATCH_BLOCK_PID_DIR" \
  BATCH_COUNTER_LOCK="$BATCH_COUNTER_LOCK" \
  BATCH_CURL_ACTIVE="$BATCH_CURL_ACTIVE" \
  BATCH_CURL_MAX="$BATCH_CURL_MAX" \
  TMPDIR="$TEST_TEMP_DIR/batch-worker-tmp" \
  DOMAIN_CHECK_SOURCE_ONLY=0 \
  "$real_timeout" --preserve-status --signal=INT --kill-after=5 1 \
  bash "$BATCH_DRIVER" hard-timeout.example.com \
  >"$INTERRUPT_OUTPUT" 2>&1
interrupt_status=$?
set -e
assert_equal 'true' \
  "$([[ -s "$BATCH_BLOCK_PID_DIR/hard-timeout.pid" ]] && printf true || printf false)" \
  'interrupt fixture reaches a permanently blocked timeout child'
assert_equal '130' "$interrupt_status" \
  'Ctrl+C preserves the conventional interrupted exit status'
interrupt_blocker_pid=$(<"$BATCH_BLOCK_PID_DIR/hard-timeout.pid")
set +e
kill -0 "$interrupt_blocker_pid" 2>/dev/null
interrupt_blocker_alive=$?
set -e
assert_equal '1' "$interrupt_blocker_alive" \
  'Ctrl+C terminates the active timeout process and its blocking command'

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
  2000000000 \
  1900000000 \
  1 \
  0
assert_equal '1' "$MOCK_RUN_STATUS" \
  'failed normal OpenSSL command remains a hard failure despite TLS1.3 text'
assert_contains 'TLS 1.3 握手失败' "$MOCK_RUN_OUTPUT" \
  'failed normal OpenSSL command cannot promote parsed TLS1.3 evidence'
assert_contains 'ALPN 未协商 h2' "$MOCK_RUN_OUTPUT" \
  'failed normal OpenSSL command cannot promote parsed ALPN evidence'
assert_contains '证书链、有效期或主机名验证失败' "$MOCK_RUN_OUTPUT" \
  'failed normal OpenSSL command cannot promote certificate evidence'

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
  2000000000 \
  1900000000 \
  0 \
  1
assert_equal '1' "$MOCK_RUN_STATUS" \
  'failed X25519 OpenSSL command remains a hard failure despite key text'
assert_contains '强制 X25519 握手失败' "$MOCK_RUN_OUTPUT" \
  'failed X25519 command cannot promote parsed temporary-key evidence'

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
  'successful independent TCP probe survives incomplete TLS evidence'
assert_equal '1' \
  "$(grep -Fc '<openssl>' "$MOCK_LOG_DIR/timeout.log")" \
  'missing TLS1.3 handshake evidence skips the X25519 probe'
assert_equal '0' "$(<"$MOCK_LOG_DIR/curl.count")" \
  'missing TLS1.3 handshake evidence skips READY and HTTP curl calls'
assert_not_contains '连接就绪计时样本不足' "$MOCK_RUN_OUTPUT" \
  'skipped READY sampling does not report misleading sample insufficiency'
assert_not_contains 'HTTP 请求失败' "$MOCK_RUN_OUTPUT" \
  'skipped HTTP checking does not report a misleading request failure'

run_mocked_domain_check \
  '000|000|000' \
  '0|0|0' \
  '35|35|35' \
  '||' \
  0 \
  '' \
  '0|0|0' \
  0 \
  0 \
  2000000000 \
  1900000000 \
  1 \
  1 \
  example.com \
  0
assert_equal '1' "$MOCK_RUN_STATUS" \
  'TCP-reachable TLS1.2-only fixture fails all forced TLS1.3 probes'
assert_contains 'TLS 1.3 握手失败' "$MOCK_RUN_OUTPUT" \
  'TLS1.2-only fixture reports the TLS1.3 failure'
assert_contains '强制 X25519 握手失败' "$MOCK_RUN_OUTPUT" \
  'TLS1.2-only fixture reports the X25519 failure'
assert_contains 'ALPN 未协商 h2' "$MOCK_RUN_OUTPUT" \
  'TLS1.2-only fixture reports the missing h2 negotiation'
assert_contains '证书链、有效期或主机名验证失败' "$MOCK_RUN_OUTPUT" \
  'TLS1.2-only fixture reports unavailable forced-handshake certificate evidence'
assert_not_contains 'HTTP 请求失败' "$MOCK_RUN_OUTPUT" \
  'TLS1.2-only fixture skips the impossible HTTP check'
assert_not_contains '连接就绪计时样本不足' "$MOCK_RUN_OUTPUT" \
  'TLS1.2-only fixture skips READY rather than creating empty samples'
assert_equal '0' "$(<"$MOCK_LOG_DIR/curl.count")" \
  'TLS1.2-only fixture performs no READY or HTTP curl calls'
assert_not_contains 'TCP 443 不可达' "$MOCK_RUN_OUTPUT" \
  'TLS1.3 failure cannot overwrite a successful TCP probe'

run_mocked_domain_check \
  '200|200|200' \
  '0.010|0|0' \
  '0|35|35' \
  '||' \
  1
assert_equal '0' "$MOCK_RUN_STATUS" \
  'timing sample insufficiency is warning-only'
assert_contains '连接就绪计时样本不足（1/3）' "$MOCK_RUN_OUTPUT" \
  'one valid READY timing sample produces an explicit warning'
assert_contains 'WARN' "$MOCK_RUN_OUTPUT" \
  'timing insufficiency changes the row to WARN'

run_mocked_domain_check \
  '200|200|200' \
  '0|0|0' \
  '0|0|0' \
  '||' \
  1 '' '0.005|0.006|0.007' 1 0 2000000000 1900000000 \
  0 0 example.com 0 \
  '35|35|35' '0|0|0'
assert_equal '0' "$MOCK_RUN_STATUS" \
  'deterministic READY curl failure remains warning-only'
assert_equal '2' "$(<"$MOCK_LOG_DIR/curl.count")" \
  'deterministic READY failure stops after one sample and still checks HTTP once'
assert_equal '1' \
  "$(grep -Fc '<--insecure>' "$MOCK_LOG_DIR/curl.log")" \
  'deterministic READY failure performs only one locked timing attempt'
assert_equal '1' \
  "$(grep -Fc '<--dump-header>' "$MOCK_LOG_DIR/curl.log")" \
  'READY failure releases the lock before the strict HTTP check'
assert_contains '连接就绪计时样本不足（0/3）' "$MOCK_RUN_OUTPUT" \
  'deterministic READY failure reports its zero successful samples'

run_mocked_domain_check \
  '200|200|200' \
  '0.010|0.020|0.030' \
  '0|0|0' \
  '||' \
  1 '' '0.005|0.006|0.007' 1 0 2000000000 1900000000 \
  0 0 example.com 0 \
  '0|0|0' '60|60|60'
assert_equal '0' "$MOCK_RUN_STATUS" \
  'deterministic strict HTTP failure remains warning-only'
assert_equal '4' "$(<"$MOCK_LOG_DIR/curl.count")" \
  'deterministic HTTP failure stops after one strict attempt'
assert_equal '1' \
  "$(grep -Fc '<--dump-header>' "$MOCK_LOG_DIR/curl.log")" \
  'deterministic HTTP curl error is not retried three times'
assert_contains 'HTTP 请求失败' "$MOCK_RUN_OUTPUT" \
  'deterministic HTTP failure retains the existing warning detail'

run_mocked_domain_check \
  '503|503|503' \
  '0.010|0.020|0.030' \
  '0|0|0' \
  '||' \
  1
assert_equal '0' "$MOCK_RUN_STATUS" \
  'three HTTP 5xx responses remain warning-only'
assert_equal '6' "$(<"$MOCK_LOG_DIR/curl.count")" \
  'HTTP 5xx retains all three strict retries after three READY samples'
assert_contains '连续 3 次 5xx' "$MOCK_RUN_OUTPUT" \
  'HTTP 5xx retains the existing consecutive-retry detail'

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
  2000000000 \
  1900000000 \
  0 \
  0 \
  example.com \
  1
assert_equal '1' "$MOCK_RUN_STATUS" \
  'explicit TCP 443 failure stops the domain as a hard failure'
assert_contains 'TCP 443 不可达' "$MOCK_RUN_OUTPUT" \
  'explicit TCP failure is reported without downstream probing'
assert_not_contains 'DNS 无法解析' "$MOCK_RUN_OUTPUT" \
  'resolved address is not mislabeled as DNS failure'
assert_equal '0' "$(<"$MOCK_LOG_DIR/curl.count")" \
  'explicit TCP failure skips all READY and HTTP curl calls'
assert_equal '0' \
  "$(grep -Fc '<openssl>' "$MOCK_LOG_DIR/timeout.log")" \
  'explicit TCP failure skips TLS and X25519 OpenSSL calls'
assert_not_contains 'HTTP 请求失败' "$MOCK_RUN_OUTPUT" \
  'TCP fail-fast does not add a misleading HTTP failure'
assert_not_contains '连接就绪计时样本不足' "$MOCK_RUN_OUTPUT" \
  'TCP fail-fast does not add a misleading READY warning'
failed_html_log=$(find "$TEST_LOG_HOME/mock/domain-check-logs" \
  -maxdepth 1 -type f -name 'domain-check-*.html' -print -quit)
assert_equal 'true' \
  "$([[ -n "$failed_html_log" && -s "$failed_html_log" ]] &&
    printf true || printf false)" \
  'exit-1 detector run still writes a complete HTML log'
assert_file_contains \
  '<span class="summary-item status-fail"><span>FAIL</span><strong>1</strong></span>' \
  "$failed_html_log" 'failed HTML log contains the FAIL summary'
assert_file_contains '<li class="detail-fail">TCP 443 不可达</li>' \
  "$failed_html_log" 'failed HTML log contains structured DETAILS'

run_mocked_domain_check \
  '000|000|000' \
  '0|0|0' \
  '7|7|7' \
  '||' \
  0 \
  '' \
  '0|0|0' \
  0 \
  0 \
  2000000000 \
  1900000000 \
  1 \
  1 \
  example.com \
  1
assert_equal '1' "$MOCK_RUN_STATUS" \
  'TCP 443 remains a hard failure when the independent probe fails'
assert_contains 'TCP 443 不可达' "$MOCK_RUN_OUTPUT" \
  'TCP failure is reported before downstream checks begin'
assert_equal '0' "$(<"$MOCK_LOG_DIR/curl.count")" \
  'TCP failure never enters the global READY lock or HTTP retry loops'

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
assert_contains 'READY(ms)' "$MOCK_RUN_OUTPUT" \
  'redirect output retains the connection-ready timing header'
assert_not_contains 'HS(ms)' "$MOCK_RUN_OUTPUT" \
  'redirect output does not restore the old handshake header'

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
