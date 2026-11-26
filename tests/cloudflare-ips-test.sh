#!/usr/bin/env bash
# shellcheck disable=SC2016 # Single quotes keep sed scripts and generated shell literal.
# The Cloudflare 8443 refresh tool embedded in debian-init.sh must validate the downloaded IP lists
# before it touches UFW: a bad download leaves the existing rules alone and warns.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir "$work/bin" "$work/fixtures"
export STUB_BIN="$work/bin" FIXTURES="$work/fixtures" UFW_LOG="$work/ufw.log"
# A test machine without python3 on PATH (for example Git Bash on Windows) may offer python.
if ! python3 -c 'import ipaddress' 2>/dev/null; then
  python_path=$(command -v python) || fail 'python3 is required'
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$python_path" >"$work/bin/python3"
  chmod +x "$work/bin/python3"
fi

# Extract the embedded tool exactly as CI does, then point it at the test directory.
awk '/<<.CFEOF./ { capture=1; next } capture && $0 == "CFEOF" { exit } capture { print }' "$repo/debian-init.sh" >"$work/original-tool"
test -s "$work/original-tool"
printf 'IPV6=yes\n' >"$work/ufw-default"
sed -e "s|mktemp -d /root/vps-init-cf\\.|mktemp -d \"$work/\"vps-init-cf.|" \
    -e 's|\[\[ \$EUID -eq 0 \]\]|true|' \
    -e "s|/etc/default/ufw|$work/ufw-default|" \
    -e 's|^export PATH=.*|export PATH="$STUB_BIN:/usr/local/bin:/usr/bin:/bin"|' \
    "$work/original-tool" >"$work/tool"
if grep -Fq '/root/' "$work/tool"; then fail 'tool still writes under /root'; fi
grep -Fq "$work/ufw-default" "$work/tool" || fail 'ufw defaults path was not redirected'
grep -Fq 'STUB_BIN' "$work/tool" || fail 'PATH was not redirected'

cat >"$work/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -Eeuo pipefail
url='' output='' proto=no
while (( $# )); do
  case "$1" in
    -o) output=$2; shift 2 ;;
    --proto) [[ "$2" == '=https' ]] && proto=yes; shift 2 ;;
    https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
[[ "$proto" == yes ]] || { echo 'download is not restricted to https' >&2; exit 90; }
case "$url" in
  https://www.cloudflare.com/ips-v4) name=v4 ;;
  https://www.cloudflare.com/ips-v6) name=v6 ;;
  *) echo "unexpected URL $url" >&2; exit 91 ;;
esac
[[ -f "$FIXTURES/$name" ]] || exit 22
cp "$FIXTURES/$name" "$output"
CURL
cat >"$work/bin/ufw" <<'UFW'
#!/usr/bin/env bash
case "$*" in
  status)
    echo 'Status: active'
    if grep -q '^allow' "$UFW_LOG" 2>/dev/null; then echo '8443/tcp ALLOW 1.2.3.0/24 # vps-init-cf8443'; fi ;;
  'status numbered') : ;;
  *) echo "$*" >>"$UFW_LOG" ;;
esac
UFW
chmod +x "$work/bin/curl" "$work/bin/ufw"

good_v4='173.245.48.0/20
103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
141.101.64.0/18
108.162.192.0/18
190.93.240.0/20
188.114.96.0/20
197.234.240.0/22
198.41.128.0/17
162.158.0.0/15
104.16.0.0/13
104.24.0.0/14
172.64.0.0/13
131.0.72.0/22'
good_v6='2400:cb00::/32
2606:4700::/32
2803:f800::/32
2405:b500::/32
2405:8100::/32
2a06:98c0::/29
2c0f:f248::/32'
v4_count() { local i; for ((i = 1; i <= $1; i++)); do printf '11.0.%d.0/24\n' "$i"; done; }
v6_count() { local i; for ((i = 1; i <= $1; i++)); do printf '2600:%x::/32\n' "$i"; done; }

# run NAME EXPECTED(pass|fail) V4_CONTENT V6_CONTENT; a content of -- means "no file" (download fails).
run() {
  local name=$1 expected=$2 v4=$3 v6=$4 rc=0
  rm -f "$FIXTURES"/v4 "$FIXTURES"/v6
  if [[ "$v4" != -- ]]; then printf '%s\n' "$v4" >"$FIXTURES/v4"; fi
  if [[ "$v6" != -- ]]; then printf '%s\n' "$v6" >"$FIXTURES/v6"; fi
  : >"$UFW_LOG"
  bash "$work/tool" >"$work/stdout" 2>"$work/stderr" || rc=$?
  if [[ "$expected" == pass ]]; then
    [[ "$rc" == 0 ]] || { cat "$work/stderr" >&2; fail "$name: rejected a valid download (rc=$rc)"; }
    grep -q '^allow' "$UFW_LOG" || fail "$name: no rule was installed"
  else
    [[ "$rc" != 0 ]] || fail "$name: accepted an invalid download"
    if [[ -s "$UFW_LOG" ]]; then cat "$UFW_LOG" >&2; fail "$name: touched UFW although the download was invalid"; fi
    grep -Fq 'WARNING:' "$work/stderr" || { cat "$work/stderr" >&2; fail "$name: no warning was printed"; }
    grep -Fq 'left unchanged' "$work/stderr" || fail "$name: warning does not say the rules were kept"
  fi
}

