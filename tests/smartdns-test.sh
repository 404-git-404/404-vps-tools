#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd)
# shellcheck disable=SC1091
source "$REPO_ROOT/debian-init.sh"
trap - EXIT ERR HUP INT TERM
IFS=$' \t\n'
TEST_TMP=$(mktemp -d)
trap 'rm -rf -- "$TEST_TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected [$1], got [$2]"; }

# Exercise both architecture mappings without touching dpkg or APT.
for architecture in amd64 arm64; do
  dpkg() { printf '%s\n' "$architecture"; }
  smartdns_pkg_values
  [[ "$SMARTDNS_SHA" =~ ^[0-9a-f]{64}$ ]] || fail 'invalid pinned checksum'
  [[ "$SMARTDNS_URL" == "https://github.com/pymumu/smartdns/releases/download/$SMARTDNS_RELEASE/"* ]] || fail 'unexpected release URL'
done
unset -f dpkg

# SmartDNS listens on IPv4 loopback only, in every mode, whether or not ::1 exists.
for stack in ipv4 dual auto; do
  NETWORK_STACK=$stack
  NETWORK_REQUEST=$stack
  for transport in h2 dns53; do
    write_smartdns_config "$TEST_TMP/$stack-$transport.conf" "$transport"
    config=$(cat "$TEST_TMP/$stack-$transport.conf")
    [[ "$config" == *'bind 127.0.0.1:53'* && "$config" == *'bind-tcp 127.0.0.1:53'* ]] || fail 'missing local UDP/TCP listener'
    assert_eq 2 "$(grep -c '^bind' "$TEST_TMP/$stack-$transport.conf")" "$stack $transport listener count"
    if grep -Fq '::1' "$TEST_TMP/$stack-$transport.conf"; then fail "$stack $transport config contains ::1"; fi
    if [[ "$stack" == ipv4 ]]; then
      [[ "$config" == *'force-AAAA-SOA yes'* ]] || fail 'IPv4 DNS leaked IPv6'
    else
      [[ "$config" == *'force-AAAA-SOA no'* ]] || fail "$stack DNS blocks AAAA"
    fi
    upstreams=$(grep '^server' "$TEST_TMP/$stack-$transport.conf")
    if [[ "$transport" == h2 ]]; then
      expected=$'server-https https://cloudflare-dns.com/dns-query -host-ip 1.1.1.1\nserver-https https://dns.google/dns-query -host-ip 8.8.8.8'
    else
      expected=$'server 1.1.1.1\nserver 8.8.8.8\nserver-tcp 1.1.1.1\nserver-tcp 8.8.8.8'
    fi
    assert_eq "$expected" "$upstreams" "$stack $transport upstreams"
  done
done

# A CNAME alone or a broken TCP listener cannot satisfy the DNS health gate.
(
  NETWORK_STACK=ipv4
  NETWORK_REQUEST=ipv4
  dig() {
    case " $* " in
      *' TXT '*) echo 'status: NXDOMAIN,' ;;
      *' AAAA '*) return 0 ;;
      *) echo 192.0.2.1 ;;
    esac
  }
  smartdns_health_check || fail 'valid IPv4 DNS rejected'
  dig() { if [[ " $* " == *' TXT '* ]]; then echo 'status: SERVFAIL,'; else echo 192.0.2.1; fi; }
  if smartdns_health_check; then fail 'cached addresses passed without an upstream response'; fi
  dig() { if [[ " $* " == *' TXT '* ]]; then echo 'status: NXDOMAIN,'; else echo cname.invalid.; fi; }
  if smartdns_health_check; then fail 'CNAME accepted as an address'; fi
  dig() {
    case " $* " in
      *' TXT '*) echo 'status: NXDOMAIN,' ;;
      *' +tcp '*) return 1 ;;
      *) echo 192.0.2.1 ;;
    esac
  }
  if smartdns_health_check; then fail 'broken TCP listener accepted'; fi
  NETWORK_STACK=dual
  NETWORK_REQUEST=dual
  dig() {
    case " $* " in
      *' TXT '*) echo 'status: NXDOMAIN,' ;;
      *' AAAA '*) echo 2001:db8::1 ;;
      *) echo 192.0.2.1 ;;
    esac
  }
  smartdns_health_check || fail 'valid dual DNS rejected'
)

NETWORK_STACK=unknown
NETWORK_REQUEST=auto

# Quick menus use the real validation path, including occupied ports and CLI precedence.
for selection in default standard custom cli preserve; do
  (
    prompt=0
    # shellcheck disable=SC2329 # Used by the sourced quick menu.
    command() { if [[ "$*" == '-v ss' ]]; then return 0; fi; builtin command "$@"; }
    ss() {
      if [[ "$*" == *':1234' ]]; then echo 'LISTEN 0 128 0.0.0.0:1234 0.0.0.0:* users:(("other",pid=1,fd=2))'; fi
    }
    read_tty() {
      local response=''
      prompt=$((prompt+1))
      case "$selection:$prompt" in
        standard:1) response=1 ;;
        standard:2) response=2 ;;
        preserve:1) response=4 ;;
        preserve:2) response=3 ;;
        custom:1|custom:3|custom:5|custom:7) response=3 ;;
        custom:2) response=443 ;;
        custom:4) response=1234 ;;
        custom:6) response=43210 ;;
        cli:*) fail 'explicit CLI options prompted' ;;
      esac
      printf -v "$2" '%s' "$response"
    }
    if [[ "$selection" == cli ]]; then parse_args --ssh-port 22 --keep-22 --network-stack ipv4; fi
    collect_quick_choices
    case "$selection" in
      default) assert_eq '53651/auto/2' "$SSH_PORT/$NETWORK_REQUEST/$prompt" 'quick defaults' ;;
      standard) assert_eq '22/ipv4/2' "$SSH_PORT/$NETWORK_REQUEST/$prompt" 'quick 22 only' ;;
      custom) assert_eq '43210/dual/7' "$SSH_PORT/$NETWORK_REQUEST/$prompt" 'quick custom port' ;;
      cli) assert_eq '22/ipv4/0' "$SSH_PORT/$NETWORK_REQUEST/$prompt" 'explicit CLI' ;;
      preserve) assert_eq 'true/dual/2' "$PRESERVE_SSH/$NETWORK_REQUEST/$prompt" 'preserve SSH menu' ;;
    esac
    if ssh_has_backup_port; then fail 'unexpected backup SSH port'; fi
    ss() { printf 'LISTEN 0 128 0.0.0.0:%s 0.0.0.0:* users:(("sshd",pid=1,fd=2))\n' "$SSH_PORT"; }
    validate_ssh_listeners || fail 'single SSH listener rejected'
    ss() { printf 'LISTEN 0 128 0.0.0.0:%s 0.0.0.0:* users:(("sshd",pid=1,fd=2))\n' "$SSH_PORT" 22222; }
    if validate_ssh_listeners; then fail 'unexpected SSH listener accepted'; fi
  )
done

for args in --ssh-port --keep-22 --close-22 --pubkey --pubkey-file --cloudflare-8443; do
  case "$args" in
    --ssh-port|--pubkey|--pubkey-file)
      if (parse_args --preserve-ssh "$args" 22) >/dev/null 2>&1; then fail "accepted conflicting $args"; fi ;;
    *)
      if (parse_args --preserve-ssh "$args") >/dev/null 2>&1; then fail "accepted conflicting $args"; fi ;;
  esac
done

(
  parse_args --preserve-ssh --network-stack dual
  read_tty() { fail 'unexpected SSH prompt in preserve mode'; }
  collect_quick_choices
  collect_choices
  systemctl() { fail 'preserve mode attempted to manage SSH'; }
  ufw() { fail 'preserve mode attempted to change UFW'; }
  configure_ssh
  configure_ufw
  configure_cf8443
)

