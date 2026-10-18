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

for stack in ipv4 dual; do
  NETWORK_STACK=$stack
  for transport in h3 dns53; do
    write_smartdns_config "$TEST_TMP/$stack-$transport.conf" "$transport"
    config=$(cat "$TEST_TMP/$stack-$transport.conf")
    [[ "$config" == *'bind 127.0.0.1:53'* && "$config" == *'bind-tcp 127.0.0.1:53'* ]] || fail 'missing local UDP/TCP listener'
    if [[ "$stack" == ipv4 ]]; then
      [[ "$config" == *'force-AAAA-SOA yes'* && "$config" != *'bind [::1]:53'* ]] || fail 'IPv4 DNS leaked IPv6'
    else
      [[ "$config" == *'force-AAAA-SOA no'* && "$config" == *'bind [::1]:53'* ]] || fail 'dual DNS missing IPv6'
    fi
    if [[ "$transport" == h3 ]]; then
      [[ "$config" == *'server-h3 h3://'* ]] || fail 'H3 upstream missing'
    else
      [[ "$config" != *'server-h3 '* && "$config" == *'server-tcp 1.1.1.1'* ]] || fail 'DNS53 fallback missing'
    fi
  done
done

# A CNAME alone or a broken TCP listener cannot satisfy the DNS health gate.
(
  NETWORK_STACK=ipv4
  dig() { if [[ " $* " == *' AAAA '* ]]; then return 0; fi; echo 192.0.2.1; }
  smartdns_health_check || fail 'valid IPv4 DNS rejected'
  dig() { echo cname.invalid.; }
  if smartdns_health_check; then fail 'CNAME accepted as an address'; fi
  dig() { [[ " $* " != *' +tcp '* ]] || return 1; echo 192.0.2.1; }
  if smartdns_health_check; then fail 'broken TCP listener accepted'; fi
  NETWORK_STACK=dual
  dig() { if [[ " $* " == *' AAAA '* ]]; then echo 2001:db8::1; else echo 192.0.2.1; fi; }
  smartdns_health_check || fail 'valid dual DNS rejected'
)

NETWORK_STACK=unknown

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

# Exercise H3 failure and DNS53 recovery through the production fallback branch.
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
  smartdns_try_transport() { echo "$1" >>"$TRACE"; [[ "$1" == dns53 ]]; }
  log() { :; }
  warn() { :; }
  install_and_configure_smartdns
  assert_eq $'h3\ndns53' "$(cat "$TRACE")" 'transport fallback order'
  assert_eq DNS53 "$SMARTDNS_TRANSPORT" 'fallback result'
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

# Exercise the downloaded entry point with a fake curl and no system changes.
mkdir -p "$TEST_TMP/bootstrap" "$TEST_TMP/bin" "$TEST_TMP/downloads"
cp "$REPO_ROOT/404notfound.sh" "$TEST_TMP/bootstrap/404notfound.sh"
cat >"$TEST_TMP/bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -Eeuo pipefail
while (( $# )); do
  if [[ "$1" == -o ]]; then
    printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail' 'printf "%s\n" "$@"' >"$2"
    exit 0
  fi
  shift
done
exit 1
MOCK_CURL
chmod +x "$TEST_TMP/bin/curl"
result=$(PATH="$TEST_TMP/bin:$PATH" TMPDIR="$TEST_TMP/downloads" bash "$TEST_TMP/bootstrap/404notfound.sh" --smartdns-only)
assert_eq --smartdns-only "$result" 'downloaded entry point argument forwarding'
[[ -z "$(ls -A "$TEST_TMP/downloads")" ]] || fail 'bootstrap leaked temporary files'
printf '%s\n' '#!/usr/bin/env bash' 'exit 23' >"$TEST_TMP/bin/curl"
if PATH="$TEST_TMP/bin:$PATH" TMPDIR="$TEST_TMP/downloads" bash "$TEST_TMP/bootstrap/404notfound.sh" >"$TEST_TMP/download-failure.log" 2>&1; then
  fail 'bootstrap ignored download failure'
fi
[[ -z "$(ls -A "$TEST_TMP/downloads")" ]] || fail 'failed bootstrap leaked temporary files'

printf 'PASS: Debian dispatch, DNS health, sing-box startup gates and bootstrap cleanup\n'