run 'real lists' pass "$good_v4" "$good_v6"
[[ "$(grep -c '^allow' "$UFW_LOG")" == 22 ]] || fail "expected 15 IPv4 + 7 IPv6 rules, got $(grep -c '^allow' "$UFW_LOG")"
grep -Fq 'from 173.245.48.0/20 to any port 8443' "$UFW_LOG" || fail 'rule for the first range is missing'
run 'CRLF line endings and blank lines' pass "$(printf '%s\n' "$good_v4" | sed 's/$/\r/')"$'\n\n' "$(printf '%s\n' "$good_v6" | sed 's/$/\r/')"
run 'duplicates are collapsed' pass "$good_v4"$'\n'"$good_v4" "$good_v6"
[[ "$(grep -c '^allow' "$UFW_LOG")" == 22 ]] || fail 'duplicates were installed twice'
run 'minimum counts (5 IPv4, 3 IPv6)' pass "$(v4_count 5)" "$(v6_count 3)"
run 'maximum counts (100 and 100)' pass "$(v4_count 100)" "$(v6_count 100)"

run 'empty IPv4 list' fail '' "$good_v6"
run 'empty IPv6 list' fail "$good_v4" ''
run 'whitespace-only list' fail '   ' "$good_v6"
run 'download failure IPv4' fail -- "$good_v6"
run 'download failure IPv6' fail "$good_v4" --
run 'IPv4 below minimum (4)' fail "$(v4_count 4)" "$good_v6"
run 'IPv4 above maximum (101)' fail "$(v4_count 101)" "$good_v6"
run 'IPv6 below minimum (2)' fail "$good_v4" "$(v6_count 2)"
run 'IPv6 above maximum (101)' fail "$good_v4" "$(v6_count 101)"
run 'HTML error page' fail '<html><body>Access denied</body></html>' "$good_v6"
run 'comment line' fail "$good_v4"$'\n# note' "$good_v6"
run 'bare IPv4 address' fail "$good_v4"$'\n1.1.1.1' "$good_v6"
run 'bare IPv6 address' fail "$good_v4" "$good_v6"$'\n2606:4700::1111'
run 'invalid prefix length' fail "$good_v4"$'\n1.2.3.0/33' "$good_v6"
run 'host bits set' fail "$good_v4"$'\n173.245.48.1/20' "$good_v6"
run 'IPv6 range inside the IPv4 list' fail "$good_v4"$'\n2606:4700::/32' "$good_v6"
run 'IPv4 range inside the IPv6 list' fail "$good_v4" "$good_v6"$'\n104.16.0.0/13'
run 'catch-all 0.0.0.0/0' fail "$good_v4"$'\n0.0.0.0/0' "$good_v6"
run 'catch-all ::/0' fail "$good_v4" "$good_v6"$'\n::/0'
run 'IPv4 range wider than /8' fail "$good_v4"$'\n64.0.0.0/7' "$good_v6"
run 'carrier-grade NAT 100.64.0.0/10 (not global)' fail "$good_v4"$'\n100.64.0.0/10' "$good_v6"
run 'IPv6 range far too wide 2000::/15' fail "$good_v4" "$good_v6"$'\n2000::/15'
run 'private 10.0.0.0/8' fail "$good_v4"$'\n10.0.0.0/8' "$good_v6"
run 'private 192.168.0.0/16' fail "$good_v4"$'\n192.168.0.0/16' "$good_v6"
run 'loopback 127.0.0.0/8' fail "$good_v4"$'\n127.0.0.0/8' "$good_v6"
run 'multicast 224.0.0.0/8' fail "$good_v4"$'\n224.0.0.0/8' "$good_v6"
run 'IPv6 unique-local fc00::/7' fail "$good_v4" "$good_v6"$'\nfc00::/7'
run 'non-ASCII bytes' fail "$good_v4"$'\n\xc3\xa9' "$good_v6"

# The pre-existing managed rules survive an invalid download: no delete is ever issued.
run 'invalid download keeps old rules' fail '<html>' "$good_v6"
if grep -Fq 'delete' "$UFW_LOG"; then fail 'a managed rule was deleted'; fi

echo 'PASS: Cloudflare IP lists are validated before UFW is touched'
