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
REDIRECT_CODE='-'
HTTP_REQUEST_OK=false
HTTP_CODE=''
HTTP_STATUS='-'
HTTP_LOCATION=''
HTTP_5XX_COUNT=0
HTTP_SHOULD_RETRY=false
HTTP_RESULT_STATUS='PASS'
HTTP_RESULT_REASON=''
BORDER_HORIZONTAL='-'
BORDER_VERTICAL='|'
BORDER_TOP_LEFT='+'
BORDER_TOP_MIDDLE='+'
BORDER_TOP_RIGHT='+'
BORDER_MIDDLE_LEFT='+'
BORDER_MIDDLE_MIDDLE='+'
BORDER_MIDDLE_RIGHT='+'
BORDER_BOTTOM_LEFT='+'
BORDER_BOTTOM_MIDDLE='+'
BORDER_BOTTOM_RIGHT='+'
TABLE_TOTAL_WIDTH=0
declare -a TABLE_WIDTHS=()
readonly -a TABLE_HEADERS=(
  'DOMAIN' 'IP' 'TLS1.3' 'X25519' 'H2'
  'TLS(ms)' 'CERT' 'HTTP' 'REDIRECT' 'RESULT'
)
readonly -a TABLE_MIN_WIDTHS=(18 15 6 6 4 7 5 4 8 6)
readonly -a TABLE_MAX_WIDTHS=(48 39 0 0 0 0 0 0 0 0)

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
  REDIRECT_CODE='-'
  location=$(trim_location "$location")
  [[ -n "$location" ]] || return 0

  if [[ "$location" == *$'\n'* || "$location" == *$'\r'* ||
    "$location" == *$'\t'* ]]; then
    REDIRECT_STATUS='WARN'
    REDIRECT_DETAIL='无法解析'
    REDIRECT_CODE='INVALID'
    return 0
  fi

  if [[ "$location" == //* ]]; then
    location="https:$location"
  elif [[ ! "$location" =~ ^[Hh][Tt][Tt][Pp][Ss]?:// ]]; then
    REDIRECT_STATUS='WARN'
    REDIRECT_DETAIL='相对路径'
    REDIRECT_CODE='RELATIVE'
    return 0
  fi

  if [[ ! "$location" =~ ^([Hh][Tt][Tt][Pp][Ss]?)://([^/?#]+)(.*)$ ]]; then
    REDIRECT_STATUS='WARN'
    REDIRECT_DETAIL='无法解析'
    REDIRECT_CODE='INVALID'
    return 0
  fi
  scheme=${BASH_REMATCH[1],,}
  authority=${BASH_REMATCH[2]}
  remainder=${BASH_REMATCH[3]}

  if [[ "$scheme" == 'http' ]]; then
    REDIRECT_STATUS='FAIL'
    REDIRECT_DETAIL='降级 HTTP'
    REDIRECT_CODE='HTTP'
    return 0
  fi
  if [[ "$authority" == *[[:space:]]* ||
    "$remainder" == *$'\n'* || "$remainder" == *$'\r'* ]]; then
    REDIRECT_STATUS='WARN'
    REDIRECT_DETAIL='无法解析'
    REDIRECT_CODE='INVALID'
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
      REDIRECT_CODE='INVALID'
      return 0
    fi
  else
    if [[ "$authority" == *:* ]]; then
      [[ "$authority" != *:*:* ]] || {
        REDIRECT_STATUS='WARN'
        REDIRECT_DETAIL='无法解析'
        REDIRECT_CODE='INVALID'
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
    REDIRECT_CODE='INVALID'
    return 0
  fi
  if [[ -z "$host" || "$host" == *[[:space:]/?#]* ]]; then
    REDIRECT_STATUS='WARN'
    REDIRECT_DETAIL='无法解析'
    REDIRECT_CODE='INVALID'
    return 0
  fi

  if [[ "$host" == "$domain" ]]; then
    REDIRECT_STATUS='WARN'
    if [[ "$userinfo_present" == true ]]; then
      REDIRECT_DETAIL='同主机（含用户信息）'
    else
      REDIRECT_DETAIL='同主机'
    fi
    REDIRECT_CODE='SAME'
  elif [[ "$domain" != www.* && "$host" == "www.$domain" ]] ||
    [[ "$domain" == www.* && "$host" == "${domain#www.}" ]]; then
    REDIRECT_STATUS='WARN'
    REDIRECT_DETAIL='www 切换'
    REDIRECT_CODE='WWW'
  else
    REDIRECT_STATUS='FAIL'
    REDIRECT_DETAIL='跨主机'
    REDIRECT_CODE='CROSS'
  fi
}

aggregate_exit_code() {
  local status
  for status in "$@"; do
    [[ "$status" != 'FAIL' ]] || return 1
  done
  return 0
}

reset_http_retry_state() {
  HTTP_REQUEST_OK=false
  HTTP_CODE=''
  HTTP_STATUS='-'
  HTTP_LOCATION=''
  HTTP_5XX_COUNT=0
  HTTP_SHOULD_RETRY=false
}

record_http_attempt() {
  local attempt=$1
  local request_ok=$2
  local status=$3
  local location=$4

  HTTP_REQUEST_OK=false
  HTTP_CODE=''
  HTTP_STATUS='-'
  HTTP_LOCATION=''
  HTTP_SHOULD_RETRY=false

  if [[ "$request_ok" == true && "$status" =~ ^[0-9]{3}$ &&
    "$status" != '000' ]]; then
    HTTP_REQUEST_OK=true
    HTTP_CODE=$status
    HTTP_STATUS=$status
    HTTP_LOCATION=$location
    if [[ "$status" =~ ^5[0-9][0-9]$ ]]; then
      (( HTTP_5XX_COUNT += 1 ))
      (( attempt < 3 )) && HTTP_SHOULD_RETRY=true
    fi
  fi
  return 0
}

analyze_http_redirect() {
  local domain=$1
  local request_ok=$2
  local status=$3
  local location=$4

  REDIRECT_STATUS='PASS'
  REDIRECT_DETAIL='-'
  REDIRECT_CODE='-'
  if [[ "$request_ok" == true && -n "$location" ]]; then
    classify_redirect "$domain" "$location"
  elif [[ "$request_ok" == true &&
    "$status" =~ ^(301|302|303|307|308)$ ]]; then
    REDIRECT_STATUS='WARN'
    REDIRECT_DETAIL='缺少 Location'
    REDIRECT_CODE='NO-LOC'
  fi
}

classify_http_result() {
  local request_ok=$1
  local status=$2
  local consecutive_5xx=$3

  HTTP_RESULT_STATUS='PASS'
  HTTP_RESULT_REASON=''
  if [[ "$request_ok" != true ]]; then
    HTTP_RESULT_STATUS='WARN'
    HTTP_RESULT_REASON='HTTP 请求失败'
    return 0
  fi

  case "$status" in
    200|204|301|302|303|307|308|404)
      ;;
    401|403|429)
      HTTP_RESULT_STATUS='WARN'
      HTTP_RESULT_REASON="HTTP $status"
      ;;
    5??)
      HTTP_RESULT_STATUS='WARN'
      if (( consecutive_5xx == 3 )); then
        HTTP_RESULT_REASON="HTTP $status（连续 3 次 5xx）"
      else
        HTTP_RESULT_REASON="HTTP $status"
      fi
      ;;
    *)
      HTTP_RESULT_STATUS='WARN'
      HTTP_RESULT_REASON="HTTP $status"
      ;;
  esac
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
    function valid_ipv4(value, parts, count, octet_number) {
      count = split(value, parts, ".")
      if (count != 4) {
        return 0
      }
      for (octet_number = 1; octet_number <= 4; octet_number++) {
        if (parts[octet_number] !~ /^[0-9]+$/ ||
          parts[octet_number] > 255) {
          return 0
        }
      }
      return 1
    }
    valid_ipv4($1) { print $1; exit }
  ' "$1"
}

first_ipv6_from_file() {
  awk '$1 ~ /^[0-9A-Fa-f:]+$/ && $1 ~ /:/ { print $1; exit }' "$1"
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
  local redirect_code='-'
  local start_us
  local end_us
  local tls_command_ok=false
  local x25519_command_ok=false
  local http_request_ok=false
  local http_code=''
  local location=''
  local http_5xx_count=0
  local attempt
  local attempt_request_ok
  local attempt_http_code
  local attempt_http_status
  local attempt_location
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
  handshake_ms="$(( (10#$end_us - 10#$start_us + 500) / 1000 ))"

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
      -tls1_3 -groups X25519; then
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

  reset_http_retry_state
  for attempt in 1 2 3; do
    attempt_request_ok=false
    attempt_http_code=''
    attempt_http_status='-'
    attempt_location=''
    http_output_file="$TEMP_DIR/http-output-$index-$attempt"
    http_header_file="$TEMP_DIR/http-header-$index-$attempt"
    if run_network_command "$http_output_file" "$HTTP_TIMEOUT" \
      curl --silent --output /dev/null --dump-header "$http_header_file" \
        --write-out '%{http_code}\n' --connect-timeout 5 --max-time 9 \
        --noproxy '*' --proto '=https' --user-agent "$HTTP_USER_AGENT" \
        "https://$domain/"; then
      attempt_http_code=$(extract_http_code "$http_output_file")
      if [[ "$attempt_http_code" =~ ^[0-9]{3}$ &&
        "$attempt_http_code" != '000' ]]; then
        attempt_request_ok=true
        attempt_http_status=$attempt_http_code
        attempt_location=$(extract_location "$http_header_file")
      fi
    fi
    record_http_attempt "$attempt" "$attempt_request_ok" \
      "$attempt_http_status" "$attempt_location"
    if [[ "$HTTP_SHOULD_RETRY" == true ]]; then
      continue
    fi
    break
  done
  http_request_ok=$HTTP_REQUEST_OK
  http_code=$HTTP_CODE
  http_status=$HTTP_STATUS
  [[ -z "$http_code" ]] || http_status=$http_code
  location=$HTTP_LOCATION
  http_5xx_count=$HTTP_5XX_COUNT

  analyze_http_redirect "$domain" "$http_request_ok" "$http_status" "$location"
  redirect_status=$REDIRECT_STATUS
  redirect_detail=$REDIRECT_DETAIL
  redirect_code=$REDIRECT_CODE

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

  classify_http_result "$http_request_ok" "$http_status" "$http_5xx_count"
  if [[ "$HTTP_RESULT_STATUS" == 'WARN' ]]; then
    if [[ "$http_request_ok" == true ]] ||
      [[ "$tls_status" == 'PASS' && "$x25519_status" == 'PASS' &&
        "$h2_status" == 'PASS' && "$certificate_status" == 'PASS' ]]; then
      append_reason "$HTTP_RESULT_REASON"
      [[ "$final_status" == 'FAIL' ]] || final_status='WARN'
    fi
  fi

  [[ -n "$REASONS" ]] || REASONS='-'
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$domain" "$ip" "$tls_status" "$x25519_status" "$h2_status" \
    "$handshake_ms" "$certificate_status" "$http_status" "$redirect_code" \
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
  COLOR_ENABLED=false
  if [[ -t 1 && -t 2 && -z ${NO_COLOR+x} ]]; then
    COLOR_ENABLED=true
  fi
}

locale_supports_utf8() {
  local effective_locale=${LC_ALL:-${LC_CTYPE:-${LANG:-}}}
  effective_locale=${effective_locale,,}
  [[ "$effective_locale" == *utf-8* || "$effective_locale" == *utf8* ]]
}

initialize_borders() {
  BORDER_HORIZONTAL='-'
  BORDER_VERTICAL='|'
  BORDER_TOP_LEFT='+'
  BORDER_TOP_MIDDLE='+'
  BORDER_TOP_RIGHT='+'
  BORDER_MIDDLE_LEFT='+'
  BORDER_MIDDLE_MIDDLE='+'
  BORDER_MIDDLE_RIGHT='+'
  BORDER_BOTTOM_LEFT='+'
  BORDER_BOTTOM_MIDDLE='+'
  BORDER_BOTTOM_RIGHT='+'

  if [[ -t 1 && -t 2 ]] && locale_supports_utf8; then
    BORDER_HORIZONTAL='─'
    BORDER_VERTICAL='│'
    BORDER_TOP_LEFT='┌'
    BORDER_TOP_MIDDLE='┬'
    BORDER_TOP_RIGHT='┐'
    BORDER_MIDDLE_LEFT='├'
    BORDER_MIDDLE_MIDDLE='┼'
    BORDER_MIDDLE_RIGHT='┤'
    BORDER_BOTTOM_LEFT='└'
    BORDER_BOTTOM_MIDDLE='┴'
    BORDER_BOTTOM_RIGHT='┘'
  fi
}

initialize_output_style() {
  initialize_colors
  initialize_borders
}

plain_cell_width() {
  printf '%d' "${#1}"
}

truncate_ascii() {
  local value=$1
  local maximum_width=$2
  local prefix_width
  if (( ${#value} <= maximum_width )); then
    printf '%s' "$value"
  else
    prefix_width=$(( maximum_width - 3 ))
    printf '%s...' "${value:0:prefix_width}"
  fi
}

repeat_character() {
  local character=$1
  local count=$2
  local character_number
  for (( character_number = 0; character_number < count; character_number++ )); do
    printf '%s' "$character"
  done
}

color_for_status() {
  case "$1" in
    PASS) printf '32' ;;
    WARN) printf '33' ;;
    FAIL) printf '31' ;;
    -) printf '90' ;;
    *) printf '' ;;
  esac
}

color_for_http() {
  case "$1" in
    2??) printf '32' ;;
    3??) printf '36' ;;
    4??) printf '33' ;;
    5??) printf '31' ;;
    -) printf '90' ;;
    *) printf '' ;;
  esac
}

