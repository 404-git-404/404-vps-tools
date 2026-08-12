#!/usr/bin/env bash

set -Eeuo pipefail

readonly PROGRAM_NAME='domain-check'
readonly USAGE_TEXT='Usage: domain-check domain1.com/domain2.com/domain3.com'
readonly MAX_CONCURRENCY=8
readonly DOMAIN_HARD_TIMEOUT=90
readonly DOMAIN_TERMINATE_GRACE=2
readonly DNS_TIMEOUT=6
readonly TCP_TIMEOUT=6
readonly TLS_TIMEOUT=4
readonly HTTP_TIMEOUT=10
readonly HTTP_USER_AGENT='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0 Safari/537.36'

declare -a DOMAIN_INPUTS=()
declare -a WORKER_PIDS=()
declare -A WORKER_INDEX_BY_PID=()
declare -a RESULT_STATUSES=()
TEMP_DIR=''
COLOR_ENABLED=false
ACTIVE_PID=''
ACTIVE_PID_FILE=''
DOMAIN_CHILD_PID=''
DOMAIN_TIMER_PID=''
DOMAIN_ACTIVE_PID_FILE=''
READY_SAMPLE_LOCK_HELD=false
COMPLETED_COUNT=0
PROGRESS_WIDTH=0
REASONS=''
REDIRECT_STATUS='PASS'
REDIRECT_DETAIL='-'
REDIRECT_CODE='-'
HTTP_REQUEST_OK=false
HTTP_CODE=''
HTTP_STATUS='-'
HTTP_LOCATION=''
HTTP_5XX_COUNT=0
HTTP_FINALIZED=false
HTTP_HEADER_FILE=''
HTTP_RESULT_STATUS='PASS'
HTTP_RESULT_REASON=''
READY_MS='-'
READY_SAMPLE_COUNT=0
CDN_STATUS='-'
CDN_DETAIL=''
CERTIFICATE_EXPIRY_STATUS='PASS'
CERTIFICATE_DAYS='-'
CERTIFICATE_WARNING=''
HTML_LOG_PATH=''
HTML_ESCAPED_VALUE=''
HTML_CSS_CLASS=''
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
  'READY(ms)' 'CERT(d)' 'CDN' 'HTTP' 'REDIRECT' 'RESULT'
)
readonly -a TABLE_MIN_WIDTHS=(18 15 6 6 4 9 7 4 4 8 6)
readonly -a TABLE_MAX_WIDTHS=(48 39 0 0 0 0 0 0 0 0 0)

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
    REDIRECT_STATUS='WARN'
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
    REDIRECT_STATUS='WARN'
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
  HTTP_FINALIZED=false
  HTTP_HEADER_FILE=''
}

record_http_attempt() {
  local attempt=$1
  local request_ok=$2
  local status=$3
  local location=$4
  local header_file=${5:-}

  if [[ "$HTTP_FINALIZED" == true ]]; then
    return 0
  fi
  HTTP_REQUEST_OK=false
  HTTP_CODE=''
  HTTP_STATUS='-'
  HTTP_LOCATION=''
  HTTP_HEADER_FILE=''

  if [[ "$request_ok" == true && "$status" =~ ^[0-9]{3}$ &&
    "$status" != '000' ]]; then
    HTTP_REQUEST_OK=true
    HTTP_CODE=$status
    HTTP_STATUS=$status
    HTTP_LOCATION=$location
    HTTP_HEADER_FILE=$header_file
    if [[ "$status" =~ ^5[0-9][0-9]$ ]]; then
      (( HTTP_5XX_COUNT += 1 ))
      if (( attempt >= 3 )); then
        HTTP_FINALIZED=true
      fi
    else
      HTTP_FINALIZED=true
    fi
  elif (( attempt >= 3 )); then
    HTTP_FINALIZED=true
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

curl_failure_is_deterministic() {
  case ${1:-} in
    1|2|3|4|35|51|58|59|60|77|90|91)
      return 0
      ;;
  esac
  return 1
}

append_reason() {
  local reason=$1
  if [[ -n "$REASONS" ]]; then
    REASONS+="; $reason"
  else
    REASONS=$reason
  fi
}

release_ready_sample_lock_for_pid() {
  local owner_pid=$1
  local lock_dir="$TEMP_DIR/ready-sample-lock"
  local owner_file="$lock_dir/owner"
  local recorded_pid=''

  [[ -r "$owner_file" ]] || return 0
  IFS= read -r recorded_pid <"$owner_file" || :
  [[ "$recorded_pid" == "$owner_pid" ]] || return 0
  rm -f -- "$owner_file"
  rmdir -- "$lock_dir" 2>/dev/null || :
}

release_ready_sample_lock() {
  if [[ "$READY_SAMPLE_LOCK_HELD" == true ]]; then
    release_ready_sample_lock_for_pid "$BASHPID"
    READY_SAMPLE_LOCK_HELD=false
  fi
}

acquire_ready_sample_lock() {
  local lock_dir="$TEMP_DIR/ready-sample-lock"

  while ! mkdir -- "$lock_dir" 2>/dev/null; do
    sleep 0.05
  done
  printf '%s\n' "$BASHPID" >"$lock_dir/owner"
  READY_SAMPLE_LOCK_HELD=true
}

terminate_pid_with_grace() {
  local pid=$1
  local ticks=0
  local max_ticks=$(( DOMAIN_TERMINATE_GRACE * 10 ))

  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  kill -TERM "$pid" 2>/dev/null || return 0
  while kill -0 "$pid" 2>/dev/null && (( ticks < max_ticks )); do
    sleep 0.1
    (( ticks += 1 ))
  done
  kill -KILL "$pid" 2>/dev/null || :
}

run_network_command() {
  local output_file=$1
  local timeout_seconds=$2
  local status
  shift 2

  timeout --signal=TERM --kill-after=2 "$timeout_seconds" \
    "$@" </dev/null >"$output_file" 2>&1 &
  ACTIVE_PID=$!
  if [[ -n "$ACTIVE_PID_FILE" ]]; then
    printf '%s\n' "$ACTIVE_PID" >"$ACTIVE_PID_FILE"
  fi
  if wait "$ACTIVE_PID"; then
    status=0
  else
    status=$?
  fi
  ACTIVE_PID=''
  [[ -z "$ACTIVE_PID_FILE" ]] || rm -f -- "$ACTIVE_PID_FILE"
  return "$status"
}