# Run the production quick-install flow, replacing only host-changing operations.
# shellcheck disable=SC2329 # Mocks are called through the sourced installer.
check_preserved_ssh_network_mode() (
  local connection=$1 request=$2 expected=$3
  local phase_trace="$TEST_TMP/preserve-network.trace" result=0
  : >"$phase_trace"
  case "$connection" in
    ipv4) SSH_CONNECTION='192.0.2.10 12345 192.0.2.20 22' ;;
    mapped) SSH_CONNECTION='::ffff:192.0.2.10 12345 ::ffff:192.0.2.20 22' ;;
    ipv6) SSH_CONNECTION='2001:db8::10 12345 2001:db8::20 53651' ;;
    console) unset SSH_CONNECTION ;;
  esac
  INSTALL_MODE=quick
  CONTAINER_KIND=lxc
  preflight() { :; }
  acquire_lock() { :; }
  qemu_guest_agent_status() { echo not-installed; }
  # Simulate menu choice 4 and explicitly select the requested network mode.
  command() { if [[ "$*" == '-v ss' ]]; then return 0; fi; builtin command "$@"; }
  read_tty() {
    case "$1" in
      *'请选择 SSH 端口'*) printf -v "$2" 4 ;;
      *'请选择网络模式'*)
        case "$request" in
          auto) printf -v "$2" 1 ;;
          ipv4) printf -v "$2" 2 ;;
          dual) printf -v "$2" 3 ;;
        esac ;;
      '确认以上配置并开始自动安装？'*) printf -v "$2" y ;;
      *) fail 'unexpected prompt in preserve mode' ;;
    esac
  }
  collect_public_key() { fail 'preserve mode requested SSH key'; }
  install_authorized_key() { fail 'preserve mode would install SSH key'; }
  systemctl() { fail 'preserve mode called an unmocked systemctl operation'; }
  ufw() { fail 'preserve mode attempted to change UFW'; }
  configure_fail2ban() { fail 'preserve mode attempted to reconfigure Fail2ban'; }
  install_early_dependencies() { echo dependencies >>"$phase_trace"; }
  configure_swap() { :; }
  collect_swap_choice() { :; }
  update_system_and_tools() { :; }
  ipv4_https_works() { :; }
  configure_chrony() { :; }
  configure_tcp_tuning() { :; }
  install_sing_box() { echo sing-box >>"$phase_trace"; }
  backup_dns_state() { :; }
  apply_network_stack() { echo "apply=$NETWORK_REQUEST" >>"$phase_trace"; }
  cleanup_legacy_network_stack() { :; }
  ipv6_boot_state() { echo on; }
  ipv6_global_present() { [[ "$connection" == ipv6 ]]; }
  ipv6_route_present() { [[ "$connection" == ipv6 ]]; }
  ipv6_https_works() { [[ "$connection" == ipv6 ]]; }
  install_and_configure_smartdns() { echo "smartdns=$NETWORK_STACK" >>"$phase_trace"; }
  configure_system_dns() { DNS_TX=false; }
  print_report() { :; }
  (main) >"$TEST_TMP/preserve-network.log" 2>&1 || result=$?
  if [[ "$expected" == blocked ]]; then
    assert_eq 1 "$result" "$connection/$request result"
    [[ ! -s "$phase_trace" ]] || fail 'IPv6 SSH guard ran after host changes'
    grep -Fq '当前 SSH 会话正在通过 IPv6' "$TEST_TMP/preserve-network.log" || fail 'missing IPv6 SSH diagnostic'
  else
    if (( result != 0 )); then cat "$TEST_TMP/preserve-network.log" >&2; fail "$connection/$request was rejected"; fi
    assert_eq "$(printf 'dependencies\nsing-box\napply=%s\nsmartdns=%s' "$request" "$expected")" "$(cat "$phase_trace")" "$connection/$request operation order"
  fi
)
for connection in ipv4 ipv6 console; do
  for request in auto ipv4 dual; do
    expected=$request
    case "$connection/$request" in
      ipv6/ipv4) expected=blocked ;;
      ipv6/auto) expected=dual ;;
      */auto) expected=ipv4 ;;
    esac
    check_preserved_ssh_network_mode "$connection" "$request" "$expected"
  done
done
check_preserved_ssh_network_mode mapped ipv4 ipv4

(
  CONTAINER_KIND=lxc
  systemctl() {
    [[ "$2" == chrony.service ]] || fail 'unexpected service operation'
    [[ "$1" != restart ]]
  }
  configure_chrony 2>"$TEST_TMP/chrony.log"
  grep -Fq '容器（lxc）内 Chrony 启动失败；继续安装' "$TEST_TMP/chrony.log"
)

# Redirect only file destinations. Exercise real policy generation and rollback.
for policy in fresh provider legacy legacy-service ipv4 dual ipv4-auto ipv4-dual; do
  (
    export POLICY_TEST_DIR="$TEST_TMP/policy-$policy"
    export POLICY_TEST_SCENARIO="$policy"
    # shellcheck disable=SC2016 # Expand the test path in the child Bash.
    sed -e 's|^readonly NETWORK_SYSCTL=.*|readonly NETWORK_SYSCTL="$POLICY_TEST_DIR/network.conf"|' \
      -e 's|^readonly IPV4_POLICY_HELPER=.*|readonly IPV4_POLICY_HELPER="$POLICY_TEST_DIR/libexec/vps-init-ipv4-only"|' \
      -e 's|^readonly IPV4_POLICY_SERVICE=.*|readonly IPV4_POLICY_SERVICE="$POLICY_TEST_DIR/systemd/vps-init-ipv4-only.service"|' \
      -e 's|^readonly IPV4_POLICY_TIMER=.*|readonly IPV4_POLICY_TIMER="$POLICY_TEST_DIR/systemd/vps-init-ipv4-only.timer"|' \
      -e 's|^readonly IPV4_POLICY_IFUP=.*|readonly IPV4_POLICY_IFUP="$POLICY_TEST_DIR/ifup/vps-init-ipv4-only"|' \
      -e 's|^readonly LEGACY_NETWORK_UNIT=.*|readonly LEGACY_NETWORK_UNIT="$POLICY_TEST_DIR/404-network-stack.service"|' \
      -e 's|^readonly LEGACY_NETWORK_HELPER=.*|readonly LEGACY_NETWORK_HELPER="$POLICY_TEST_DIR/helper"|' \
      -e 's|^readonly LEGACY_IPV6_SYSCTL=.*|readonly LEGACY_IPV6_SYSCTL="$POLICY_TEST_DIR/99-disable-ipv6.conf"|' \
      "$REPO_ROOT/debian-init.sh" >"$TEST_TMP/policy-installer.sh"
    bash -s "$TEST_TMP/policy-installer.sh" <<'TEST'
set -Eeuo pipefail
source "$1"
trap - EXIT ERR HUP INT TERM
IFS=$' \t\n'
BACKUP_DIR="$POLICY_TEST_DIR/backup"
TMP_DIR="$POLICY_TEST_DIR"
mkdir -p "$BACKUP_DIR/dns" "$TMP_DIR/proc/sys/net/ipv6/conf"
for iface in all default lo ens18 vlan.20; do
  mkdir -p "$TMP_DIR/proc/sys/net/ipv6/conf/$iface"
  echo 1 >"$TMP_DIR/proc/sys/net/ipv6/conf/$iface/disable_ipv6"
done
trace="$POLICY_TEST_DIR/sysctl"
: >"$trace"
export trace
make_mutable() { :; }
install() {
  if [[ "$1" == -d ]]; then
    shift 3; mkdir -p "$@"
  elif [[ "${4##*/}" == helper ]]; then
    sed -e "s|/proc/sys/|$TMP_DIR/proc/sys/|g" -e "s|/run/lock/|$TMP_DIR/|g" "$4" >"$5"
    chmod 0755 "$5"
  else
    cp -- "$4" "$5"
  fi
}
sysctl() {
  local key=${*: -1} node
  key=${key//net.ipv6.conf./net/ipv6/conf/}
  key=${key//.disable_ipv6//disable_ipv6}
  node="$POLICY_TEST_DIR/proc/sys/${key%=*}"
  if [[ "$1" == -n ]]; then cat "$node"; return; fi
  printf '%s\n' "${*: -1}" >>"$trace"
  if [[ "${MOCK_DENIED:-}" == "$key" ]]; then printf 'Read-only file system: %s\n' "$key" >&2; return 1; fi
  printf '%s\n' "${key##*=}" >"$node"
}
ip() {
  case "$*" in
    '-o -6 address show') printf '%s' "${MOCK_IPV6_ADDR:-}" ;;
    '-o -6 route show table all exact ::/0')
      printf '%s' "${MOCK_IPV6_ROUTE:-}"
      if [[ -f "$POLICY_TEST_DIR/nexthop-route" ]]; then cat "$POLICY_TEST_DIR/nexthop-route"; fi ;;
    '-6 route del default table 42601 metric 1024') rm -f -- "$POLICY_TEST_DIR/nexthop-route" ;;
    *) return 1 ;;
  esac
}
flock() { :; }
pgrep() { [[ "${MOCK_IFUP:-false}" == true ]]; }
export -f sysctl ip flock pgrep
systemctl() { printf '%s\n' "$*" >>"$trace"; }
ipv6_probe_keys() { printf '%s\n' net/ipv6/conf/{lo,ens18,vlan.20}/disable_ipv6; }
ipv6_global_present() { return 1; }
case "$POLICY_TEST_SCENARIO" in
  provider) printf '# Provider settings\nnet.ipv6.conf.eth0.accept_ra = 2\n' >"$NETWORK_SYSCTL" ;;
  legacy) printf '# Managed by vps-init.sh\nnet.ipv6.conf.all.disable_ipv6 = 1\n' >"$NETWORK_SYSCTL" ;;
  legacy-service)
    printf 'Description=Apply 404-vps-tools IPv4-only network stack\n' >"$LEGACY_NETWORK_UNIT"
    printf 'net.ipv6.conf.all.disable_ipv6 = 1\n' >"$LEGACY_IPV6_SYSCTL" ;;
  ipv4*) NETWORK_REQUEST=ipv4 ;;
  dual) NETWORK_REQUEST=dual ;;
