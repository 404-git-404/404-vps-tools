#!/usr/bin/env bash
# shellcheck disable=SC2329,SC2034 # Test doubles/state are called by the sourced installer.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
fail() { echo "FAIL: $*" >&2; exit 1; }

if [[ "${1:-}" == --integration ]]; then
  [[ -f /.dockerenv && "$repo" == /repo ]] || fail 'requires the isolated CI container'
  # shellcheck disable=SC1091
  source "$repo/debian-init.sh"
  BACKUP_DIR="$work/backup"
  TMP_DIR="$work/tmp"
  mkdir -p "$BACKUP_DIR" "$TMP_DIR"
  backup_ufw_state
  original_ufw_active=$UFW_OLD_ACTIVE
  trap 'UFW_TX=true; UFW_OLD_ACTIVE=$original_ufw_active; rollback_ufw; rm -rf -- "$work"' EXIT
  ufw --force reset >/dev/null
  set_ufw_ipv6 no
  ufw allow 45671/tcp comment 'operator tcp (v6) text'
  ufw allow 45671/udp comment 'operator udp'
  ufw deny out 45672:45674/tcp comment 'outbound range'
  ufw reject 45675/udp comment 'reject fixture'
  ufw allow proto tcp from 192.0.2.0/24 to any port 45676
  ufw limit 45677/tcp
  ufw allow in on lo to any port 45678 proto tcp
  ufw allow OpenSSH
  ufw route allow proto tcp from any to any port 45679
  # Earlier IPv4 DENY must precede a pre-existing broad IPv6 ALLOW.
  ufw deny 45680/tcp comment 'exception before broad allow'
  ufw allow 45680:45690/tcp comment 'broad allow'
  set_ufw_ipv6 yes
  ufw allow from ::/0 to ::/0 port 45680:45690 proto tcp comment 'existing v6 owner'
  ufw deny from 2001:db8::1 to 2001:db8::2 port 45691 proto tcp
  # A multi-tuple application has one displayed rule number. Its IPv4 rules
  # must survive family-specific numbered deletion.
  cat >/etc/ufw/applications.d/vps-init-test <<'PROFILE'
[Fixture v6]
title=UFW family fixture
description=Disposable CI fixture
ports=45692/tcp|45693/udp
PROFILE
  ufw allow 'Fixture v6'
  set_ufw_ipv6 no
  for request in dual ipv4 dual dual; do
    ufw_is_active && UFW_OLD_ACTIVE=true || UFW_OLD_ACTIVE=false
    NETWORK_REQUEST=$request NETWORK_STACK=$request SSH_PORT=43210 KEEP_SSH_22=false UFW_TX=true
    configure_ufw
    ufw status numbered >"$work/status"
    if [[ "$request" == ipv4 ]]; then
      grep -Fx 'IPV6=no' "$UFW_DEFAULT"
      if grep -q '^### tuple ### ' "$UFW_RULES6"; then fail 'IPv6 tuples remain'; fi
      if ip6tables -S ufw6-user-input 2>/dev/null; then fail 'IPv6 kernel chain remains'; fi
    else
      grep -Fx 'IPV6=yes' "$UFW_DEFAULT"
      grep -F '45671/tcp (v6)' "$work/status" | grep -F '# operator tcp (v6) text'
      grep -F '45671/udp (v6)' "$work/status"
      grep -F '45672:45674/tcp (v6)' "$work/status" | grep -F 'DENY OUT'
      grep -F '45675/udp (v6)' "$work/status" | grep -F 'REJECT IN'
      if grep -Eq '^### tuple ### .* (45676|45677|45678|45679) ' "$UFW_RULES6"; then fail 'copied complex rule'; fi
      [[ "$(grep -c '^### tuple ### allow tcp 45671 ' "$UFW_RULES6")" == 1 ]]
      ip6tables -S ufw6-user-input | grep -F -- '--dport 45671 -j ACCEPT'
      ip6tables -S ufw6-user-output | grep -F -- '--dport 45672:45674 -j DROP'
      ip6tables -S ufw6-user-input | grep -F -- '--dport 45675 -j REJECT'
      deny_line=$(grep -n '^### tuple ### deny tcp 45680 ' "$UFW_RULES6" | cut -d: -f1)
      allow_line=$(grep -n '^### tuple ### allow tcp 45680:45690 ' "$UFW_RULES6" | cut -d: -f1)
      (( deny_line < allow_line ))
    fi
    grep -F 'operator tcp (v6) text' "$work/status" | grep -F '45671/tcp '
    grep -q '^### tuple ### allow tcp 45676 .*192.0.2.0/24' "$UFW_RULES"
    grep -q 'Fixture%20v6' "$UFW_RULES"
  done
  # Auto failure keeps all IPv6 rules and the switch; preserve mode is a no-op.
  cp "$UFW_RULES6" "$work/v6"
  NETWORK_REQUEST=auto NETWORK_STACK=ipv4 UFW_TX=true
  ufw_is_active && UFW_OLD_ACTIVE=true || UFW_OLD_ACTIVE=false
  configure_ufw
  cmp "$work/v6" "$UFW_RULES6"
  PRESERVE_SSH=true
  sha256sum "$UFW_DEFAULT" "$UFW_RULES" "$UFW_RULES6" >"$work/before"
  NETWORK_REQUEST=ipv4 configure_ufw
  sha256sum --check "$work/before"
  echo 'PASS: real UFW IPv6 switch, rule ordering, reload and kernel rules'
  exit 0