worker_signal() {
  trap - INT TERM
  if [[ -n "$ACTIVE_PID" ]]; then
    terminate_pid_with_grace "$ACTIVE_PID"
    wait "$ACTIVE_PID" 2>/dev/null || :
  fi
  ACTIVE_PID=''
  [[ -z "$ACTIVE_PID_FILE" ]] || rm -f -- "$ACTIVE_PID_FILE"
  release_ready_sample_lock
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
  awk -F '\t' '
    $1 == "DOMAIN_CHECK_METRICS" { code = $2 }
    /^[0-9][0-9][0-9]$/ { code = $0 }
    END { print code }
  ' "$1"
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

extract_curl_metric() {
  local output_file=$1
  local field_number=$2
  awk -F '\t' -v field_number="$field_number" '
    $1 == "DOMAIN_CHECK_METRICS" { value = $field_number }
    END { print value }
  ' "$output_file"
}

seconds_to_milliseconds() {
  awk -v seconds="$1" '
    BEGIN {
      if (seconds !~ /^([0-9]+([.][0-9]*)?|[.][0-9]+)$/) {
        exit 1
      }
      printf "%.0f\n", seconds * 1000
    }
  '
}

positive_seconds() {
  awk -v seconds="$1" '
    BEGIN {
      exit !(seconds ~ /^([0-9]+([.][0-9]*)?|[.][0-9]+)$/ && seconds > 0)
    }
  '
}

aggregate_ready_samples() {
  local -a valid_samples=()
  local sample

  for sample in "$@"; do
    [[ "$sample" =~ ^[0-9]+$ ]] && valid_samples+=("$sample")
  done

  READY_SAMPLE_COUNT=${#valid_samples[@]}
  case "$READY_SAMPLE_COUNT" in
    0)
      READY_MS='-'
      ;;
    1)
      READY_MS=${valid_samples[0]}
      ;;
    2)
      READY_MS=$(awk -v first="${valid_samples[0]}" \
        -v second="${valid_samples[1]}" \
        'BEGIN { printf "%.0f\n", (first + second) / 2 }')
      ;;
    3)
      READY_MS=$(awk -v first="${valid_samples[0]}" \
        -v second="${valid_samples[1]}" -v third="${valid_samples[2]}" '
          BEGIN {
            if (first > second) {
              temporary = first
              first = second
              second = temporary
            }
            if (second > third) {
              temporary = second
              second = third
              third = temporary
            }
            if (first > second) {
              second = first
            }
            printf "%.0f\n", second
          }
        ')
      ;;
  esac
}

openssl_target_for_ip() {
  local ip=$1
  if [[ "$ip" == *:* ]]; then
    printf '[%s]:443' "$ip"
  else
    printf '%s:443' "$ip"
  fi
}

curl_resolve_for_ip() {
  local domain=$1
  local ip=$2
  if [[ "$ip" == *:* ]]; then
    printf '%s:443:[%s]' "$domain" "$ip"
  else
    printf '%s:443:%s' "$domain" "$ip"
  fi
}

tls13_evidence_present() {
  grep -Eqi '(^|[^[:alnum:]_.])TLSv1\.3([^[:alnum:]_.]|$)' \
    "$1"
}

h2_evidence_present() {
  grep -Eqi '^ALPN protocol:[[:space:]]*h2\r?$' "$1"
}

certificate_verified_evidence_present() {
  grep -Eqi '^Verify return code:[[:space:]]*0[[:space:]]+\(ok\)\r?$' "$1"
}

x25519_evidence_present() {
  tls13_evidence_present "$1" &&
    grep -Eqi '^[[:space:]]*(Peer|Server)[[:space:]]+(Temp Key|temporary key):[[:space:]]*X25519([,[:space:]]|$)' \
      "$1"
}

extract_leaf_certificate() {
  local input_file=$1
  local certificate_file=$2
  awk '
    /-----BEGIN CERTIFICATE-----/ && !copying {
      copying = 1
    }
    copying {
      print
    }
    /-----END CERTIFICATE-----/ && copying {
      complete = 1
      exit
    }
    END {
      if (!complete) {
        exit 1
      }
    }
  ' "$input_file" >"$certificate_file"
}

evaluate_certificate_expiry() {
  local expiry_epoch=${1:-}
  local current_epoch=${2:-}

  CERTIFICATE_EXPIRY_STATUS='PASS'
  CERTIFICATE_DAYS='-'
  CERTIFICATE_WARNING=''
  if [[ ! "$expiry_epoch" =~ ^[0-9]+$ ||
    ! "$current_epoch" =~ ^[0-9]+$ ]]; then
    CERTIFICATE_WARNING='证书已验证，但无法提取到期日'
  elif (( expiry_epoch < current_epoch )); then
    CERTIFICATE_EXPIRY_STATUS='FAIL'
    CERTIFICATE_DAYS='FAIL'
    CERTIFICATE_WARNING='证书已过期'
  else
    CERTIFICATE_DAYS=$(( (expiry_epoch - current_epoch) / 86400 ))
    if (( CERTIFICATE_DAYS <= 7 )); then
      CERTIFICATE_WARNING="证书仅剩 ${CERTIFICATE_DAYS} 个完整日"
    fi
  fi
}

first_cname_from_file() {
  awk '
    $1 ~ /^[A-Za-z0-9._-]+[.]?$/ {
      value = tolower($1)
      sub(/[.]$/, "", value)
      if (!first_value) {
        first_value = value
      }
      if (value ~ /[.](cloudflare[.]net|cloudfront[.]net|akamai[.]net|akamaiedge[.]net|akamaitechnologies[.]com|edgekey[.]net|edgesuite[.]net|azurefd[.]net|fastly[.]net|fastlylb[.]net|b-cdn[.]net|gcdn[.]co)$/) {
        print value
        found = 1
        exit
      }
    }
    END {
      if (!found) {
        print first_value
      }
    }
  ' "$1"
}