esac
NETWORK_STACK=ipv4
apply_network_stack
cleanup_legacy_network_stack
case "$POLICY_TEST_SCENARIO" in
  fresh) [[ ! -e "$NETWORK_SYSCTL" && ! -s "$trace" ]] ;;
  provider)
    [[ ! -s "$trace" ]]
    grep -Fxq 'net.ipv6.conf.eth0.accept_ra = 2' "$NETWORK_SYSCTL" ;;
  legacy|legacy-service)
    [[ ! -e "$NETWORK_SYSCTL" && ! -e "$LEGACY_NETWORK_UNIT" && ! -e "$LEGACY_IPV6_SYSCTL" ]]
    grep -Fxq 'net.ipv6.conf.all.disable_ipv6=0' "$trace"
    if grep -Eq 'disable_ipv6=1$' "$trace"; then exit 1; fi
    rollback_legacy_network_stack
    rollback_network_policy
    if [[ "$POLICY_TEST_SCENARIO" == legacy ]]; then
      cmp "$BACKUP_DIR/dns/network-sysctl" "$NETWORK_SYSCTL"
    else
      [[ -f "$LEGACY_NETWORK_UNIT" && -f "$LEGACY_IPV6_SYSCTL" ]]
      grep -Fxq 'enable 404-network-stack.service' "$trace"
    fi ;;
  ipv4*)
    [[ ! -e "$NETWORK_SYSCTL" ]]
    grep -Fxq 'OnActiveSec=1s' "$IPV4_POLICY_TIMER"
    grep -Fxq 'OnUnitInactiveSec=1h' "$IPV4_POLICY_TIMER"
    grep -Fxq 'AccuracySec=1min' "$IPV4_POLICY_TIMER"
    grep -Fq 'After=systemd-sysctl.service network.target networking.service' "$IPV4_POLICY_SERVICE"
    grep -Fxq 'enable --now vps-init-ipv4-only.timer' "$trace"
    # an interface reconfigured by a manager, despite global/default=1
    sysctl -q -w net/ipv6/conf/vlan.20/disable_ipv6=0
    MOCK_IPV6_ADDR='vlan.20 inet6 2001:db8::2/64' MOCK_IPV6_ROUTE='default via fe80::1 dev vlan.20' verify_ipv4_policy >"$TMP_DIR/verify" 2>&1
    [[ "$IPV4_POLICY_STATUS" == FAIL* ]]
    grep -Fq 'vlan.20: expected disable_ipv6=1, got 0' "$TMP_DIR/verify"
    grep -Fq 'IPv6 route still present' "$TMP_DIR/verify"
    printf '%s\n' 'default nhid 9000 via fe80::1 dev vlan.20 table 42601 proto ra metric 1024 pref medium' >"$TMP_DIR/nexthop-route"
    if MOCK_DENIED=net/ipv6/conf/vlan.20/disable_ipv6=1 "$IPV4_POLICY_HELPER" >"$TMP_DIR/denied" 2>&1; then exit 1; fi
    grep -Fq 'Read-only file system: net/ipv6/conf/vlan.20/disable_ipv6=1' "$TMP_DIR/denied"
    [[ -f "$TMP_DIR/nexthop-route" ]]
    MOCK_IFUP=true "$IPV4_POLICY_HELPER"
    [[ "$(sysctl -n net/ipv6/conf/vlan.20/disable_ipv6)" == 0 ]]
    "$IPV4_POLICY_HELPER"
    [[ "$(sysctl -n net/ipv6/conf/vlan.20/disable_ipv6)" == 1 ]]
    [[ ! -e "$TMP_DIR/nexthop-route" ]]
    ADDRFAM=inet6 IFACE=vlan.20 "$IPV4_POLICY_HELPER" --ifup
    [[ "$(sysctl -n net/ipv6/conf/vlan.20/disable_ipv6)" == 0 ]]
    "$IPV4_POLICY_HELPER"
    verify_ipv4_policy
    [[ "$IPV4_POLICY_STATUS" == PASS* ]]
    if [[ "$POLICY_TEST_SCENARIO" == ipv4 ]]; then
      rollback_network_policy
      for path in "${IPV4_POLICY_FILES[@]}"; do [[ ! -e "$path" ]]; done
    else
      BACKUP_DIR="$TMP_DIR/transition"
      mkdir -p "$BACKUP_DIR/dns"
      NETWORK_REQUEST=${POLICY_TEST_SCENARIO#ipv4-}
      apply_network_stack
      for path in "${IPV4_POLICY_FILES[@]}"; do [[ ! -e "$path" ]]; done
      grep -Fxq 'net.ipv6.conf.all.disable_ipv6=0' "$trace"
      if [[ "$NETWORK_REQUEST" == auto ]]; then
        [[ ! -e "$NETWORK_SYSCTL" ]]
      else
        grep -Fxq 'net.ipv6.conf.all.disable_ipv6 = 0' "$NETWORK_SYSCTL"
      fi
      rollback_network_policy
      for path in "${IPV4_POLICY_FILES[@]}"; do cmp "$path" "$BACKUP_DIR/dns/${path##*/}"; done
    fi ;;
  dual)
    grep -Fxq 'net.ipv6.conf.all.disable_ipv6 = 0' "$NETWORK_SYSCTL" ;;
esac
TEST
  )
done

(
  # The default transport and Auto request never depend on host IPv6 state.
  NETWORK_REQUEST=auto
  write_smartdns_config "$TEST_TMP/auto-default.conf"
  grep -Fxq 'bind 127.0.0.1:53' "$TEST_TMP/auto-default.conf"
  grep -Fxq 'bind-tcp 127.0.0.1:53' "$TEST_TMP/auto-default.conf"
  grep -Fxq 'force-AAAA-SOA no' "$TEST_TMP/auto-default.conf"
  if grep -Fq '::1' "$TEST_TMP/auto-default.conf"; then fail 'Auto config contains ::1'; fi
)

