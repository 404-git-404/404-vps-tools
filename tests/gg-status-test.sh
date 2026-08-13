#!/usr/bin/env bash

set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$repo_root/gg-status"
test_shell=${GG_STATUS_SHELL:-/bin/sh}
test_root=$(mktemp -d)
mock_bin="$test_root/bin"
curl_log="$test_root/curl.log"

cleanup() {
  rm -rf -- "$test_root"
}

trap cleanup EXIT
mkdir -p "$mock_bin"

cat > "$mock_bin/curl" <<'EOF'
#!/bin/sh

set -eu

url=''
for argument do
  case $argument in
    https://*) url=$argument ;;
  esac
done

case $url in
  https://www.youtube.com/premium) service=youtube ;;
  https://www.google.com/search*) service=search ;;
  https://accounts.google.com/) service=login ;;
  https://gemini.google.com/) service=gemini ;;
  *) exit 2 ;;
esac

printf '%s\n' "$service" >> "$GG_CURL_LOG"

case $service in
  youtube) fixture=${GG_YOUTUBE_CASE:-not_cn} ;;
  search) fixture=${GG_SEARCH_CASE:-normal} ;;
  login) fixture=${GG_LOGIN_CASE:-normal} ;;
  gemini) fixture=${GG_GEMINI_CASE:-region} ;;
esac

[ "$fixture" != failure ] || exit 1

status=200
type='text/html; charset=utf-8'
effective_url=$url

case "$service:$fixture" in
  youtube:google_cn) body='<html><title>YouTube Premium</title>www.google.cn</html>' ;;
  youtube:inner_cn) body='<html>{"INNERTUBE_CONTEXT_GL":"CN"}</html>' ;;
  youtube:content_cn) body='<html>{"contentRegion":"CN"}</html>' ;;
  youtube:not_cn) body='<html>{"INNERTUBE_CONTEXT_GL":"US","contentRegion":"JP"}</html>' ;;
  youtube:content_jp) body='<html>{"contentRegion":"JP"}</html>' ;;
  youtube:invalid_region) body='<html>{"INNERTUBE_CONTEXT_GL":"usa"}</html>' ;;
  youtube:consent) body='<html><title>Before you continue to YouTube</title></html>' ;;
  youtube:unknown) body='<html><title>YouTube</title></html>' ;;
  search:normal) body='<html><title>curl - Google Search</title><form action="/search" method="get"></form></html>' ;;
  search:captcha) body='<html><title>Google</title><script src="/recaptcha/api.js"></script></html>' ;;
  search:unusual) body='<html><title>Google</title>Our systems have detected unusual traffic from your computer network</html>' ;;
  search:sorry) body='<html><title>Sorry...</title></html>'; effective_url='https://www.google.com/sorry/index' ;;
  search:blocked) body='<html><title>Access denied</title>Your request has been blocked</html>'; status=403 ;;
  search:malformed) body='<html><title>Unexpected</title></html>' ;;
  search:empty) body='' ;;
  login:normal) body='<html><title>Sign in - Google Accounts</title><input id="identifierId" name="identifier"><button id="identifierNext"></button></html>'; effective_url='https://accounts.google.com/v3/signin/identifier?continue=x' ;;
  login:challenge) body='<html><title>Verify your identity</title></html>'; effective_url='https://accounts.google.com/v3/signin/challenge/pwd' ;;
  login:unusual) body='<html>Unusual traffic from your computer network</html>'; effective_url='https://accounts.google.com/v3/signin/identifier' ;;
  login:blocked) body='<html><title>Access denied</title>Your request has been blocked</html>'; status=403 ;;
  login:unexpected) body='<html><title>Google</title></html>' ;;
  login:empty) body='' ;;
  gemini:region) body='<html><title>Google Gemini</title>45631641,null,true,2,1,200,"USA"</html>' ;;
  gemini:available) body='<html><title>Google Gemini</title>45631641,null,true</html>' ;;
  gemini:blocked) body='<html><title>Google Gemini</title>45631641,null,false</html>' ;;
  gemini:blocked_text) body='<html><title>Google Gemini</title>Gemini is not available in your country</html>' ;;
  gemini:malformed) body='<html><title>Gemini</title>45631641,null,true,2,1,200,"US"</html>' ;;
  gemini:empty) body='' ;;
  *) exit 3 ;;