detect_cdn() {
  local cname=${1,,}
  local header_file=$2
  local has_via=false
  local has_x_cache=false
  local has_fastly_served_by=false

  CDN_STATUS='-'
  CDN_DETAIL=''

  case "$cname" in
    *.cloudflare.net)
      CDN_STATUS='HIGH'
      CDN_DETAIL="Cloudflare（CNAME: $cname）"
      return 0
      ;;
    *.cloudfront.net)
      CDN_STATUS='HIGH'
      CDN_DETAIL="CloudFront（CNAME: $cname）"
      return 0
      ;;
    *.akamai.net|*.akamaiedge.net|*.akamaitechnologies.com|*.edgekey.net|*.edgesuite.net)
      CDN_STATUS='HIGH'
      CDN_DETAIL="Akamai（CNAME: $cname）"
      return 0
      ;;
    *.azurefd.net)
      CDN_STATUS='HIGH'
      CDN_DETAIL="Azure Front Door（CNAME: $cname）"
      return 0
      ;;
    *.fastly.net|*.fastlylb.net)
      CDN_STATUS='HIGH'
      CDN_DETAIL="Fastly（CNAME: $cname）"
      return 0
      ;;
    *.b-cdn.net)
      CDN_STATUS='HIGH'
      CDN_DETAIL="Bunny CDN（CNAME: $cname）"
      return 0
      ;;
    *.gcdn.co)
      CDN_STATUS='HIGH'
      CDN_DETAIL="Gcore（CNAME: $cname）"
      return 0
      ;;
  esac

  [[ -s "$header_file" ]] || return 0
  if grep -Eqi '^cf-ray:' "$header_file"; then
    CDN_STATUS='HIGH'
    CDN_DETAIL='Cloudflare（CF-Ray）'
  elif grep -Eqi '^cf-cache-status:' "$header_file"; then
    CDN_STATUS='HIGH'
    CDN_DETAIL='Cloudflare（CF-Cache-Status）'
  elif grep -Eqi '^x-amz-cf-id:' "$header_file"; then
    CDN_STATUS='HIGH'
    CDN_DETAIL='CloudFront（X-Amz-Cf-Id）'
  elif grep -Eqi '^x-amz-cf-pop:' "$header_file"; then
    CDN_STATUS='HIGH'
    CDN_DETAIL='CloudFront（X-Amz-Cf-Pop）'
  elif grep -Eqi '^x-akamai-transformed:' "$header_file"; then
    CDN_STATUS='HIGH'
    CDN_DETAIL='Akamai（X-Akamai-Transformed）'
  elif grep -Eqi '^akamai-grn:' "$header_file"; then
    CDN_STATUS='HIGH'
    CDN_DETAIL='Akamai（Akamai-GRN）'
  elif grep -Eqi '^x-azure-ref:' "$header_file"; then
    CDN_STATUS='HIGH'
    CDN_DETAIL='Azure Front Door（X-Azure-Ref）'
  else
    grep -Eqi '^via:' "$header_file" && has_via=true
    grep -Eqi '^x-cache:' "$header_file" && has_x_cache=true
    grep -Eqi '^x-served-by:' "$header_file" && has_fastly_served_by=true
    if [[ "$has_fastly_served_by" == true && "$has_x_cache" == true ]]; then
      CDN_STATUS='HIGH'
      CDN_DETAIL='Fastly（x-served-by + x-cache）'
    elif [[ "$has_fastly_served_by" == true ]]; then
      CDN_STATUS='MED'
      CDN_DETAIL='Fastly（单一弱特征响应头）'
    elif [[ "$has_via" == true && "$has_x_cache" == true ]]; then
      CDN_STATUS='MED'
      CDN_DETAIL='缓存代理（Via + X-Cache）'
    fi
  fi
}