color_for_redirect() {
  case "$1" in
    -) printf '90' ;;
    SAME|WWW|RELATIVE|NO-LOC|INVALID) printf '33' ;;
    CROSS|HTTP) printf '31' ;;
    *) printf '' ;;
  esac
}

color_for_latency() {
  if [[ "$1" == '-' ]]; then
    printf '90'
  else
    printf '36'
  fi
}

print_plain_cell() {
  local value=$1
  local width=$2
  printf ' %-*s ' "$width" "$value"
}

print_colored_text() {
  local value=$1
  local color=$2
  if [[ "$COLOR_ENABLED" == true && -n "$color" ]]; then
    printf '\033[%sm%s\033[0m' "$color" "$value"
  else
    printf '%s' "$value"
  fi
}

print_colored_cell() {
  local value=$1
  local width=$2
  local color=$3
  local padding=$(( width - ${#value} ))

  printf ' '
  print_colored_text "$value" "$color"
  printf '%*s ' "$padding" ''
}

frame_color_begin() {
  [[ "$COLOR_ENABLED" == true ]] && printf '\033[90m'
  return 0
}

frame_color_end() {
  [[ "$COLOR_ENABLED" == true ]] && printf '\033[0m'
  return 0
}

print_frame_piece() {
  frame_color_begin
  printf '%s' "$1"
  frame_color_end
}

update_column_width() {
  local column_number=$1
  local value=$2
  local maximum_width=${TABLE_MAX_WIDTHS[$column_number]}
  local value_width

  value_width=$(plain_cell_width "$value")
  if (( value_width > TABLE_WIDTHS[column_number] )); then
    TABLE_WIDTHS[column_number]=$value_width
  fi
  if (( maximum_width > 0 &&
    TABLE_WIDTHS[column_number] > maximum_width )); then
    TABLE_WIDTHS[column_number]=$maximum_width
  fi
}

calculate_table_widths() {
  local index
  local domain
  local ip
  local tls_status
  local x25519_status
  local h2_status
  local handshake_ms
  local certificate_status
  local http_status
  local redirect_code
  local final_status
  local reasons
  local domain_display
  local column_number
  local width
  local -a values=()

  TABLE_WIDTHS=("${TABLE_MIN_WIDTHS[@]}")
  for column_number in "${!TABLE_HEADERS[@]}"; do
    update_column_width "$column_number" "${TABLE_HEADERS[$column_number]}"
  done

  for index in "${!DOMAIN_INPUTS[@]}"; do
    IFS=$'\t' read -r domain ip tls_status x25519_status h2_status \
      handshake_ms certificate_status http_status redirect_code final_status \
      reasons <"$TEMP_DIR/result-$index"
    domain_display=$(truncate_ascii "$domain" 48)
    values=(
      "$domain_display" "$ip" "$tls_status" "$x25519_status" "$h2_status"
      "$handshake_ms" "$certificate_status" "$http_status" "$redirect_code"
      "$final_status"
    )
    for column_number in "${!values[@]}"; do
      update_column_width "$column_number" "${values[$column_number]}"
    done
  done

  TABLE_TOTAL_WIDTH=1
  for width in "${TABLE_WIDTHS[@]}"; do
    (( TABLE_TOTAL_WIDTH += width + 3 ))
  done
}

print_border_line() {
  local left_character=$1
  local middle_character=$2
  local right_character=$3
  local column_number

  frame_color_begin
  printf '%s' "$left_character"
  for column_number in "${!TABLE_WIDTHS[@]}"; do
    repeat_character "$BORDER_HORIZONTAL" \
      "$(( TABLE_WIDTHS[column_number] + 2 ))"
    if (( column_number + 1 == ${#TABLE_WIDTHS[@]} )); then
      printf '%s' "$right_character"
    else
      printf '%s' "$middle_character"
    fi
  done
  frame_color_end
  printf '\n'
}

print_top_border() {
  print_border_line \
    "$BORDER_TOP_LEFT" "$BORDER_TOP_MIDDLE" "$BORDER_TOP_RIGHT"
}

print_header_separator() {
  print_border_line \
    "$BORDER_MIDDLE_LEFT" "$BORDER_MIDDLE_MIDDLE" "$BORDER_MIDDLE_RIGHT"
}

print_bottom_border() {
  print_border_line \
    "$BORDER_BOTTOM_LEFT" "$BORDER_BOTTOM_MIDDLE" "$BORDER_BOTTOM_RIGHT"
}

print_header_row() {
  local column_number
  print_frame_piece "$BORDER_VERTICAL"
  for column_number in "${!TABLE_HEADERS[@]}"; do
    print_plain_cell \
      "${TABLE_HEADERS[$column_number]}" "${TABLE_WIDTHS[$column_number]}"
    print_frame_piece "$BORDER_VERTICAL"
  done
  printf '\n'
}

print_data_row() {
  local domain
  domain=$(truncate_ascii "$1" 48)
  local ip=$2
  local tls_status=$3
  local x25519_status=$4
  local h2_status=$5
  local handshake_ms=$6
  local certificate_status=$7
  local http_status=$8
  local redirect_code=$9
  local final_status=${10}

  print_frame_piece "$BORDER_VERTICAL"
  print_colored_cell "$domain" "${TABLE_WIDTHS[0]}" '96'
  print_frame_piece "$BORDER_VERTICAL"
  print_plain_cell "$ip" "${TABLE_WIDTHS[1]}"
  print_frame_piece "$BORDER_VERTICAL"
  print_colored_cell \
    "$tls_status" "${TABLE_WIDTHS[2]}" "$(color_for_status "$tls_status")"
  print_frame_piece "$BORDER_VERTICAL"
  print_colored_cell \
    "$x25519_status" "${TABLE_WIDTHS[3]}" "$(color_for_status "$x25519_status")"
  print_frame_piece "$BORDER_VERTICAL"
  print_colored_cell \
    "$h2_status" "${TABLE_WIDTHS[4]}" "$(color_for_status "$h2_status")"
  print_frame_piece "$BORDER_VERTICAL"
  print_colored_cell \
    "$handshake_ms" "${TABLE_WIDTHS[5]}" "$(color_for_latency "$handshake_ms")"
  print_frame_piece "$BORDER_VERTICAL"
  print_colored_cell "$certificate_status" "${TABLE_WIDTHS[6]}" \
    "$(color_for_status "$certificate_status")"
  print_frame_piece "$BORDER_VERTICAL"
  print_colored_cell \
    "$http_status" "${TABLE_WIDTHS[7]}" "$(color_for_http "$http_status")"
  print_frame_piece "$BORDER_VERTICAL"
  print_colored_cell "$redirect_code" "${TABLE_WIDTHS[8]}" \
    "$(color_for_redirect "$redirect_code")"
  print_frame_piece "$BORDER_VERTICAL"
  print_colored_cell \
    "$final_status" "${TABLE_WIDTHS[9]}" "$(color_for_status "$final_status")"
  print_frame_piece "$BORDER_VERTICAL"
  printf '\n'
}

table_has_details() {
  local index
  local reasons
  for index in "${!DOMAIN_INPUTS[@]}"; do
    IFS=$'\t' read -r _ _ _ _ _ _ _ _ _ _ reasons \
      <"$TEMP_DIR/result-$index"
    [[ "$reasons" == '-' ]] || return 0
  done
  return 1
}

print_details_header() {
  local fill_count=$(( TABLE_TOTAL_WIDTH - 12 ))
  frame_color_begin
  printf '%s%s DETAILS ' "$BORDER_MIDDLE_LEFT" "$BORDER_HORIZONTAL"
  repeat_character "$BORDER_HORIZONTAL" "$fill_count"
  printf '%s' "$BORDER_MIDDLE_RIGHT"
  frame_color_end
  printf '\n'
}

print_details_bottom() {
  frame_color_begin
  printf '%s' "$BORDER_BOTTOM_LEFT"
  repeat_character "$BORDER_HORIZONTAL" "$(( TABLE_TOTAL_WIDTH - 2 ))"
  printf '%s' "$BORDER_BOTTOM_RIGHT"
  frame_color_end
  printf '\n'
}

print_details() {
  local index
  local domain
  local reasons
  local domain_display
  local reason_part
  local first_reason
  local -a reason_parts=()

  print_details_header
  for index in "${!DOMAIN_INPUTS[@]}"; do
    IFS=$'\t' read -r domain _ _ _ _ _ _ _ _ _ \
      reasons <"$TEMP_DIR/result-$index"
    if [[ "$reasons" != '-' ]]; then
      domain_display=$(truncate_ascii "$domain" 48)
      IFS=';' read -r -a reason_parts <<<"$reasons"
      first_reason=true
      for reason_part in "${reason_parts[@]}"; do
        reason_part=${reason_part#"${reason_part%%[![:space:]]*}"}
        print_frame_piece "$BORDER_VERTICAL"
        printf ' '
        if [[ "$first_reason" == true ]]; then
          print_colored_text "$domain_display" '96'
          printf ': %s\n' "$reason_part"
          first_reason=false
        else
          printf '  %s\n' "$reason_part"
        fi
      done
    fi
  done
  print_details_bottom
}

print_table() {
  local index
  local domain
  local ip
  local tls_status
  local x25519_status
  local h2_status
  local handshake_ms
  local certificate_status
  local http_status
  local redirect_code
  local final_status
  local reasons

  RESULT_STATUSES=()
  print_top_border
  print_header_row
  print_header_separator
  for index in "${!DOMAIN_INPUTS[@]}"; do
    IFS=$'\t' read -r domain ip tls_status x25519_status h2_status \
      handshake_ms certificate_status http_status redirect_code final_status \
      reasons <"$TEMP_DIR/result-$index"
    RESULT_STATUSES+=("$final_status")
    print_data_row \
      "$domain" "$ip" "$tls_status" "$x25519_status" "$h2_status" \
      "$handshake_ms" "$certificate_status" "$http_status" "$redirect_code" \
      "$final_status"
  done

  if table_has_details; then
    print_details
  else
    print_bottom_border
  fi
}

print_results() {
  calculate_table_widths
  print_table
}

main() {
  local index
  local final_exit_code=0

  if (( $# != 1 )) || ! parse_domain_argument "$1"; then
    print_usage
    exit 2
  fi
  check_dependencies
  initialize_output_style

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