esac

case ${GG_LARGE_CASE:-} in
  youtube_start_2m)
    if [ "$service" = youtube ]; then
      printf '%s' '<html>www.google.cn'
      awk 'BEGIN { for (i = 0; i < 2097152; i += 1024) printf "%01024d", 0 }'
      body='</html>'
    fi
    ;;
  search_middle_2m)
    if [ "$service" = search ]; then
      awk 'BEGIN { for (i = 0; i < 1048576; i += 1024) printf "%01024d", 0 }'
      printf '%s' '<html><title>Google Search</title><a href="/search?q=test">test</a>'
      awk 'BEGIN { for (i = 0; i < 1048576; i += 1024) printf "%01024d", 0 }'
      body='</html>'
    fi
    ;;
  gemini_end_5m)
    if [ "$service" = gemini ]; then
      awk 'BEGIN { for (i = 0; i < 5241856; i += 1024) printf "%01024d", 0 }'
      body='<html><title>Google Gemini</title>45631641,null,true,2,1,200,"USA"</html>'
    fi
    ;;
esac

printf '%s\n__GG_STATUS_METADATA__:%s|%s|%s' "$body" "$status" "$effective_url" "$type"
EOF
chmod +x "$mock_bin/curl"

default_youtube='YouTube: NOT_CN [US]'
default_search='Google Search: OK'
default_login='Google Sign-in: REACHABLE'
default_gemini='Gemini: AVAILABLE [USA]'

run_fixture() {
  local name service fixture expected_line output expected
  local youtube_case search_case login_case gemini_case

  name=$1
  service=$2
  fixture=$3
  expected_line=$4
  youtube_case=not_cn
  search_case=normal
  login_case=normal
  gemini_case=region

  case $service in
    youtube) youtube_case=$fixture ;;
    search) search_case=$fixture ;;
    login) login_case=$fixture ;;
    gemini) gemini_case=$fixture ;;
  esac

  : > "$curl_log"
  output=$(
    GG_CURL_LOG="$curl_log" \
    GG_YOUTUBE_CASE="$youtube_case" \
    GG_SEARCH_CASE="$search_case" \
    GG_LOGIN_CASE="$login_case" \
    GG_GEMINI_CASE="$gemini_case" \
    PATH="$mock_bin:$PATH" \
    "$test_shell" "$script"
  )

  case $service in
    youtube) printf -v expected '%s\n%s\n%s\n%s' "$expected_line" "$default_search" "$default_login" "$default_gemini" ;;
    search) printf -v expected '%s\n%s\n%s\n%s' "$default_youtube" "$expected_line" "$default_login" "$default_gemini" ;;
    login) printf -v expected '%s\n%s\n%s\n%s' "$default_youtube" "$default_search" "$expected_line" "$default_gemini" ;;
    gemini) printf -v expected '%s\n%s\n%s\n%s' "$default_youtube" "$default_search" "$default_login" "$expected_line" ;;
  esac

  if [[ $output != "$expected" ]]; then
    printf 'FAIL %s\nexpected:\n%s\nactual:\n%s\n' "$name" "$expected" "$output" >&2
    exit 1
  fi
  if [[ $(wc -l < "$curl_log") -ne 4 ]] ||
     [[ $(paste -sd, "$curl_log") != youtube,search,login,gemini ]]; then
    printf 'FAIL %s: unexpected curl invocation sequence\n' "$name" >&2
    exit 1
  fi
  printf 'PASS %s\n' "$name"
}