check_domain() {
  local index=$1
  local domain=$2
  local result_file="$TEMP_DIR/result-$index"
  local ipv4=''
  local ipv6=''
  local cname=''
  local ip='-'
  local dns_status='FAIL'
  local tcp_status='FAIL'
  local tls_status='FAIL'
  local x25519_status='FAIL'
  local h2_status='FAIL'
  local certificate_status='FAIL'
  local certificate_days='FAIL'
  local certificate_warning=''
  local ready_ms='-'
  local ready_sample_count=0
  local cdn_status='-'
  local cdn_detail=''
  local http_status='-'
  local final_status='PASS'
  local redirect_status='PASS'
  local redirect_detail='-'
  local redirect_code='-'
  local http_request_ok=false
  local http_code=''
  local location=''
  local http_5xx_count=0
  local http_command_ok=false
  local http_command_status=0
  local http_check_attempted=false
  local ready_command_status=0
  local ready_check_attempted=false
  local tls_command_ok=false
  local tls_handshake_available=false
  local x25519_command_ok=false
  local openssl_target=''
  local curl_resolve=''
  local attempt
  local attempt_request_ok
  local attempt_http_code
  local attempt_http_status
  local attempt_location
  local attempt_time_connect
  local attempt_time_appconnect
  local attempt_ready_ms
  local final_header_file=''
  local certificate_enddate=''
  local expiry_epoch=''
  local current_epoch=''
  local -a ready_samples=()
  local -a curl_common_args=()
  local -a curl_address_family=()
  local ready_output_file
  local dns_a_file="$TEMP_DIR/dns-a-$index"
  local dns_aaaa_file="$TEMP_DIR/dns-aaaa-$index"
  local dns_cname_file="$TEMP_DIR/dns-cname-$index"
  local tcp_file="$TEMP_DIR/tcp-$index"
  local tls_file="$TEMP_DIR/tls-$index"
  local x25519_file="$TEMP_DIR/x25519-$index"
  local leaf_certificate_file="$TEMP_DIR/leaf-certificate-$index"
  local http_output_file
  local http_header_file

  trap - EXIT ERR
  trap worker_signal INT TERM
  ACTIVE_PID_FILE="$TEMP_DIR/active-pid-$index"
  READY_SAMPLE_LOCK_HELD=false
  REASONS=''

  if command -v dig >/dev/null 2>&1; then
    run_network_command "$dns_a_file" "$DNS_TIMEOUT" \
      dig +time=5 +tries=1 +short A "$domain" || :
    run_network_command "$dns_aaaa_file" "$DNS_TIMEOUT" \
      dig +time=5 +tries=1 +short AAAA "$domain" || :
    run_network_command "$dns_cname_file" "$DNS_TIMEOUT" \
      dig +time=5 +tries=1 +short CNAME "$domain" || :
  else
    run_network_command "$dns_a_file" "$DNS_TIMEOUT" \
      getent ahostsv4 "$domain" || :
    run_network_command "$dns_aaaa_file" "$DNS_TIMEOUT" \
      getent ahostsv6 "$domain" || :
    printf '' >"$dns_cname_file"
  fi
  ipv4=$(first_ipv4_from_file "$dns_a_file")
  ipv6=$(first_ipv6_from_file "$dns_aaaa_file")
  cname=$(first_cname_from_file "$dns_cname_file")
  if [[ -n "$ipv4" ]]; then
    ip=$ipv4
    dns_status='PASS'
  elif [[ -n "$ipv6" ]]; then
    ip=$ipv6
    dns_status='PASS'
  else
    append_reason 'DNS 无法解析'
  fi

  reset_http_retry_state
  if [[ "$dns_status" == 'PASS' ]]; then
    if run_network_command "$tcp_file" "$TCP_TIMEOUT" \
      bash -c "exec 3<>\"/dev/tcp/\$1/443\"; exec 3<&-; exec 3>&-" \
        bash "$ip"; then
      tcp_status='PASS'
    fi

    if [[ "$tcp_status" == 'PASS' ]]; then
      openssl_target=$(openssl_target_for_ip "$ip")
      curl_resolve=$(curl_resolve_for_ip "$domain" "$ip")
      if [[ "$ip" == *:* ]]; then
        curl_address_family=(--ipv6)
      else
        curl_address_family=(--ipv4)
      fi
      curl_common_args=(
        "${curl_address_family[@]}"
        --silent --show-error --output /dev/null
        --connect-timeout 5 --max-time 9 --no-keepalive
        --header 'Connection: close' --noproxy '*' --proto '=https'
        --tlsv1.3 --tls-max 1.3 --resolve "$curl_resolve"
        --user-agent "$HTTP_USER_AGENT" "https://$domain/"
      )

      if run_network_command "$tls_file" "$TLS_TIMEOUT" \
        openssl s_client -connect "$openssl_target" -servername "$domain" \
          -tls1_3 -alpn h2 -verify_hostname "$domain" -verify_return_error \
          -showcerts; then
        tls_command_ok=true
      fi

      if tls13_evidence_present "$tls_file"; then
        tls_handshake_available=true
        tcp_status='PASS'
      fi
      if [[ "$tls_command_ok" == true &&
        "$tls_handshake_available" == true ]]; then
        tls_status='PASS'
        tcp_status='PASS'
      fi
      if [[ "$tls_command_ok" == true ]] &&
        h2_evidence_present "$tls_file"; then
        h2_status='PASS'
      fi
      if [[ "$tls_command_ok" == true ]] &&
        certificate_verified_evidence_present "$tls_file"; then
        certificate_status='PASS'
        if extract_leaf_certificate "$tls_file" "$leaf_certificate_file" &&
          certificate_enddate=$(openssl x509 -noout -enddate \
            -in "$leaf_certificate_file" 2>/dev/null) &&
          [[ "$certificate_enddate" == notAfter=* ]] &&
          expiry_epoch=$(date -u -d "${certificate_enddate#notAfter=}" +%s \
            2>/dev/null) &&
          current_epoch=$(date -u +%s); then
          evaluate_certificate_expiry "$expiry_epoch" "$current_epoch"
        else
          evaluate_certificate_expiry
        fi
        certificate_status=$CERTIFICATE_EXPIRY_STATUS
        certificate_days=$CERTIFICATE_DAYS
        certificate_warning=$CERTIFICATE_WARNING
      fi

      if [[ "$tls_handshake_available" == true ]]; then
        if run_network_command "$x25519_file" "$TLS_TIMEOUT" \
          openssl s_client -connect "$openssl_target" -servername "$domain" \
            -tls1_3 -groups X25519; then
          x25519_command_ok=true
        fi
        if [[ "$x25519_command_ok" == true ]] &&
          x25519_evidence_present "$x25519_file"; then
          x25519_status='PASS'
          tcp_status='PASS'
        fi

        # READY deliberately skips CA verification for timing purposes.
        # Certificate trust, hostname, and expiry are validated separately by
        # the strict OpenSSL check above. Acquire the global lock per sample so
        # a failing target cannot monopolize it across three timeouts.
        ready_check_attempted=true
        for attempt in 1 2 3; do
          attempt_time_appconnect=''
          ready_command_status=0
          ready_output_file="$TEMP_DIR/ready-output-$index-$attempt"
          acquire_ready_sample_lock
          if run_network_command "$ready_output_file" "$HTTP_TIMEOUT" \
            curl --insecure \
              --write-out 'DOMAIN_CHECK_METRICS\t%{http_code}\t%{time_connect}\t%{time_appconnect}\n' \
              "${curl_common_args[@]}"; then
            ready_command_status=0
          else
            ready_command_status=$?
          fi
          release_ready_sample_lock
          attempt_time_appconnect=$(extract_curl_metric \
            "$ready_output_file" 4)
          if positive_seconds "$attempt_time_appconnect" &&
            attempt_ready_ms=$(seconds_to_milliseconds \
              "$attempt_time_appconnect"); then
            ready_samples+=("$attempt_ready_ms")
            tcp_status='PASS'
          elif curl_failure_is_deterministic "$ready_command_status"; then
            break
          fi
        done

        # HTTP checks use strict certificate verification. Retry transport
        # failures that may be transient and retain the existing 5xx policy,
        # but stop immediately for deterministic curl/TLS configuration errors.
        http_check_attempted=true
        for attempt in 1 2 3; do
          attempt_request_ok=false
          attempt_http_code=''
          attempt_http_status='-'
          attempt_location=''
          attempt_time_connect=''
          http_command_ok=false
          http_command_status=0
          http_output_file="$TEMP_DIR/http-output-$index-$attempt"
          http_header_file="$TEMP_DIR/http-header-$index-$attempt"
          if run_network_command "$http_output_file" "$HTTP_TIMEOUT" \
            curl --dump-header "$http_header_file" \
              --write-out 'DOMAIN_CHECK_METRICS\t%{http_code}\t%{time_connect}\t%{time_appconnect}\n' \
              "${curl_common_args[@]}"; then
            http_command_ok=true
          else
            http_command_status=$?
          fi

          attempt_http_code=$(extract_http_code "$http_output_file")
          attempt_time_connect=$(extract_curl_metric "$http_output_file" 3)
          if positive_seconds "$attempt_time_connect"; then
            tcp_status='PASS'
          fi
          if [[ "$http_command_ok" == true &&
            "$attempt_http_code" =~ ^[0-9]{3}$ &&
            "$attempt_http_code" != '000' ]]; then
            attempt_request_ok=true
            tcp_status='PASS'
            attempt_http_status=$attempt_http_code
            attempt_location=$(extract_location "$http_header_file")
          fi
          record_http_attempt "$attempt" "$attempt_request_ok" \
            "$attempt_http_status" "$attempt_location" "$http_header_file"
          if [[ "$HTTP_FINALIZED" == true ]] ||
            curl_failure_is_deterministic "$http_command_status"; then
            HTTP_FINALIZED=true
            break
          fi
        done
      fi
    fi

    aggregate_ready_samples "${ready_samples[@]}"
    ready_ms=$READY_MS
    ready_sample_count=$READY_SAMPLE_COUNT
    final_header_file=$HTTP_HEADER_FILE
    detect_cdn "$cname" "$final_header_file"
    cdn_status=$CDN_STATUS
    cdn_detail=$CDN_DETAIL
  else
    aggregate_ready_samples
  fi

  if [[ "$dns_status" == 'PASS' && "$tcp_status" == 'FAIL' ]]; then
    append_reason 'TCP 443 不可达'
  fi
  if [[ "$dns_status" == 'PASS' && "$tcp_status" == 'PASS' ]]; then
    [[ "$tls_status" == 'PASS' ]] || append_reason 'TLS 1.3 握手失败'
    [[ "$x25519_status" == 'PASS' ]] || append_reason '强制 X25519 握手失败'
    [[ "$h2_status" == 'PASS' ]] || append_reason 'ALPN 未协商 h2'
    if [[ "$certificate_status" == 'FAIL' ]]; then
      if [[ "$certificate_warning" == '证书已过期' ]]; then
        append_reason "$certificate_warning"
      else
        append_reason '证书链、有效期或主机名验证失败'
      fi
    fi
  fi

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
    "$h2_status" == 'FAIL' || "$certificate_status" == 'FAIL' ]]; then
    final_status='FAIL'
  fi

  if [[ "$redirect_status" == 'WARN' ]]; then
    append_reason "跳转：$redirect_detail"
    [[ "$final_status" == 'FAIL' ]] || final_status='WARN'
  fi

  if [[ "$http_check_attempted" == true ]]; then
    classify_http_result "$http_request_ok" "$http_status" "$http_5xx_count"
    if [[ "$HTTP_RESULT_STATUS" == 'WARN' ]]; then
      append_reason "$HTTP_RESULT_REASON"
      [[ "$final_status" == 'FAIL' ]] || final_status='WARN'
    fi
  fi
  if [[ "$ready_check_attempted" == true ]] &&
    (( ready_sample_count < 3 )); then
    append_reason "连接就绪计时样本不足（${ready_sample_count}/3）"
    [[ "$final_status" == 'FAIL' ]] || final_status='WARN'
  fi
  if [[ "$certificate_status" == 'PASS' &&
    -n "$certificate_warning" ]]; then
    append_reason "$certificate_warning"
    [[ "$final_status" == 'FAIL' ]] || final_status='WARN'
  fi
  if [[ -n "$cdn_detail" ]]; then
    append_reason "CDN $cdn_status: $cdn_detail"
  fi

  [[ -n "$REASONS" ]] || REASONS='-'
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$domain" "$ip" "$tls_status" "$x25519_status" "$h2_status" \
    "$ready_ms" "$certificate_days" "$cdn_status" "$http_status" \
    "$redirect_code" "$final_status" "$REASONS" >"$result_file"
  rm -f -- "$ACTIVE_PID_FILE"
}

