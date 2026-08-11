#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME='protocol-benchmark'
readonly DEFAULT_DURATION=2
readonly DEEP_DURATION=3
readonly DEFAULT_COOLDOWN=1
readonly DEFAULT_BUDGET_MB=200
readonly DEEP_BUDGET_MB=600
readonly DEFAULT_SERVER_WAIT=600
readonly SERVER_SESSION_IDLE=120
readonly SERVER_ERROR_LIMIT=3
readonly DEFAULT_MAX_PERCENT=20
readonly DEEP_MAX_PERCENT=35
readonly MIN_PORT=49152
readonly MAX_PORT=65535
readonly ASYMMETRY_THROUGHPUT_RATIO=0.65
readonly ASYMMETRY_UDP_SEVERE_DELTA=2.0
readonly ASYMMETRY_UDP_PERSISTENT_DELTA=0.30
readonly ASYMMETRY_TCP_SEVERE_RETRANS=100
readonly ASYMMETRY_TCP_PERSISTENT_RETRANS=50
readonly ASYMMETRY_TCP_RETRANS_RATIO=4
readonly ASYMMETRY_TCP_DENSITY=50
readonly ASYMMETRY_LOAD_RTT_DELTA=30
readonly ASYMMETRY_LOAD_RTT_HIGH=40
readonly PREFERENCE_MATERIAL_MARGIN=15
readonly PREFERENCE_USABLE_SCORE=65
# Retransmission density is normalized per direction. A 5 MB effective sample
# prevents a single retransmission in a tiny transfer from being magnified.
readonly TCP_RETRANS_MIN_DIRECTION_BYTES=5000000
readonly TCP_RETRANS_NOISE_FLOOR=20
readonly TCP_RETRANS_NOISE_MAX_PENALTY=2
readonly TCP_RETRANS_PENALTY_PER_DOUBLING=6
readonly TCP_RETRANS_MAX_PENALTY=50
readonly TCP_RETRANS_DIAGNOSTIC_PENALTY=15
readonly DEFAULT_HISTORY_LIMIT=20
readonly MAX_HISTORY_LIMIT=100
readonly HISTORY_RETENTION=100
readonly TEST_RESULT_OK=0
readonly TEST_RESULT_FAILED=1
readonly TEST_RESULT_BUDGET_DENIED=2

MODE='client'
PEER=''
PORT=''
ALLOW_PEER=''
SERVER_WAIT=$DEFAULT_SERVER_WAIT
NOMINAL_MBPS=''
DEEP=false
SAVE_BASELINE=false
COMPARE_BASELINE=false
HISTORY_LIMIT=$DEFAULT_HISTORY_LIMIT
HISTORY_LIMIT_SET=false
DURATION=$DEFAULT_DURATION
COOLDOWN=$DEFAULT_COOLDOWN
BUDGET_MB=$DEFAULT_BUDGET_MB
MAX_PERCENT=$DEFAULT_MAX_PERCENT
BUDGET_BYTES=0
TRAFFIC_RESERVED_BYTES=0
TRAFFIC_ACCOUNTED_BYTES=0
TRAFFIC_ACTUAL_BYTES=0
TEMP_DIR=''
RESULT_FILE=''
FAILURE_FILE=''
ACTIVE_IPERF_PID=''
ACTIVE_PING_PID=''
FIREWALL_RULE_ADDED=false
FIREWALL_COMMENT=''
FIREWALL_STATUS='unchanged'
SERVER_TESTS=0
TEST_FAILURES=0
TCP_FAILURES=0
UDP_FAILURES=0
CPU_LIMITED=false
BUDGET_LIMITED=false
EARLY_STOP=false
TCP_ADAPTIVE_STOP=false
UDP_ADAPTIVE_STOP=false
TCP_STOP_STAGE=0
UDP_STOP_STAGE=0
TCP_HIGHEST_STAGE=0
UDP_HIGHEST_STAGE=0
IDLE_RTT=''
IDLE_VARIATION=''
IDLE_LOSS=''
PING_AVG=''
PING_VARIATION=''
PING_LOSS=''
MAX_LOAD_INCREASE=0
MAX_CPU=0
MAX_LOAD_AVERAGE=0
TCP_SCORE=0
UDP_SCORE=0
TCP_RETRANS_DENSITY_A_TO_B=0
TCP_RETRANS_DENSITY_B_TO_A=0
TCP_RETRANS_WORST_DIRECTION='NONE'
TCP_RETRANS_PENALTY=0
TCP_TRANSFERRED_BYTES_A_TO_B=0
TCP_TRANSFERRED_BYTES_B_TO_A=0
TCP_RETRANSMISSIONS_A_TO_B=0
TCP_RETRANSMISSIONS_B_TO_A=0
LINK_HEALTH=0
CONFIDENCE='LOW'
STATUS='POOR'
PREFERRED='FIX LINK'
REASON='Insufficient evidence to classify this VPS-to-VPS link.'
RESULT_STATE='COMPLETE'
TCP_EVALUABLE=false
UDP_EVALUABLE=false
ASYMMETRY_REASON=''
LABELS=''
PLATFORM_FAMILY=''
PLATFORM_VERSION=''
AWK_BIN=''
PRIVILEGE_HELPER=''
IPERF3_INSTALLED_NOW=false
OS_RELEASE_FILE=${PROTOCOL_BENCHMARK_OS_RELEASE_FILE:-/etc/os-release}
declare -a UFW_COMMAND=()
declare -a MISSING_COMMANDS=()
declare -a MISSING_PACKAGES=()
MAIN_BASHPID=$BASHPID
readonly MAIN_BASHPID

print_usage() {
  printf '%s - LOW-IMPACT VPS-to-VPS link diagnosis\n\n' "$PROGRAM_NAME"
  cat <<'EOF'

Usage:
  protocol-benchmark.sh --server [--port PORT] [--allow-peer IP]
  protocol-benchmark.sh PEER --port PORT [options]
  protocol-benchmark.sh --history PEER [--limit COUNT]

Server options:
  --server              Run the temporary iperf3 server supervisor.
  --port PORT           Use this high port instead of a random one.
  --allow-peer IP       Temporarily allow only this IP through active UFW.
  --server-wait SEC     Stop if no first test arrives (default: 600).

Client options:
  --port PORT           Port printed by the temporary server (required).
  --bandwidth MBPS      Nominal package bandwidth; skips the prompt.
  --deep                Explicit bounded deeper mode (max 35%, 600 MB).
  --save-baseline       Save the current healthy-link baseline.
  --compare             Compare the current result with a saved baseline.

History options:
  --history PEER        Show recent controller-side history for PEER.
  --limit COUNT         Show 1-100 entries (default: 20).

Two-VPS workflow:
  VPS-B: bash protocol-benchmark.sh --server --allow-peer A_IP
  VPS-A: bash protocol-benchmark.sh B_IP --port PORT

The server prints its random PORT and temporarily manages an already active UFW.
Use --allow-peer to enforce a peer-only temporary TCP/UDP rule.
The result describes the underlying VPS-to-VPS link, not sing-box or proxies.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

is_root() {
  (( EUID == 0 ))
}

awk() {
  if [[ -n "$AWK_BIN" ]]; then
    "$AWK_BIN" "$@"
  else
    command awk "$@"
  fi
}

is_uint() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

is_positive_number() {
  local value=$1
  [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ &&
    "$value" =~ [1-9] ]]
}