run_large_fixture() {
  local name large_case expected_line started elapsed output

  name=$1
  large_case=$2
  expected_line=$3

  : > "$curl_log"
  started=$(date +%s%N)
  output=$(
    GG_CURL_LOG="$curl_log" \
    GG_LARGE_CASE="$large_case" \
    PATH="$mock_bin:$PATH" \
    "$test_shell" "$script"
  )
  elapsed=$((($(date +%s%N) - started) / 1000000))

  if ! grep -Fqx "$expected_line" <<< "$output"; then
    printf 'FAIL %s: expected output missing\n' "$name" >&2
    exit 1
  fi
  if ((elapsed >= 1000)); then
    printf 'FAIL %s: parsing took %dms\n' "$name" "$elapsed" >&2
    exit 1
  fi
  if [[ $(wc -l < "$curl_log") -ne 4 ]]; then
    printf 'FAIL %s: expected four curl invocations\n' "$name" >&2
    exit 1
  fi
  printf 'PASS %s (%dms)\n' "$name" "$elapsed"
}

run_fixture youtube-google-cn youtube google_cn 'YouTube: CN'
run_fixture youtube-inner-cn youtube inner_cn 'YouTube: CN'
run_fixture youtube-content-cn youtube content_cn 'YouTube: CN'
run_fixture youtube-not-cn youtube not_cn 'YouTube: NOT_CN [US]'
run_fixture youtube-content-jp youtube content_jp 'YouTube: NOT_CN [JP]'
run_fixture youtube-invalid-region youtube invalid_region 'YouTube: UNKNOWN'
run_fixture youtube-consent youtube consent 'YouTube: UNKNOWN'
run_fixture youtube-unknown youtube unknown 'YouTube: UNKNOWN'
run_fixture youtube-curl-failure youtube failure 'YouTube: UNKNOWN'

run_fixture search-normal search normal 'Google Search: OK'
run_fixture search-captcha search captcha 'Google Search: CHALLENGE'
run_fixture search-unusual search unusual 'Google Search: CHALLENGE'
run_fixture search-sorry search sorry 'Google Search: CHALLENGE'
run_fixture search-blocked search blocked 'Google Search: BLOCKED'
run_fixture search-malformed search malformed 'Google Search: UNKNOWN'
run_fixture search-empty search empty 'Google Search: UNKNOWN'
run_fixture search-curl-failure search failure 'Google Search: UNKNOWN'

run_fixture login-normal login normal 'Google Sign-in: REACHABLE'
run_fixture login-challenge login challenge 'Google Sign-in: CHALLENGE'
run_fixture login-unusual login unusual 'Google Sign-in: CHALLENGE'
run_fixture login-blocked login blocked 'Google Sign-in: BLOCKED'
run_fixture login-unexpected login unexpected 'Google Sign-in: UNKNOWN'
run_fixture login-empty login empty 'Google Sign-in: UNKNOWN'
run_fixture login-curl-failure login failure 'Google Sign-in: UNKNOWN'

run_fixture gemini-region gemini region 'Gemini: AVAILABLE [USA]'
run_fixture gemini-available gemini available 'Gemini: AVAILABLE'
run_fixture gemini-blocked gemini blocked 'Gemini: BLOCKED'
run_fixture gemini-blocked-text gemini blocked_text 'Gemini: BLOCKED'
run_fixture gemini-malformed gemini malformed 'Gemini: UNKNOWN'
run_fixture gemini-empty gemini empty 'Gemini: UNKNOWN'
run_fixture gemini-curl-failure gemini failure 'Gemini: UNKNOWN'

run_large_fixture youtube-large-start-2mb youtube_start_2m 'YouTube: CN'
run_large_fixture search-large-middle-2mb search_middle_2m 'Google Search: OK'
run_large_fixture gemini-large-near-end-5mb gemini_end_5m 'Gemini: AVAILABLE [USA]'