write_domain_failure_result() {
  local index=$1
  local domain=$2
  local reason=$3

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$domain" - FAIL FAIL FAIL - FAIL - - - FAIL "$reason" \
    >"$TEMP_DIR/result-$index"
}

terminate_domain_child() {
  local child_pid=$1
  local active_pid_file=$2
  local active_pid=''

  if [[ -r "$active_pid_file" ]]; then
    IFS= read -r active_pid <"$active_pid_file" || :
  fi
  if [[ "$active_pid" =~ ^[0-9]+$ ]]; then
    kill -TERM "$active_pid" 2>/dev/null || :
  fi
  terminate_pid_with_grace "$child_pid"
  if [[ "$active_pid" =~ ^[0-9]+$ ]]; then
    kill -KILL "$active_pid" 2>/dev/null || :
  fi
  wait "$child_pid" 2>/dev/null || :
  release_ready_sample_lock_for_pid "$child_pid"
  rm -f -- "$active_pid_file"
}

domain_worker_signal() {
  trap - INT TERM
  if [[ -n "$DOMAIN_TIMER_PID" ]]; then
    kill -TERM "$DOMAIN_TIMER_PID" 2>/dev/null || :
    wait "$DOMAIN_TIMER_PID" 2>/dev/null || :
  fi
  if [[ -n "$DOMAIN_CHILD_PID" ]]; then
    terminate_domain_child "$DOMAIN_CHILD_PID" "$DOMAIN_ACTIVE_PID_FILE"
  fi
  exit 130
}

run_domain_worker() {
  local index=$1
  local domain=$2
  local completed_pid=''
  local child_status=0

  DOMAIN_ACTIVE_PID_FILE="$TEMP_DIR/active-pid-$index"
  trap domain_worker_signal INT TERM

  check_domain "$index" "$domain" &
  DOMAIN_CHILD_PID=$!
  sleep "$DOMAIN_HARD_TIMEOUT" &
  DOMAIN_TIMER_PID=$!

  if wait -n -p completed_pid "$DOMAIN_CHILD_PID" "$DOMAIN_TIMER_PID"; then
    child_status=0
  else
    child_status=$?
  fi

  if [[ "$completed_pid" == "$DOMAIN_TIMER_PID" ]]; then
    terminate_domain_child "$DOMAIN_CHILD_PID" "$DOMAIN_ACTIVE_PID_FILE"
    write_domain_failure_result "$index" "$domain" \
      "单域名检测超时（${DOMAIN_HARD_TIMEOUT} 秒）"
  else
    kill -TERM "$DOMAIN_TIMER_PID" 2>/dev/null || :
    wait "$DOMAIN_TIMER_PID" 2>/dev/null || :
    release_ready_sample_lock_for_pid "$DOMAIN_CHILD_PID"
    rm -f -- "$DOMAIN_ACTIVE_PID_FILE"
    if (( child_status != 0 )) || [[ ! -s "$TEMP_DIR/result-$index" ]]; then
      write_domain_failure_result "$index" "$domain" '域名检测内部失败'
    fi
  fi

  DOMAIN_CHILD_PID=''
  DOMAIN_TIMER_PID=''
  DOMAIN_ACTIVE_PID_FILE=''
  trap - INT TERM
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
  local completed_index=''
  if wait -n -p completed_pid "${WORKER_PIDS[@]}"; then
    :
  else
    :
  fi
  [[ -n "$completed_pid" ]] || return 1
  completed_index=${WORKER_INDEX_BY_PID[$completed_pid]-}
  unset 'WORKER_INDEX_BY_PID[$completed_pid]'
  remove_worker_pid "$completed_pid"
  if [[ "$completed_index" =~ ^[0-9]+$ ]]; then
    (( COMPLETED_COUNT += 1 ))
    report_worker_completion "${DOMAIN_INPUTS[$completed_index]}"
  fi
}

