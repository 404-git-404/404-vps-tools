#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME='domain-check'
readonly USAGE_TEXT='Usage: domain-check domain1.com/domain2.com/domain3.com'
readonly MAX_CONCURRENCY=8
readonly DNS_TIMEOUT=6
readonly TCP_TIMEOUT=6
readonly TLS_TIMEOUT=10
readonly HTTP_TIMEOUT=10
readonly HTTP_USER_AGENT='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0 Safari/537.36'

declare -a DOMAIN_INPUTS=()
declare -a WORKER_PIDS=()
declare -a RESULT_STATUSES=()
TEMP_DIR=''
COLOR_ENABLED=false
ACTIVE_PID=''
REASONS=''
REDIRECT_STATUS='PASS'
REDIRECT_DETAIL='-'

print_usage() {
  printf '%s\n' "$USAGE_TEXT" >&2
}

validate_domain() {
  local domain=$1
  local label
  local -a labels=()

  (( ${#domain} >= 3 && ${#domain} <= 253 )) || return 1
  [[ "$domain" == *.* ]] || return 1
  [[ "$domain" != .* && "$domain" != *. ]] || return 1
  [[ "$domain" != *..* ]] || return 1
  [[ "$domain" =~ ^[a-z0-9.-]+$ ]] || return 1
  [[ ! "$domain" =~ ^[0-9.]+$ ]] || return 1

  IFS='.' read -r -a labels <<<"$domain"
  (( ${#labels[@]} >= 2 )) || return 1
  for label in "${labels[@]}"; do
    (( ${#label} >= 1 && ${#label} <= 63 )) || return 1
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
}

parse_domain_argument() {
  local argument=$1
  local segment
  local normalized
  local -a segments=()
  local -A seen=()

  DOMAIN_INPUTS=()
  [[ -n "$argument" ]] || return 1
  [[ "$argument" != *[[:space:]]* ]] || return 1
  [[ "$argument" != /* && "$argument" != */ ]] || return 1
  [[ "$argument" != *'//'* ]] || return 1

  IFS='/' read -r -a segments <<<"$argument"
  (( ${#segments[@]} > 0 )) || return 1
  for segment in "${segments[@]}"; do
    [[ -n "$segment" ]] || return 1
    normalized=${segment,,}
    validate_domain "$normalized" || return 1
    if [[ -z ${seen[$normalized]+x} ]]; then
      seen["$normalized"]=1
      DOMAIN_INPUTS+=("$normalized")
    fi
  done
}

trim_location() {
  local value=$1
  value=${value%$'\r'}
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s' "$value"
}

classify_redirect() {
  local domain=$1
  local location=$2
  local scheme
  local authority
  local host
  local port=''
  local remainder
  local userinfo_present=false

  REDIRECT_STATUS='PASS'
  REDIRECT_DETAIL='-'
  location=$(trim_location "$location")
  [[ -n "$location" ]] || return 0

  if [[ "$location" == *$'\n'* || "$location" == *$'\r'* ||
    "$location" == *$'\t'* ]]; then
    REDIRECT_STATUS='WARN'
    REDIRECT_DETAIL='无法解析'
    return 0
  fi

  if [[ "$location" == //* ]]; then
    location="https:$location"
  elif [[ ! "$location" =~ ^[Hh][Tt][Tt][Pp][Ss]?:// ]]; then
    REDIRECT_STATUS='WARN'
    REDIRECT_DETAIL='相对路径'
    return 0
  fi

  if [[ ! "$location" =~ ^([Hh][Tt][Tt][Pp][Ss]?)://([^/?#]+)(.*)$ ]]; then
    REDIRECT_STATUS='WARN'
    REDIRECT_DETAIL='无法解析'
    return 0
  fi
  scheme=${BASH_REMATCH[1],,}
  authority=${BASH_REMATCH[2]}
  remainder=${BASH_REMATCH[3]}

  if [[ "$scheme" == 'http' ]]; then
    REDIRECT_STATUS='FAIL'
    REDIRECT_DETAIL='降级 HTTP'
    return 0
  fi
  if [[ "$authority" == *[[:space:]]* ||
    "$remainder" == *$'\n'* || "$remainder" == *$'\r'* ]]; then
    REDIRECT_STATUS='WARN'
    REDIRECT_DETAIL='无法解析'
    return 0
  fi
  if [[ "$authority" == *'@'* ]]; then
    userinfo_present=true
    authority=${authority##*@}
  fi

  if [[ "$authority" == \[* ]]; then
    if [[ "$authority" =~ ^\[([^]]+)\](:([0-9]+))?$ ]]; then
      host=${BASH_REMATCH[1],,}
      port=${BASH_REMATCH[3]:-}
    else
      REDIRECT_STATUS='WARN'
      REDIRECT_DETAIL='无法解析'
      return 0
    fi
  else
    if [[ "$authority" == *:* ]]; then
      [[ "$authority" != *:*:* ]] || {
        REDIRECT_STATUS='WARN'
        REDIRECT_DETAIL='无法解析'
        return 0
      }
      host=${authority%%:*}
      port=${authority#*:}
    else
      host=$authority
    fi
    host=${host,,}
  fi

  if [[ -n "$port" ]] &&
    { [[ ! "$port" =~ ^[0-9]+$ ]] || (( ${#port} > 5 )) ||
      (( 10#$port < 1 || 10#$port > 65535 )); }; then
    REDIRECT_STATUS='WARN'
    REDIRECT_DETAIL='无法解析'
    return 0
  fi
  if [[ -z "$host" || "$host" == *[[:space:]/?#]* ]]; then
    REDIRECT_STATUS='WARN'
    REDIRECT_DETAIL='无法解析'
    return 0
  fi

  if [[ "$host" == "$domain" ]]; then
    REDIRECT_STATUS='WARN'
    if [[ "$userinfo_present" == true ]]; then
      REDIRECT_DETAIL='同主机（含用户信息）'
    else
      REDIRECT_DETAIL='同主机'
    fi
  elif [[ "$domain" != www.* && "$host" == "www.$domain" ]] ||
    [[ "$domain" == www.* && "$host" == "${domain#www.}" ]]; then
    REDIRECT_STATUS='WARN'
    REDIRECT_DETAIL='www 切换'
  else
    REDIRECT_STATUS='FAIL'
    REDIRECT_DETAIL="$host"
  fi
}

aggregate_exit_code() {
  local status
  for status in "$@"; do
    [[ "$status" != 'FAIL' ]] || return 1
  done
  return 0
}

append_reason() {
  local reason=$1
  if [[ -n "$REASONS" ]]; then
    REASONS+="; $reason"
  else
    REASONS=$reason
  fi
}

epoch_microseconds() {
  printf '%s' "${EPOCHREALTIME/./}"
}

run_network_command() {
  local output_file=$1
  local timeout_seconds=$2
  local status
  shift 2

  timeout --signal=TERM --kill-after=2 "$timeout_seconds" \
    "$@" </dev/null >"$output_file" 2>&1 &
  ACTIVE_PID=$!
  if wait "$ACTIVE_PID"; then
    status=0
  else
    status=$?
  fi
  ACTIVE_PID=''
  return "$status"
}

worker_signal() {
  trap - INT TERM
  if [[ -n "$ACTIVE_PID" ]]; then
    kill -TERM "$ACTIVE_PID" 2>/dev/null || :
    wait "$ACTIVE_PID" 2>/dev/null || :
  fi
  exit 130
}

first_ipv4_from_file() {
  awk '
    function valid_ipv4(value, parts, count, index) {
      count = split(value, parts, ".")
      if (count != 4) {
        return 0
      }
      for (index = 1; index <= 4; index++) {
        if (parts[index] !~ /^[0-9]+$/ || parts[index] > 255) {
          return 0
        }
      }
      return 1
    }
    valid_ipv4($1) { print $1; exit }
  ' "$1"
}

first_ipv6_from_file() {
  awk '$1 ~ /^[0-9A-Fa-f:]+$/ && index($1, ":") { print $1; exit }' "$1"
}

extract_http_code() {
  awk '/^[0-9][0-9][0-9]$/ { code = $0 } END { print code }' "$1"
}

extract_location() {
  awk '
    tolower($1) == "location:" {
      sub(/^[^:]*:[[:space:]]*/, "")
      sub(/\r$/, "")
      value = $0
    }
    END { print value }
  ' "$1"
}

check_domain() {
  local index=$1
  local domain=$2
  local result_file="$TEMP_DIR/result-$index"
  local ipv4=''
  local ipv6=''
  local ip='-'
  local dns_status='FAIL'
  local tcp_status='FAIL'
  local tls_status='FAIL'
  local x25519_status='FAIL'
  local h2_status='FAIL'
  local certificate_status='FAIL'
  local handshake_ms='-'
  local http_status='-'
  local final_status='PASS'
  local redirect_status='PASS'
  local redirect_detail='-'
  local start_us
  local end_us
  local tls_command_ok=false
  local x25519_command_ok=false
  local http_request_ok=false
  local http_code=''
  local location=''
  local attempt
  local dns_a_file="$TEMP_DIR/dns-a-$index"
  local dns_aaaa_file="$TEMP_DIR/dns-aaaa-$index"
  local tcp_file="$TEMP_DIR/tcp-$index"
  local tls_file="$TEMP_DIR/tls-$index"
  local x25519_file="$TEMP_DIR/x25519-$index"
  local http_output_file
  local http_header_file

  trap - EXIT ERR
  trap worker_signal INT TERM
  REASONS=''

  if command -v dig >/dev/null 2>&1; then
    run_network_command "$dns_a_file" "$DNS_TIMEOUT" \
      dig +time=5 +tries=1 +short A "$domain" || :
    run_network_command "$dns_aaaa_file" "$DNS_TIMEOUT" \
      dig +time=5 +tries=1 +short AAAA "$domain" || :
  else
    run_network_command "$dns_a_file" "$DNS_TIMEOUT" \
      getent ahostsv4 "$domain" || :
    run_network_command "$dns_aaaa_file" "$DNS_TIMEOUT" \
      getent ahostsv6 "$domain" || :
  fi
  ipv4=$(first_ipv4_from_file "$dns_a_file")
  ipv6=$(first_ipv6_from_file "$dns_aaaa_file")
  if [[ -n "$ipv4" ]]; then
    ip=$ipv4
    dns_status='PASS'
  elif [[ -n "$ipv6" ]]; then
    ip=$ipv6
    dns_status='PASS'
  else
    append_reason 'DNS 无法解析'
  fi

  # The child Bash, not this shell, expands its positional parameter.
  # shellcheck disable=SC2016
  if run_network_command "$tcp_file" "$TCP_TIMEOUT" \
    bash -c 'exec 3<>"/dev/tcp/$1/443"' bash "$domain"; then
    tcp_status='PASS'
  else
    append_reason 'TCP 443 不可达'
  fi

  start_us=$(epoch_microseconds)
  if run_network_command "$tls_file" "$TLS_TIMEOUT" \
    openssl s_client -connect "$domain:443" -servername "$domain" \
      -tls1_3 -alpn h2 -verify_hostname "$domain" -verify_return_error \
      -showcerts; then
    tls_command_ok=true
  fi
  end_us=$(epoch_microseconds)
  handshake_ms="$(( (10#$end_us - 10#$start_us + 500) / 1000 ))ms"

  if grep -Eq 'TLSv1\.3' "$tls_file"; then
    tls_status='PASS'
  else
    append_reason 'TLS 1.3 握手失败'
  fi
  if grep -Eq '^ALPN protocol: h2\r?$' "$tls_file"; then
    h2_status='PASS'
  else
    append_reason 'ALPN 未协商 h2'
  fi
  if [[ "$tls_command_ok" == true ]] &&
    grep -Eq '^Verify return code: 0 \(ok\)\r?$' "$tls_file"; then
    certificate_status='PASS'
  else
    append_reason '证书链、有效期或主机名验证失败'
  fi

  if run_network_command "$x25519_file" "$TLS_TIMEOUT" \
    openssl s_client -connect "$domain:443" -servername "$domain" \
      -tls1_3 -groups X25519 -verify_hostname "$domain" \
      -verify_return_error; then
    x25519_command_ok=true
  fi
  if [[ "$x25519_command_ok" == true ]] &&
    grep -Eq 'TLSv1\.3' "$x25519_file" &&
    grep -Eqi '(Peer|Server) (Temp Key|temporary key): X25519|X25519, [0-9]+ bits' \
      "$x25519_file"; then
    x25519_status='PASS'
  else
    append_reason '强制 X25519 握手失败'
  fi

  for attempt in 1 2 3; do
    http_output_file="$TEMP_DIR/http-output-$index-$attempt"
    http_header_file="$TEMP_DIR/http-header-$index-$attempt"
    if run_network_command "$http_output_file" "$HTTP_TIMEOUT" \
      curl --silent --output /dev/null --dump-header "$http_header_file" \
        --write-out '%{http_code}\n' --connect-timeout 5 --max-time 9 \
        --proto '=https' --user-agent "$HTTP_USER_AGENT" \
        "https://$domain/"; then
      http_code=$(extract_http_code "$http_output_file")
      if [[ "$http_code" =~ ^[0-9]{3}$ && "$http_code" != '000' ]]; then
        http_request_ok=true
        http_status=$http_code
        location=$(extract_location "$http_header_file")
      fi
    fi
    if [[ "$http_request_ok" == true && "$http_status" =~ ^5[0-9][0-9]$ &&
      "$attempt" -lt 3 ]]; then
      http_request_ok=false
      continue
    fi
    break
  done

  if [[ -n "$location" ]]; then
    classify_redirect "$domain" "$location"
    redirect_status=$REDIRECT_STATUS
    redirect_detail=$REDIRECT_DETAIL
  elif [[ "$http_request_ok" == true &&
    "$http_status" =~ ^(301|302|303|307|308)$ ]]; then
    redirect_status='WARN'
    redirect_detail='缺少 Location'
  fi

  if [[ "$dns_status" == 'FAIL' || "$tcp_status" == 'FAIL' ||
    "$tls_status" == 'FAIL' || "$x25519_status" == 'FAIL' ||
    "$h2_status" == 'FAIL' || "$certificate_status" == 'FAIL' ||
    "$redirect_status" == 'FAIL' ]]; then
    final_status='FAIL'
  fi

  if [[ "$redirect_status" == 'WARN' ]]; then
    append_reason "跳转：$redirect_detail"
    [[ "$final_status" == 'FAIL' ]] || final_status='WARN'
  elif [[ "$redirect_status" == 'FAIL' ]]; then
    append_reason "不允许的跳转：$redirect_detail"
  fi

  if [[ "$http_request_ok" != true ]]; then
    if [[ "$tls_status" == 'PASS' && "$x25519_status" == 'PASS' &&
      "$h2_status" == 'PASS' && "$certificate_status" == 'PASS' ]]; then
      append_reason 'HTTP 请求失败'
      [[ "$final_status" == 'FAIL' ]] || final_status='WARN'
    fi
  else
    case "$http_status" in
      200|204|301|302|303|307|308|404)
        ;;
      401|403|429)
        append_reason "HTTP $http_status"
        [[ "$final_status" == 'FAIL' ]] || final_status='WARN'
        ;;
      5??)
        append_reason "HTTP $http_status（连续 3 次 5xx）"
        [[ "$final_status" == 'FAIL' ]] || final_status='WARN'
        ;;
      *)
        append_reason "HTTP $http_status"
        [[ "$final_status" == 'FAIL' ]] || final_status='WARN'
        ;;
    esac
  fi

  [[ -n "$REASONS" ]] || REASONS='-'
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$domain" "$ip" "$tls_status" "$x25519_status" "$h2_status" \
    "$handshake_ms" "$certificate_status" "$http_status" "$redirect_detail" \
    "$final_status" "$REASONS" >"$result_file"
}

remove_worker_pid() {
  local completed_pid=$1
  local pid
  local -a remaining=()
  for pid in "${WORKER_PIDS[@]}"; do
    [[ "$pid" == "$completed_pid" ]] || remaining+=("$pid")
  done
  WORKER_PIDS=("${remaining[@]}")
}

wait_for_one_worker() {
  local completed_pid=''
  if wait -n -p completed_pid "${WORKER_PIDS[@]}"; then
    :
  else
    :
  fi
  [[ -n "$completed_pid" ]] || return 1
  remove_worker_pid "$completed_pid"
}

terminate_workers() {
  local pid
  for pid in "${WORKER_PIDS[@]}"; do
    kill -TERM "$pid" 2>/dev/null || :
  done
  for pid in "${WORKER_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || :
  done
  WORKER_PIDS=()
}

cleanup() {
  local exit_code=$?
  trap - EXIT ERR INT TERM
  terminate_workers
  if [[ -n "$TEMP_DIR" && "$TEMP_DIR" == /* && -d "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
  exit "$exit_code"
}

handle_interrupt() {
  trap - INT TERM
  terminate_workers
  exit 130
}

handle_internal_error() {
  local exit_code=$?
  trap - ERR
  printf '%s: internal error (exit %d).\n' "$PROGRAM_NAME" "$exit_code" >&2
  exit 2
}

check_dependencies() {
  local command_name
  local -a missing=()
  local -a required=(
    bash openssl curl timeout awk sed grep mktemp getent
  )

  for command_name in "${required[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
  done
  if (( ${#missing[@]} > 0 )); then
    printf '%s: missing required command(s): %s\n' \
      "$PROGRAM_NAME" "${missing[*]}" >&2
    exit 2
  fi
}

initialize_colors() {
  if [[ -t 1 && -t 2 && -z ${NO_COLOR+x} ]]; then
    COLOR_ENABLED=true
  fi
}

print_colored_status() {
  local status=$1
  local color=''
  if [[ "$COLOR_ENABLED" == true ]]; then
    case "$status" in
      PASS) color='32' ;;
      WARN) color='33' ;;
      FAIL) color='31' ;;
    esac
  fi
  if [[ -n "$color" ]]; then
    printf '\033[%sm%s\033[0m' "$color" "$status"
  else
    printf '%s' "$status"
  fi
}

print_results() {
  local index
  local domain
  local ip
  local tls_status
  local x25519_status
  local h2_status
  local handshake_ms
  local certificate_status
  local http_status
  local redirect_detail
  local final_status
  local reasons

  printf '域名 | IP | TLS1.3 | X25519 | H2 | 握手 | 证书 | HTTP | 跳转 | 结果\n'
  for index in "${!DOMAIN_INPUTS[@]}"; do
    IFS=$'\t' read -r domain ip tls_status x25519_status h2_status \
      handshake_ms certificate_status http_status redirect_detail final_status \
      reasons <"$TEMP_DIR/result-$index"
    RESULT_STATUSES+=("$final_status")
    printf '%s | %s | %s | %s | %s | %s | %s | %s | %s | ' \
      "$domain" "$ip" "$tls_status" "$x25519_status" "$h2_status" \
      "$handshake_ms" "$certificate_status" "$http_status" "$redirect_detail"
    print_colored_status "$final_status"
    printf '\n'
  done

  for index in "${!DOMAIN_INPUTS[@]}"; do
    IFS=$'\t' read -r domain ip tls_status x25519_status h2_status \
      handshake_ms certificate_status http_status redirect_detail final_status \
      reasons <"$TEMP_DIR/result-$index"
    if [[ "$reasons" != '-' ]]; then
      printf -- '- %s: %s\n' "$domain" "$reasons"
    fi
  done
}

main() {
  local index
  local final_exit_code=0

  if (( $# != 1 )) || ! parse_domain_argument "$1"; then
    print_usage
    exit 2
  fi
  check_dependencies
  initialize_colors

  if ! TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/domain-check.XXXXXXXX"); then
    printf '%s: unable to create temporary directory.\n' "$PROGRAM_NAME" >&2
    exit 2
  fi
  [[ -n "$TEMP_DIR" && "$TEMP_DIR" == /* && -d "$TEMP_DIR" ]] || {
    printf '%s: unable to create temporary directory.\n' "$PROGRAM_NAME" >&2
    exit 2
  }

  trap cleanup EXIT
  trap handle_interrupt INT TERM
  trap handle_internal_error ERR

  for index in "${!DOMAIN_INPUTS[@]}"; do
    check_domain "$index" "${DOMAIN_INPUTS[$index]}" &
    WORKER_PIDS+=("$!")
    if (( ${#WORKER_PIDS[@]} >= MAX_CONCURRENCY )); then
      wait_for_one_worker
    fi
  done
  while (( ${#WORKER_PIDS[@]} > 0 )); do
    wait_for_one_worker
  done

  for index in "${!DOMAIN_INPUTS[@]}"; do
    if [[ ! -s "$TEMP_DIR/result-$index" ]]; then
      printf '%s: worker failed for %s.\n' \
        "$PROGRAM_NAME" "${DOMAIN_INPUTS[$index]}" >&2
      exit 2
    fi
  done

  print_results
  if ! aggregate_exit_code "${RESULT_STATUSES[@]}"; then
    final_exit_code=1
  fi
  exit "$final_exit_code"
}

if [[ ${DOMAIN_CHECK_SOURCE_ONLY:-0} != '1' ]]; then
  main "$@"
fi