fi

mkdir -p "$work/ufw" "$work/tmp"
sed -e "s|/etc/default/ufw|$work/default|g" -e "s|/etc/ufw|$work/ufw|g" \
  "$repo/debian-init.sh" >"$work/installer"
# shellcheck disable=SC1091
source "$work/installer"
trap - ERR HUP INT TERM
trap 'rc=$?; if (( rc )); then tail -70 "$work/warnings" 2>/dev/null || true; fi; rm -rf -- "$work"; exit "$rc"' EXIT
TMP_DIR="$work/tmp"
make_mutable() { :; }
install() { [[ "$1" == -d && "$2" == -m ]] || fail 'unexpected install'; mkdir -p -- "${@:4}"; }
rollback_ssh() { if [[ "$SSH_TX" == true ]]; then echo ssh-rollback >>"$work/trace"; SSH_TX=false; fi; }
ufw_ipv6_rule_numbers() {
  local v4 v6 n
  v4=$(grep -c '^### tuple ### ' "$UFW_RULES" || true)
  v6=$(grep -c '^### tuple ### ' "$UFW_RULES6" || true)
  for ((n=v4+v6; n>v4; n--)); do echo "$n"; done
}

mock_add() {
  local path=$1 tuple=$2 position=$3 entry key=${2#* } old_key found=false index=0
  local -a entries=() result=()
  mapfile -t entries <"$path"
  for entry in "${entries[@]}"; do
    old_key=${entry#'### tuple ### '}; old_key=${old_key#* }; old_key=${old_key%' comment='*}
    if [[ "$old_key" == "${key%' comment='*}" ]]; then found=true; fi
  done
  # A prepend/insert must not overwrite an existing owner/action.
  if [[ "$found" == true ]]; then return 0; fi
  for entry in "${entries[@]}"; do
    if (( position == index )); then result+=("### tuple ### $tuple"); fi
    result+=("$entry")
    index=$((index + 1))
  done
  if (( position < 0 || position >= index )); then result+=("### tuple ### $tuple"); fi
  printf '%s\n' "${result[@]}" >"$path"
}

ufw() {
  local IFS=' '
  printf '%s\n' "$*" >>"$work/trace"
  local enabled=false family file entry n=0 action protocol port dst sport src direction body comment token position=-1 explicit=false
  local -a parts=() selected=() kept=()
  if grep -q '^IPV6=yes$' "$UFW_DEFAULT"; then enabled=true; fi
  case "$*" in
    'status'|'status numbered')
      if [[ ! -e "$work/active" ]]; then echo 'Status: inactive'; return; fi
      echo 'Status: active'
      for family in 4 6; do
        if [[ "$family" == 6 && "$enabled" == false ]]; then continue; fi
        file=$UFW_RULES; if [[ "$family" == 6 ]]; then file=$UFW_RULES6; fi
        while IFS= read -r entry; do
          [[ "$entry" == '### tuple ### '* ]] || continue
          n=$((n+1))
          body=${entry#'### tuple ### '}; comment=''
          if [[ "$body" == *' comment='* ]]; then
            token=${body##*' comment='}; body=${body%' comment='*}
            # shellcheck disable=SC2001 # Decode hex byte pairs.
            comment=$(printf '%b' "$(echo "$token" | sed 's/../\\x&/g')")
          fi
          IFS=' ' read -r -a parts <<<"$body"
          action=${parts[0]%%_*}; port=${parts[2]}; protocol=${parts[1]}; direction=${parts[6]}
          if [[ "$port" == any ]]; then port=Anywhere; fi
          if [[ "$protocol" != any ]]; then port+="/$protocol"; fi
          dst=$port; src=Anywhere
          if [[ "$family" == 6 ]]; then dst+=' (v6)'; src+=' (v6)'; fi
          if [[ "$*" == 'status numbered' ]]; then printf '[%2d] ' "$n"; fi
          printf '%-26s %-12s%s' "$dst" "${action^^} ${direction^^}" "$src"
          if [[ -n "$comment" ]]; then printf ' # %s' "$comment"; fi
          printf '\n'
        done <"$file"
      done
      return ;;
    'reload'|'--force enable')
      if [[ -e "$work/fail-reload" ]]; then rm "$work/fail-reload"; return 1; fi
      touch "$work/active"
      cp "$UFW_RULES" "$work/live4"
      if [[ "$enabled" == true ]]; then cp "$UFW_RULES6" "$work/live6"; else rm -f "$work/live6"; fi
      return ;;
    '--force disable') rm -f "$work/active" "$work/live4" "$work/live6"; return ;;
    default*) return ;;
    '--force delete '*)
      token=$3
      for family in 4 6; do
        file=$UFW_RULES; if [[ "$family" == 6 ]]; then file=$UFW_RULES6; fi
        mapfile -t selected <"$file"; kept=()
        for entry in "${selected[@]}"; do
          n=$((n+1))
          if (( n != token )); then kept+=("$entry"); fi
        done
        : >"$file"; if (( ${#kept[@]} )); then printf '%s\n' "${kept[@]}" >"$file"; fi
      done
      return ;;
  esac
  case "$1" in prepend) position=0; shift;; insert) position=$2; shift 2;; esac
  action=$1; shift
  direction=in protocol=any port=any src=0.0.0.0/0 dst=0.0.0.0/0 comment=''
  while (( $# )); do
    case "$1" in
      in|out) direction=$1; shift;;
      log|log-all) action+="_$1"; shift;;
      proto) protocol=$2; shift 2;;
      from) src=$2; explicit=true; shift 2;;
      to) dst=$2; shift 2;;
      port) port=$2; shift 2;;
      comment) comment=$(printf '%s' "$2" | od -An -v -tx1 | tr -d ' \n'); shift 2;;
      *) port=${1%/*}; protocol=${1#*/}; shift;;
    esac
  done
  if (( position > 0 )); then
    n=$(grep -c '^### tuple ### ' "$UFW_RULES")
    position=$((position-n-1))
  fi
  for family in 4 6; do
    if [[ "$explicit" == true && "$family" == 4 ]]; then continue; fi
    if [[ "$family" == 6 && "$enabled" == false ]]; then continue; fi
    file=$UFW_RULES
    if [[ "$family" == 6 ]]; then file=$UFW_RULES6; src=::/0; dst=::/0; fi
    body="$action $protocol $port $dst any $src $direction"
    if [[ -n "$comment" ]]; then body+=" comment=$comment"; fi
    mock_add "$file" "$body" "$position"
  done
}