report_worker_completion() {
  local domain=$1
  local message="[$COMPLETED_COUNT/${#DOMAIN_INPUTS[@]}] $domain"

  if [[ -t 2 ]]; then
    if (( PROGRESS_WIDTH > 0 )); then
      printf '\r%*s\r' "$PROGRESS_WIDTH" '' >&2
    fi
    printf '%s' "$message" >&2
    PROGRESS_WIDTH=${#message}
  else
    printf '%s\n' "$message" >&2
  fi
}

clear_progress() {
  if (( PROGRESS_WIDTH > 0 )); then
    printf '\r%*s\r' "$PROGRESS_WIDTH" '' >&2
    PROGRESS_WIDTH=0
  fi
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
  WORKER_INDEX_BY_PID=()
}

cleanup() {
  local exit_code=$?
  trap - EXIT ERR INT TERM
  terminate_workers
  clear_progress
  if [[ -n "$TEMP_DIR" && "$TEMP_DIR" == /* && -d "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
  exit "$exit_code"
}

handle_interrupt() {
  trap - INT TERM
  terminate_workers
  clear_progress
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
    bash openssl curl timeout awk sed grep mktemp getent date sleep
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
    SAME|WWW|RELATIVE|NO-LOC|INVALID|CROSS|HTTP) printf '33' ;;
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

color_for_certificate_days() {
  local value=$1
  if [[ "$value" == '-' ]]; then
    printf '90'
  elif [[ "$value" == 'FAIL' ]]; then
    printf '31'
  elif (( value <= 7 )); then
    printf '31'
  elif (( value <= 30 )); then
    printf '33'
  else
    printf '32'
  fi
}

color_for_cdn() {
  case "$1" in
    HIGH) printf '36' ;;
    MED) printf '33' ;;
    -) printf '90' ;;
    *) printf '' ;;
  esac
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
  local ready_ms
  local certificate_days
  local cdn_status
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
      ready_ms certificate_days cdn_status http_status redirect_code \
      final_status reasons <"$TEMP_DIR/result-$index"
    domain_display=$(truncate_ascii "$domain" 48)
    values=(
      "$domain_display" "$ip" "$tls_status" "$x25519_status" "$h2_status"
      "$ready_ms" "$certificate_days" "$cdn_status" "$http_status"
      "$redirect_code" "$final_status"
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
  local ready_ms=$6
  local certificate_days=$7
  local cdn_status=$8
  local http_status=$9
  local redirect_code=${10}
  local final_status=${11}

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
    "$ready_ms" "${TABLE_WIDTHS[5]}" "$(color_for_latency "$ready_ms")"
  print_frame_piece "$BORDER_VERTICAL"
  print_colored_cell "$certificate_days" "${TABLE_WIDTHS[6]}" \
    "$(color_for_certificate_days "$certificate_days")"
  print_frame_piece "$BORDER_VERTICAL"
  print_colored_cell \
    "$cdn_status" "${TABLE_WIDTHS[7]}" "$(color_for_cdn "$cdn_status")"
  print_frame_piece "$BORDER_VERTICAL"
  print_colored_cell \
    "$http_status" "${TABLE_WIDTHS[8]}" "$(color_for_http "$http_status")"
  print_frame_piece "$BORDER_VERTICAL"
  print_colored_cell "$redirect_code" "${TABLE_WIDTHS[9]}" \
    "$(color_for_redirect "$redirect_code")"
  print_frame_piece "$BORDER_VERTICAL"
  print_colored_cell \
    "$final_status" "${TABLE_WIDTHS[10]}" "$(color_for_status "$final_status")"
  print_frame_piece "$BORDER_VERTICAL"
  printf '\n'
}

table_has_details() {
  local index
  local reasons
  for index in "${!DOMAIN_INPUTS[@]}"; do
    IFS=$'\t' read -r _ _ _ _ _ _ _ _ _ _ _ reasons \
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
    IFS=$'\t' read -r domain _ _ _ _ _ _ _ _ _ _ \
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
  local ready_ms
  local certificate_days
  local cdn_status
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
      ready_ms certificate_days cdn_status http_status redirect_code \
      final_status reasons <"$TEMP_DIR/result-$index"
    RESULT_STATUSES+=("$final_status")
    print_data_row \
      "$domain" "$ip" "$tls_status" "$x25519_status" "$h2_status" \
      "$ready_ms" "$certificate_days" "$cdn_status" "$http_status" \
      "$redirect_code" "$final_status"
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

set_html_escaped_value() {
  local value=$1
  local character
  local escaped=''
  local position

  for (( position = 0; position < ${#value}; position += 1 )); do
    character=${value:position:1}
    case "$character" in
      '&') escaped+='&amp;' ;;
      '<') escaped+='&lt;' ;;
      '>') escaped+='&gt;' ;;
      '"') escaped+='&quot;' ;;
      "'") escaped+='&#39;' ;;
      *) escaped+=$character ;;
    esac
  done
  HTML_ESCAPED_VALUE=$escaped
}

escape_html() {
  set_html_escaped_value "$1"
  printf '%s' "$HTML_ESCAPED_VALUE"
}

set_status_css_class() {
  case ${1:-} in
    PASS) HTML_CSS_CLASS='status status-pass' ;;
    WARN) HTML_CSS_CLASS='status status-warn' ;;
    FAIL) HTML_CSS_CLASS='status status-fail' ;;
    HIGH) HTML_CSS_CLASS='status status-high' ;;
    -|'') HTML_CSS_CLASS='muted' ;;
    *) HTML_CSS_CLASS='value' ;;
  esac
}

set_http_css_class() {
  case ${1:-} in
    2??) HTML_CSS_CLASS='http http-2xx' ;;
    3??) HTML_CSS_CLASS='http http-3xx' ;;
    4??) HTML_CSS_CLASS='http http-4xx' ;;
    5??) HTML_CSS_CLASS='http http-5xx' ;;
    -|'') HTML_CSS_CLASS='muted' ;;
    *) HTML_CSS_CLASS='http' ;;
  esac
}

set_detail_css_class() {
  local final_status=$1
  local reason=$2

  if [[ "$reason" == CDN\ * ]]; then
    HTML_CSS_CLASS='detail-info'
  elif [[ "$final_status" == 'FAIL' ]]; then
    HTML_CSS_CLASS='detail-fail'
  elif [[ "$final_status" == 'WARN' ]]; then
    HTML_CSS_CLASS='detail-warn'
  else
    HTML_CSS_CLASS='detail-info'
  fi
}

render_html_report() {
  local generated_at=$1
  local index
  local domain
  local ip
  local tls_status
  local x25519_status
  local h2_status
  local ready_ms
  local certificate_days
  local cdn_status
  local http_status
  local redirect_code
  local final_status
  local reasons
  local reason_part
  local input_targets=''
  local pass_count=0
  local warn_count=0
  local fail_count=0
  local domain_class
  local ip_class
  local tls_class
  local x25519_class
  local h2_class
  local ready_class
  local certificate_class
  local cdn_class
  local http_class
  local redirect_class
  local result_class
  local detail_class
  local -a reason_parts=()

  for index in "${!DOMAIN_INPUTS[@]}"; do
    IFS=$'\t' read -r domain _ _ _ _ _ _ _ _ _ final_status _ \
      <"$TEMP_DIR/result-$index"
    [[ -z "$input_targets" ]] || input_targets+='/'
    input_targets+=$domain
    case "$final_status" in
      PASS) (( pass_count += 1 )) ;;
      WARN) (( warn_count += 1 )) ;;
      FAIL) (( fail_count += 1 )) ;;
    esac
  done
  set_html_escaped_value "$generated_at"
  generated_at=$HTML_ESCAPED_VALUE
  set_html_escaped_value "$input_targets"
  input_targets=$HTML_ESCAPED_VALUE

  printf '%s\n' \
    '<!doctype html>' \
    '<html lang="en">' \
    '<head>' \
    '<meta charset="utf-8">' \
    '<meta name="viewport" content="width=device-width, initial-scale=1">' \
    '<title>Domain Check Report</title>' \
    '<style>' \
    ':root{color-scheme:dark light;--bg:#0b0f14;--panel:#111820;--text:#d7e0e8;--muted:#74808b;--border:#33404c;--head:#17212b;--domain:#54d6e8;--ip:#e08cff;--pass:#53d769;--warn:#f6bd4b;--fail:#ff626e;--high:#4fc3f7;--ready:#8bd5ff;--row:#0e151c}' \
    '*{box-sizing:border-box}' \
    'body{margin:0;background:var(--bg);color:var(--text);font-family:ui-monospace,SFMono-Regular,Consolas,"Liberation Mono",monospace;font-size:13px;line-height:1.35}' \
    'main{max-width:1600px;margin:0 auto;padding:18px}' \
    'h1{margin:0 0 10px;font-size:21px;color:var(--domain)}' \
    '.meta{display:grid;grid-template-columns:max-content 1fr;gap:3px 10px;margin-bottom:10px}.meta dt{color:var(--muted)}.meta dd{margin:0;overflow-wrap:anywhere}' \
    '.summary{display:flex;flex-wrap:wrap;gap:6px;margin:8px 0 12px}.summary-item{border:1px solid var(--border);background:var(--panel);padding:3px 8px;border-radius:4px}.summary-item strong{margin-left:6px}' \
    '.table-wrap{overflow-x:auto;border:1px solid var(--border)}' \
    'table{width:100%;border-collapse:collapse;white-space:nowrap;background:var(--panel)}' \
    'th,td{border-right:1px solid var(--border);border-bottom:1px solid var(--border);padding:4px 7px;text-align:left}th:last-child,td:last-child{border-right:0}tbody tr:last-child td{border-bottom:0}' \
    'th{background:var(--head);color:var(--text);font-weight:700}tbody tr:nth-child(even){background:var(--row)}' \
    '.domain{color:var(--domain)}.ip{color:var(--ip)}.muted{color:var(--muted)}.ready{color:var(--ready)}' \
    '.status,.result,.http{font-weight:700}.status-pass,.http-2xx{color:var(--pass)}.status-warn,.http-4xx{color:var(--warn)}.status-fail,.http-5xx{color:var(--fail)}.status-high,.http-3xx{color:var(--high)}' \
    '.result{font-weight:800;text-shadow:0 0 8px color-mix(in srgb,currentColor 30%,transparent)}' \
    '.details{margin-top:14px}.details h2{font-size:16px;margin:0 0 7px}.detail-card{border-left:3px solid var(--border);background:var(--panel);padding:6px 9px;margin:0 0 6px}.detail-card h3{font-size:13px;color:var(--domain);margin:0 0 3px}.detail-card ul{margin:0;padding-left:18px}.detail-card li{margin:1px 0}.detail-fail{color:var(--fail)}.detail-warn{color:var(--warn)}.detail-info{color:var(--high)}' \
    '@media (prefers-color-scheme:dark){:root{color-scheme:dark}}' \
    '@media (prefers-color-scheme:light){:root{--bg:#f6f8fa;--panel:#fff;--text:#20262d;--muted:#69737d;--border:#b8c1ca;--head:#e8edf2;--domain:#007c91;--ip:#a11bb8;--pass:#187c2f;--warn:#a96100;--fail:#c51f32;--high:#006ea6;--ready:#006b9e;--row:#f3f6f8}}' \
    '</style>' \
    '</head>' \
    '<body>' \
    '<main>' \
    '<h1>Domain Check Report</h1>'
  printf '<dl class="meta"><dt>Time</dt><dd>%s</dd><dt>Input</dt><dd>%s</dd></dl>\n' \
    "$generated_at" "$input_targets"
  printf '<div class="summary"><span class="summary-item"><span>Targets</span><strong>%d</strong></span>' \
    "${#DOMAIN_INPUTS[@]}"
  printf '<span class="summary-item status-pass"><span>PASS</span><strong>%d</strong></span>' "$pass_count"
  printf '<span class="summary-item status-warn"><span>WARN</span><strong>%d</strong></span>' "$warn_count"
  printf '<span class="summary-item status-fail"><span>FAIL</span><strong>%d</strong></span></div>\n' "$fail_count"
  printf '%s\n' \
    '<div class="table-wrap"><table>' \
    '<thead><tr><th>DOMAIN</th><th>IP</th><th>TLS1.3</th><th>X25519</th><th>H2</th><th>READY(ms)</th><th>CERT(d)</th><th>CDN</th><th>HTTP</th><th>REDIRECT</th><th>RESULT</th></tr></thead>' \
    '<tbody>'

  for index in "${!DOMAIN_INPUTS[@]}"; do
    IFS=$'\t' read -r domain ip tls_status x25519_status h2_status \
      ready_ms certificate_days cdn_status http_status redirect_code \
      final_status reasons <"$TEMP_DIR/result-$index"
    set_html_escaped_value "$domain"; domain=$HTML_ESCAPED_VALUE
    set_html_escaped_value "$ip"; ip=$HTML_ESCAPED_VALUE
    set_html_escaped_value "$tls_status"; tls_status=$HTML_ESCAPED_VALUE
    set_html_escaped_value "$x25519_status"; x25519_status=$HTML_ESCAPED_VALUE
    set_html_escaped_value "$h2_status"; h2_status=$HTML_ESCAPED_VALUE
    set_html_escaped_value "$ready_ms"; ready_ms=$HTML_ESCAPED_VALUE
    set_html_escaped_value "$certificate_days"; certificate_days=$HTML_ESCAPED_VALUE
    set_html_escaped_value "$cdn_status"; cdn_status=$HTML_ESCAPED_VALUE
    set_html_escaped_value "$http_status"; http_status=$HTML_ESCAPED_VALUE
    set_html_escaped_value "$redirect_code"; redirect_code=$HTML_ESCAPED_VALUE
    set_html_escaped_value "$final_status"; final_status=$HTML_ESCAPED_VALUE
    domain_class='domain'
    ip_class='ip'
    set_status_css_class "$tls_status"; tls_class=$HTML_CSS_CLASS
    set_status_css_class "$x25519_status"; x25519_class=$HTML_CSS_CLASS
    set_status_css_class "$h2_status"; h2_class=$HTML_CSS_CLASS
    [[ "$ready_ms" == '-' ]] && ready_class='muted' || ready_class='ready'
    set_status_css_class "$certificate_days"; certificate_class=$HTML_CSS_CLASS
    set_status_css_class "$cdn_status"; cdn_class=$HTML_CSS_CLASS
    set_http_css_class "$http_status"; http_class=$HTML_CSS_CLASS
    set_status_css_class "$redirect_code"; redirect_class=$HTML_CSS_CLASS
    set_status_css_class "$final_status"; result_class="result ${HTML_CSS_CLASS#status }"
    printf '<tr><td class="%s">%s</td><td class="%s">%s</td>' \
      "$domain_class" "$domain" "$ip_class" "$ip"
    printf '<td class="%s">%s</td><td class="%s">%s</td><td class="%s">%s</td>' \
      "$tls_class" "$tls_status" "$x25519_class" "$x25519_status" \
      "$h2_class" "$h2_status"
    printf '<td class="%s">%s</td><td class="%s">%s</td><td class="%s">%s</td>' \
      "$ready_class" "$ready_ms" "$certificate_class" "$certificate_days" \
      "$cdn_class" "$cdn_status"
    printf '<td class="%s">%s</td><td class="%s">%s</td><td class="%s">%s</td></tr>\n' \
      "$http_class" "$http_status" "$redirect_class" "$redirect_code" \
      "$result_class" "$final_status"
  done

  printf '%s\n' '</tbody></table></div>' '<section class="details"><h2>DETAILS</h2>'
  if table_has_details; then
    for index in "${!DOMAIN_INPUTS[@]}"; do
      IFS=$'\t' read -r domain _ _ _ _ _ _ _ _ _ final_status reasons \
        <"$TEMP_DIR/result-$index"
      [[ "$reasons" != '-' ]] || continue
      set_html_escaped_value "$domain"; domain=$HTML_ESCAPED_VALUE
      printf '<article class="detail-card"><h3>%s</h3><ul>\n' "$domain"
      IFS=';' read -r -a reason_parts <<<"$reasons"
      for reason_part in "${reason_parts[@]}"; do
        reason_part=${reason_part#"${reason_part%%[![:space:]]*}"}
        set_detail_css_class "$final_status" "$reason_part"
        detail_class=$HTML_CSS_CLASS
        set_html_escaped_value "$reason_part"; reason_part=$HTML_ESCAPED_VALUE
        printf '<li class="%s">%s</li>\n' "$detail_class" "$reason_part"
      done
      printf '%s\n' '</ul></article>'
    done
  else
    printf '%s\n' '<p class="muted">None</p>'
  fi
  printf '%s\n' '</section>' '</main>' '</body>' '</html>'
}

write_html_log() {
  local log_home=${HOME:-}
  local log_dir
  local log_timestamp
  local generated_at
  local reservation_attempt
  local reserved=false

  HTML_LOG_PATH=''
  if [[ -z "$log_home" || "$log_home" != /* ]]; then
    printf '%s: WARN: unable to create HTML log: HOME is not absolute.\n' \
      "$PROGRAM_NAME" >&2
    return 0
  fi
  log_dir="$log_home/domain-check-logs"
  if ! mkdir -p -- "$log_dir"; then
    printf '%s: WARN: unable to create HTML log directory: %s\n' \
      "$PROGRAM_NAME" "$log_dir" >&2
    return 0
  fi

  for reservation_attempt in 1 2 3; do
    log_timestamp=$(date '+%Y%m%d-%H%M%S') || log_timestamp=''
    if [[ "$log_timestamp" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
      HTML_LOG_PATH="$log_dir/domain-check-$log_timestamp.html"
      if (set -o noclobber; : >"$HTML_LOG_PATH") 2>/dev/null; then
        reserved=true
        break
      fi
    fi
    (( reservation_attempt < 3 )) && sleep 1
  done
  if [[ "$reserved" != true ]]; then
    HTML_LOG_PATH=''
    printf '%s: WARN: unable to reserve a unique HTML log file in: %s\n' \
      "$PROGRAM_NAME" "$log_dir" >&2
    return 0
  fi

  generated_at=$(date -u '+%Y-%m-%d %H:%M:%S UTC') || generated_at='-'
  if ! render_html_report "$generated_at" >"$HTML_LOG_PATH"; then
    rm -f -- "$HTML_LOG_PATH"
    printf '%s: WARN: unable to write HTML log: %s\n' \
      "$PROGRAM_NAME" "$HTML_LOG_PATH" >&2
    HTML_LOG_PATH=''
    return 0
  fi
  printf 'HTML log: %s\n' "$HTML_LOG_PATH" >&2
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

  COMPLETED_COUNT=0
  PROGRESS_WIDTH=0
  for index in "${!DOMAIN_INPUTS[@]}"; do
    run_domain_worker "$index" "${DOMAIN_INPUTS[$index]}" &
    WORKER_PIDS+=("$!")
    WORKER_INDEX_BY_PID["$!"]=$index
    if (( ${#WORKER_PIDS[@]} >= MAX_CONCURRENCY )); then
      wait_for_one_worker
    fi
  done
  while (( ${#WORKER_PIDS[@]} > 0 )); do
    wait_for_one_worker
  done

  for index in "${!DOMAIN_INPUTS[@]}"; do
    if [[ ! -s "$TEMP_DIR/result-$index" ]]; then
      write_domain_failure_result "$index" "${DOMAIN_INPUTS[$index]}" \
        '域名检测结果缺失'
    fi
  done

  clear_progress
  print_results
  if ! aggregate_exit_code "${RESULT_STATUSES[@]}"; then
    final_exit_code=1
  fi
  write_html_log
  exit "$final_exit_code"
}

if [[ ${DOMAIN_CHECK_SOURCE_ONLY:-0} != '1' ]]; then
  main "$@"
fi
