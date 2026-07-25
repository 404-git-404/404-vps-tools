#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly TEST_DIR
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd)
readonly REPO_ROOT
readonly DOMAIN_CHECK_SCRIPT="$REPO_ROOT/domain-check.sh"

export DOMAIN_CHECK_SOURCE_ONLY=1
# The path is anchored to this test file, rather than the caller's directory.
# shellcheck disable=SC1090
source "$DOMAIN_CHECK_SCRIPT"

TEST_COUNT=0

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

assert_parse 'example.com' 'example.com'
assert_parse 'example.com/test.com' 'example.com/test.com'
assert_parse 'EXAMPLE.COM/Test.COM' 'example.com/test.com'
assert_parse 'example.com/example.com/test.com' 'example.com/test.com'

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

assert_aggregate 0 PASS PASS
assert_aggregate 0 PASS WARN
assert_aggregate 0 WARN WARN
assert_aggregate 1 PASS FAIL
assert_aggregate 1 WARN FAIL

printf 'PASS: %d offline assertions\n' "$TEST_COUNT"