# Validate the production address/route filters and the exact curl arguments.
(
  TRACE="$TEST_TMP/ipv6-curl.trace"
  ip() {
    case "$*" in
      '-6 addr show scope global') printf '%s\n' "$addresses" ;;
      '-6 route show table all default') printf '%s\n' "$routes" ;;
      *) fail "unexpected ip invocation: $*" ;;
    esac
  }
  curl() {
    local host address status
    case "${*: -1}" in
      https://cloudflare-dns.com/dns-query) host='cloudflare-dns.com'; address=2606:4700:4700::1111; status=$cloudflare ;;
      https://dns.google/dns-query) host=dns.google; address=2001:4860:4860::8888; status=$google ;;
      *) fail 'unexpected HTTPS target' ;;
    esac
    assert_eq '--disable' "$1" 'curl ignores curlrc'
    local args
    args=$(printf '%s\n' "$@")
    for arg in -6 --noproxy '*' --resolve "$host:443:[$address]" --connect-timeout --max-time; do
      grep -Fxq -- "$arg" <<<"$args" || fail "missing curl argument: $arg"
    done
    if grep -Exq -- '(-k|--insecure|--fail|--location)' <<<"$args"; then fail 'unsafe curl flags'; fi
    echo "$host" >>"$TRACE"
    if [[ "$status" == 400 ]]; then echo 400; return 0; fi
    echo 'simulated curl failure' >&2
    return "$status"
  }
  check_ipv6() {
    local expected=$1 count=$2 output="$TEST_TMP/ipv6-detect.log"
    : >"$TRACE"
    detect_ipv6_stack >"$output" 2>&1
    assert_eq "$expected" "$NETWORK_STACK" 'detected network stack'
    assert_eq "$count" "$(wc -l <"$TRACE" | tr -d ' ')" 'probe count'
    for label in 'Global Address' 'Default Route' 'HTTPS Cloudflare' 'HTTPS Google'; do
      grep -Eq "IPv6 $label: (PASS|FAIL)" "$output" || fail "missing diagnostic: $label"
    done
  }
  # Model a resolver that suppresses AAAA: the fake curl only works with the
  # literal IPv6 mapping, and this path must never make a DNS query.
  # shellcheck disable=SC2329 # Fail if the detection ever calls dig.
  dig() { fail 'IPv6 detection queried local DNS'; }
  addresses='    inet6 2001:db8::1/64 scope global'
  routes='default via fe80::1 dev eth0'
  cloudflare=400 google=400
  check_ipv6 dual 2
  cloudflare=28
  check_ipv6 dual 2
  grep -Fq 'curl 28' "$TEST_TMP/ipv6-detect.log"
  cloudflare=400 google=60
  check_ipv6 dual 2
  grep -Fq 'curl 60' "$TEST_TMP/ipv6-detect.log"
  cloudflare=7
  check_ipv6 ipv4 2
  addresses=$'    inet6 fd00::1/64 scope global\n    inet6 2001:db8::1/64 scope global tentative'
  check_ipv6 ipv4 0
  addresses='    inet6 2001:db8::1/64 scope global'
  routes=$'unreachable default dev lo\ndefault via fe80::1 dev eth0 linkdown'
  check_ipv6 ipv4 0
  for mode in ipv4 dual; do
    INSTALL_MODE='' NETWORK_REQUEST=auto
    parse_args --smartdns-only --network-stack "$mode"
    install_component_dependencies() { :; }
    backup_dns_state() { :; }
    install_and_configure_smartdns() { :; }
    configure_system_dns() { DNS_TX=false; }
    detect_ipv6_stack() { fail 'manual mode invoked auto detection'; }
    run_smartdns_only
    assert_eq "$mode" "$NETWORK_STACK" 'manual SmartDNS network stack'
  done
)

# Use simulated per-interface sysctls and the real signal/EXIT cleanup handlers.
for failure in timeout enable-error probe-error TERM; do
  (
    probe_key=net/ipv6/conf/eth0/disable_ipv6
    state="$TEST_TMP/ipv6-sysctl"
    echo 1 >"$state"
    NETWORK_REQUEST=auto
    CONTAINER_KIND=none
    unset SSH_CONNECTION
    managed_ipv6_policy() { return 0; }
    ipv6_global_present() { [[ "$(cat "$state")" == 0 ]]; }
    ipv6_route_present() { :; }
    ipv6_probe_keys() { printf '%s\n' "$probe_key" net/ipv6/conf/eth1/disable_ipv6; }
    sleep() { :; }
    sysctl() {
      case "$*" in
        "-n $probe_key") cat "$state" ;;
        '-n net/ipv6/conf/eth1/disable_ipv6') echo 0 ;;
        "-q -w $probe_key=0")
          echo 0 >"$state"
          [[ "$failure" != enable-error ]] ;;
        "-q -w $probe_key=1") echo 1 >"$state" ;;
        *) fail "unexpected sysctl: $*" ;;
      esac
    }
    ipv6_https_works() {
      case "$failure" in
        TERM) kill -TERM "$BASHPID" ;;
        probe-error) die 'simulated unexpected probe failure' ;;
        *) return 1 ;;
      esac
    }
    if [[ "$failure" == TERM || "$failure" == probe-error ]]; then
      # A standalone Bash process receives the same handlers as the installer.
      (
        trap 'on_signal TERM' TERM
        trap cleanup EXIT
        detect_network_stack
      ) && fail 'interrupted probe returned success'
    else
      detect_network_stack
      assert_eq ipv4 "$NETWORK_STACK" 'failed probe network stack'
    fi
    assert_eq 1 "$(cat "$state")" 'temporary interface state restored'
  )
done

# The independent modes must never reach full initialization steps.
for mode in smartdns singbox; do
  (
    INSTALL_MODE=$mode
    TRACE="$TEST_TMP/$mode.trace"
    record() { printf '%s\n' "$1" >>"$TRACE"; }
    parse_args() { :; }
    select_install_mode() { :; }
    preflight() { record preflight; }
    acquire_lock() { record lock; }
    install_component_dependencies() { record dependencies; }
    install_sing_box() { record singbox; }
    run_node_config_wizard() { record wizard; }
    # Avoid /dev/tty in this offline test; check the actual dispatch independently.
    run_singbox_only() { install_component_dependencies; install_sing_box; run_node_config_wizard; }
    NETWORK_REQUEST=auto
    ipv6_global_present() { return 1; }
    ipv6_route_present() { return 1; }
    backup_dns_state() { record dns-backup; }
    install_and_configure_smartdns() { record smartdns; }
    configure_system_dns() { record resolver; DNS_TX=false; }
    log() { :; }
    collect_choices() { fail 'component mode reached initialization'; }
    main
    if [[ "$mode" == smartdns ]]; then
      assert_eq $'preflight\nlock\ndependencies\ndns-backup\nsmartdns\nresolver' "$(cat "$TRACE")" 'SmartDNS scope/order'
      assert_eq ipv4 "$NETWORK_STACK" 'auto DNS family'
    else
      assert_eq $'preflight\nlock\ndependencies\nsingbox\nwizard' "$(cat "$TRACE")" 'sing-box scope/order'
    fi
  )
done

# Conflicting independent CLI modes fail, before any system modification.
if (parse_args --smartdns-only --sing-box-only) >"$TEST_TMP/conflict.log" 2>&1; then
  fail 'conflicting modes accepted'
fi

# A new sing-box is masked through package installation and config removal.
(
  INSTALL_MODE=singbox
  TRACE="$TEST_TMP/singbox-install.trace"
  record() { printf '%s\n' "$*" >>"$TRACE"; }
  capture_singbox_state() { SINGBOX_WAS_INSTALLED=false; SINGBOX_WAS_MANAGED=false; }
  configure_sagernet_repo() { :; }
  apt_get() { record "apt $*"; }
  # shellcheck disable=SC2329,SC2317 # Called by the sourced installer.
  command() { if [[ "${1:-}" == -v && "${2:-}" == sing-box ]]; then return 0; fi; builtin command "$@"; }
  install() { :; }
  configure_singbox_boot_gate() { record gate; }
  remove_fresh_singbox_default_config() { record remove-config; }
  mark_singbox_managed() { :; }
  restore_singbox_state() { record restore-state; }
  systemctl() { record "systemctl $*"; }
  sing-box() { echo 'sing-box test'; }
  log() { :; }
  install_sing_box
  expected=$'apt update\nsystemctl mask --runtime sing-box.service\napt install -y sing-box\ngate\nremove-config\nsystemctl unmask --runtime sing-box.service\nrestore-state\nsystemctl is-active sing-box.service\nsystemctl is-enabled sing-box.service'
  assert_eq "$expected" "$(cat "$TRACE")" 'sing-box startup protection'
  assert_eq false "$SINGBOX_RUNTIME_MASK" 'runtime mask released'
)

# Auto: what a reboot does to IPv6 is computed by systemd-sysctl (stubbed here; the
# real thing runs in tests/ipv6-boot-state-test.sh). User files are never edited.
boot_dir=$(mktemp -d "$TEST_TMP/boot.XXXXXX")
boot_dir=$(cd -- "$boot_dir" && pwd -P)
sed -e "s|^readonly NETWORK_SYSCTL=.*|readonly NETWORK_SYSCTL='$boot_dir/etc/99-vps-init-network.conf'|" \
  -e "s|^readonly LEGACY_IPV6_SYSCTL=.*|readonly LEGACY_IPV6_SYSCTL='$boot_dir/etc/99-disable-ipv6.conf'|" \
  -e "s|^readonly LEGACY_NETWORK_UNIT=.*|readonly LEGACY_NETWORK_UNIT='$boot_dir/etc/404-network-stack.service'|" \
  -e "s|^readonly LEGACY_NETWORK_HELPER=.*|readonly LEGACY_NETWORK_HELPER='$boot_dir/etc/404-network-stack'|" \
  -e "s|^readonly IPV4_POLICY_HELPER=.*|readonly IPV4_POLICY_HELPER='$boot_dir/etc/ipv4-helper'|" \
  -e "s|^readonly IPV4_POLICY_SERVICE=.*|readonly IPV4_POLICY_SERVICE='$boot_dir/etc/ipv4.service'|" \
  -e "s|^readonly IPV4_POLICY_TIMER=.*|readonly IPV4_POLICY_TIMER='$boot_dir/etc/ipv4.timer'|" \
  -e "s|^readonly IPV4_POLICY_IFUP=.*|readonly IPV4_POLICY_IFUP='$boot_dir/etc/ipv4-ifup'|" \
  "$REPO_ROOT/debian-init.sh" >"$boot_dir/installer.sh"
