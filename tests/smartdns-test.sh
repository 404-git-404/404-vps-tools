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

ipv6_loopback_available() { return 0; }
for stack in ipv4 dual; do
  NETWORK_STACK=$stack
  NETWORK_REQUEST=$stack
  for transport in h2 dns53; do
    write_smartdns_config "$TEST_TMP/$stack-$transport.conf" "$transport"
    config=$(cat "$TEST_TMP/$stack-$transport.conf")
    [[ "$config" == *'bind 127.0.0.1:53'* && "$config" == *'bind-tcp 127.0.0.1:53'* ]] || fail 'missing local UDP/TCP listener'
    if [[ "$stack" == ipv4 ]]; then
      [[ "$config" == *'force-AAAA-SOA yes'* && "$config" != *'bind [::1]:53'* ]] || fail 'IPv4 DNS leaked IPv6'
    else
      [[ "$config" == *'force-AAAA-SOA no'* && "$config" == *'bind [::1]:53'* ]] || fail 'dual DNS missing IPv6'
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
for policy in fresh provider legacy legacy-service ipv4 dual; do
  (
    export POLICY_TEST_DIR="$TEST_TMP/policy-$policy"
    export POLICY_TEST_SCENARIO="$policy"
    # shellcheck disable=SC2016 # Expand the test path in the child Bash.
    sed -e 's|^readonly NETWORK_SYSCTL=.*|readonly NETWORK_SYSCTL="$POLICY_TEST_DIR/network.conf"|' \
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
mkdir -p "$BACKUP_DIR/dns"
trace="$POLICY_TEST_DIR/sysctl"
: >"$trace"
make_mutable() { :; }
install() { [[ "$1" == -d ]]; shift 3; mkdir -p "$@"; }
sysctl() { if [[ "$1" == -n ]]; then echo 1; else printf '%s\n' "${*: -1}" >>"$trace"; fi; }
systemctl() { printf '%s\n' "$*" >>"$trace"; }
ipv6_probe_keys() { printf 'net/ipv6/conf/eth0/disable_ipv6\n'; }
case "$POLICY_TEST_SCENARIO" in
  provider) printf '# Provider settings\nnet.ipv6.conf.eth0.accept_ra = 2\n' >"$NETWORK_SYSCTL" ;;
  legacy) printf '# Managed by vps-init.sh\nnet.ipv6.conf.all.disable_ipv6 = 1\n' >"$NETWORK_SYSCTL" ;;
  legacy-service)
    printf 'Description=Apply 404-vps-tools IPv4-only network stack\n' >"$LEGACY_NETWORK_UNIT"
    printf 'net.ipv6.conf.all.disable_ipv6 = 1\n' >"$LEGACY_IPV6_SYSCTL" ;;
  ipv4|dual) NETWORK_REQUEST=$POLICY_TEST_SCENARIO ;;
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
  ipv4|dual)
    value=0
    if [[ "$NETWORK_REQUEST" == ipv4 ]]; then value=1; fi
    grep -Fxq "net.ipv6.conf.all.disable_ipv6 = $value" "$NETWORK_SYSCTL" ;;
esac
TEST
  )
done

(
  ipv6_loopback_available() { return 1; }
  write_smartdns_config "$TEST_TMP/auto-no-loopback.conf"
  grep -Fxq 'bind 127.0.0.1:53' "$TEST_TMP/auto-no-loopback.conf"
  grep -Fxq 'bind-tcp 127.0.0.1:53' "$TEST_TMP/auto-no-loopback.conf"
  grep -Fxq 'force-AAAA-SOA no' "$TEST_TMP/auto-no-loopback.conf"
  if grep -Fq '[::1]' "$TEST_TMP/auto-no-loopback.conf"; then fail 'unavailable IPv6 listener enabled'; fi
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

# Exercise DoH success, DNS53 recovery and complete upstream failure.
(
  TMP_DIR=$TEST_TMP
  TRACE="$TEST_TMP/transport.trace"
  smartdns_pkg_values() { :; }
  install_smartdns_package() { :; }
  configure_smartdns_apt_policy() { :; }
  # shellcheck disable=SC2329,SC2317 # Called by the sourced installer.
  command() { if [[ "${1:-}" == -v && "${2:-}" == smartdns ]]; then return 0; fi; builtin command "$@"; }
  # shellcheck disable=SC2329 # Called indirectly by the sourced installer.
  install() { :; }
  systemctl() { :; }
  smartdns() { echo 'smartdns test'; }
  smartdns_try_transport() { echo "$1" >>"$TRACE"; [[ "$1" == "$available_transport" ]]; }
  log() { :; }
  warn() { :; }
  available_transport=h2
  install_and_configure_smartdns
  assert_eq h2 "$(cat "$TRACE")" 'DoH success skips fallback'
  assert_eq 'DoH (H2 优先)' "$SMARTDNS_TRANSPORT" 'DoH result'
  : >"$TRACE"
  available_transport=dns53
  install_and_configure_smartdns
  assert_eq $'h2\ndns53' "$(cat "$TRACE")" 'transport fallback order'
  assert_eq DNS53 "$SMARTDNS_TRANSPORT" 'fallback result'
  : >"$TRACE"
  available_transport=none
  journalctl() { :; }
  rollback_dns() { echo rollback >>"$TRACE"; }
  if (install_and_configure_smartdns) >"$TEST_TMP/transport-error.log" 2>&1; then
    fail 'complete upstream failure accepted'
  fi
  assert_eq $'h2\ndns53\nrollback' "$(cat "$TRACE")" 'complete failure invokes rollback'
)

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

# The Debian entry point can display help without running initialization.
help_output=$(bash "$REPO_ROOT/debian-init.sh" --help)
[[ "$help_output" == *'bash debian-init.sh'* && "$help_output" == *'--smartdns-only'* && "$help_output" == *'--sing-box-only'* ]] || fail 'direct entry point help is incomplete'

printf 'PASS: Debian dispatch, DNS health, sing-box startup gates and direct entry point\n'