reset_fixture() {
  rm -rf -- "$work/backup"
  BACKUP_DIR="$work/backup"
  mkdir "$BACKUP_DIR"
  printf 'IPV6=no\n' >"$UFW_DEFAULT"
  cat >"$UFW_RULES" <<'RULES'
### tuple ### allow tcp 45671 0.0.0.0/0 any 0.0.0.0/0 in comment=6f776e6572
### tuple ### allow udp 45671 0.0.0.0/0 any 0.0.0.0/0 in
### tuple ### deny tcp 45672:45674 0.0.0.0/0 any 0.0.0.0/0 out
### tuple ### reject udp 45675 0.0.0.0/0 any 0.0.0.0/0 in
### tuple ### allow tcp 45676 0.0.0.0/0 any 192.0.2.0/24 in
### tuple ### limit tcp 45677 0.0.0.0/0 any 0.0.0.0/0 in
### tuple ### allow tcp 45678 0.0.0.0/0 any 0.0.0.0/0 in_eth0
### tuple ### route:allow tcp 45679 0.0.0.0/0 any 0.0.0.0/0 in
### tuple ### allow tcp 22 0.0.0.0/0 any 0.0.0.0/0 OpenSSH - in
### tuple ### deny tcp 45680 0.0.0.0/0 any 0.0.0.0/0 in
### tuple ### allow tcp 45680:45690 0.0.0.0/0 any 0.0.0.0/0 in
RULES
  printf '### tuple ### allow tcp 45680:45690 ::/0 any ::/0 in comment=7636\n' >"$UFW_RULES6"
  : >"$work/trace"
  touch "$work/active"
  NETWORK_REQUEST=dual NETWORK_STACK=dual SSH_PORT=43210 KEEP_SSH_22=false UFW_TX=false SSH_TX=false
}