bash -s "$boot_dir" <<'TEST'
set -Eeuo pipefail
d=$1
# shellcheck disable=SC1091
source "$d/installer.sh"
trap - EXIT ERR HUP INT TERM
IFS=$' \t\n'
exec 3>&2 2>>"$d/stderr.log"
fail() { printf 'FAIL: %s\n' "$*" >&3; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "$3: expected [$1], got [$2]"; }
log() { :; }
warn() { printf '%s\n' "$*" >>"$d/warn.log"; }
lsattr() { :; }
chattr() { :; }
sleep() { :; }
systemctl() { printf 'systemctl %s\n' "$*" >>"$d/systemctl.log"; }
install() {
  case "$1" in
    -d) mkdir -p -- "${@: -1}" ;;
    *) cp -- "${@: -2:1}" "${@: -1}" ;;
  esac
}
# --- stubs for the environment -------------------------------------------------
command() { if [[ "${1:-} ${2:-}" == '-v unshare' ]]; then [[ "${MOCK_NO_UNSHARE:-false}" != true ]]; return; fi; builtin command "$@"; }
ipv6_kernel_present() { [[ "${MOCK_NO_KERNEL_IPV6:-false}" != true ]]; }
systemd_sysctl_path() { [[ "${MOCK_NO_TOOL:-false}" == true ]] && return 1; printf '/fake/systemd-sysctl\n'; }
unshare() {
  [[ "$1 $2" == '--net --' ]] || return 9
  printf '%s\n' "$*" >"$d/unshare.args"
  printf '%s\n' "${MOCK_OUT-}"
  return "${MOCK_RC:-0}"
}

# --- the four outcomes of ipv6_boot_state --------------------------------------------
state_is() { eq "$3" "$(MOCK_OUT=$1 MOCK_RC=${2:-0} ipv6_boot_state)" "state for [$1] rc=${2:-0}"; }
state_is 'all=0 default=0' 0 on
state_is 'all=1 default=0' 0 off
state_is 'all=0 default=1' 0 off
state_is 'all=1 default=1' 0 off
state_is 'all=0 default=0' 3 unknown
# systemd-sysctl itself failing inside the namespace (the script exits 4) is never read as on.
state_is 'all=0 default=0' 4 unknown
state_is 'nonsense' 0 unknown
state_is '' 0 unknown
eq unknown "$(MOCK_NO_UNSHARE=true ipv6_boot_state)" 'missing unshare'
eq unknown "$(MOCK_NO_TOOL=true ipv6_boot_state)" 'missing systemd-sysctl'
eq kernel-off "$(MOCK_NO_KERNEL_IPV6=true ipv6_boot_state)" 'kernel without IPv6'
# The namespace script runs the discovered systemd-sysctl for net.ipv6.conf only, after zeroing all/default.
MOCK_OUT='all=0 default=0' ipv6_boot_state >/dev/null
grep -Fq '/fake/systemd-sysctl' "$d/unshare.args" || fail 'tool path not passed to the namespace'
grep -Fq -- '--prefix=net.ipv6.conf' "$d/unshare.args" || fail 'systemd-sysctl not limited to net.ipv6.conf'
grep -Fq -- '--net --' "$d/unshare.args" || fail 'not run in a new network namespace'
if grep -Eq 'sysctl -w|\.lo\.' "$d/unshare.args"; then fail 'namespace script touches more than all/default'; fi

