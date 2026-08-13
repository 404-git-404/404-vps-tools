#!/usr/bin/env bash

set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)

cleanup() {
  rm -rf -- "$test_root"
}

trap cleanup EXIT

cat > "$test_root/curl" <<'EOF'
#!/bin/sh

set -eu

url=''
for argument do
  case $argument in
    https://*) url=$argument ;;
  esac
done

case $url in
  https://www.youtube.com/premium)
    effective_url=$url
    case ${GG_CONTAINER_CASE:-normal} in
      normal) body='<html>{"INNERTUBE_CONTEXT_GL":"US"}</html>' ;;
      mixed) body='<html>www.google.cn</html>' ;;
    esac
    ;;
  https://www.google.com/search*)
    effective_url=$url
    case ${GG_CONTAINER_CASE:-normal} in
      normal) body='<html><title>Google Search</title><a href="/search?q=test">test</a></html>' ;;
      mixed) body='<html>Our systems have detected unusual traffic from your computer network</html>' ;;
    esac
    ;;
  https://accounts.google.com/)
    case ${GG_CONTAINER_CASE:-normal} in
      normal)
        body='<html><title>Sign in - Google Accounts</title><input id="identifierId" name="identifier"><button id="identifierNext"></button></html>'
        effective_url='https://accounts.google.com/v3/signin/identifier'
        ;;
      mixed)
        body='<html><title>Access denied</title>Your request has been blocked</html>'
        effective_url=$url
        ;;
    esac
    ;;
  https://gemini.google.com/)
    effective_url=$url
    case ${GG_CONTAINER_CASE:-normal} in
      normal) body='<html><title>Google Gemini</title>45631641,null,true,2,1,200,"USA"</html>' ;;
      mixed) body='<html><title>Google Gemini</title>45631641,null,false</html>' ;;
    esac
    ;;
  *) exit 2 ;;
esac

printf '%s\n__GG_STATUS_METADATA__:200|%s|text/html; charset=utf-8' "$body" "$effective_url"
EOF
chmod +x "$test_root/curl"

run_container() {
  local image install_command

  image=$1
  install_command=$2

  docker run --rm \
    -v "$repo_root:/work:ro" \
    -v "$test_root:/fixture:ro" \
    "$image" /bin/sh -c "
      $install_command
      /bin/sh -n /work/gg-status
      normal=\$(PATH=/fixture:\$PATH /bin/sh /work/gg-status)
      expected_normal='YouTube: NOT_CN [US]
Google Search: OK
Google Sign-in: REACHABLE
Gemini: AVAILABLE [USA]'
      test \"\$normal\" = \"\$expected_normal\"
      mixed=\$(GG_CONTAINER_CASE=mixed PATH=/fixture:\$PATH /bin/sh /work/gg-status)
      expected_mixed='YouTube: CN
Google Search: CHALLENGE
Google Sign-in: BLOCKED
Gemini: BLOCKED'
      test \"\$mixed\" = \"\$expected_mixed\"
    "
}

run_container debian:12-slim 'apt-get update >/dev/null && apt-get install --yes --no-install-recommends curl mawk >/dev/null'
run_container alpine:latest 'apk add --no-cache curl >/dev/null'