reset_fixture
cp "$UFW_RULES" "$work/original4"
configure_ufw 2>"$work/warnings"
grep -Fq '源/目标地址' "$work/warnings"
grep -Fq 'LIMIT' "$work/warnings"
grep -Fq '接口限定' "$work/warnings"
grep -Fq '应用配置' "$work/warnings"
grep -q '^### tuple ### allow tcp 45671 ::/0 any ::/0 in comment=6f776e6572$' "$UFW_RULES6"
grep -q '^### tuple ### deny tcp 45672:45674 ::/0 any ::/0 out$' "$UFW_RULES6"
grep -q '^### tuple ### reject udp 45675 ::/0 any ::/0 in$' "$UFW_RULES6"
if grep -Eq '^### tuple ### .* (45676|45677|45678|45679) ' "$UFW_RULES6"; then fail 'copied complex rule'; fi
grep -q '^### tuple ### allow tcp 45680:45690 .*comment=7636$' "$UFW_RULES6"
deny_line=$(grep -n '^### tuple ### deny tcp 45680 ' "$UFW_RULES6" | cut -d: -f1)
allow_line=$(grep -n '^### tuple ### allow tcp 45680:45690 ' "$UFW_RULES6" | cut -d: -f1)
(( deny_line < allow_line ))
for family in 4 6; do cp "$work/ufw/user$([[ "$family" == 6 ]] && echo 6).rules" "$work/stable$family"; done
configure_ufw
cmp "$work/stable4" "$UFW_RULES"
cmp "$work/stable6" "$UFW_RULES6"
cmp "$UFW_RULES6" "$work/live6"
NETWORK_REQUEST=auto NETWORK_STACK=ipv4
configure_ufw
cmp "$work/stable6" "$UFW_RULES6"
NETWORK_REQUEST=ipv4
configure_ufw
[[ ! -s "$UFW_RULES6" && ! -e "$work/live6" ]]
grep -Fxq 'IPV6=no' "$UFW_DEFAULT"
cmp "$work/stable4" "$UFW_RULES"
NETWORK_REQUEST=dual
configure_ufw
grep -q '^### tuple ### allow tcp 45671 ::/0 ' "$UFW_RULES6"

# A comment containing (v6) must never identify an IPv4 rule for deletion.
mock_add "$UFW_RULES" 'allow tcp 45699 0.0.0.0/0 any 0.0.0.0/0 in comment=28763629' -1
NETWORK_REQUEST=ipv4 configure_ufw
grep -q '45699 .*comment=28763629' "$UFW_RULES"

# Auto without a usable IPv6 probe keeps hidden persisted rules and IPV6=no.
reset_fixture
cp "$UFW_RULES6" "$work/hidden6"
NETWORK_REQUEST=auto NETWORK_STACK=ipv4
configure_ufw
cmp "$work/hidden6" "$UFW_RULES6"
grep -Fxq 'IPV6=no' "$UFW_DEFAULT"

# Failure rolls back both rule files/defaults and restores live IPv4 access.
reset_fixture
cp "$UFW_DEFAULT" "$work/before-default"
cp "$UFW_RULES" "$work/before4"
cp "$UFW_RULES6" "$work/before6"
set +e
(set -Ee; trap 'on_error $LINENO' ERR; SSH_TX=true; touch "$work/fail-reload"; configure_ufw)
failure_rc=$?
set -e
(( failure_rc != 0 )) || fail 'accepted failed reload'
cmp "$work/before-default" "$UFW_DEFAULT"
cmp "$work/before4" "$UFW_RULES"
cmp "$work/before6" "$UFW_RULES6"
cmp "$work/before4" "$work/live4"
grep -Fxq ssh-rollback "$work/trace"
PRESERVE_SSH=true
cp "$work/trace" "$work/before-trace"
configure_ufw
cmp "$work/before-trace" "$work/trace"

# Persisted IPv6 cleanup also works when UFW started inactive.
PRESERVE_SSH=false
reset_fixture
rm "$work/active"
NETWORK_REQUEST=ipv4
configure_ufw
[[ ! -s "$UFW_RULES6" ]]
grep -Fxq 'IPV6=no' "$UFW_DEFAULT"

# Conflicting user IPv6 actions keep their original ownership and policy.
reset_fixture
printf '### tuple ### deny tcp 45671 ::/0 any ::/0 in comment=7636\n' >>"$UFW_RULES6"
configure_ufw 2>"$work/warnings"
grep -q '^### tuple ### deny tcp 45671 ::/0 any ::/0 in comment=7636$' "$UFW_RULES6"
grep -Fq '保留冲突' "$work/warnings"
echo 'PASS: UFW transitions, comments, ordering, safe skips, reload, rollback and preserve mode'