# --- shared fixtures ------------------------------------------------------------
reset() {
  rm -rf "$d/etc" "$d/proc" "$d/backup" "$d/backup2" "$d/tmp" "$d/orig" "$d/state.fixed" "$d/state.base" "$d/warn.log" "$d/systemctl.log"
  mkdir -p "$d/etc" "$d/proc" "$d/backup/dns" "$d/backup2/dns" "$d/tmp" "$d/orig"
  : >"$d/warn.log"
  BACKUP_DIR="$d/backup"
  TMP_DIR="$d/tmp"
  NETWORK_REQUEST=auto
  NETWORK_REQUEST_SET=false
  BASE_ONLY=false
  NETWORK_STACK=unknown
  NETWORK_POLICY_CHANGED=false
  IPV6_BOOT_STATE=unknown IPV6_RESTORE_CHOICE='' IPV6_BOOT_RESULT='' IPV6_RESTORED=false
  IPV6_FORCE_IPV4=false IPV6_PROBE_RESULT='' IPV6_OLD_ALL='' IPV6_OLD_DEFAULT=''
  IPV6_OLD_INTERFACES=()
  IPV6_BOOT_LINES=()
  for key in all default lo ens18; do printf '1\n' >"$d/proc/net.ipv6.conf.$key.disable_ipv6"; done
  printf '%s\n' '# user file' 'net.ipv6.conf.all.disable_ipv6 = 1' 'net.ipv6.conf.default.disable_ipv6 = 1' >"$d/etc/99-user-ipv6.conf"
  cp -- "$d/etc/99-user-ipv6.conf" "$d/orig/99-user-ipv6.conf"
  printf 'off\n' >"$d/state.base"
}
user_file_untouched() { cmp -s "$d/orig/99-user-ipv6.conf" "$d/etc/99-user-ipv6.conf" || fail "user file modified: $1"; }
rt() { cat "$d/proc/net.ipv6.conf.$1.disable_ipv6"; }
sysctl() {
  local key node f
  if [[ "$1" == -n ]]; then key=${2//\//.}; cat "$d/proc/$key" 2>/dev/null; return; fi
  key=${*: -1}
  printf '%s\n' "$key" >>"$d/sysctl.trace"
  node=${key%%=*}
  node=${node//\//.}
  # Writing "all" reaches every device, like the kernel does.
  if [[ "$node" == net.ipv6.conf.all.disable_ipv6 ]]; then
    for f in "$d"/proc/net.ipv6.conf.*.disable_ipv6; do printf '%s\n' "${key#*=}" >"$f"; done
  fi
  printf '%s\n' "${key#*=}" >"$d/proc/$node"
}
ipv6_probe_keys() { printf '%s\n' net/ipv6/conf/lo/disable_ipv6 net/ipv6/conf/ens18/disable_ipv6; }
ipv6_boot_disable_lines() { printf '%s\n' "$d/etc/99-user-ipv6.conf: net.ipv6.conf.all.disable_ipv6 = 1"; }
# Model systemd-sysctl: the script's override file (all = 0, sorted last) wins over the user file.
ipv6_boot_state() {
  if [[ -f "$d/state.fixed" ]]; then cat "$d/state.fixed"; return; fi
  if [[ -f "$NETWORK_SYSCTL" ]] && grep -Fxq 'net.ipv6.conf.all.disable_ipv6 = 0' "$NETWORK_SYSCTL"; then echo on; return; fi
  cat "$d/state.base"
}
tty_available() { return 0; }
answer=''
asked=0
ANSWERS=()
PROMPT_MODE=ok
read_tty() {
  if [[ "$PROMPT_MODE" == fail ]]; then fail "unexpected prompt: $1"; fi
  if (( ${#ANSWERS[@]} )); then printf -v "$2" '%s' "${ANSWERS[asked]}"; else printf -v "$2" '%s' "$answer"; fi
  asked=$((asked + 1))
}
auto_flow() {
  collect_ipv6_boot_policy
  apply_network_stack
  cleanup_legacy_network_stack
  apply_ipv6_boot_policy
  NETWORK_STACK=${MOCK_PROBE:-dual}
  finalize_ipv6_stack
}
expected_file=$'# Managed by vps-init.sh\n# IPv6 restored by Auto: overrides unmanaged disable_ipv6 settings\nnet.ipv6.conf.all.disable_ipv6 = 0\nnet.ipv6.conf.default.disable_ipv6 = 0\nnet.ipv6.conf.lo.disable_ipv6 = 0'

# --- collection: prompt, defaults, and when nothing is asked ---------------------------
reset
printf 'on\n' >"$d/state.base"
asked=0
collect_ipv6_boot_policy
eq 0 "$asked" 'on must not prompt'
eq '' "$IPV6_RESTORE_CHOICE" 'on choice'
for answer in 1 2 ''; do
  reset
  asked=0
  collect_ipv6_boot_policy
  eq 1 "$asked" "prompt count for [$answer]"
  eq off "$IPV6_BOOT_STATE" 'off recorded'
  case "$answer" in 1) eq restore "$IPV6_RESTORE_CHOICE" 'choice 1' ;; *) eq keep "$IPV6_RESTORE_CHOICE" "choice [$answer]" ;; esac
  eq 1 "${#IPV6_BOOT_LINES[@]}" 'offending lines listed'
done
reset
asked=0
ANSWERS=(9 1)
collect_ipv6_boot_policy
eq restore "$IPV6_RESTORE_CHOICE" 'invalid answer re-asks'
eq 2 "$asked" 'invalid answer prompt count'
ANSWERS=()
PROMPT_MODE=fail
reset
tty_available() { return 1; }
collect_ipv6_boot_policy
eq keep "$IPV6_RESTORE_CHOICE" 'no terminal default'
grep -Fq '默认保留' "$d/warn.log" || fail 'missing default warning'
tty_available() { return 0; }
reset
NETWORK_REQUEST_SET=true
collect_ipv6_boot_policy
eq keep "$IPV6_RESTORE_CHOICE" 'argument mode default'
for fixed in unknown kernel-off; do
  reset
  printf '%s\n' "$fixed" >"$d/state.fixed"
  collect_ipv6_boot_policy
  eq '' "$IPV6_RESTORE_CHOICE" "$fixed must not prompt"
  eq "$fixed" "$IPV6_BOOT_STATE" "$fixed recorded"
  if [[ "$fixed" == unknown ]]; then grep -Fq '无法判断' "$d/warn.log" || fail 'unknown must warn'; fi
done
# Other modes never ask, never even look.
original_state_stub=$(declare -f ipv6_boot_state)
ipv6_boot_state() { fail 'state checked for an explicit mode'; }
for request in dual ipv4; do
  reset
  NETWORK_REQUEST=$request
  collect_ipv6_boot_policy
  apply_ipv6_boot_policy
  eq '' "$IPV6_RESTORE_CHOICE$IPV6_BOOT_RESULT" "$request mode state"
done
reset
BASE_ONLY=true
collect_ipv6_boot_policy
eq '' "$IPV6_RESTORE_CHOICE" 'base-only choice'
# Older policy files of this script are migrated later, so the boot state is checked again afterwards.
reset
printf '%s\n' '# Managed by vps-init.sh' 'net.ipv6.conf.all.disable_ipv6 = 1' >"$NETWORK_SYSCTL"
collect_ipv6_boot_policy
eq pending "$IPV6_BOOT_STATE" 'managed =1 file is pending'
reset
printf '%s\n' '# Managed by vps-init.sh' 'net.ipv6.conf.all.disable_ipv6 = 1' >"$d/etc/99-disable-ipv6.conf"
collect_ipv6_boot_policy
eq pending "$IPV6_BOOT_STATE" 'managed legacy file is pending'
eval "$original_state_stub"
# A provider-owned network file cannot be replaced: no prompt, keep.
reset
printf '%s\n' '# Provider settings' 'net.ipv6.conf.eth0.accept_ra = 2' >"$NETWORK_SYSCTL"
collect_ipv6_boot_policy
eq keep "$IPV6_RESTORE_CHOICE" 'foreign network file'
IPV6_RESTORE_CHOICE=restore
IPV6_BOOT_RESULT=''
restore_ipv6_boot_policy
eq $'# Provider settings\nnet.ipv6.conf.eth0.accept_ra = 2' "$(cat "$NETWORK_SYSCTL")" 'foreign network file overwritten'
eq true "$IPV6_FORCE_IPV4" 'foreign file forces ipv4'

# --- [1] restore: our file, runtime values, verification, no user file touched -----------
PROMPT_MODE=ok
reset
answer=1
auto_flow
eq restore "$IPV6_RESTORE_CHOICE" 'choice recorded'
eq "$expected_file" "$(cat "$NETWORK_SYSCTL")" 'override file content'
for key in all default lo ens18; do eq 0 "$(rt "$key")" "runtime $key"; done
eq 已恢复 "$IPV6_BOOT_RESULT" 'result'
eq dual "$NETWORK_STACK" 'probe dual keeps dual'
eq dual "$IPV6_PROBE_RESULT" 'probe result'
user_file_untouched 'restore'
report=$(ipv6_report_lines)
grep -Fq '重启后 IPv6 : 已恢复' <<<"$report" || fail "report lacks boot result: $report"
grep -Fq '当前探测     : dual' <<<"$report" || fail "report lacks probe line: $report"
grep -Fq '已被脚本配置覆盖' <<<"$report" || fail "report lacks the override note: $report"
grep -Fq '99-user-ipv6.conf' <<<"$report" || fail "report lacks the overridden file: $report"
# Rerunning Auto keeps the file: the migration must not delete the restore override.
cp -- "$NETWORK_SYSCTL" "$d/orig/first.conf"
NETWORK_POLICY_CHANGED=false
IPV6_RESTORE_CHOICE='' IPV6_BOOT_RESULT='' IPV6_RESTORED=false IPV6_FORCE_IPV4=false
BACKUP_DIR="$d/backup2"
mkdir -p "$BACKUP_DIR"
asked=0
auto_flow
cmp -s "$d/orig/first.conf" "$NETWORK_SYSCTL" || fail 'rerun removed or changed the override file'
eq 0 "$asked" 'rerun prompted'
eq 无需处理 "$IPV6_BOOT_RESULT" 'rerun result'
eq 1 "$(grep -c '^net.ipv6.conf.all.disable_ipv6' "$NETWORK_SYSCTL")" 'rerun duplicated lines'
eq dual "$NETWORK_STACK" 'rerun stack'
# Rollback removes our file (it did not exist before) and restores the runtime values.
reset
answer=1
auto_flow
rollback_network_policy
[[ ! -e "$NETWORK_SYSCTL" ]] || fail 'rollback kept the override file'
for key in all default lo ens18; do eq 1 "$(rt "$key")" "rollback runtime $key"; done
user_file_untouched 'rollback'

# --- verification fails: a later file still wins ---------------------------------------
reset
printf 'off\n' >"$d/state.fixed"
answer=1
auto_flow
[[ ! -e "$NETWORK_SYSCTL" ]] || fail 'ineffective override file was kept'
for key in all default lo ens18; do eq 1 "$(rt "$key")" "reverted runtime $key"; done
eq 仍禁用 "$IPV6_BOOT_RESULT" 'ineffective result'
eq ipv4 "$NETWORK_STACK" 'ineffective forces ipv4'
eq dual "$IPV6_PROBE_RESULT" 'probe is reported separately'
grep -Fq '没有生效' "$d/warn.log" || fail 'missing warning'
grep -Fq '99-user-ipv6.conf' "$d/stderr.log" || fail 'offending files not listed'
user_file_untouched 'ineffective'
[[ "$(ipv6_report_lines)" != *'已被脚本配置覆盖'* ]] || fail 'ineffective override reported as overriding'
# A pre-existing managed file is migrated, replaced by the override, and rollback brings it back.
reset
printf '%s\n' '# Managed by vps-init.sh' 'net.ipv6.conf.all.disable_ipv6 = 0' >"$NETWORK_SYSCTL"
cp -- "$NETWORK_SYSCTL" "$d/orig/old-dual.conf"
IPV6_RESTORE_CHOICE=restore
apply_network_stack
apply_ipv6_boot_policy
eq "$expected_file" "$(cat "$NETWORK_SYSCTL")" 'override replaces migrated file'
rollback_network_policy
cmp -s "$d/orig/old-dual.conf" "$NETWORK_SYSCTL" || fail 'rollback did not bring the old managed file back'
for key in all default lo ens18; do eq 1 "$(rt "$key")" "rollback after migration runtime $key"; done

# --- [2] keep, and the recheck after Auto's own migration -------------------------------
reset
answer=2
auto_flow
[[ ! -e "$NETWORK_SYSCTL" ]] || fail 'keep wrote a file'
eq ipv4 "$NETWORK_STACK" 'keep follows the post-reboot state'
eq 仍禁用 "$IPV6_BOOT_RESULT" 'keep result'
eq dual "$IPV6_PROBE_RESULT" 'keep probe result'
user_file_untouched 'keep'
for key in all default lo ens18; do eq 1 "$(rt "$key")" "keep runtime $key"; done
# Old explicit-Dual file: boot state looks fine, Auto removes it, and the second look finds IPv6 off.
reset
printf '%s\n' '# Managed by vps-init.sh' 'net.ipv6.conf.all.disable_ipv6 = 0' >"$NETWORK_SYSCTL"
asked=0
auto_flow
eq 0 "$asked" 'unexpected prompt before the recheck'
[[ ! -e "$NETWORK_SYSCTL" ]] || fail 'old managed file not migrated'
eq ipv4 "$NETWORK_STACK" 'recheck after migration must force ipv4'
eq 仍禁用 "$IPV6_BOOT_RESULT" 'recheck result'
user_file_untouched 'recheck'
# Kernel-level disable.
reset
printf 'kernel-off\n' >"$d/state.fixed"
auto_flow
eq ipv4 "$NETWORK_STACK" 'kernel-off forces ipv4'
# Unknown only warns; the probe result stands.
reset
printf 'unknown\n' >"$d/state.fixed"
auto_flow
eq dual "$NETWORK_STACK" 'unknown keeps the probe result'
eq 无法判断 "$IPV6_BOOT_RESULT" 'unknown result'
# Restored, but IPv6 addresses have not appeared yet.
reset
answer=1
MOCK_PROBE=ipv4 auto_flow
eq ipv4 "$NETWORK_STACK" 'failed probe after restore'
eq 已恢复 "$IPV6_BOOT_RESULT" 'configuration stays restored'
eq ipv4 "$IPV6_PROBE_RESULT" 'probe reported separately'
grep -Fq '网络服务重新初始化' "$d/warn.log" || fail 'missing late-address hint'
[[ -f "$NETWORK_SYSCTL" ]] || fail 'failed probe removed the configuration fix'

# A failed attempt restores a pre-existing override file instead of deleting it.
reset
existing=$'# Managed by vps-init.sh\n# IPv6 restored by Auto: overrides unmanaged disable_ipv6 settings\n# from an earlier run\nnet.ipv6.conf.all.disable_ipv6 = 0\nnet.ipv6.conf.default.disable_ipv6 = 0'
printf '%s\n' "$existing" >"$NETWORK_SYSCTL"
printf 'off\n' >"$d/state.fixed"
IPV6_RESTORE_CHOICE=restore
apply_network_stack
apply_ipv6_boot_policy
eq "$existing" "$(cat "$NETWORK_SYSCTL")" 'pre-existing override file was changed or removed by a failed attempt'
eq 仍禁用 "$IPV6_BOOT_RESULT" 'pre-existing file result'
eq true "$IPV6_FORCE_IPV4" 'pre-existing file forces ipv4'
for key in all default lo ens18; do eq 1 "$(rt "$key")" "pre-existing file runtime $key"; done
[[ -f "$BACKUP_DIR/dns/network-sysctl.before-restore" ]] || fail 'no copy of the pre-existing file'
# Written but not verifiable: never reported as restored.
reset
printf 'unknown\n' >"$d/state.fixed"
IPV6_RESTORE_CHOICE=restore
apply_ipv6_boot_policy
eq "$expected_file" "$(cat "$NETWORK_SYSCTL")" 'unverified override file is kept'
eq '已写入、未验证' "$IPV6_BOOT_RESULT" 'unverified result'
eq false "$IPV6_RESTORED" 'unverified must not count as restored'
eq false "$IPV6_FORCE_IPV4" 'unverified does not force ipv4'
grep -Fq '不能确认 IPv6 已恢复' "$d/warn.log" || fail 'missing unverified warning'
IPV6_BOOT_LINES=("$d/etc/99-user-ipv6.conf: net.ipv6.conf.all.disable_ipv6 = 1")
NETWORK_STACK=dual
finalize_ipv6_stack
eq dual "$NETWORK_STACK" 'unverified with a working probe'
report=$(ipv6_report_lines)
[[ "$report" != *'已恢复'* ]] || fail "unverified report says restored: $report"
[[ "$report" != *'已被脚本配置覆盖'* ]] || fail "unverified report claims an override: $report"
grep -Fq '已写入、未验证' <<<"$report" || fail "report lacks the unverified state: $report"
NETWORK_STACK=ipv4
: >"$d/warn.log"
finalize_ipv6_stack
grep -Fq '覆盖文件已写入但未验证' "$d/warn.log" || fail 'missing unverified probe hint'
if grep -Fq 'IPv6 已恢复' "$d/warn.log"; then fail 'unverified probe hint says restored'; fi
eq ipv4 "$NETWORK_STACK" 'unverified with a failed probe'

# The listing is a list of related configuration, not of effective values.
reset
answer=1
auto_flow
report=$(ipv6_report_lines)
grep -Fq '相关配置（不一定都是最终生效值）' <<<"$report" || fail "report wording: $report"
reset
collect_ipv6_boot_policy
grep -Fq '相关配置（不一定都是最终生效值）' "$d/warn.log" || fail 'collection wording'
reset
printf 'off\n' >"$d/state.fixed"
IPV6_RESTORE_CHOICE=restore
apply_ipv6_boot_policy
grep -Fq '相关配置（不一定都是最终生效值）' "$d/warn.log" || fail 'revert wording'
TEST

# resolv.conf, SmartDNS rerun and the independence from host IPv6.
dns_dir=$(mktemp -d "$TEST_TMP/dns.XXXXXX")
dns_dir=$(cd -- "$dns_dir" && pwd -P)
# Nothing below may read or write the host's resolver or SmartDNS files.
sed -e "s|/etc/resolv\.conf|$dns_dir/resolv.conf|g" \
  -e "s|/etc/smartdns|$dns_dir/smartdns-etc|g" \
  -e "s|/var/cache/smartdns|$dns_dir/smartdns-cache|g" \
  "$REPO_ROOT/debian-init.sh" >"$dns_dir/installer.sh"
bash -s "$dns_dir" <<'TEST'
set -Eeuo pipefail
d=$1
# shellcheck disable=SC1091
source "$d/installer.sh"
trap - EXIT ERR HUP INT TERM
IFS=$' \t\n'
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "$3: expected [$1], got [$2]"; }
log() { :; }
warn() { printf '%s\n' "$*" >>"$d/warn.log"; }
BACKUP_DIR="$d/backup"
TMP_DIR="$d/tmp"
mkdir -p "$BACKUP_DIR" "$TMP_DIR" "$d/smartdns-etc"
lsattr() { :; }
chattr() { :; }
mountpoint() { return 1; }
getent() { return 0; }
sleep() { :; }
# SmartDNS config generation must never look at host IPv6 state.
ip() { fail 'SmartDNS or DNS setup probed host IPv6'; }
install() {
  case "$1" in
    -d) [[ "${*: -1}" == "$d"/* ]] && mkdir -p -- "${*: -1}"; return 0 ;;
    *) cp -- "${@: -2:1}" "${@: -1}" ;;
  esac
}

# resolv.conf: SmartDNS first, fixed fallback second, no duplicates after repeated runs.
printf 'nameserver 9.9.9.9\nsearch example.invalid\n' >"$d/resolv.conf"
eq 1.1.1.1 "$FALLBACK_DNS" 'fallback constant'
expected=$(printf 'nameserver 127.0.0.1\nnameserver %s\noptions timeout:2 attempts:2' "$FALLBACK_DNS")
for _ in 1 2 3; do
  DNS_TX=true
  configure_system_dns
  eq "$expected" "$(cat "$d/resolv.conf")" 'resolv.conf content'
  eq 2 "$(grep -c '^nameserver' "$d/resolv.conf")" 'nameserver lines'
  eq 1 "$(grep -c '^options' "$d/resolv.conf")" 'options lines'
done
eq 'nameserver 9.9.9.9' "$(sed -n 1p "$BACKUP_DIR/files$d/resolv.conf")" 'original resolv.conf backup'
getent() { return 2; }
if (configure_system_dns) >/dev/null 2>&1; then fail 'unresolvable system DNS accepted'; fi
getent() { return 0; }

# SmartDNS: an old [::1] listener is removed on rerun; start-up and health never depend on ::1.
systemctl() {
  printf '%s\n' "$*" >>"$d/systemctl.log"
  [[ "$*" != 'restart smartdns.service' || "${restart_fail:-false}" != true ]]
}
dig() {
  printf '%s\n' "$*" >>"$d/dig.log"
  case " $* " in
    *' TXT '*) echo 'status: NXDOMAIN,' ;;
    *' AAAA '*) echo 2001:db8::1 ;;
    *) echo 192.0.2.1 ;;
  esac
}
for request in auto dual ipv4; do
  NETWORK_REQUEST=$request
  for transport in h2 dns53; do
    : >"$d/systemctl.log"
    : >"$d/dig.log"
    printf 'bind 127.0.0.1:53\nbind [::1]:53\nbind-tcp [::1]:53\n' >"$SMARTDNS_CONF"
    if [[ "$request" == ipv4 ]]; then
      dig() {
        printf '%s\n' "$*" >>"$d/dig.log"
        case " $* " in
          *' TXT '*) echo 'status: NXDOMAIN,' ;;
          *' AAAA '*) : ;;
          *) echo 192.0.2.1 ;;
        esac
      }
    fi
    smartdns_try_transport "$transport" "$TMP_DIR/staged.conf" || fail "$request $transport rejected a healthy resolver"
    if grep -Fq '::1' "$SMARTDNS_CONF"; then fail "$request $transport kept an old ::1 listener"; fi
    eq 2 "$(grep -c '^bind' "$SMARTDNS_CONF")" "$request $transport listeners"
    eq 1 "$(grep -c '^restart smartdns.service$' "$d/systemctl.log")" "$request $transport restart count"
    # Health probes query the local SmartDNS directly, never the resolv.conf fallback.
    awk '$1 != "@127.0.0.1" { bad=1 } END { exit bad || NR == 0 }' "$d/dig.log" || fail "$request $transport health probe bypassed 127.0.0.1"
  done
done
# A failed start is final: no IPv4-only retry path exists, and the config still has no ::1.
NETWORK_REQUEST=auto
: >"$d/systemctl.log"
restart_fail=true
if smartdns_try_transport h2 "$TMP_DIR/staged.conf"; then fail 'failed SmartDNS start accepted'; fi
eq 1 "$(grep -c '^restart smartdns.service$' "$d/systemctl.log")" 'failed start must not retry'
if grep -Fq '::1' "$SMARTDNS_CONF"; then fail 'failed start left ::1 in config'; fi
restart_fail=false
# A dead SmartDNS fails the health gate even though system DNS would still resolve via the fallback.
dig() { printf '%s\n' "$*" >>"$d/dig.log"; return 1; }
if smartdns_try_transport h2 "$TMP_DIR/staged.conf"; then fail 'fallback DNS masked a dead SmartDNS'; fi

# Full and SmartDNS-only installs share install_and_configure_smartdns; both end up IPv4-only.
dig() {
  case " $* " in
    *' TXT '*) echo 'status: NXDOMAIN,' ;;
    *' AAAA '*) echo 2001:db8::1 ;;
    *) echo 192.0.2.1 ;;
  esac
}
smartdns_pkg_values() { :; }
install_smartdns_package() { :; }
configure_smartdns_apt_policy() { :; }
smartdns() { echo 'smartdns test'; }
journalctl() { :; }
id() { echo root; }
for mode in quick smartdns; do
  INSTALL_MODE=$mode
  NETWORK_REQUEST=auto
  printf 'bind [::1]:53\n' >"$SMARTDNS_CONF"
  install_and_configure_smartdns
  if grep -Fq '::1' "$SMARTDNS_CONF"; then fail "$mode install kept ::1"; fi
  grep -Fxq 'bind-tcp 127.0.0.1:53' "$SMARTDNS_CONF" || fail "$mode install lacks the IPv4 TCP listener"
done

# A failure while the DNS transaction is open restores the previous state, including
# the case where /etc/resolv.conf did not exist at all.
dns_failure() {
  local mode=$1 status=0
  rm -rf "$BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"
  rm -f -- "$d/resolv.conf" "$SMARTDNS_CONF"
  if [[ "$mode" == existing ]]; then
    printf 'nameserver 9.9.9.9\nsearch example.invalid\n' >"$d/resolv.conf"
    printf 'bind 127.0.0.1:53\n' >"$SMARTDNS_CONF"
  fi
  (
    DNS_TX=false
    NETWORK_POLICY_CHANGED=false
    getent() { return 2; }
    backup_dns_state
    DNS_TX=true
    configure_system_dns
  ) >/dev/null 2>&1 || status=$?
  (( status != 0 )) || fail "$mode: unresolvable DNS accepted"
  if [[ "$mode" == existing ]]; then
    eq $'nameserver 9.9.9.9\nsearch example.invalid' "$(cat "$d/resolv.conf")" 'resolv.conf restored'
    eq 'bind 127.0.0.1:53' "$(cat "$SMARTDNS_CONF")" 'smartdns.conf restored'
  else
    [[ ! -e "$d/resolv.conf" && ! -L "$d/resolv.conf" ]] || fail 'resolv.conf that did not exist was left behind'
    [[ ! -e "$SMARTDNS_CONF" ]] || fail 'smartdns.conf that did not exist was left behind'
  fi
}
dns_failure existing
dns_failure missing

# "resolv.conf did not exist" only licenses removing what this run wrote, unchanged.
fresh_backup() {
  rm -rf "$BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"
  rm -f -- "$d/resolv.conf"
  : >"$d/warn.log"
}
# (a) written by this run and untouched: removed.
fresh_backup
(
  RESOLV_WRITTEN_SHA=''
  backup_dns_state
  DNS_TX=true
  configure_system_dns
  DNS_TX=true
  rollback_dns
) >/dev/null 2>&1
[[ ! -e "$d/resolv.conf" ]] || fail 'our own resolv.conf was not removed'
# (b) the run failed before writing; a file created meanwhile by a user or service stays.
fresh_backup
(
  RESOLV_WRITTEN_SHA=''
  backup_dns_state
  printf 'nameserver 8.8.4.4\n' >"$d/resolv.conf"
  DNS_TX=true
  rollback_dns
) >/dev/null 2>&1
eq 'nameserver 8.8.4.4' "$(cat "$d/resolv.conf")" 'foreign resolv.conf created before our write was removed'
grep -Fq '已保留' "$d/warn.log" || fail 'missing keep warning (before write)'
# (c) written by this run, then replaced by someone else: stays.
fresh_backup
(
  RESOLV_WRITTEN_SHA=''
  backup_dns_state
  DNS_TX=true
  configure_system_dns
  printf 'nameserver 9.9.9.9\n' >"$d/resolv.conf"
  DNS_TX=true
  rollback_dns
) >/dev/null 2>&1
eq 'nameserver 9.9.9.9' "$(cat "$d/resolv.conf")" 'replaced resolv.conf was removed'
grep -Fq '已保留' "$d/warn.log" || fail 'missing keep warning (after replacement)'
rm -f -- "$d/resolv.conf"

# Transport order: DoH first, UDP/TCP 53 next, and a complete failure rolls back.
TRACE="$d/transport.trace"
: >"$TRACE"
smartdns_try_transport() { echo "$1" >>"$TRACE"; [[ "$1" == "$available_transport" ]]; }
available_transport=h2
install_and_configure_smartdns
eq h2 "$(cat "$TRACE")" 'DoH success skips fallback'
eq 'DoH (H2 优先)' "$SMARTDNS_TRANSPORT" 'DoH result'
: >"$TRACE"
available_transport=dns53
install_and_configure_smartdns
eq $'h2\ndns53' "$(cat "$TRACE")" 'transport fallback order'
eq DNS53 "$SMARTDNS_TRANSPORT" 'fallback result'
: >"$TRACE"
available_transport=none
rollback_dns() { echo rollback >>"$TRACE"; }
if (install_and_configure_smartdns) >/dev/null 2>&1; then fail 'complete upstream failure accepted'; fi
eq $'h2\ndns53\nrollback' "$(cat "$TRACE")" 'complete failure invokes rollback'
TEST

# The Debian entry point can display help without running initialization.
help_output=$(bash "$REPO_ROOT/debian-init.sh" --help)
[[ "$help_output" == *'bash debian-init.sh'* && "$help_output" == *'--smartdns-only'* && "$help_output" == *'--sing-box-only'* ]] || fail 'direct entry point help is incomplete'

printf 'PASS: Debian dispatch, DNS health, sing-box startup gates and direct entry point\n'