number_not_greater_than_100000() {
  local value=$1
  local whole=${value%%.*}
  local fraction=''

  [[ "$value" == *.* ]] && fraction=${value#*.}
  while [[ ${#whole} -gt 1 && "$whole" == 0* ]]; do
    whole=${whole#0}
  done
  (( ${#whole} < 6 )) && return 0
  (( ${#whole} > 6 )) && return 1
  [[ "$whole" == '100000' && ( -z "$fraction" ||
    ! "$fraction" =~ [1-9] ) ]]
}

validate_port() {
  is_uint "$1" && (( 10#$1 >= MIN_PORT && 10#$1 <= MAX_PORT ))
}

validate_peer() {
  local value=$1
  [[ -n "$value" && "$value" != -* && "$value" != *[[:space:]]* &&
    "$value" =~ ^[A-Za-z0-9._:-]+$ ]]
}

validate_firewall_peer() {
  local value=$1
  [[ "$value" =~ ^[0-9A-Fa-f:.]+$ && "$value" == *[.:]* ]]
}

check_platform() {
  local os_id=''
  local version_id=''

  [[ -r "$OS_RELEASE_FILE" ]] ||
    die 'Debian 12/13 or Alpine 3.21-3.24 is required.'
  # shellcheck disable=SC1090
  source "$OS_RELEASE_FILE"
  os_id=${ID:-}
  version_id=${VERSION_ID:-}
  case "$os_id" in
    debian)
      [[ "$version_id" == '12' || "$version_id" == '13' ]] ||
        die 'Debian 12/13 or Alpine 3.21-3.24 is required.'
      PLATFORM_FAMILY='debian'
      PLATFORM_VERSION=$version_id
      ;;
    alpine)
      [[ "$version_id" =~ ^3[.](21|22|23|24)([.][0-9]+)*$ ]] ||
        die 'Debian 12/13 or Alpine 3.21-3.24 is required.'
      PLATFORM_FAMILY='alpine'
      PLATFORM_VERSION="3.${BASH_REMATCH[1]}"
      ;;
    *)
      die 'Debian 12/13 or Alpine 3.21-3.24 is required.'
      ;;
  esac
  [[ -n "$PLATFORM_FAMILY" && -n "$PLATFORM_VERSION" ]] ||
    die 'Unable to identify the supported platform.'
}

add_missing_dependency() {
  local description=$1
  local package=$2
  local existing

  MISSING_COMMANDS+=("$description")
  for existing in "${MISSING_PACKAGES[@]}"; do
    [[ "$existing" != "$package" ]] || return 0
  done
  MISSING_PACKAGES+=("$package")
}

has_gnu_sed() {
  local version

  command_exists sed || return 1
  version=$(sed --version 2>/dev/null) || return 1
  [[ "$version" == 'sed (GNU sed) '* ]]
}

has_coreutils_date() {
  local value
  command_exists date || return 1
  value=$(date -u +%N 2>/dev/null) || return 1
  [[ "$value" =~ ^[0-9]{9}$ ]]
}

has_coreutils_timeout() {
  local version

  command_exists timeout || return 1
  version=$(timeout --version 2>/dev/null) || return 1
  [[ "$version" == *'GNU coreutils'* ]]
}

has_coreutils_sort() {
  local version

  command_exists sort || return 1
  version=$(sort --version 2>/dev/null) || return 1
  [[ "$version" == *'GNU coreutils'* ]]
}

has_iputils_ping() {
  local version

  command_exists ping || return 1
  version=$(ping -V 2>&1) || return 1
  [[ "${version,,}" == *iputils* ]]
}

collect_missing_dependencies() {
  MISSING_COMMANDS=()
  MISSING_PACKAGES=()

  if [[ "$MODE" == 'history' ]]; then
    command_exists jq || add_missing_dependency 'jq' 'jq'
    has_coreutils_sort || add_missing_dependency 'coreutils sort' 'coreutils'
    return 0
  fi

  command_exists mawk || add_missing_dependency 'mawk-compatible awk' 'mawk'
  has_gnu_sed || add_missing_dependency 'GNU sed' 'sed'
  command_exists iperf3 || add_missing_dependency 'iperf3' 'iperf3'
  has_coreutils_timeout ||
    add_missing_dependency 'coreutils timeout --foreground' 'coreutils'
  if [[ "$MODE" == 'client' ]]; then
    command_exists jq || add_missing_dependency 'jq' 'jq'
    has_coreutils_date ||
      add_missing_dependency 'coreutils date with nanoseconds' 'coreutils'
    has_iputils_ping || add_missing_dependency 'iputils ping' \
      "$([[ "$PLATFORM_FAMILY" == 'debian' ]] && printf 'iputils-ping' || printf 'iputils')"
  fi
}

manual_install_command() {
  local packages=${MISSING_PACKAGES[*]}
  if [[ "$PLATFORM_FAMILY" == 'debian' ]]; then
    printf 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends %s' \
      "$packages"
  else
    printf 'apk add --no-cache %s' "$packages"
    if alpine_iperf3_constraint_needed; then
      printf " '%s'" '!iperf3-openrc'
    fi
  fi
}

alpine_iperf3_constraint_needed() {
  local package

  [[ "$PLATFORM_FAMILY" == 'alpine' ]] || return 1
  for package in "${MISSING_PACKAGES[@]}"; do
    [[ "$package" != 'iperf3' ]] || return 0
  done
  return 1
}

choose_privilege_helper() {
  PRIVILEGE_HELPER=''
  ! is_root || return 0
  if [[ "$PLATFORM_FAMILY" == 'alpine' ]] && command_exists doas; then
    PRIVILEGE_HELPER='doas'
  elif command_exists sudo; then
    PRIVILEGE_HELPER='sudo'
  else
    return 1
  fi
}

install_runtime_packages() {
  local package_manager
  local -a alpine_packages=()

  (( ${#MISSING_PACKAGES[@]} > 0 )) || return 0
  choose_privilege_helper || die "Missing runtime capabilities: ${MISSING_COMMANDS[*]}. Required packages: ${MISSING_PACKAGES[*]}. Run as root: $(manual_install_command)"
  if [[ "$PLATFORM_FAMILY" == 'debian' ]]; then
    package_manager=(apt-get)
    if [[ -z "$PRIVILEGE_HELPER" ]]; then
      DEBIAN_FRONTEND=noninteractive apt-get update ||
        die 'apt-get update failed; no benchmark was started.'
      DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --no-install-recommends "${MISSING_PACKAGES[@]}" ||
        die 'apt-get install failed; no benchmark was started.'
    else
      "$PRIVILEGE_HELPER" env DEBIAN_FRONTEND=noninteractive apt-get update ||
        die 'apt-get update failed; no benchmark was started.'
      "$PRIVILEGE_HELPER" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --no-install-recommends "${MISSING_PACKAGES[@]}" ||
        die 'apt-get install failed; no benchmark was started.'
    fi
  else
    package_manager=(apk)
    [[ -z "$PRIVILEGE_HELPER" ]] || package_manager=("$PRIVILEGE_HELPER" apk)
    alpine_packages=("${MISSING_PACKAGES[@]}")
    if alpine_iperf3_constraint_needed; then
      alpine_packages+=('!iperf3-openrc')
    fi
    "${package_manager[@]}" add --no-cache "${alpine_packages[@]}" ||
      die 'apk add failed; no benchmark was started.'
  fi
}

ensure_alpine_iperf3_service_absent() {
  [[ "$PLATFORM_FAMILY" == 'alpine' &&
    "$IPERF3_INSTALLED_NOW" == true ]] || return 0
  if apk info -e iperf3-openrc >/dev/null 2>&1 ||
    [[ -e /etc/init.d/iperf3 ]]; then
    die 'The Alpine iperf3 OpenRC service package was not excluded.'
  fi
}

run_privileged() {
  if is_root; then
    "$@"
  elif [[ -n "$PRIVILEGE_HELPER" ]]; then
    "$PRIVILEGE_HELPER" "$@"
  else
    return 1
  fi
}

ensure_new_iperf3_daemon_disabled() {
  [[ "$PLATFORM_FAMILY" == 'debian' &&
    "$IPERF3_INSTALLED_NOW" == true ]] || return 0
  if command_exists systemctl; then
    run_privileged systemctl stop iperf3.service >/dev/null 2>&1 || true
    run_privileged systemctl disable iperf3.service >/dev/null 2>&1 || true
    if systemctl is-active --quiet iperf3.service 2>/dev/null ||
      [[ "$(systemctl is-enabled iperf3.service 2>/dev/null || true)" == 'enabled' ]]; then
      die 'The newly installed iperf3 service could not be left inactive and disabled.'
    fi
  else
    if command_exists service; then
      run_privileged service iperf3 stop >/dev/null 2>&1 || true
    fi
    if command_exists update-rc.d; then
      run_privileged update-rc.d iperf3 disable >/dev/null 2>&1 || true
    fi
  fi
}

check_dependencies() {
  local iperf3_was_missing=false

  [[ "$MODE" == 'history' ]] || command_exists iperf3 ||
    iperf3_was_missing=true
  collect_missing_dependencies
  install_runtime_packages
  collect_missing_dependencies
  if (( ${#MISSING_COMMANDS[@]} > 0 )); then
    die "Runtime dependencies remain unavailable after installation: ${MISSING_COMMANDS[*]} (packages: ${MISSING_PACKAGES[*]})."
  fi
  if [[ "$MODE" != 'history' ]]; then
    AWK_BIN=$(command -v mawk)
    [[ -x "$AWK_BIN" ]] || die 'A verified mawk executable is required.'
  fi

  if [[ "$iperf3_was_missing" == true && "$MODE" != 'history' ]]; then
    IPERF3_INSTALLED_NOW=true
    ensure_alpine_iperf3_service_absent
    ensure_new_iperf3_daemon_disabled
  fi
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --server)
        [[ "$MODE" == 'client' && -z "$PEER" ]] ||
          die 'Choose only one of client, --server, or --history mode.'
        MODE='server'
        shift
        ;;
      --history)
        (( $# >= 2 )) || die '--history requires a peer.'
        [[ "$MODE" == 'client' && -z "$PEER" ]] ||
          die 'Choose only one of client, --server, or --history mode.'
        MODE='history'
        PEER=$2
        shift 2
        ;;
      --limit)
        (( $# >= 2 )) || die '--limit requires a positive integer.'
        HISTORY_LIMIT=$2
        HISTORY_LIMIT_SET=true
        shift 2
        ;;
      --port)
        (( $# >= 2 )) || die '--port requires a value.'
        PORT=$2
        shift 2
        ;;
      --allow-peer)
        (( $# >= 2 )) || die '--allow-peer requires an IP address.'
        ALLOW_PEER=$2
        shift 2
        ;;
      --server-wait)
        (( $# >= 2 )) || die '--server-wait requires seconds.'
        SERVER_WAIT=$2
        shift 2
        ;;
      --bandwidth)
        (( $# >= 2 )) || die '--bandwidth requires Mbps.'
        NOMINAL_MBPS=$2
        shift 2
        ;;
      --deep)
        DEEP=true
        shift
        ;;
      --save-baseline)
        SAVE_BASELINE=true
        shift
        ;;
      --compare)
        COMPARE_BASELINE=true
        shift
        ;;
      -h|--help)
        print_usage
        exit 0
        ;;
      --*)
        die "Unknown option: $1"
        ;;
      *)
        [[ -z "$PEER" ]] || die 'Only one peer may be specified.'
        PEER=$1
        shift
        ;;
    esac
  done

  if [[ "$MODE" == 'server' ]]; then
    [[ -z "$PEER" ]] || die 'Server mode does not accept a peer argument.'
    [[ -z "$NOMINAL_MBPS" ]] || die '--bandwidth is a client option.'
    [[ "$DEEP" == false && "$SAVE_BASELINE" == false &&
      "$COMPARE_BASELINE" == false ]] || die 'Client options cannot be used with --server.'
    if ! is_uint "$SERVER_WAIT" ||
      (( SERVER_WAIT < 30 || SERVER_WAIT > 3600 )); then
      die '--server-wait must be between 30 and 3600 seconds.'
    fi
    if [[ -n "$ALLOW_PEER" ]]; then
      validate_firewall_peer "$ALLOW_PEER" ||
        die '--allow-peer must be a literal IPv4 or IPv6 address.'
    fi
    [[ "$HISTORY_LIMIT_SET" == false ]] || die '--limit is a history option.'
  elif [[ "$MODE" == 'history' ]]; then
    validate_peer "$PEER" || die 'A valid history peer is required.'
    [[ -z "$PORT" && -z "$ALLOW_PEER" && -z "$NOMINAL_MBPS" &&
      "$DEEP" == false && "$SAVE_BASELINE" == false &&
      "$COMPARE_BASELINE" == false ]] ||
      die 'Benchmark and server options cannot be used with --history.'
    if ! is_uint "$HISTORY_LIMIT" || (( 10#$HISTORY_LIMIT < 1 ||
      10#$HISTORY_LIMIT > MAX_HISTORY_LIMIT )); then
      die "--limit must be between 1 and $MAX_HISTORY_LIMIT."
    fi
  else
    validate_peer "$PEER" || die 'A valid peer host or IP is required.'
    [[ -z "$ALLOW_PEER" ]] || die '--allow-peer is a server option.'
    [[ -n "$PORT" ]] || die 'Specify the random server port with --port PORT.'
    [[ "$HISTORY_LIMIT_SET" == false ]] || die '--limit is a history option.'
  fi

  if [[ -n "$PORT" ]]; then
    validate_port "$PORT" || die "Port must be between $MIN_PORT and $MAX_PORT."
  fi
  if [[ -n "$NOMINAL_MBPS" ]]; then
    is_positive_number "$NOMINAL_MBPS" || die 'Bandwidth must be a positive Mbps value.'
    number_not_greater_than_100000 "$NOMINAL_MBPS" ||
      die 'Bandwidth is unreasonably large.'
  fi
}

read_answer() {
  local prompt=$1
  local answer

  if [[ -r /dev/tty ]]; then
    printf '%s' "$prompt" >/dev/tty
    IFS= read -r answer </dev/tty || return 1
  else
    printf '%s' "$prompt" >&2
    IFS= read -r answer || return 1
  fi
  printf '%s' "$answer"
}

choose_bandwidth() {
  local choice
  local custom

  [[ -z "$NOMINAL_MBPS" ]] || return 0
  cat >&2 <<'EOF'
Nominal bandwidth:

1) 100 Mbps
2) 200 Mbps
3) 500 Mbps
4) 1 Gbps
5) 2 Gbps
6) Custom
EOF
  choice=$(read_answer 'Selection: ') || die 'Unable to read bandwidth selection.'
  case "$choice" in
    1) NOMINAL_MBPS=100 ;;
    2) NOMINAL_MBPS=200 ;;
    3) NOMINAL_MBPS=500 ;;
    4) NOMINAL_MBPS=1000 ;;
    5) NOMINAL_MBPS=2000 ;;
    6)
      custom=$(read_answer 'Custom bandwidth (Mbps): ') ||
        die 'Unable to read custom bandwidth.'
      is_positive_number "$custom" || die 'Custom bandwidth must be positive Mbps.'
      NOMINAL_MBPS=$custom
      ;;
    *) die 'Invalid bandwidth selection.' ;;
  esac
}

random_port() {
  local candidate
  local span=$((MAX_PORT - MIN_PORT + 1))

  for _ in {1..30}; do
    candidate=$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | awk '{$1=$1; print}')
    [[ -n "$candidate" ]] || candidate=$RANDOM
    candidate=$((candidate % span + MIN_PORT))
    if command_exists ss && ss -H -lntu 2>/dev/null |
      awk '{print $5}' | grep -Eq "(^|:)$candidate$"; then
      continue
    fi
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

run_ufw() {
  if (( ${#UFW_COMMAND[@]} > 0 )); then
    "${UFW_COMMAND[@]}" "$@"
  else
    ufw "$@"
  fi
}

cleanup_firewall() {
  local number
  local protocol
  local status_output
  local cleanup_failed=false
  local -a rule_numbers=()

  [[ "$FIREWALL_RULE_ADDED" == true ]] || return 0
  status_output=$(LC_ALL=C run_ufw status numbered 2>/dev/null || true)
  mapfile -t rule_numbers < <(printf '%s\n' "$status_output" | awk \
    -v marker="$FIREWALL_COMMENT" 'index($0, "# " marker) {
      number=$0; sub(/^[^[]*\[[[:space:]]*/, "", number);
      sub(/\].*$/, "", number); gsub(/[^0-9]/, "", number);
      if (number != "") print number
    }' | sort -rn)
  for number in "${rule_numbers[@]}"; do
    if ! run_ufw --force delete "$number" >/dev/null 2>&1; then
      warn "Could not remove temporary UFW rule $number; inspect ufw status numbered."
      cleanup_failed=true
    fi
  done
  if (( ${#rule_numbers[@]} == 0 )); then
    for protocol in tcp udp; do
      if [[ -n "$ALLOW_PEER" ]]; then
        if ! run_ufw --force delete allow from "$ALLOW_PEER" to any port \
          "$PORT" proto "$protocol" comment "$FIREWALL_COMMENT" \
          >/dev/null 2>&1; then
          cleanup_failed=true
        fi
      else
        if ! run_ufw --force delete allow to any port "$PORT" proto "$protocol" \
          comment "$FIREWALL_COMMENT" >/dev/null 2>&1; then
          cleanup_failed=true
        fi
      fi
    done
  fi
  status_output=$(LC_ALL=C run_ufw status numbered 2>/dev/null || true)
  if printf '%s\n' "$status_output" | grep -Fq "# $FIREWALL_COMMENT"; then
    warn 'Temporary UFW rule cleanup could not be verified; inspect ufw status numbered.'
    return 1
  fi
  if [[ "$cleanup_failed" == true ]]; then
    warn 'One or more temporary UFW rule deletions failed.'
    return 1
  fi
  FIREWALL_RULE_ADDED=false
}

cleanup() {
  local status=$?

  if [[ "$BASHPID" != "$MAIN_BASHPID" ]]; then
    return "$status"
  fi
  trap - EXIT INT TERM HUP
  if [[ -n "$ACTIVE_PING_PID" ]]; then
    kill "$ACTIVE_PING_PID" 2>/dev/null || true
    wait "$ACTIVE_PING_PID" 2>/dev/null || true
    ACTIVE_PING_PID=''
  fi
  if [[ -n "$ACTIVE_IPERF_PID" ]]; then
    kill "$ACTIVE_IPERF_PID" 2>/dev/null || true
    wait "$ACTIVE_IPERF_PID" 2>/dev/null || true
    ACTIVE_IPERF_PID=''
  fi
  cleanup_firewall ||
    warn 'Automatic UFW cleanup was incomplete; inspect the unique benchmark comment.'
  if [[ -n "$TEMP_DIR" && "$TEMP_DIR" == /tmp/* && -d "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
  exit "$status"
}

signal_exit() {
  if [[ "$MODE" == 'server' ]]; then
    printf '\nServer stopped: manual signal; listener and firewall cleanup are automatic.\n' >&2
  fi
  exit 130
}

trap cleanup EXIT
trap signal_exit INT TERM HUP

setup_firewall() {
  local ufw_status
  local verified_count
  local protocol

  FIREWALL_STATUS='unchanged (UFW is not active)'
  UFW_COMMAND=()
  if ! command_exists ufw; then
    [[ -z "$ALLOW_PEER" ]] ||
      die '--allow-peer requested but peer-only firewall enforcement is unavailable (UFW is not installed).'
    warn 'Firewall unchanged: UFW is not installed.'
    return 0
  fi
  if is_root; then
    UFW_COMMAND=(ufw)
  elif command_exists sudo && sudo -n ufw status >/dev/null 2>&1; then
    UFW_COMMAND=(sudo -n ufw)
  else
    [[ -z "$ALLOW_PEER" ]] ||
      die '--allow-peer requested but peer-only firewall enforcement is unavailable (cannot inspect UFW).'
    FIREWALL_STATUS='unchanged (UFW status unavailable)'
    warn 'Firewall unchanged: UFW is installed but cannot be inspected without privilege.'
    return 0
  fi
  ufw_status=$(LC_ALL=C "${UFW_COMMAND[@]}" status 2>/dev/null | sed -n '1p')
  if [[ "$ufw_status" != 'Status: active' ]]; then
    [[ -z "$ALLOW_PEER" ]] ||
      die '--allow-peer requested but peer-only firewall enforcement is unavailable (UFW is not active).'
    warn 'Firewall unchanged: UFW is not active.'
    return 0
  fi
  FIREWALL_COMMENT="protocol-benchmark-${MAIN_BASHPID}-${PORT}-${RANDOM}"
  FIREWALL_RULE_ADDED=true
  for protocol in tcp udp; do
    if [[ -n "$ALLOW_PEER" ]]; then
      if ! "${UFW_COMMAND[@]}" insert 1 allow from "$ALLOW_PEER" to any \
        port "$PORT" proto "$protocol" comment "$FIREWALL_COMMENT" >/dev/null; then
        cleanup_firewall || true
        die "Unable to add the temporary $protocol UFW rule."
      fi
    elif ! "${UFW_COMMAND[@]}" insert 1 allow to any port "$PORT" \
      proto "$protocol" comment "$FIREWALL_COMMENT" >/dev/null; then
      cleanup_firewall || true
      die "Unable to add the temporary $protocol UFW rule."
    fi
  done
  verified_count=$(LC_ALL=C "${UFW_COMMAND[@]}" status numbered 2>/dev/null | awk \
    -v marker="$FIREWALL_COMMENT" 'index($0, "# " marker) {count++} END {print count+0}')
  if (( verified_count != 2 )); then
    cleanup_firewall || true
    die 'Temporary UFW rules could not be verified; rules were rolled back.'
  fi
  if [[ -n "$ALLOW_PEER" ]]; then
    FIREWALL_STATUS="temporary TCP/UDP allow from $ALLOW_PEER"
  else
    FIREWALL_STATUS='temporary TCP/UDP allow added'
  fi
}

run_server() {
  local consecutive_errors=0
  local deadline
  local now
  local wait_seconds
  local status
  local server_log

  [[ -n "$PORT" ]] || PORT=$(random_port) || die 'Unable to choose a free high port.'
  TEMP_DIR=$(mktemp -d /tmp/protocol-benchmark-server.XXXXXXXX)
  server_log="$TEMP_DIR/iperf3-server.json"
  setup_firewall
  printf '\nProtocol Benchmark temporary server\n'
  printf '%s\n' '-----------------------------------'
  printf 'Port:         %s (TCP and UDP)\n' "$PORT"
  printf 'Firewall:     %s\n' "$FIREWALL_STATUS"
  printf 'First wait:   %s seconds\n' "$SERVER_WAIT"
  printf 'Auto-close:   %s seconds after the last test\n' "$SERVER_SESSION_IDLE"
  printf '\nClient command:\n'
  printf 'bash <(curl -fsSL https://raw.githubusercontent.com/404-git-404/404notfound/main/protocol-benchmark.sh) SERVER_IP --port %s\n' "$PORT"
  printf '\nStop: Ctrl+C (cleanup is automatic)\n\n'

  now=$(date +%s)
  deadline=$((now + SERVER_WAIT))
  while true; do
    now=$(date +%s)
    if (( now >= deadline )); then
      if (( SERVER_TESTS == 0 )); then
        printf 'Server closed: idle timeout before the first client session; no listener retained.\n'
      else
        printf 'Server closed: idle timeout after the last test (%ss, %d completed); no listener retained.\n' \
          "$SERVER_SESSION_IDLE" "$SERVER_TESTS"
      fi
      return 0
    fi
    wait_seconds=$((deadline - now))
    timeout --foreground "$wait_seconds" iperf3 -s -1 -J -p "$PORT" \
      >"$server_log" 2>&1 &
    ACTIVE_IPERF_PID=$!
    if wait "$ACTIVE_IPERF_PID"; then
      status=0
    else
      status=$?
    fi
    ACTIVE_IPERF_PID=''
    if (( status == 124 )); then
      if (( SERVER_TESTS == 0 )); then
        printf 'Server closed: idle timeout before the first client session; no listener retained.\n'
      else
        printf 'Server closed: idle timeout after the last test (%ss, %d completed); no listener retained.\n' \
          "$SERVER_SESSION_IDLE" "$SERVER_TESTS"
      fi
      return 0
    fi
    if (( status == 0 )); then
      (( SERVER_TESTS += 1 ))
      consecutive_errors=0
      now=$(date +%s)
      deadline=$((now + SERVER_SESSION_IDLE))
      printf 'Completed test %d; waiting %ss for the next stage.\n' \
        "$SERVER_TESTS" "$SERVER_SESSION_IDLE"
      continue
    fi
    if (( status == 130 || status == 143 )); then
      printf 'Server stopped: manual signal; listener and firewall cleanup are automatic.\n' >&2
      return "$status"
    fi
    (( consecutive_errors += 1 ))
    warn "iperf3 server session exited with status $status; retrying listener ($consecutive_errors/$SERVER_ERROR_LIMIT)."
    if (( consecutive_errors >= SERVER_ERROR_LIMIT )); then
      printf 'Server stopped: unrecoverable iperf3 server failure after %d consecutive error(s); cleanup is automatic.\n' \
        "$consecutive_errors" >&2
      return 1
    fi
    sleep 1
  done
}

float_max() {
  awk -v a="$1" -v b="$2" 'BEGIN { print (a > b ? a : b) }'
}

read_cpu_sample() {
  awk '/^cpu / {
    idle=$5+$6; total=0;
    for (i=2; i<=NF; i++) total+=$i;
    printf "%.0f %.0f\n", total, idle;
    exit
  }' /proc/stat
}

cpu_between() {
  local before_total=$1
  local before_idle=$2
  local after_total=$3
  local after_idle=$4
  awk -v bt="$before_total" -v bi="$before_idle" -v at="$after_total" -v ai="$after_idle" '
    BEGIN {
      delta=at-bt; idle=ai-bi;
      if (delta <= 0) print 0;
      else printf "%.2f", 100 * (delta-idle) / delta;
    }'
}

parse_ping_file() {
  local file=$1
  PING_LOSS=$(awk '
    /packet loss/ {
      for (i=1; i<=NF; i++) if ($i ~ /%/) {
        gsub(/%/, "", $i); print $i; exit
      }
    }' "$file")
  PING_AVG=$(awk -F/ '/^(rtt|round-trip)/ {print $5; exit}' "$file")
  PING_VARIATION=$(awk -F/ '/^(rtt|round-trip)/ {
    value=$7; sub(/[[:space:]].*/, "", value); print value; exit
  }' "$file")
  PING_LOSS=${PING_LOSS:-100}
}

collect_idle_baseline() {
  local ping_file="$TEMP_DIR/idle-ping.txt"
  local status

  printf 'Collecting idle RTT baseline...\n'
  set +e
  LC_ALL=C ping -n -c 6 -i 0.2 -W 2 "$PEER" >"$ping_file" 2>&1
  status=$?
  set -e
  parse_ping_file "$ping_file"
  IDLE_LOSS=$PING_LOSS
  IDLE_RTT=$PING_AVG
  IDLE_VARIATION=$PING_VARIATION
  if (( status != 0 )) || [[ -z "$IDLE_RTT" ]]; then
    warn 'Idle ping was incomplete; confidence will be reduced.'
  fi
}

rate_for_percent() {
  awk -v nominal="$NOMINAL_MBPS" -v percent="$1" \
    'BEGIN { printf "%.3f", nominal * percent / 100 }'
}

planned_bytes() {
  local rate_mbps=$1
  local duration=$2
  awk -v rate="$rate_mbps" -v seconds="$duration" \
    'BEGIN { printf "%.0f", rate * 1000000 * seconds / 8 * 1.10 }'
}

reserve_budget() {
  local bytes=$1
  if (( TRAFFIC_ACCOUNTED_BYTES + TRAFFIC_RESERVED_BYTES + bytes > BUDGET_BYTES )); then
    BUDGET_LIMITED=true
    return "$TEST_RESULT_BUDGET_DENIED"
  fi
  (( TRAFFIC_RESERVED_BYTES += bytes ))
}

release_budget_reservation() {
  local bytes=$1
  if (( bytes >= TRAFFIC_RESERVED_BYTES )); then
    TRAFFIC_RESERVED_BYTES=0
  else
    (( TRAFFIC_RESERVED_BYTES -= bytes ))
  fi
}

sanitize_failure_text() {
  local value=$1

  [[ -z "$TEMP_DIR" ]] || value=${value//"$TEMP_DIR"/<temporary>}
  value=$(printf '%s' "$value" | LC_ALL=C sed -E \
    $'s/\033\[[0-9;?]*[ -\/]*[@-~]//g; s#/tmp/[^[:space:]]+#<temporary>#g' |
    LC_ALL=C tr -cd '[:print:]\t')
  value=${value//$'\t'/ }
  while [[ "$value" == *'  '* ]]; do value=${value//'  '/' '}; done
  value=${value# }
  value=${value% }
  printf '%.180s' "$value"
}

extract_failure_reason() {
  local json_file=$1
  local status=$2
  local reason=''
  local line

  if jq -e . "$json_file" >/dev/null 2>&1; then
    reason=$(jq -r '.error // empty' "$json_file" 2>/dev/null || true)
  fi
  if [[ -z "$reason" && -r "$json_file.stderr" ]]; then
    while IFS= read -r line; do
      line=$(sanitize_failure_text "$line")
      if [[ -n "$line" ]]; then
        reason=$line
        break
      fi
    done <"$json_file.stderr"
  fi
  reason=$(sanitize_failure_text "$reason")
  if [[ -z "$reason" ]]; then
    if ! jq -e . "$json_file" >/dev/null 2>&1; then
      reason="invalid iperf3 JSON (exit $status)"
    else
      reason="iperf3 exited with status $status"
    fi
  fi
  printf '%s\n' "$reason"
}

failure_bytes_from_json() {
  local json_file=$1
  local bytes

  bytes=$(jq -r '
    .end.sum.bytes // .end.sum_received.bytes // .end.sum_sent.bytes // 0
  ' "$json_file" 2>/dev/null || printf '0')
  bytes=${bytes%.*}
  is_uint "$bytes" || bytes=0
  printf '%s\n' "$bytes"
}

failure_has_no_transfer() {
  local reason=${1,,}
  [[ "$reason" == *'unable to connect'* ||
    "$reason" == *'connection refused'* ||
    "$reason" == *'connection timed out'* ||
    "$reason" == *'timed out'* ||
    "$reason" == *'no route to host'* ||
    "$reason" == *'network is unreachable'* ||
    "$reason" == *'name or service not known'* ||
    "$reason" == *'temporary failure in name resolution'* ]]
}

failure_indicates_server_unavailable() {
  local reason=${1,,}

  failure_has_no_transfer "$reason" ||
    [[ "$reason" == *'unable to read from stream socket'* ||
      "$reason" == *'unable to receive control message'* ||
      "$reason" == *'control socket has closed unexpectedly'* ]]
}

benchmark_server_became_unavailable() {
  local protocol direction percent status reason
  local tcp_connection_failure=false
  local udp_connection_failure=false

  [[ -n "$RESULT_FILE" && -s "$RESULT_FILE" &&
    -n "$FAILURE_FILE" && -s "$FAILURE_FILE" ]] || return 1
  while IFS=$'\t' read -r protocol direction percent status reason; do
    failure_indicates_server_unavailable "$reason" || continue
    case "$protocol" in
      TCP) tcp_connection_failure=true ;;
      UDP) udp_connection_failure=true ;;
    esac
  done <"$FAILURE_FILE"
  [[ "$tcp_connection_failure" == true && "$udp_connection_failure" == true ]]
}

account_failed_test() {
  local reserve=$1
  local json_file=$2
  local reason=$3
  local bytes

  release_budget_reservation "$reserve"
  bytes=$(failure_bytes_from_json "$json_file")
  if (( bytes > 0 )); then
    (( TRAFFIC_ACTUAL_BYTES += bytes ))
    (( TRAFFIC_ACCOUNTED_BYTES += bytes ))
  elif ! failure_has_no_transfer "$reason"; then
    (( TRAFFIC_ACCOUNTED_BYTES += reserve ))
  fi
}

append_label() {
  local label=$1
  [[ ",$LABELS," == *",$label,"* ]] || LABELS=${LABELS:+$LABELS,}$label
}

record_failure() {
  local protocol=$1
  local direction=${2:-UNKNOWN}
  local percent=${3:-0}
  local status=${4:-1}
  local reason=${5:-'iperf3 execution failed'}

  (( TEST_FAILURES += 1 ))
  if [[ "$protocol" == 'TCP' ]]; then
    (( TCP_FAILURES += 1 ))
  else
    (( UDP_FAILURES += 1 ))
  fi
  if [[ -n "$FAILURE_FILE" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$protocol" "$direction" \
      "$percent" "$status" "$reason" >>"$FAILURE_FILE"
  fi
}

run_controlled_test() {
  local protocol=$1
  local direction=$2
  local percent=$3
  local streams=$4
  local rate_mbps
  local reserve
  local json_file
  local ping_file
  local status
  local before_total
  local before_idle
  local after_total
  local after_idle
  local local_cpu
  local remote_cpu
  local current_load_average
  local achieved
  local ratio
  local retrans=0
  local loss=0
  local jitter=0
  local bytes
  local load_rtt=''
  local load_increase=0
  local error
  local json_valid=false
  local -a command=(iperf3 -c "$PEER" -p "$PORT" -J -t "$DURATION")

  rate_mbps=$(rate_for_percent "$percent")
  reserve=$(planned_bytes "$rate_mbps" "$DURATION")
  reserve_budget "$reserve" || return "$TEST_RESULT_BUDGET_DENIED"
  json_file="$TEMP_DIR/${protocol,,}-${direction,,}-${percent}-${streams}.json"
  ping_file="$TEMP_DIR/${protocol,,}-${direction,,}-${percent}-${streams}.ping"
  command+=(-b "${rate_mbps}M" -P "$streams")
  [[ "$protocol" == 'UDP' ]] && command+=(-u)
  [[ "$direction" == 'B_TO_A' ]] && command+=(-R)

  printf '  %-3s %-6s %5s%%  %7s Mbps  P=%s ... ' \
    "$protocol" "${direction//_TO_/->}" "$percent" "$rate_mbps" "$streams"
  read -r before_total before_idle < <(read_cpu_sample)
  LC_ALL=C ping -n -i 0.2 -w "$((DURATION + 1))" "$PEER" \
    >"$ping_file" 2>&1 &
  ACTIVE_PING_PID=$!
  set +e
  LC_ALL=C "${command[@]}" >"$json_file" 2>"$json_file.stderr" &
  ACTIVE_IPERF_PID=$!
  wait "$ACTIVE_IPERF_PID"
  status=$?
  ACTIVE_IPERF_PID=''
  wait "$ACTIVE_PING_PID" 2>/dev/null
  ACTIVE_PING_PID=''
  set -e
  read -r after_total after_idle < <(read_cpu_sample)
  local_cpu=$(cpu_between "$before_total" "$before_idle" "$after_total" "$after_idle")

  if jq -e . "$json_file" >/dev/null 2>&1; then
    json_valid=true
  fi
  if [[ "$json_valid" == true ]]; then
    error=$(jq -r '.error // empty' "$json_file")
  else
    error=''
  fi
  if (( status != 0 )) || [[ "$json_valid" == false || -n "$error" ]]; then
    error=$(extract_failure_reason "$json_file" "$status")
    printf 'FAILED: %s\n' "$error"
    account_failed_test "$reserve" "$json_file" "$error"
    record_failure "$protocol" "$direction" "$percent" "$status" "$error"
    sleep "$COOLDOWN"
    return "$TEST_RESULT_FAILED"
  fi

  if [[ "$protocol" == 'TCP' ]]; then
    achieved=$(jq -r '.end.sum_received.bits_per_second // .end.sum_sent.bits_per_second // 0' "$json_file")
    retrans=$(jq -r '.end.sum_sent.retransmits // 0' "$json_file")
    bytes=$(jq -r '.end.sum_received.bytes // .end.sum_sent.bytes // 0' "$json_file")
  else
    achieved=$(jq -r '.end.sum.bits_per_second // .end.sum_received.bits_per_second // 0' "$json_file")
    loss=$(jq -r '.end.sum.lost_percent // .end.sum_received.lost_percent // 100' "$json_file")
    jitter=$(jq -r '.end.sum.jitter_ms // .end.sum_received.jitter_ms // 0' "$json_file")
    bytes=$(jq -r '.end.sum.bytes // .end.sum_received.bytes // 0' "$json_file")
  fi
  achieved=$(awk -v value="$achieved" 'BEGIN { printf "%.3f", value / 1000000 }')
  ratio=$(awk -v achieved="$achieved" -v offered="$rate_mbps" '
    BEGIN { if (offered <= 0) print 0; else printf "%.4f", achieved / offered }')
  remote_cpu=$(jq -r '.end.cpu_utilization_percent.remote_total // 0' "$json_file")
  current_load_average=$(awk '{print $1}' /proc/loadavg)
  MAX_LOAD_AVERAGE=$(float_max "$MAX_LOAD_AVERAGE" "$current_load_average")
  parse_ping_file "$ping_file"
  load_rtt=$PING_AVG
  if [[ -n "$load_rtt" && -n "$IDLE_RTT" ]]; then
    load_increase=$(awk -v loaded_rtt="$load_rtt" -v idle="$IDLE_RTT" \
      'BEGIN { value=loaded_rtt-idle; printf "%.3f", (value > 0 ? value : 0) }')
  fi
  MAX_LOAD_INCREASE=$(float_max "$MAX_LOAD_INCREASE" "$load_increase")
  MAX_CPU=$(float_max "$MAX_CPU" "$(float_max "$local_cpu" "$remote_cpu")")
  if awk -v cpu="$local_cpu" -v remote="$remote_cpu" \
    'BEGIN { exit !(cpu >= 90 || remote >= 90) }'; then
    CPU_LIMITED=true
  fi
  bytes=${bytes%.*}
  is_uint "$bytes" || bytes=0
  release_budget_reservation "$reserve"
  (( TRAFFIC_ACTUAL_BYTES += bytes ))
  (( TRAFFIC_ACCOUNTED_BYTES += bytes ))
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$protocol" "$direction" "$percent" "$streams" "$rate_mbps" \
    "$achieved" "$ratio" "$retrans" "$loss" "$jitter" \
    "$load_increase" "$bytes" >>"$RESULT_FILE"
  if [[ "$protocol" == 'TCP' ]]; then
    printf '%s Mbps, retrans=%s, RTT +%sms\n' "$achieved" "$retrans" "$load_increase"
  else
    printf '%s Mbps, loss=%s%%, jitter=%sms, RTT +%sms\n' \
      "$achieved" "$loss" "$jitter" "$load_increase"
  fi
  sleep "$COOLDOWN"
  return 0
}

protocol_count() {
  awk -F '\t' -v protocol="$1" '$1 == protocol {count++} END {print count+0}' "$RESULT_FILE"
}

protocol_is_evaluable() {
  awk -F '\t' -v protocol="$1" '
    $1 == protocol && $2 == "A_TO_B" {forward=1}
    $1 == protocol && $2 == "B_TO_A" {reverse=1}
    END {exit !(forward && reverse)}
  ' "$RESULT_FILE"
}

tcp_is_severe() {
  awk -F '\t' '$1 == "TCP" {
    count++; if ($7 < min || count == 1) min=$7;
    if ($11 > max_rtt) max_rtt=$11;
    retrans+=$8; bytes+=$12;
  } END {
    density=(bytes > 0 ? retrans*100000000/bytes : 0);
    exit !(count >= 2 && (min < 0.50 || max_rtt >= 150 || density >= 1000));
  }' "$RESULT_FILE"
}

udp_is_severe() {
  awk -F '\t' '$1 == "UDP" {
    count++; if ($7 < min || count == 1) min=$7;
    if ($9 > max_loss) max_loss=$9;
    if ($10 > max_jitter) max_jitter=$10;
    if ($11 > max_rtt) max_rtt=$11;
  } END {
    exit !(count >= 2 && (min < 0.70 || max_loss >= 2 ||
      max_jitter >= 30 || max_rtt >= 120));
  }' "$RESULT_FILE"
}

tcp_is_healthy() {
  awk -F '\t' '$1 == "TCP" {
    count++; if ($7 < min || count == 1) min=$7;
    if ($11 > max_rtt) max_rtt=$11;
    retrans+=$8; bytes+=$12;
  } END {
    density=(bytes > 0 ? retrans*100000000/bytes : 9999);
    exit !(count >= 4 && min >= 0.85 && max_rtt <= 50 && density <= 100);
  }' "$RESULT_FILE"
}

udp_is_healthy() {
  awk -F '\t' '$1 == "UDP" {
    count++; if ($7 < min || count == 1) min=$7;
    if ($9 > max_loss) max_loss=$9;
    if ($10 > max_jitter) max_jitter=$10;
    if ($11 > max_rtt) max_rtt=$11;
  } END {
    exit !(count >= 4 && min >= 0.85 && max_loss <= 0.20 &&
      max_jitter <= 10 && max_rtt <= 50);
  }' "$RESULT_FILE"
}

run_direction_pair() {
  local protocol=$1
  local percent=$2
  local streams=${3:-1}
  local forward_result=0
  local reverse_result=0

  if run_controlled_test "$protocol" 'A_TO_B' "$percent" "$streams"; then
    forward_result=$TEST_RESULT_OK
  else
    forward_result=$?
  fi
  if (( forward_result == TEST_RESULT_BUDGET_DENIED )); then
    return "$TEST_RESULT_BUDGET_DENIED"
  fi
  if run_controlled_test "$protocol" 'B_TO_A' "$percent" "$streams"; then
    reverse_result=$TEST_RESULT_OK
  else
    reverse_result=$?
  fi
  (( reverse_result != TEST_RESULT_BUDGET_DENIED )) ||
    return "$TEST_RESULT_BUDGET_DENIED"
  if (( forward_result != TEST_RESULT_OK || reverse_result != TEST_RESULT_OK )); then
    return "$TEST_RESULT_FAILED"
  fi
  return "$TEST_RESULT_OK"
}

should_try_two_streams() {
  [[ "$CPU_LIMITED" == false ]] || return 1
  awk -F '\t' '$1 == "TCP" && $4 == 1 {
    count++; ratio+=$7
  } END { exit !(count >= 2 && ratio/count < 0.75) }' "$RESULT_FILE"
}

run_adaptive_matrix() {
  local percent
  local pair_result
  local tcp_stopped=false
  local udp_stopped=false
  local tcp_healthy=false
  local udp_healthy=false
  local tcp_execution_failed=false
  local udp_execution_failed=false
  local budget_denied=false
  local -a levels=(5 10 20)

  TCP_ADAPTIVE_STOP=false
  UDP_ADAPTIVE_STOP=false
  TCP_STOP_STAGE=0
  UDP_STOP_STAGE=0
  TCP_HIGHEST_STAGE=0
  UDP_HIGHEST_STAGE=0

  if [[ "$DEEP" == true ]]; then
    levels=(5 10 20 35)
  fi
  printf '\nControlled tests (%s, hard ceiling %s%%, budget %s MB)\n' \
    "$([[ "$DEEP" == true ]] && printf 'DEEP' || printf 'LOW-IMPACT')" \
    "$MAX_PERCENT" "$BUDGET_MB"
  printf '%s\n' '----------------------------------------------------------------'
  for percent in "${levels[@]}"; do
    (( percent <= MAX_PERCENT )) || break
    if [[ "$tcp_stopped" == false &&
      ( "$tcp_healthy" == false || "$DEEP" == true ) ]]; then
      if run_direction_pair 'TCP' "$percent"; then
        pair_result=$TEST_RESULT_OK
      else
        pair_result=$?
      fi
      if (( pair_result == TEST_RESULT_BUDGET_DENIED )); then
        budget_denied=true
      elif (( pair_result == TEST_RESULT_FAILED )); then
        tcp_stopped=true
        tcp_execution_failed=true
        if (( percent < MAX_PERCENT )); then
          TCP_ADAPTIVE_STOP=true
          TCP_STOP_STAGE=$percent
        fi
      elif tcp_is_severe; then
        tcp_stopped=true
        append_label 'TCP-DEGRADED'
        if (( percent < MAX_PERCENT )); then
          TCP_ADAPTIVE_STOP=true
          TCP_STOP_STAGE=$percent
        fi
      elif tcp_is_healthy; then
        tcp_healthy=true
        if [[ "$DEEP" == false ]] && (( percent < MAX_PERCENT )); then
          TCP_ADAPTIVE_STOP=true
          TCP_STOP_STAGE=$percent
        fi
      fi
    fi
    [[ "$budget_denied" == false ]] || break
    if [[ "$udp_stopped" == false &&
      ( "$udp_healthy" == false || "$DEEP" == true ) ]]; then
      if run_direction_pair 'UDP' "$percent"; then
        pair_result=$TEST_RESULT_OK
      else
        pair_result=$?
      fi
      if (( pair_result == TEST_RESULT_BUDGET_DENIED )); then
        budget_denied=true
      elif (( pair_result == TEST_RESULT_FAILED )); then
        udp_stopped=true
        udp_execution_failed=true
        if (( percent < MAX_PERCENT )); then
          UDP_ADAPTIVE_STOP=true
          UDP_STOP_STAGE=$percent
        fi
      elif udp_is_severe; then
        udp_stopped=true
        append_label 'UDP-DEGRADED'
        if (( percent < MAX_PERCENT )); then
          UDP_ADAPTIVE_STOP=true
          UDP_STOP_STAGE=$percent
        fi
      elif udp_is_healthy; then
        udp_healthy=true
        if [[ "$DEEP" == false ]] && (( percent < MAX_PERCENT )); then
          UDP_ADAPTIVE_STOP=true
          UDP_STOP_STAGE=$percent
        fi
      fi
    fi
    [[ "$budget_denied" == false ]] || break

    if (( percent == 5 )) && ! protocol_is_evaluable TCP &&
      ! protocol_is_evaluable UDP; then
      printf '  Active benchmark stopped: no valid bidirectional 5%% samples.\n'
      break
    fi

    if [[ "$DEEP" == false && "$tcp_healthy" == true &&
      "$udp_healthy" == true ]]; then
      EARLY_STOP=true
      printf '  Early Stop: %s%% data is sufficient for high-confidence classification.\n' \
        "$percent"
      break
    fi
    if [[
      ( "$tcp_healthy" == true || "$tcp_stopped" == true ) &&
      ( "$udp_healthy" == true || "$udp_stopped" == true ) &&
      ( "$tcp_execution_failed" == true || "$udp_execution_failed" == true )
    ]]; then
      EARLY_STOP=true
      printf '  Early Stop: execution failure prevents further useful escalation.\n'
      break
    fi
    if [[ "$DEEP" == false &&
      ( "$tcp_healthy" == true || "$tcp_stopped" == true ) &&
      ( "$udp_healthy" == true || "$udp_stopped" == true ) ]]; then
      EARLY_STOP=true
      printf '  Early Stop: available data resolves both protocol classifications.\n'
      break
    fi
    if [[ "$udp_stopped" == true ]]; then
      printf '  UDP escalation stopped: degradation threshold reached.\n'
    fi
  done

  if [[ "$tcp_execution_failed" == false ]] && protocol_is_evaluable TCP &&
    should_try_two_streams; then
    printf '  Diagnostic: one bounded 2-stream TCP confirmation.\n'
    run_controlled_test 'TCP' 'A_TO_B' 10 2 || true
  fi
  TCP_HIGHEST_STAGE=$(awk -F '\t' '$1 == "TCP" && $3 > max {max=$3}
    END {print max+0}' "$RESULT_FILE")
  UDP_HIGHEST_STAGE=$(awk -F '\t' '$1 == "UDP" && $3 > max {max=$3}
    END {print max+0}' "$RESULT_FILE")
}

calculate_tcp_retransmission_metrics() {
  awk -F '\t' \
    -v min_bytes="$TCP_RETRANS_MIN_DIRECTION_BYTES" \
    -v noise_floor="$TCP_RETRANS_NOISE_FLOOR" \
    -v noise_max_penalty="$TCP_RETRANS_NOISE_MAX_PENALTY" \
    -v penalty_per_doubling="$TCP_RETRANS_PENALTY_PER_DOUBLING" \
    -v max_penalty="$TCP_RETRANS_MAX_PENALTY" '
    $1 == "TCP" {
      retrans[$2]+=$8;
      bytes[$2]+=$12;
    }
    function density(direction, effective_bytes) {
      if (retrans[direction] <= 0) return 0;
      effective_bytes=bytes[direction];
      if (effective_bytes < min_bytes) effective_bytes=min_bytes;
      return retrans[direction]*100000000/effective_bytes;
    }
    END {
      forward=density("A_TO_B");
      reverse=density("B_TO_A");
      worst_density=(forward > reverse ? forward : reverse);
      if (forward > reverse) worst_direction="A_TO_B";
      else if (reverse > forward) worst_direction="B_TO_A";
      else if (worst_density > 0) worst_direction="BOTH";
      else worst_direction="NONE";

      # Noise-scale evidence is worth at most two points. Above that floor,
      # each density doubling adds a fixed penalty, preserving high-severity
      # separation without letting one retransmission dominate a tiny sample.
      if (worst_density <= noise_floor)
        penalty=noise_max_penalty*worst_density/noise_floor;
      else
        penalty=noise_max_penalty+penalty_per_doubling*log(worst_density/noise_floor)/log(2);
      if (penalty > max_penalty) penalty=max_penalty;
      printf "%.2f\t%.2f\t%s\t%.2f\t%.0f\t%.0f\t%.0f\t%.0f\n",
        forward, reverse, worst_direction, penalty,
        bytes["A_TO_B"]+0, bytes["B_TO_A"]+0,
        retrans["A_TO_B"]+0, retrans["B_TO_A"]+0;
    }' "$RESULT_FILE"
}

calculate_protocol_score() {
  local protocol=$1
  local failures=$2
  local tcp_retrans_penalty=${3:-}
  local tcp_retrans_metrics

  if [[ "$protocol" == 'TCP' && -z "$tcp_retrans_penalty" ]]; then
    tcp_retrans_metrics=$(calculate_tcp_retransmission_metrics)
    IFS=$'\t' read -r _ _ _ tcp_retrans_penalty _ <<<"$tcp_retrans_metrics"
  fi
  awk -F '\t' -v protocol="$protocol" -v failures="$failures" \
    -v tcp_retrans_penalty="${tcp_retrans_penalty:-0}" '
    function min(a,b) { return a < b ? a : b }
    $1 == protocol {
      count++; ratio+=$7; load_sum+=$11;
      if ($11 > max_load) max_load=$11;
      if ($2 == "A_TO_B") { a_rate+=$6; a_count++ }
      else { b_rate+=$6; b_count++ }
      if (protocol != "TCP") {
        loss+=$9; if ($9 > max_loss) max_loss=$9; jitter+=$10
      }
    }
    END {
      if (count == 0) { print 0; exit }
      avg_ratio=ratio/count;
      ratio_penalty=(avg_ratio < .95 ? min(35, (.95-avg_ratio)*75) : 0);
      load_penalty=(max_load > 15 ? min(22, (max_load-15)/3) : 0);
      asymmetry=1;
      if (a_count && b_count) {
        a=a_rate/a_count; b=b_rate/b_count;
        if (a > 0 && b > 0) asymmetry=(a < b ? a/b : b/a);
      }
      asym_penalty=(asymmetry < .75 ? min(15, (.75-asymmetry)*35) : 0);
      if (protocol == "TCP") {
        quality_penalty=tcp_retrans_penalty;
      } else {
        avg_loss=loss/count; avg_jitter=jitter/count;
        quality_penalty=min(40, avg_loss*12)+min(20, max_loss*4)+(avg_jitter > 2 ? min(15, (avg_jitter-2)/2) : 0);
      }
      score=100-ratio_penalty-load_penalty-asym_penalty-quality_penalty-failures*10;
      if (score < 0) score=0; if (score > 100) score=100;
      printf "%.0f", score;
    }' "$RESULT_FILE"
}

detect_asymmetry() {
  local evidence

  ASYMMETRY_REASON=''
  evidence=$(awk -F '\t' \
    -v throughput_ratio="$ASYMMETRY_THROUGHPUT_RATIO" \
    -v udp_severe_delta="$ASYMMETRY_UDP_SEVERE_DELTA" \
    -v udp_persistent_delta="$ASYMMETRY_UDP_PERSISTENT_DELTA" \
    -v tcp_severe_retrans="$ASYMMETRY_TCP_SEVERE_RETRANS" \
    -v tcp_persistent_retrans="$ASYMMETRY_TCP_PERSISTENT_RETRANS" \
    -v tcp_retrans_ratio="$ASYMMETRY_TCP_RETRANS_RATIO" \
    -v tcp_density_min="$ASYMMETRY_TCP_DENSITY" \
    -v load_delta_min="$ASYMMETRY_LOAD_RTT_DELTA" \
    -v load_high_min="$ASYMMETRY_LOAD_RTT_HIGH" '
    function abs(value) { return value < 0 ? -value : value }
    function max(a, b) { return a > b ? a : b }
    function min(a, b) { return a < b ? a : b }
    {
      protocol=$1; direction=$2; stage=$3 SUBSEP $4;
      rate_sum[protocol, direction]+=$6;
      rate_count[protocol, direction]++;
      load_sum[direction]+=$11;
      load_count[direction]++;
      if (protocol == "TCP") {
        tcp_retrans[direction]+=$8;
        tcp_bytes[direction]+=$12;
        tcp_stage[stage]=1;
        tcp_stage_retrans[stage, direction]=$8;
        tcp_stage_seen[stage, direction]=1;
      } else if (protocol == "UDP") {
        udp_loss_sum[direction]+=$9;
        udp_loss_count[direction]++;
        udp_stage[stage]=1;
        udp_stage_loss[stage, direction]=$9;
        udp_stage_seen[stage, direction]=1;
      }
    }
    END {
      forward="A_TO_B"; reverse="B_TO_A";

      if (udp_loss_count[forward] && udp_loss_count[reverse]) {
        forward_loss=udp_loss_sum[forward]/udp_loss_count[forward];
        reverse_loss=udp_loss_sum[reverse]/udp_loss_count[reverse];
        loss_high=max(forward_loss, reverse_loss);
        loss_low=min(forward_loss, reverse_loss);
        loss_delta=abs(forward_loss-reverse_loss);
        for (stage in udp_stage) {
          if (udp_stage_seen[stage, forward] && udp_stage_seen[stage, reverse]) {
            stage_delta=udp_stage_loss[stage, forward]-udp_stage_loss[stage, reverse];
            if (abs(stage_delta) >= udp_persistent_delta &&
              max(udp_stage_loss[stage, forward], udp_stage_loss[stage, reverse]) >= udp_persistent_delta) {
              if (stage_delta > 0) forward_loss_worse++;
              else reverse_loss_worse++;
            }
          }
        }
        severe_loss=(loss_delta >= udp_severe_delta && loss_high >= udp_severe_delta &&
          (loss_low <= .5 || loss_high >= loss_low*1.75));
        persistent_loss=(loss_delta >= udp_persistent_delta &&
          loss_high >= udp_persistent_delta &&
          (loss_low <= .1 || loss_high >= loss_low*2) &&
          (forward_loss_worse >= 2 || reverse_loss_worse >= 2));
        if (severe_loss || persistent_loss) {
          worse=(forward_loss > reverse_loss ? "forward" : "reverse");
          printf "UDP loss is materially worse in %s direction (A->B %.2f%% vs B->A %.2f%%).", worse, forward_loss, reverse_loss;
          exit;
        }
      }

      forward_retrans=tcp_retrans[forward]+0;
      reverse_retrans=tcp_retrans[reverse]+0;
      forward_density=(tcp_bytes[forward] > 0 ? forward_retrans*100000000/tcp_bytes[forward] : 0);
      reverse_density=(tcp_bytes[reverse] > 0 ? reverse_retrans*100000000/tcp_bytes[reverse] : 0);
      retrans_high=max(forward_retrans, reverse_retrans);
      retrans_low=min(forward_retrans, reverse_retrans);
      retrans_delta=abs(forward_retrans-reverse_retrans);
      density_high=max(forward_density, reverse_density);
      for (stage in tcp_stage) {
        if (tcp_stage_seen[stage, forward] && tcp_stage_seen[stage, reverse]) {
          stage_delta=tcp_stage_retrans[stage, forward]-tcp_stage_retrans[stage, reverse];
          if (abs(stage_delta) >= 10) {
            if (stage_delta > 0) forward_retrans_worse++;
            else reverse_retrans_worse++;
          }
        }
      }
      severe_retrans=(retrans_high >= tcp_severe_retrans &&
        retrans_delta >= tcp_severe_retrans && density_high >= tcp_density_min &&
        (retrans_low <= 5 || retrans_high >= retrans_low*tcp_retrans_ratio));
      persistent_retrans=(retrans_high >= tcp_persistent_retrans &&
        retrans_delta >= tcp_persistent_retrans && density_high >= tcp_density_min &&
        (retrans_low <= 5 || retrans_high >= retrans_low*tcp_retrans_ratio) &&
        (forward_retrans_worse >= 2 || reverse_retrans_worse >= 2));
      if (severe_retrans || persistent_retrans) {
        worse=(forward_retrans > reverse_retrans ? "forward" : "reverse");
        printf "%s TCP path shows substantially more retransmissions (A->B %.0f vs B->A %.0f).", worse, forward_retrans, reverse_retrans;
        exit;
      }

      if (load_count[forward] >= 2 && load_count[reverse] >= 2) {
        forward_load=load_sum[forward]/load_count[forward];
        reverse_load=load_sum[reverse]/load_count[reverse];
        load_high=max(forward_load, reverse_load);
        load_low=min(forward_load, reverse_load);
        if (abs(forward_load-reverse_load) >= load_delta_min &&
          load_high >= load_high_min &&
          (load_low <= 10 || load_high >= load_low*2)) {
          worse=(forward_load > reverse_load ? "forward" : "reverse");
          printf "load RTT is materially worse in %s direction (A->B +%.1f ms vs B->A +%.1f ms).", worse, forward_load, reverse_load;
          exit;
        }
      }

      for (protocol_index=1; protocol_index<=2; protocol_index++) {
        protocol=(protocol_index == 1 ? "TCP" : "UDP");
        if (rate_count[protocol, forward] && rate_count[protocol, reverse]) {
          forward_rate=rate_sum[protocol, forward]/rate_count[protocol, forward];
          reverse_rate=rate_sum[protocol, reverse]/rate_count[protocol, reverse];
          if (forward_rate > 0 && reverse_rate > 0) {
            rate_ratio=(forward_rate < reverse_rate ? forward_rate/reverse_rate : reverse_rate/forward_rate);
            if (rate_ratio < throughput_ratio) {
              worse=(forward_rate < reverse_rate ? "forward" : "reverse");
              printf "%s achieved throughput is materially lower in %s direction (A->B %.2f Mbps vs B->A %.2f Mbps).", protocol, worse, forward_rate, reverse_rate;
              exit;
            }
          }
        }
      }
    }' "$RESULT_FILE")
  [[ -n "$evidence" ]] || return 1
  ASYMMETRY_REASON=$evidence
  return 0
}

choose_preferred_transport() {
  local tcp_degraded=false
  local udp_degraded=false

  [[ ",$LABELS," == *',TCP-DEGRADED,'* ]] && tcp_degraded=true
  [[ ",$LABELS," == *',UDP-DEGRADED,'* ]] && udp_degraded=true

  if (( TCP_SCORE < PREFERENCE_USABLE_SCORE &&
    UDP_SCORE < PREFERENCE_USABLE_SCORE )); then
    PREFERRED='FIX LINK'
    REASON='Both TCP and UDP are materially degraded; fix or replace the underlying path before choosing a transport.'
  elif (( TCP_SCORE >= PREFERENCE_USABLE_SCORE &&
    UDP_SCORE < PREFERENCE_USABLE_SCORE )); then
    PREFERRED='TCP'
    REASON='UDP is materially degraded while TCP remains the more usable transport.'
  elif (( UDP_SCORE >= PREFERENCE_USABLE_SCORE &&
    TCP_SCORE < PREFERENCE_USABLE_SCORE )); then
    PREFERRED='HY2'
    REASON='UDP quality is materially better than TCP on this path.'
  elif [[ "$udp_degraded" == true && "$tcp_degraded" == false ]]; then
    PREFERRED='TCP'
    REASON='UDP is materially degraded while TCP remains the more usable transport.'
  elif [[ "$tcp_degraded" == true && "$udp_degraded" == false ]]; then
    PREFERRED='HY2'
    REASON='UDP quality is materially better than TCP on this path.'
  elif (( TCP_SCORE >= UDP_SCORE + PREFERENCE_MATERIAL_MARGIN )); then
    PREFERRED='TCP'
    if [[ "$udp_degraded" == true ]]; then
      REASON='UDP is materially degraded while TCP remains the more usable transport.'
    else
      REASON='TCP quality is materially better than UDP on this path.'
    fi
  elif (( UDP_SCORE >= TCP_SCORE + PREFERENCE_MATERIAL_MARGIN )); then
    PREFERRED='HY2'
    REASON='UDP quality is materially better than TCP on this path.'
  else
    PREFERRED='EITHER'
    REASON='TCP and UDP are both healthy with no material quality advantage.'
  fi
}

calculate_results() {
  local sample_count
  local idle_penalty=0
  local load_average
  local cpu_count

  TCP_EVALUABLE=false
  UDP_EVALUABLE=false
  protocol_is_evaluable TCP && TCP_EVALUABLE=true
  protocol_is_evaluable UDP && UDP_EVALUABLE=true
  if benchmark_server_became_unavailable; then
    RESULT_STATE='INFRASTRUCTURE_FAILURE'
    CONFIDENCE='NONE'
    STATUS='INCOMPLETE'
    PREFERRED='INCONCLUSIVE'
    REASON='Benchmark server became unavailable during the test; protocol classification is invalid/incomplete.'
    append_label 'INFRASTRUCTURE-FAILURE'
    return 0
  fi
  if [[ "$TCP_EVALUABLE" == false && "$UDP_EVALUABLE" == false ]]; then
    RESULT_STATE='FAILED'
    CONFIDENCE='NONE'
    STATUS='NO VALID DATA'
    PREFERRED='INCONCLUSIVE'
    REASON='Unable to complete controlled iperf3 tests; no link-quality conclusion is available.'
    append_label 'EXECUTION-FAILED'
    return 0
  fi

  IFS=$'\t' read -r TCP_RETRANS_DENSITY_A_TO_B \
    TCP_RETRANS_DENSITY_B_TO_A TCP_RETRANS_WORST_DIRECTION \
    TCP_RETRANS_PENALTY TCP_TRANSFERRED_BYTES_A_TO_B \
    TCP_TRANSFERRED_BYTES_B_TO_A TCP_RETRANSMISSIONS_A_TO_B \
    TCP_RETRANSMISSIONS_B_TO_A < <(calculate_tcp_retransmission_metrics)
  TCP_SCORE=0
  UDP_SCORE=0
  if [[ "$TCP_EVALUABLE" == true ]]; then
    TCP_SCORE=$(calculate_protocol_score 'TCP' "$TCP_FAILURES" \
      "$TCP_RETRANS_PENALTY")
  fi
  if [[ "$UDP_EVALUABLE" == true ]]; then
    UDP_SCORE=$(calculate_protocol_score 'UDP' "$UDP_FAILURES")
  fi
  if [[ "$TCP_EVALUABLE" != "$UDP_EVALUABLE" ]]; then
    RESULT_STATE='PARTIAL'
    CONFIDENCE='LOW'
    STATUS='INCOMPLETE'
    PREFERRED='INCONCLUSIVE'
    REASON='Only one protocol produced valid bidirectional samples; no combined link-quality score or transport recommendation was produced.'
    append_label 'PARTIAL-DATA'
    [[ "$CPU_LIMITED" == false ]] || append_label 'CPU-LIMITED'
    if [[ "$TCP_EVALUABLE" == true ]] && (( TCP_SCORE < 65 )); then
      append_label 'TCP-DEGRADED'
    fi
    if [[ "$UDP_EVALUABLE" == true ]] && (( UDP_SCORE < 65 )); then
      append_label 'UDP-DEGRADED'
    fi
    return 0
  fi
  RESULT_STATE='COMPLETE'
  if [[ -n "$IDLE_LOSS" ]]; then
    idle_penalty=$(awk -v loss="$IDLE_LOSS" -v variation="${IDLE_VARIATION:-0}" '
      BEGIN {
        penalty=loss*1.5;
        if (variation > 10) penalty+=(variation-10)/2;
        if (penalty > 20) penalty=20;
        printf "%.0f", penalty;
      }')
  fi
  LINK_HEALTH=$(awk -v tcp="$TCP_SCORE" -v udp="$UDP_SCORE" -v penalty="$idle_penalty" '
    BEGIN {
      score=tcp*.45+udp*.55-penalty;
      if (score < 0) score=0; if (score > 100) score=100;
      printf "%.0f", score;
    }')

  load_average=$(float_max "$MAX_LOAD_AVERAGE" "$(awk '{print $1}' /proc/loadavg)")
  MAX_LOAD_AVERAGE=$load_average
  cpu_count=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')
  if awk -v average="$load_average" -v cpus="$cpu_count" \
    'BEGIN { exit !(average > cpus*1.5) }'; then
    CPU_LIMITED=true
  fi
  if [[ "$CPU_LIMITED" == true ]]; then
    append_label 'CPU-LIMITED'
  fi
  if awk -v value="$MAX_LOAD_INCREASE" 'BEGIN { exit !(value >= 80) }'; then
    append_label 'HIGH-LOAD-LATENCY'
  fi
  if detect_asymmetry; then
    append_label 'ASYMMETRIC'
  fi
  (( TCP_SCORE < 65 )) && append_label 'TCP-DEGRADED'
  (( UDP_SCORE < 65 )) && append_label 'UDP-DEGRADED'

  sample_count=$(awk 'END {print NR+0}' "$RESULT_FILE")
  if (( sample_count >= 8 && TEST_FAILURES == 0 &&
    $(protocol_count TCP) >= 4 && $(protocol_count UDP) >= 4 )) &&
    [[ -n "$IDLE_RTT" && "$CPU_LIMITED" == false ]]; then
    CONFIDENCE='HIGH'
  elif (( sample_count >= 4 )); then
    CONFIDENCE='MEDIUM'
  else
    CONFIDENCE='LOW'
  fi
  if [[ "$BUDGET_LIMITED" == true || "$CPU_LIMITED" == true ]]; then
    [[ "$CONFIDENCE" == 'HIGH' ]] && CONFIDENCE='MEDIUM'
  fi
  [[ "$CONFIDENCE" != 'LOW' ]] || append_label 'LOW-CONFIDENCE'

  if (( LINK_HEALTH >= 80 )); then
    STATUS='HEALTHY'
  elif (( LINK_HEALTH >= 55 )); then
    STATUS='DEGRADED'
  else
    STATUS='POOR'
  fi

  choose_preferred_transport
}

human_bandwidth() {
  awk -v value="$NOMINAL_MBPS" 'BEGIN {
    if (value >= 1000 && value % 1000 == 0) printf "%g Gbps", value/1000;
    else printf "%g Mbps", value;
  }'
}

human_traffic() {
  awk -v bytes="$TRAFFIC_ACTUAL_BYTES" 'BEGIN { printf "%.1f MB", bytes/1000000 }'
}

human_bytes() {
  awk -v bytes="$1" 'BEGIN { printf "%.1f MB (%s bytes)", bytes/1000000, bytes }'
}

adaptive_stop_summary() {
  local protocol=$1
  local stopped highest stop_stage

  if [[ "$protocol" == 'TCP' ]]; then
    stopped=$TCP_ADAPTIVE_STOP
    highest=$TCP_HIGHEST_STAGE
    stop_stage=$TCP_STOP_STAGE
  else
    stopped=$UDP_ADAPTIVE_STOP
    highest=$UDP_HIGHEST_STAGE
    stop_stage=$UDP_STOP_STAGE
  fi
  if [[ "$stopped" == true ]]; then
    printf 'yes (after %s%%; highest test %s%%)' "$stop_stage" "$highest"
  else
    printf 'no (reached %s%%)' "$highest"
  fi
}

print_results() {
  local idle_display='unavailable'
  local variation_display='unavailable'
  local labels_display='none'
  local retrans_direction_display

  [[ -z "$IDLE_RTT" ]] || idle_display="${IDLE_RTT} ms"
  [[ -z "$IDLE_VARIATION" ]] || variation_display="${IDLE_VARIATION} ms"
  [[ -z "$LABELS" ]] || labels_display=$LABELS
  case "$TCP_RETRANS_WORST_DIRECTION" in
    A_TO_B) retrans_direction_display='A->B' ;;
    B_TO_A) retrans_direction_display='B->A' ;;
    BOTH) retrans_direction_display='both' ;;
    *) retrans_direction_display='none' ;;
  esac
  printf '\nProtocol Benchmark\n'
  printf '%s\n' '------------------------------------'
  printf 'Peer:          %s:%s\n' "$PEER" "$PORT"
  printf 'Mode:          %s\n' "$([[ "$DEEP" == true ]] && printf 'DEEP' || printf 'LOW-IMPACT')"
  printf 'Nominal BW:    %s\n' "$(human_bandwidth)"
  printf 'Test ceiling:  %s%% adaptive\n' "$MAX_PERCENT"
  printf 'Traffic used:  %s (hard budget %s MB)\n' "$(human_traffic)" "$BUDGET_MB"
  printf 'Adaptive stop: %s\n' "$([[ "$EARLY_STOP" == true ]] && printf 'yes' || printf 'no')"
  printf 'TCP adaptive stop: %s\n' "$(adaptive_stop_summary TCP)"
  printf 'UDP adaptive stop: %s\n' "$(adaptive_stop_summary UDP)"
  printf '\nIdle RTT:      %s\n' "$idle_display"
  printf 'RTT variation: %s\n' "$variation_display"
  printf 'Idle loss:     %s%%\n' "${IDLE_LOSS:-unavailable}"
  printf 'Load RTT:      +%s ms max\n' "$MAX_LOAD_INCREASE"
  printf 'Peak CPU:      %s%%\n' "$MAX_CPU"
  printf 'Max load avg:  %s\n' "$MAX_LOAD_AVERAGE"
  if [[ "$RESULT_STATE" == 'INFRASTRUCTURE_FAILURE' ]]; then
    printf '\nTEST RESULT:   INCOMPLETE / INFRASTRUCTURE FAILURE\n'
    printf 'CONFIDENCE:    NONE\n'
    printf 'TCP SCORE:     not produced\n'
    printf 'UDP SCORE:     not produced\n'
    printf 'LINK HEALTH:   not produced\n'
    printf 'STATUS:        INCOMPLETE\n'
    printf '\nPreferred:     INCONCLUSIVE\n'
    printf '\nReason:\n%s\n' "$REASON"
    print_successful_sample_summary
    print_failure_summary
    printf '\nEarlier successful samples are retained for diagnosis but were not used for protocol classification.\n'
    return 0
  fi
  if [[ "$RESULT_STATE" == 'FAILED' ]]; then
    printf '\nTEST RESULT:   FAILED\n'
    printf 'CONFIDENCE:    NONE\n'
    printf 'Budget stop:   %s\n' "$BUDGET_LIMITED"
    printf '\nNo valid bidirectional TCP or UDP benchmark samples were collected.\n'
    printf '\nReason:\nUnable to complete controlled iperf3 tests.\n'
    printf 'Check the temporary server, port, firewall, or connectivity.\n'
    print_failure_summary
    printf '\nNo link-quality score or transport recommendation was produced.\n'
    return 0
  fi
  if [[ "$RESULT_STATE" == 'PARTIAL' ]]; then
    printf '\nTEST RESULT:   INCOMPLETE / PARTIAL DATA\n'
    printf 'CONFIDENCE:    LOW\n'
    if [[ "$TCP_EVALUABLE" == true ]]; then
      printf 'TCP SCORE:     %s / 100\n' "$TCP_SCORE"
    else
      printf 'TCP SCORE:     not evaluable\n'
    fi
    if [[ "$UDP_EVALUABLE" == true ]]; then
      printf 'UDP SCORE:     %s / 100\n' "$UDP_SCORE"
    else
      printf 'UDP SCORE:     not evaluable\n'
    fi
    printf 'LINK HEALTH:   not produced\n'
    printf 'STATUS:        INCOMPLETE\n'
    printf '\nPreferred:     INCONCLUSIVE\n'
    printf '\nReason:\n%s\n' "$REASON"
    print_failure_summary
    if [[ "$BUDGET_LIMITED" == true ]]; then
      printf '\nBudget stop: no further active stages were allowed.\n'
    fi
    printf '\nNo combined link-quality conclusion was produced.\n'
    return 0
  fi
  printf '\nTCP SCORE:     %s / 100\n' "$TCP_SCORE"
  printf 'TCP retransmissions:\n'
  printf '  A->B:        %s\n' "$TCP_RETRANSMISSIONS_A_TO_B"
  printf '  B->A:        %s\n' "$TCP_RETRANSMISSIONS_B_TO_A"
  printf 'TCP transferred:\n'
  printf '  A->B:        %s\n' "$(human_bytes "$TCP_TRANSFERRED_BYTES_A_TO_B")"
  printf '  B->A:        %s\n' "$(human_bytes "$TCP_TRANSFERRED_BYTES_B_TO_A")"
  printf 'TCP retrans density:\n'
  printf '  A->B:        %s retrans / 100MB\n' \
    "$TCP_RETRANS_DENSITY_A_TO_B"
  printf '  B->A:        %s retrans / 100MB\n' \
    "$TCP_RETRANS_DENSITY_B_TO_A"
  printf '  Worst path:  %s\n' "$retrans_direction_display"
  printf '  Penalty:     %s / %s\n' "$TCP_RETRANS_PENALTY" \
    "$TCP_RETRANS_MAX_PENALTY"
  printf 'UDP SCORE:     %s / 100\n' "$UDP_SCORE"
  printf 'LINK HEALTH:   %s / 100\n' "$LINK_HEALTH"
  printf 'CONFIDENCE:    %s\n' "$CONFIDENCE"
  printf 'STATUS:        %s\n' "$STATUS"
  printf 'LABELS:        %s\n' "$labels_display"
  printf '\nPreferred:     %s\n' "$PREFERRED"
  printf '\nReason:\n%s\n' "$REASON"
  if [[ -n "$ASYMMETRY_REASON" ]]; then
    printf 'ASYMMETRIC: %s\n' "$ASYMMETRY_REASON"
  fi
  if awk -v penalty="$TCP_RETRANS_PENALTY" \
    -v threshold="$TCP_RETRANS_DIAGNOSTIC_PENALTY" \
    'BEGIN { exit !(penalty >= threshold) }'; then
    case "$TCP_RETRANS_WORST_DIRECTION" in
      A_TO_B) printf 'TCP retransmission density is materially worse in forward direction.\n' ;;
      B_TO_A) printf 'TCP retransmission density is materially worse in reverse direction.\n' ;;
      *) printf 'TCP retransmission density is materially elevated in both directions.\n' ;;
    esac
  fi
  if [[ "$CPU_LIMITED" == true ]]; then
    printf '\nWARNING: CPU-LIMITED\nConfidence reduced; network scores may be CPU-polluted.\n'
  fi
  if [[ "$BUDGET_LIMITED" == true ]]; then
    printf '\nBudget stop: no further active stages were allowed.\n'
  fi
  print_failure_summary
  printf '\nUnderlying VPS<->VPS link appears %s.\n' "${STATUS,,}"
  printf 'This does NOT prove the sing-box/proxy layer is healthy.\n'
}

print_successful_sample_summary() {
  local protocol direction percent streams _offered achieved ratio retrans loss
  local jitter load_increase bytes

  [[ -n "$RESULT_FILE" && -s "$RESULT_FILE" ]] || return 0
  printf '\nSuccessful samples retained (not scored):\n'
  while IFS=$'\t' read -r protocol direction percent streams _offered achieved \
    ratio retrans loss jitter load_increase bytes; do
    if [[ "$protocol" == 'TCP' ]]; then
      printf '  TCP %s %s%%: %s Mbps, retrans=%s\n' \
        "${direction//_TO_/->}" "$percent" "$achieved" "$retrans"
    else
      printf '  UDP %s %s%%: %s Mbps, loss=%s%%, jitter=%sms\n' \
        "${direction//_TO_/->}" "$percent" "$achieved" "$loss" "$jitter"
    fi
  done <"$RESULT_FILE"
}

print_failure_summary() {
  local protocol direction percent status reason

  [[ -n "$FAILURE_FILE" && -s "$FAILURE_FILE" ]] || return 0
  printf '\nExecution failures:\n'
  while IFS=$'\t' read -r protocol direction percent status reason; do
    printf '  %s %s %s%% (exit %s): %s\n' "$protocol" \
      "${direction//_TO_/->}" "$percent" "$status" "$reason"
  done <"$FAILURE_FILE"
}

baseline_directory() {
  if [[ -n ${PROTOCOL_BENCHMARK_STATE_DIR:-} ]]; then
    printf '%s\n' "$PROTOCOL_BENCHMARK_STATE_DIR"
  elif (( EUID == 0 )); then
    printf '%s\n' '/var/lib/protocol-benchmark'
  else
    printf '%s\n' "${XDG_STATE_HOME:-${HOME}/.local/state}/protocol-benchmark"
  fi
}

history_peer_key() {
  local value=$1
  local character
  local encoded=''
  local index
  local code
  local LC_ALL=C

  [[ -n "$value" ]] || return 1
  for (( index=0; index<${#value}; index++ )); do
    character=${value:index:1}
    printf -v code '%02X' "'$character"
    encoded+=$code
  done
  [[ -n "$encoded" ]] || return 1
  printf 'peer-%s\n' "$encoded"
}

history_root_directory() {
  printf '%s/history\n' "$(baseline_directory)"
}

history_peer_directory() {
  local key
  key=$(history_peer_key "$1") || return 1
  printf '%s/%s\n' "$(history_root_directory)" "$key"
}

ensure_private_directory() {
  local directory=$1

  [[ ! -L "$directory" ]] || return 1
  mkdir -p -- "$directory" || return 1
  [[ -d "$directory" && ! -L "$directory" ]] || return 1
  chmod 0700 -- "$directory" || return 1
}

ensure_history_directory() {
  local state_directory
  local history_directory
  local peer_directory

  state_directory=$(baseline_directory)
  history_directory=$(history_root_directory)
  peer_directory=$(history_peer_directory "$PEER") || return 1
  ensure_private_directory "$state_directory" || return 1
  ensure_private_directory "$history_directory" || return 1
  ensure_private_directory "$peer_directory" || return 1
  printf '%s\n' "$peer_directory"
}

history_filename() {
  date -u +%Y%m%dT%H%M%S%NZ.json
}

list_history_files() {
  local directory=$1
  local path
  local name
  local -a names=()

  [[ -d "$directory" && ! -L "$directory" ]] || return 0
  for path in "$directory"/*.json; do
    [[ -f "$path" && ! -L "$path" ]] || continue
    name=${path##*/}
    [[ "$name" =~ ^[0-9]{8}T[0-9]{15}Z[.]json$ ]] || continue
    names+=("$name")
  done
  (( ${#names[@]} > 0 )) || return 0
  printf '%s\n' "${names[@]}" | LC_ALL=C sort -r
}

prune_history() {
  local directory=$1
  local index
  local -a files=()

  mapfile -t files < <(list_history_files "$directory")
  for (( index=HISTORY_RETENTION; index<${#files[@]}; index++ )); do
    rm -f -- "$directory/${files[index]}" || return 1
  done
}

history_samples_json() {
  jq -Rn '[inputs | split("\t") | select(length >= 12) | {
    protocol: .[0], direction: .[1], stage_percent: (.[2] | tonumber),
    streams: (.[3] | tonumber), offered_mbps: (.[4] | tonumber),
    achieved_mbps: (.[5] | tonumber), achieved_ratio: (.[6] | tonumber),
    retransmissions: (.[7] | tonumber), loss_percent: (.[8] | tonumber),
    jitter_ms: (.[9] | tonumber), load_rtt_delta_ms: (.[10] | tonumber),
    transferred_bytes: (.[11] | tonumber)
  }]' <"$RESULT_FILE"
}

write_history_json() {
  local timestamp=$1
  local samples
  local benchmark_mode='LOW-IMPACT'
  local highest_stage

  samples=$(history_samples_json) || return 1
  [[ "$DEEP" == false ]] || benchmark_mode='DEEP'
  highest_stage=$(( TCP_HIGHEST_STAGE > UDP_HIGHEST_STAGE ?
    TCP_HIGHEST_STAGE : UDP_HIGHEST_STAGE ))
  jq -n \
    --arg timestamp "$timestamp" \
    --arg peer "$PEER" \
    --arg benchmark_mode "$benchmark_mode" \
    --arg confidence "$CONFIDENCE" \
    --arg status "$STATUS" \
    --arg tags "$LABELS" \
    --arg asymmetry_reason "$ASYMMETRY_REASON" \
    --arg preferred "$PREFERRED" \
    --arg preferred_reason "$REASON" \
    --argjson nominal "$NOMINAL_MBPS" \
    --argjson highest_stage "$highest_stage" \
    --argjson idle_rtt "${IDLE_RTT:-null}" \
    --argjson idle_loss "${IDLE_LOSS:-null}" \
    --argjson load_rtt "${PING_AVG:-null}" \
    --argjson load_delta "$MAX_LOAD_INCREASE" \
    --argjson tcp_score "$TCP_SCORE" \
    --argjson udp_score "$UDP_SCORE" \
    --argjson link_health "$LINK_HEALTH" \
    --argjson tcp_bytes_forward "$TCP_TRANSFERRED_BYTES_A_TO_B" \
    --argjson tcp_bytes_reverse "$TCP_TRANSFERRED_BYTES_B_TO_A" \
    --argjson tcp_retrans_forward "$TCP_RETRANSMISSIONS_A_TO_B" \
    --argjson tcp_retrans_reverse "$TCP_RETRANSMISSIONS_B_TO_A" \
    --argjson tcp_density_forward "$TCP_RETRANS_DENSITY_A_TO_B" \
    --argjson tcp_density_reverse "$TCP_RETRANS_DENSITY_B_TO_A" \
    --arg tcp_worst_direction "$TCP_RETRANS_WORST_DIRECTION" \
    --argjson tcp_penalty "$TCP_RETRANS_PENALTY" \
    --argjson tcp_adaptive_stop "$TCP_ADAPTIVE_STOP" \
    --argjson udp_adaptive_stop "$UDP_ADAPTIVE_STOP" \
    --argjson tcp_stop_stage "$TCP_STOP_STAGE" \
    --argjson udp_stop_stage "$UDP_STOP_STAGE" \
    --argjson tcp_highest_stage "$TCP_HIGHEST_STAGE" \
    --argjson udp_highest_stage "$UDP_HIGHEST_STAGE" \
    --argjson traffic_bytes "$TRAFFIC_ACTUAL_BYTES" \
    --argjson overall_adaptive_stop "$EARLY_STOP" \
    --argjson samples "$samples" '
    {
      version: 1,
      timestamp: $timestamp,
      peer: $peer,
      nominal_bandwidth_mbps: $nominal,
      benchmark_mode: $benchmark_mode,
      highest_overall_stage_reached_percent: $highest_stage,
      latency: {
        idle_rtt_ms: $idle_rtt,
        idle_loss_percent: $idle_loss,
        load_rtt_ms: $load_rtt,
        load_rtt_delta_ms: $load_delta
      },
      tcp: {
        score: $tcp_score,
        stages: [$samples[] | select(.protocol == "TCP") | {
          direction, stage_percent, streams, offered_mbps, achieved_mbps,
          retransmissions, transferred_bytes, load_rtt_delta_ms
        }],
        directions: {
          a_to_b: {
            retransmissions: $tcp_retrans_forward,
            transferred_bytes: $tcp_bytes_forward,
            retransmission_density_per_100mb: $tcp_density_forward
          },
          b_to_a: {
            retransmissions: $tcp_retrans_reverse,
            transferred_bytes: $tcp_bytes_reverse,
            retransmission_density_per_100mb: $tcp_density_reverse
          }
        },
        worst_retransmission_direction: $tcp_worst_direction,
        retransmission_penalty: $tcp_penalty,
        adaptive_stop: $tcp_adaptive_stop,
        adaptive_stop_after_percent: (if $tcp_adaptive_stop then $tcp_stop_stage else null end),
        highest_stage_reached_percent: $tcp_highest_stage
      },
      udp: {
        score: $udp_score,
        stages: [$samples[] | select(.protocol == "UDP") | {
          direction, stage_percent, streams, offered_mbps, achieved_mbps,
          loss_percent, jitter_ms, transferred_bytes, load_rtt_delta_ms
        }],
        adaptive_stop: $udp_adaptive_stop,
        adaptive_stop_after_percent: (if $udp_adaptive_stop then $udp_stop_stage else null end),
        highest_stage_reached_percent: $udp_highest_stage
      },
      overall: {
        link_health: $link_health,
        confidence: $confidence,
        status: $status,
        tags: $tags,
        asymmetry_reason: $asymmetry_reason,
        preferred_transport: $preferred,
        preferred_reason: $preferred_reason,
        traffic_used_bytes: $traffic_bytes,
        adaptive_stop: $overall_adaptive_stop
      }
    }'
}

save_history() {
  local directory
  local filename
  local final_file
  local temporary=''
  local timestamp

  directory=$(ensure_history_directory) || return 1
  filename=$(history_filename) || return 1
  final_file="$directory/$filename"
  [[ ! -e "$final_file" && ! -L "$final_file" ]] || return 1
  temporary=$(mktemp "$directory/.history.XXXXXXXX") || return 1
  timestamp=$(date -u +%FT%TZ) || {
    rm -f -- "$temporary"
    return 1
  }
  if ! write_history_json "$timestamp" >"$temporary" ||
    ! jq -e . "$temporary" >/dev/null ||
    ! chmod 0600 -- "$temporary" ||
    ! mv -- "$temporary" "$final_file"; then
    rm -f -- "$temporary"
    return 1
  fi
  if ! prune_history "$directory"; then
    warn "History was saved, but retention cleanup failed in $directory."
  fi
  printf 'History saved: %s\n' "$final_file"
}

persist_history() {
  if [[ "$RESULT_STATE" != 'COMPLETE' || ! -s "$RESULT_FILE" ]] ||
    ! protocol_is_evaluable TCP || ! protocol_is_evaluable UDP; then
    return 0
  fi
  if ! save_history; then
    warn 'History could not be saved; benchmark result and exit status are unchanged.'
  fi
  return 0
}

show_history() {
  local state_directory
  local history_directory
  local directory
  local file
  local date_display
  local tcp_score
  local udp_score
  local link_health
  local status
  local preferred
  local tags
  local count=0
  local -a files=()

  state_directory=$(baseline_directory)
  history_directory=$(history_root_directory)
  [[ ! -L "$state_directory" && ! -L "$history_directory" ]] ||
    die 'Refusing an unsafe history state directory.'
  directory=$(history_peer_directory "$PEER") ||
    die 'Unable to derive a safe history peer key.'
  if [[ ! -e "$directory" ]]; then
    printf 'No history found for %s.\n' "$PEER"
    return 0
  fi
  [[ -d "$directory" && ! -L "$directory" ]] ||
    die 'Refusing an unsafe history directory.'
  mapfile -t files < <(list_history_files "$directory")
  if (( ${#files[@]} == 0 )); then
    printf 'No history found for %s.\n' "$PEER"
    return 0
  fi
  printf '%-19s %4s %4s %4s %-10s %-10s %s\n' \
    'DATE' 'TCP' 'UDP' 'LINK' 'STATUS' 'PREFERRED' 'TAGS'
  for file in "${files[@]}"; do
    (( count < HISTORY_LIMIT )) || break
    file="$directory/$file"
    if ! jq -e '
      (.timestamp | type == "string") and
      (.tcp.score | type == "number") and
      (.udp.score | type == "number") and
      (.overall.link_health | type == "number")
    ' "$file" >/dev/null 2>&1; then
      warn "Skipping invalid history entry: ${file##*/}"
      continue
    fi
    IFS=$'\t' read -r date_display tcp_score udp_score link_health \
      status preferred tags < <(jq -r '[
        (.timestamp | sub("T"; " ") | sub("Z$"; "")),
        .tcp.score, .udp.score, .overall.link_health,
        .overall.status, .overall.preferred_transport,
        (if .overall.tags == "" then "none" else .overall.tags end)
      ] | @tsv' "$file")
    tags=${tags%$'\r'}
    printf '%-19s %4s %4s %4s %-10s %-10s %s\n' \
      "$date_display" "$tcp_score" "$udp_score" "$link_health" \
      "$status" "$preferred" "$tags"
    (( count += 1 ))
  done
}

baseline_file() {
  local safe_peer
  safe_peer=$(printf '%s' "$PEER" | sed 's/[^A-Za-z0-9._-]/_/g')
  printf '%s/%s.json\n' "$(baseline_directory)" "$safe_peer"
}

ensure_baseline_directory() {
  local directory
  directory=$(baseline_directory)
  if [[ ! -d "$directory" ]]; then
    mkdir -p -- "$directory"
  fi
  [[ ! -L "$directory" ]] || die 'Refusing a symlink baseline directory.'
  chmod 0700 -- "$directory"
}

save_baseline() {
  local file
  local temporary

  [[ "$STATUS" == 'HEALTHY' ]] ||
    die 'Refusing to save a baseline unless the current link is HEALTHY.'
  ensure_baseline_directory
  file=$(baseline_file)
  [[ ! -L "$file" ]] || die 'Refusing to replace a symlink baseline file.'
  temporary=$(mktemp "$(baseline_directory)/.baseline.XXXXXXXX")
  jq -n \
    --arg timestamp "$(date -u +%FT%TZ)" \
    --arg peer "$PEER" \
    --argjson nominal "$NOMINAL_MBPS" \
    --argjson rtt "${IDLE_RTT:-null}" \
    --argjson tcp "$TCP_SCORE" \
    --argjson udp "$UDP_SCORE" \
    --argjson health "$LINK_HEALTH" \
    '{version:1,timestamp:$timestamp,peer:$peer,nominal_mbps:$nominal,
      rtt_ms:$rtt,tcp_score:$tcp,udp_score:$udp,link_health:$health}' \
    >"$temporary"
  chmod 0600 "$temporary"
  mv -f -- "$temporary" "$file"
  printf '\nBaseline saved: %s\n' "$file"
}

compare_baseline() {
  local file
  local baseline_rtt
  local baseline_tcp
  local baseline_udp
  local baseline_health
  local change
  local rtt_delta=0
  local score_delta

  file=$(baseline_file)
  [[ -f "$file" && ! -L "$file" ]] || die "No safe baseline exists for $PEER."
  jq -e --arg peer "$PEER" '
    .version == 1 and .peer == $peer and
    (.tcp_score | type == "number") and
    (.udp_score | type == "number") and
    (.link_health | type == "number") and
    (.rtt_ms == null or (.rtt_ms | type == "number"))
  ' "$file" >/dev/null || die 'Baseline file is invalid or belongs to another peer.'
  baseline_rtt=$(jq -r '.rtt_ms // "unavailable"' "$file")
  baseline_tcp=$(jq -r '.tcp_score' "$file")
  baseline_udp=$(jq -r '.udp_score' "$file")
  baseline_health=$(jq -r '.link_health' "$file")
  if [[ "$baseline_rtt" != 'unavailable' && -n "$IDLE_RTT" ]]; then
    rtt_delta=$(awk -v current="$IDLE_RTT" -v baseline="$baseline_rtt" \
      'BEGIN { printf "%.2f", current-baseline }')
  fi
  score_delta=$((LINK_HEALTH - baseline_health))
  if (( score_delta <= -30 )) ||
    awk -v delta="$rtt_delta" -v baseline="$baseline_rtt" \
      'BEGIN { exit !(baseline != "unavailable" && delta >= 30 && delta >= baseline*.5) }'; then
    change='SEVERE DEGRADATION'
  elif (( score_delta <= -12 )) ||
    awk -v delta="$rtt_delta" 'BEGIN { exit !(delta >= 15) }'; then
    change='DEGRADED'
  else
    change='insignificant'
  fi
  printf '\nCURRENT vs BASELINE\n'
  printf '%s\n' '------------------------------------'
  printf '%-16s %-12s %-12s\n' '' 'BASELINE' 'CURRENT'
  printf '%-16s %-12s %-12s\n' 'RTT' "${baseline_rtt} ms" "${IDLE_RTT:-unavailable} ms"
  printf '%-16s %-12s %-12s\n' 'TCP Score' "$baseline_tcp" "$TCP_SCORE"
  printf '%-16s %-12s %-12s\n' 'UDP Score' "$baseline_udp" "$UDP_SCORE"
  printf '%-16s %-12s %-12s\n' 'Link Health' "$baseline_health" "$LINK_HEALTH"
  printf '\nChange:         %s\n' "$change"
  printf 'Link Status:    %s\n' "$STATUS"
}

run_client() {
  choose_bandwidth
  if [[ "$DEEP" == true ]]; then
    DURATION=$DEEP_DURATION
    BUDGET_MB=$DEEP_BUDGET_MB
    MAX_PERCENT=$DEEP_MAX_PERCENT
  fi
  BUDGET_BYTES=$((BUDGET_MB * 1000 * 1000))
  TEMP_DIR=$(mktemp -d /tmp/protocol-benchmark-client.XXXXXXXX)
  RESULT_FILE="$TEMP_DIR/results.tsv"
  FAILURE_FILE="$TEMP_DIR/failures.tsv"
  : >"$RESULT_FILE"
  : >"$FAILURE_FILE"
  collect_idle_baseline
  run_adaptive_matrix
  calculate_results
  print_results
  persist_history
  if [[ "$RESULT_STATE" == 'COMPLETE' ]]; then
    [[ "$COMPARE_BASELINE" == false ]] || compare_baseline
    [[ "$SAVE_BASELINE" == false ]] || save_baseline
  elif [[ "$COMPARE_BASELINE" == true || "$SAVE_BASELINE" == true ]]; then
    warn 'Baseline operations were skipped because the benchmark result is incomplete.'
  fi
  [[ "$RESULT_STATE" != 'FAILED' &&
    "$RESULT_STATE" != 'INFRASTRUCTURE_FAILURE' ]] || return 1
}

main() {
  parse_args "$@"
  check_platform
  check_dependencies
  case "$MODE" in
    server) run_server ;;
    history) show_history ;;
    *) run_client ;;
  esac
}

if [[ ${PROTOCOL_BENCHMARK_SOURCE_ONLY:-0} != 1 ]]; then
  main "$@"
fi
