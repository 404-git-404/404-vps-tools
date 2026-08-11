#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2317,SC2329

set -Eeuo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly TEST_DIR
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd)
readonly REPO_ROOT
readonly BENCHMARK_SCRIPT="$REPO_ROOT/protocol-benchmark.sh"

export PROTOCOL_BENCHMARK_SOURCE_ONLY=1
# shellcheck disable=SC1090
source "$BENCHMARK_SCRIPT"

TEST_COUNT=0
TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/protocol-benchmark-tests.XXXXXXXX")
readonly TEST_TEMP_DIR

cleanup_tests() {
  [[ -d "$TEST_TEMP_DIR" ]] && rm -rf -- "$TEST_TEMP_DIR"
}

trap cleanup_tests EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_equal() {
  local expected=$1
  local actual=$2
  local description=$3
  (( TEST_COUNT += 1 ))
  [[ "$actual" == "$expected" ]] ||
    fail "$description: expected [$expected], got [$actual]"
}

assert_contains() {
  local expected=$1
  local actual=$2
  local description=$3
  (( TEST_COUNT += 1 ))
  [[ "$actual" == *"$expected"* ]] ||
    fail "$description: missing [$expected]"
}

assert_not_contains() {
  local unexpected=$1
  local actual=$2
  local description=$3
  (( TEST_COUNT += 1 ))
  [[ "$actual" != *"$unexpected"* ]] ||
    fail "$description: unexpectedly found [$unexpected]"
}

assert_true() {
  local description=$1
  shift
  (( TEST_COUNT += 1 ))
  "$@" || fail "$description"
}

assert_false() {
  local description=$1
  shift
  (( TEST_COUNT += 1 ))
  if "$@"; then
    fail "$description"
  fi
}

process_exists() {
  kill -0 "$1" 2>/dev/null
}

reset_fixture() {
  RESULT_FILE="$TEST_TEMP_DIR/results.tsv"
  : >"$RESULT_FILE"
  FAILURE_FILE="$TEST_TEMP_DIR/failures.tsv"
  : >"$FAILURE_FILE"
  LABELS=''
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
  IDLE_RTT=30
  IDLE_VARIATION=1
  IDLE_LOSS=0
  MAX_LOAD_INCREASE=0
  MAX_CPU=20
  MAX_LOAD_AVERAGE=0
  TRAFFIC_RESERVED_BYTES=0
  TRAFFIC_ACCOUNTED_BYTES=0
  TRAFFIC_ACTUAL_BYTES=0
  ASYMMETRY_REASON=''
  TCP_RETRANS_DENSITY_A_TO_B=0
  TCP_RETRANS_DENSITY_B_TO_A=0
  TCP_RETRANS_WORST_DIRECTION='NONE'
  TCP_RETRANS_PENALTY=0
  TCP_TRANSFERRED_BYTES_A_TO_B=0
  TCP_TRANSFERRED_BYTES_B_TO_A=0
  TCP_RETRANSMISSIONS_A_TO_B=0
  TCP_RETRANSMISSIONS_B_TO_A=0
  MODE='client'
  PEER=''
  PORT=''
  NOMINAL_MBPS=''
  HISTORY_LIMIT=$DEFAULT_HISTORY_LIMIT
  HISTORY_LIMIT_SET=false
  RESULT_STATE='COMPLETE'
  TCP_EVALUABLE=false
  UDP_EVALUABLE=false
  FIREWALL_RULE_ADDED=false
  FIREWALL_COMMENT=''
  FIREWALL_STATUS='unchanged'
  UFW_COMMAND=()
}

append_result() {
  local protocol=$1
  local direction=$2
  local percent=$3
  local achieved=$4
  local retrans=$5
  local loss=$6
  local load_rtt=$7
  local bytes=$8

  printf '%s\t%s\t%s\t1\t%s\t%s\t1.0\t%s\t%s\t0.1\t%s\t%s\n' \
    "$protocol" "$direction" "$percent" "$achieved" "$achieved" \
    "$retrans" "$loss" "$load_rtt" "$bytes" >>"$RESULT_FILE"
}

append_healthy_pair() {
  local protocol=$1
  local percent=$2
  local offered=$3
  local achieved
  achieved=$(awk -v value="$offered" 'BEGIN {printf "%.3f", value*.96}')
  if [[ "$protocol" == 'TCP' ]]; then
    printf 'TCP\tA_TO_B\t%s\t1\t%s\t%s\t0.96\t0\t0\t0\t5\t1000000\n' \
      "$percent" "$offered" "$achieved" >>"$RESULT_FILE"
    printf 'TCP\tB_TO_A\t%s\t1\t%s\t%s\t0.96\t0\t0\t0\t6\t1000000\n' \
      "$percent" "$offered" "$achieved" >>"$RESULT_FILE"
  else
    printf 'UDP\tA_TO_B\t%s\t1\t%s\t%s\t0.96\t0\t0.02\t1\t5\t1000000\n' \
      "$percent" "$offered" "$achieved" >>"$RESULT_FILE"
    printf 'UDP\tB_TO_A\t%s\t1\t%s\t%s\t0.96\t0\t0.03\t1\t6\t1000000\n' \
      "$percent" "$offered" "$achieved" >>"$RESULT_FILE"
  fi
}

test_limits_and_scaling() {
  local rate
  local reserve

  assert_equal '20' "$DEFAULT_MAX_PERCENT" 'default ceiling'
  assert_equal '200' "$DEFAULT_BUDGET_MB" 'default budget'
  assert_equal '2' "$DEFAULT_DURATION" 'default stage duration'
  NOMINAL_MBPS=100
  assert_equal '5.000' "$(rate_for_percent 5)" '100 Mbps at 5 percent'
  assert_equal '10.000' "$(rate_for_percent 10)" '100 Mbps at 10 percent'
  assert_equal '20.000' "$(rate_for_percent 20)" '100 Mbps at 20 percent'
  assert_false '100 Mbps must never offer a fixed 200 Mbps' \
    awk -v rate="$(rate_for_percent 20)" 'BEGIN {exit !(rate >= 200)}'

  BUDGET_BYTES=$((DEFAULT_BUDGET_MB * 1000 * 1000))
  TRAFFIC_RESERVED_BYTES=0
  rate=$(rate_for_percent 20)
  reserve=$(planned_bytes "$rate" "$DEFAULT_DURATION")
  while reserve_budget "$reserve"; do :; done
  assert_true 'reservation must not exceed the 200 MB budget' \
    test "$TRAFFIC_RESERVED_BYTES" -le "$BUDGET_BYTES"
}

test_validation() {
  assert_true 'valid high port' validate_port 52000
  assert_false 'low fixed port rejected' validate_port 5201
  assert_false 'out-of-range port rejected' validate_port 70000
  assert_true 'IPv4 peer accepted' validate_peer 192.0.2.1
  assert_true 'IPv6 peer accepted' validate_peer 2001:db8::1
  assert_false 'option injection rejected' validate_peer --server
  assert_false 'peer whitespace rejected' validate_peer 'host name'
  assert_true 'literal firewall IPv4 accepted' validate_firewall_peer 192.0.2.1
  assert_false 'firewall hostname rejected' validate_firewall_peer example.invalid
}

test_json_ping_parser() {
  local ping_file="$TEST_TEMP_DIR/ping.txt"
  cat >"$ping_file" <<'EOF'
6 packets transmitted, 6 received, 0% packet loss, time 1015ms
rtt min/avg/max/mdev = 36.100/37.400/39.100/0.700 ms
EOF
  parse_ping_file "$ping_file"
  assert_equal '0' "$PING_LOSS" 'ping loss parser'
  assert_equal '37.400' "$PING_AVG" 'ping average parser'
  assert_equal '0.700' "$PING_VARIATION" 'ping variation parser'

  cat >"$ping_file" <<'EOF'
10 packets transmitted, 8 received, 20% packet loss, time 1842ms
round-trip min/avg/max/stddev = 10.100/12.300/15.900/1.400 ms
EOF
  parse_ping_file "$ping_file"
  assert_equal '20' "$PING_LOSS" 'iputils partial-loss parser'
  assert_equal '12.300' "$PING_AVG" 'round-trip IPv4/IPv6 average parser'
  assert_equal '1.400' "$PING_VARIATION" 'round-trip variation parser'
}

test_iperf_json_execution() {
  local iperf_log="$TEST_TEMP_DIR/iperf-args.log"
  local tcp_row
  local udp_row

  reset_fixture
  : >"$iperf_log"
  TEMP_DIR="$TEST_TEMP_DIR"
  RESULT_FILE="$TEST_TEMP_DIR/results.tsv"
  NOMINAL_MBPS=100
  PEER=192.0.2.20
  PORT=55000
  DURATION=1
  COOLDOWN=0
  BUDGET_BYTES=200000000
  read_cpu_sample() { printf '1000 500\n'; }
  ping() {
    printf '5 packets transmitted, 5 received, 0%% packet loss\n'
    printf 'rtt min/avg/max/mdev = 30.0/35.0/40.0/1.0 ms\n'
  }
  iperf3() {
    printf '%s\n' "$*" >>"$iperf_log"
    if [[ " $* " == *' -u '* ]]; then
      printf '%s\n' '{"end":{"sum":{"bits_per_second":9600000,"bytes":1200000,"lost_percent":0.02,"jitter_ms":1.2},"cpu_utilization_percent":{"remote_total":12}}}'
    else
      printf '%s\n' '{"end":{"sum_received":{"bits_per_second":9500000,"bytes":1187500},"sum_sent":{"retransmits":2},"cpu_utilization_percent":{"remote_total":11}}}'
    fi
  }

  run_controlled_test TCP A_TO_B 10 1 >/dev/null
  run_controlled_test UDP B_TO_A 10 1 >/dev/null
  tcp_row=$(awk -F '\t' '$1 == "TCP" {print $6 ":" $8 ":" $11}' "$RESULT_FILE")
  udp_row=$(awk -F '\t' '$1 == "UDP" {print $6 ":" $9 ":" $10}' "$RESULT_FILE")
  assert_equal '9.500:2:5.000' "$tcp_row" 'TCP iperf3 JSON extraction'
  assert_equal '9.600:0.02:1.2' "$udp_row" 'UDP iperf3 JSON extraction'
  assert_contains '-b 10.000M -P 1' "$(sed -n '1p' "$iperf_log")" \
    'TCP controlled nominal-rate arguments'
  assert_contains '-u -R' "$(sed -n '2p' "$iperf_log")" \
    'UDP reverse direction arguments'
}

test_adaptive_healthy_early_stop() {
  reset_fixture
  DEEP=false
  MAX_PERCENT=20
  BUDGET_MB=200
  run_direction_pair() {
    local protocol=$1
    local percent=$2
    append_healthy_pair "$protocol" "$percent" "$percent"
  }
  should_try_two_streams() { return 1; }
  run_adaptive_matrix >/dev/null
  assert_equal 'true' "$EARLY_STOP" 'healthy link early stop'
  assert_equal '8' "$(awk 'END {print NR}' "$RESULT_FILE")" \
    'healthy link stops after two bidirectional protocol stages'
  # $3 is an awk field, not a shell expansion.
  # shellcheck disable=SC2016
  assert_false 'healthy early stop must skip 20 percent' \
    awk -F '\t' '$3 == 20 {found=1} END {exit !found}' "$RESULT_FILE"
}

test_udp_degradation_early_stop() {
  reset_fixture
  DEEP=false
  MAX_PERCENT=20
  BUDGET_MB=200
  run_direction_pair() {
    local protocol=$1
    local percent=$2
    if [[ "$protocol" == 'TCP' ]]; then
      append_healthy_pair "$protocol" "$percent" "$percent"
    else
      printf 'UDP\tA_TO_B\t%s\t1\t%s\t1\t0.20\t0\t4.0\t40\t150\t1000\n' \
        "$percent" "$percent" >>"$RESULT_FILE"
      printf 'UDP\tB_TO_A\t%s\t1\t%s\t1\t0.20\t0\t5.0\t45\t160\t1000\n' \
        "$percent" "$percent" >>"$RESULT_FILE"
    fi
  }
  should_try_two_streams() { return 1; }
  run_adaptive_matrix >/dev/null
  assert_contains 'UDP-DEGRADED' "$LABELS" 'UDP degradation label'
  assert_equal '2' "$(awk -F '\t' '$1 == "UDP" {count++} END {print count+0}' "$RESULT_FILE")" \
    'severe UDP does not escalate'
}

test_independent_adaptive_stop_diagnostics() {
  local output

  reset_fixture
  DEEP=false
  MAX_PERCENT=20
  BUDGET_MB=200
  PEER=fixture-peer
  PORT=55002
  NOMINAL_MBPS=100
  run_direction_pair() {
    local protocol=$1
    local percent=$2
    if [[ "$protocol" == 'TCP' ]]; then
      append_result TCP A_TO_B "$percent" 5 0 0 5 1234567
      append_result TCP B_TO_A "$percent" 5 125 0 5 2345678
    else
      append_result UDP A_TO_B "$percent" "$percent" 0 0.40 5 3456789
      append_result UDP B_TO_A "$percent" "$percent" 0 0.50 5 4567890
    fi
  }
  should_try_two_streams() { return 1; }
  run_adaptive_matrix >/dev/null
  assert_equal 'true' "$TCP_ADAPTIVE_STOP" 'TCP independently stops early'
  assert_equal '5' "$TCP_STOP_STAGE" 'TCP stop stage'
  assert_equal '5' "$TCP_HIGHEST_STAGE" 'TCP highest adaptive stage'
  assert_equal 'false' "$UDP_ADAPTIVE_STOP" 'UDP independently reaches ceiling'
  assert_equal '20' "$UDP_HIGHEST_STAGE" 'UDP highest adaptive stage'
  assert_equal 'false' "$EARLY_STOP" 'overall adaptive stop compatibility'
  calculate_results
  output=$(print_results)
  assert_contains 'TCP adaptive stop: yes (after 5%; highest test 5%)' \
    "$output" 'TCP adaptive stop output'
  assert_contains 'UDP adaptive stop: no (reached 20%)' "$output" \
    'UDP adaptive stop output'
  assert_contains 'A->B:        1.2 MB (1234567 bytes)' "$output" \
    'forward transferred bytes use raw counter'
  assert_contains 'B->A:        2.3 MB (2345678 bytes)' "$output" \
    'reverse transferred bytes use raw counter'
}

test_failure_control_flow_and_evaluability() {
  local output
  local pair_log="$TEST_TEMP_DIR/failure-pairs.log"
  local budget_status

  reset_fixture
  : >"$pair_log"
  DEEP=false
  MAX_PERCENT=20
  BUDGET_MB=200
  run_direction_pair() {
    printf '%s:%s\n' "$1" "$2" >>"$pair_log"
    record_failure "$1" A_TO_B "$2" 1 'connection refused'
    record_failure "$1" B_TO_A "$2" 1 'connection refused'
    return "$TEST_RESULT_FAILED"
  }
  should_try_two_streams() { return 1; }
  run_adaptive_matrix >/dev/null
  assert_equal $'TCP:5\nUDP:5' "$(cat "$pair_log")" \
    'all failed 5 percent pairs stop before higher stages'
  assert_equal '0' "$TRAFFIC_ACTUAL_BYTES" 'all immediate failures use zero traffic'
  assert_equal 'false' "$BUDGET_LIMITED" \
    'ordinary execution failure is not a budget stop'
  calculate_results
  output=$(print_results)
  assert_equal 'FAILED' "$RESULT_STATE" 'no-data result state'
  assert_equal 'NONE' "$CONFIDENCE" 'no-data confidence'
  assert_contains 'TEST RESULT:   FAILED' "$output" 'no-data output state'
  assert_contains 'Budget stop:   false' "$output" \
    'no-data output distinguishes execution failure from budget denial'
  assert_contains 'No valid bidirectional TCP or UDP' "$output" \
    'no-data output explanation'
  assert_not_contains 'TCP SCORE:' "$output" 'no-data omits TCP score'
  assert_not_contains 'UDP SCORE:' "$output" 'no-data omits UDP score'
  assert_not_contains 'LINK HEALTH:' "$output" 'no-data omits link health'
  assert_not_contains 'Preferred:     FIX LINK' "$output" \
    'no-data omits false transport conclusion'
  assert_not_contains 'link appears poor' "$output" \
    'no-data omits false poor-link conclusion'

  reset_fixture
  : >"$pair_log"
  run_direction_pair() {
    printf '%s:%s\n' "$1" "$2" >>"$pair_log"
    if [[ "$1" == 'TCP' ]]; then
      record_failure TCP A_TO_B "$2" 1 'connection refused'
      record_failure TCP B_TO_A "$2" 1 'connection refused'
      return "$TEST_RESULT_FAILED"
    fi
    append_healthy_pair UDP "$2" "$2"
  }
  run_adaptive_matrix >/dev/null
  calculate_results
  output=$(print_results)
  assert_equal 'PARTIAL' "$RESULT_STATE" 'UDP-only result is partial'
  assert_equal 'false' "$TCP_EVALUABLE" 'failed TCP is not evaluable'
  assert_equal 'true' "$UDP_EVALUABLE" 'bidirectional UDP is evaluable'
  assert_contains 'TCP SCORE:     not evaluable' "$output" \
    'partial output does not turn missing TCP into zero'
  assert_contains 'Preferred:     INCONCLUSIVE' "$output" \
    'partial UDP-only result is inconclusive'

  reset_fixture
  run_direction_pair() {
    if [[ "$1" == 'UDP' ]]; then
      record_failure UDP A_TO_B "$2" 1 'connection timed out'
      record_failure UDP B_TO_A "$2" 1 'connection timed out'
      return "$TEST_RESULT_FAILED"
    fi
    append_healthy_pair TCP "$2" "$2"
  }
  run_adaptive_matrix >/dev/null
  calculate_results
  output=$(print_results)
  assert_equal 'PARTIAL' "$RESULT_STATE" 'TCP-only result is partial'
  assert_equal 'true' "$TCP_EVALUABLE" 'bidirectional TCP is evaluable'
  assert_equal 'false' "$UDP_EVALUABLE" 'failed UDP is not evaluable'
  assert_contains 'UDP SCORE:     not evaluable' "$output" \
    'partial output does not turn missing UDP into zero'
  assert_contains 'LINK HEALTH:   not produced' "$output" \
    'partial output omits combined score'

  reset_fixture
  : >"$pair_log"
  run_direction_pair() {
    printf '%s:%s\n' "$1" "$2" >>"$pair_log"
    if [[ "$1" == 'TCP' && "$2" != '5' ]]; then
      record_failure TCP A_TO_B "$2" 1 'server terminated'
      record_failure TCP B_TO_A "$2" 1 'server terminated'
      return "$TEST_RESULT_FAILED"
    fi
    append_healthy_pair "$1" "$2" "$2"
  }
  run_adaptive_matrix >/dev/null
  calculate_results
  assert_equal 'COMPLETE' "$RESULT_STATE" \
    'later stage failure preserves earlier bidirectional data'
  assert_equal '2' "$TCP_FAILURES" 'later TCP failure count'
  assert_not_contains 'TCP:20' "$(cat "$pair_log")" \
    'TCP does not escalate after execution failure'
  assert_contains 'UDP:10' "$(cat "$pair_log")" \
    'UDP continues independently after TCP failure'
  assert_equal 'MEDIUM' "$CONFIDENCE" \
    'later execution failure reduces confidence'

  reset_fixture
  BUDGET_BYTES=0
  set +e
  reserve_budget 1
  budget_status=$?
  set -e
  assert_equal "$TEST_RESULT_BUDGET_DENIED" "$budget_status" \
    'budget denial has a distinct return status'
  assert_equal 'true' "$BUDGET_LIMITED" \
    'only actual budget denial sets budget limited'
}

test_server_disappearance_classification() {
  local output

  reset_fixture
  append_healthy_pair TCP 5 50
  record_failure TCP A_TO_B 10 1 'unable to connect to server: Connection refused'
  record_failure UDP A_TO_B 5 1 'unable to read from stream socket'
  record_failure UDP B_TO_A 5 1 'connection timed out'
  calculate_results
  output=$(print_results)
  assert_equal 'INFRASTRUCTURE_FAILURE' "$RESULT_STATE" \
    'server disappearance overrides otherwise evaluable early samples'
  assert_equal 'NONE' "$CONFIDENCE" 'infrastructure failure has no confidence'
  assert_equal 'INCOMPLETE' "$STATUS" 'infrastructure failure status'
  assert_equal 'INCONCLUSIVE' "$PREFERRED" \
    'infrastructure failure produces no transport recommendation'
  assert_contains 'INFRASTRUCTURE-FAILURE' "$LABELS" \
    'infrastructure failure diagnostic label'
  assert_contains 'INCOMPLETE / INFRASTRUCTURE FAILURE' "$output" \
    'infrastructure failure report heading'
  assert_contains 'Benchmark server became unavailable during the test' "$output" \
    'infrastructure failure report explains server disappearance'
  assert_contains 'Successful samples retained (not scored)' "$output" \
    'early successful samples remain visible'
  assert_contains 'TCP SCORE:     not produced' "$output" \
    'infrastructure failure does not score TCP'
  assert_contains 'UDP SCORE:     not produced' "$output" \
    'infrastructure failure does not score UDP'
  assert_contains 'Preferred:     INCONCLUSIVE' "$output" \
    'infrastructure failure report is inconclusive'
  assert_not_contains 'Underlying VPS<->VPS link appears' "$output" \
    'infrastructure failure does not classify link quality'

  reset_fixture
  append_healthy_pair TCP 5 50
  append_healthy_pair UDP 5 50
  record_failure TCP A_TO_B 10 1 'connection refused'
  calculate_results
  assert_equal 'COMPLETE' "$RESULT_STATE" \
    'one-protocol connection failure alone does not claim server disappearance'
}

test_failure_reason_and_reservation_lifecycle() {
  local json_file="$TEST_TEMP_DIR/failure.json"
  local output_file="$TEST_TEMP_DIR/failure-output.txt"
  local output
  local failure_reason
  local status
  local long_text

  reset_fixture
  TEMP_DIR=$TEST_TEMP_DIR
  NOMINAL_MBPS=100
  PEER=192.0.2.200
  PORT=55000
  DURATION=1
  COOLDOWN=0
  BUDGET_BYTES=200000000
  read_cpu_sample() { printf '1000 500\n'; }
  ping() {
    printf '5 packets transmitted, 5 received, 0%% packet loss\n'
    printf 'rtt min/avg/max/mdev = 30.0/35.0/40.0/1.0 ms\n'
  }
  iperf3() {
    printf 'iperf3: error - unable to connect to server: Connection refused\n' >&2
    return 1
  }
  if run_controlled_test TCP A_TO_B 5 1 >"$output_file" 2>&1; then
    status=0
  else
    status=$?
  fi
  output=$(cat "$output_file")
  assert_equal "$TEST_RESULT_FAILED" "$status" \
    'connection refusal is an execution failure'
  assert_contains 'FAILED: iperf3: error - unable to connect' "$output" \
    'connection refusal is printed directly'
  assert_equal '0' "$TRAFFIC_RESERVED_BYTES" \
    'failed reservation is released'
  assert_equal '0' "$TRAFFIC_ACCOUNTED_BYTES" \
    'known zero-transfer refusal consumes no budget'
  assert_equal '0' "$TRAFFIC_ACTUAL_BYTES" \
    'known zero-transfer refusal reports no traffic'
  assert_equal 'false' "$BUDGET_LIMITED" \
    'connection refusal does not create a fake budget stop'

  printf '%s\n' '{"error":"server terminated by policy"}' >"$json_file"
  printf '%s\n' 'stderr fallback must lose' >"$json_file.stderr"
  failure_reason=$(extract_failure_reason "$json_file" 1)
  assert_equal 'server terminated by policy' "$failure_reason" \
    'iperf JSON error has priority over stderr'

  printf '%s\n' '{invalid' >"$json_file"
  printf '\033[31mconnection timed out\033[0m\n' >"$json_file.stderr"
  failure_reason=$(extract_failure_reason "$json_file" 1)
  assert_equal 'connection timed out' "$failure_reason" \
    'stderr fallback strips ANSI control sequences'

  printf -v long_text '%0200d' 0
  failure_reason=$(sanitize_failure_text "$long_text")
  assert_equal '180' "${#failure_reason}" 'failure reason length is bounded'
}

test_scores_and_recommendation() {
  reset_fixture
  append_healthy_pair TCP 5 50
  append_healthy_pair TCP 10 100
  append_healthy_pair UDP 5 50
  append_healthy_pair UDP 10 100
  calculate_results
  assert_true 'healthy TCP score' test "$TCP_SCORE" -ge 85
  assert_true 'healthy UDP score' test "$UDP_SCORE" -ge 85
  assert_equal 'HEALTHY' "$STATUS" 'healthy status'
  assert_equal 'HIGH' "$CONFIDENCE" 'high confidence with eight clean samples'
  assert_equal 'EITHER' "$PREFERRED" 'healthy equal-quality recommendation'
}

assert_preference() {
  local expected=$1
  local tcp_score=$2
  local udp_score=$3
  local status=$4
  local labels=$5
  local description=$6

  TCP_SCORE=$tcp_score
  UDP_SCORE=$udp_score
  STATUS=$status
  LABELS=$labels
  choose_preferred_transport
  assert_equal "$expected" "$PREFERRED" "$description"
}

test_preferred_transport_model() {
  assert_preference EITHER 100 100 HEALTHY '' 'A-B equal healthy scores'
  assert_preference EITHER 98 100 HEALTHY '' 'A-C near-equal healthy scores'
  assert_preference EITHER 100 100 HEALTHY '' 'A-D equal healthy scores'
  assert_preference HY2 75 93 HEALTHY ASYMMETRIC \
    'A-E material UDP advantage'
  assert_preference TCP 75 40 DEGRADED \
    'TCP-DEGRADED,UDP-DEGRADED,ASYMMETRIC' \
    'A-F UDP degradation with usable TCP'

  assert_preference EITHER 100 96 HEALTHY '' \
    'four-point TCP edge is not material'
  assert_preference EITHER 96 100 HEALTHY '' \
    'four-point UDP edge is not material'
  assert_preference EITHER 90 90 HEALTHY '' \
    'equal healthy transports remain neutral'
  assert_preference TCP 90 60 DEGRADED UDP-DEGRADED \
    'degraded UDP with healthy TCP'
  assert_preference HY2 60 90 DEGRADED TCP-DEGRADED \
    'degraded TCP with healthy UDP'
  assert_preference HY2 95 80 DEGRADED TCP-DEGRADED \
    'one-sided TCP degradation overrides a conflicting score margin'
  assert_preference TCP 80 95 DEGRADED UDP-DEGRADED \
    'one-sided UDP degradation overrides a conflicting score margin'
  assert_preference FIX\ LINK 45 40 POOR \
    'TCP-DEGRADED,UDP-DEGRADED' 'both transports severely degraded'
  assert_preference TCP 90 20 POOR UDP-DEGRADED \
    'POOR status does not override usable TCP'
  assert_preference HY2 20 90 POOR TCP-DEGRADED \
    'POOR status does not override usable UDP'
  assert_preference FIX\ LINK 60 50 DEGRADED \
    'TCP-DEGRADED,UDP-DEGRADED' 'both scores below usable threshold'
  assert_contains 'fix or replace the underlying path' "$REASON" \
    'FIX LINK diagnostic reason'
  assert_preference EITHER 100 100 POOR '' \
    'POOR status alone does not force FIX LINK'
}

test_tcp_retransmission_scoring_model() {
  local forward reverse direction penalty
  local penalty_small penalty_large penalty_10 penalty_100 penalty_1000
  local penalty_ae penalty_af score_ae score_af

  reset_fixture
  append_result TCP A_TO_B 5 5 0 0 0 1250000
  append_result TCP B_TO_A 5 5 0 0 0 1250000
  IFS=$'\t' read -r forward reverse direction penalty _ \
    < <(calculate_tcp_retransmission_metrics)
  assert_equal '0.00' "$penalty" 'zero retransmissions have no penalty'

  reset_fixture
  append_result TCP A_TO_B 5 1 1 0 0 100000
  append_result TCP B_TO_A 5 1 0 0 0 100000
  IFS=$'\t' read -r forward reverse direction penalty _ \
    < <(calculate_tcp_retransmission_metrics)
  assert_equal '20.00' "$forward" 'tiny sample uses effective 5 MB denominator'
  assert_equal '2.00' "$penalty" \
    'one retransmission in tiny sample has only a noise-scale penalty'

  reset_fixture
  append_result TCP A_TO_B 10 50 100 0 0 5000000
  append_result TCP B_TO_A 10 50 0 0 0 5000000
  IFS=$'\t' read -r forward reverse direction penalty_small _ \
    < <(calculate_tcp_retransmission_metrics)
  reset_fixture
  append_result TCP A_TO_B 10 50 100 0 0 100000000
  append_result TCP B_TO_A 10 50 0 0 0 100000000
  IFS=$'\t' read -r forward reverse direction penalty_large _ \
    < <(calculate_tcp_retransmission_metrics)
  assert_true 'same retrans count penalizes smaller transfer more' \
    awk -v small="$penalty_small" -v large="$penalty_large" \
    'BEGIN { exit !(small > large) }'

  reset_fixture
  append_result TCP A_TO_B 10 50 10 0 0 10000000
  IFS=$'\t' read -r forward reverse direction penalty_10 _ \
    < <(calculate_tcp_retransmission_metrics)
  reset_fixture
  append_result TCP A_TO_B 10 50 100 0 0 10000000
  IFS=$'\t' read -r forward reverse direction penalty_100 _ \
    < <(calculate_tcp_retransmission_metrics)
  reset_fixture
  append_result TCP A_TO_B 10 50 1000 0 0 10000000
  IFS=$'\t' read -r forward reverse direction penalty_1000 _ \
    < <(calculate_tcp_retransmission_metrics)
  assert_true '10 retrans penalty is below 100 retrans penalty' \
    awk -v low="$penalty_10" -v high="$penalty_100" \
    'BEGIN { exit !(low < high) }'
  assert_true '100 retrans penalty is below 1000 retrans penalty' \
    awk -v low="$penalty_100" -v high="$penalty_1000" \
    'BEGIN { exit !(low < high) }'
  assert_equal '50.00' "$penalty_1000" 'extreme penalty is capped at 50'

  reset_fixture
  append_result TCP A_TO_B 5 5 125 0 0 1250000
  append_result TCP B_TO_A 5 5 0 0 0 1250000
  IFS=$'\t' read -r forward reverse direction penalty_small _ \
    < <(calculate_tcp_retransmission_metrics)
  append_result TCP B_TO_A 10 50 0 0 0 100000000
  IFS=$'\t' read -r forward reverse direction penalty_large _ \
    < <(calculate_tcp_retransmission_metrics)
  assert_equal "$penalty_small" "$penalty_large" \
    'healthy direction bytes cannot dilute bad direction'

  # A<->E: aggregate by direction across stages, then score the worse path.
  reset_fixture
  append_result TCP A_TO_B 5 24.577 12 0 0.039 6250000
  append_result TCP B_TO_A 5 25.164 0 0 0.728 6250000
  append_result TCP A_TO_B 10 48.641 52 0 0.099 12500000
  append_result TCP B_TO_A 10 50.329 0 0 0 12500000
  append_result TCP A_TO_B 20 93.771 328 0 0.019 25000000
  append_result TCP B_TO_A 20 100.133 0 0 0.107 25000000
  IFS=$'\t' read -r forward reverse direction penalty_ae _ \
    < <(calculate_tcp_retransmission_metrics)
  score_ae=$(calculate_protocol_score TCP 0 "$penalty_ae")
  assert_equal 'A_TO_B' "$direction" 'A-E worst retransmission direction'
  assert_equal '896.00' "$forward" 'A-E forward retransmission density'
  assert_equal '65' "$score_ae" 'A-E directional TCP retransmission score'

  # A<->F: the short sample remains severe despite tiny-sample protection.
  reset_fixture
  append_result TCP A_TO_B 5 5.182 0 0 5.308 1250000
  append_result TCP B_TO_A 5 5.243 125 0 6.096 1250000
  IFS=$'\t' read -r forward reverse direction penalty_af _ \
    < <(calculate_tcp_retransmission_metrics)
  score_af=$(calculate_protocol_score TCP 0 "$penalty_af")
  assert_equal 'B_TO_A' "$direction" 'A-F worst retransmission direction'
  assert_equal '2500.00' "$reverse" 'A-F reverse retransmission density'
  assert_equal '56' "$score_af" 'A-F directional TCP retransmission score'
  assert_true 'A-F penalty exceeds A-E penalty' \
    awk -v ae="$penalty_ae" -v af="$penalty_af" 'BEGIN { exit !(af > ae) }'
  assert_true 'A-E penalty exceeds healthy penalty' \
    awk -v ae="$penalty_ae" 'BEGIN { exit !(ae > 0) }'
  assert_true 'A-F score is lower than A-E score' \
    test "$score_af" -lt "$score_ae"
}

test_directional_asymmetry_regressions() {
  local diagnostic
  local output

  # A<->E: similar throughput, but persistent forward loss and retransmits.
  reset_fixture
  append_result TCP A_TO_B 5 24.577 12 0 0.039 6250000
  append_result TCP B_TO_A 5 25.164 0 0 0.728 6250000
  append_result UDP A_TO_B 5 24.992 0 0.463499 0 6250000
  append_result UDP B_TO_A 5 25.003 0 0 0.100 6250000
  append_result TCP A_TO_B 10 48.641 52 0 0.099 12500000
  append_result TCP B_TO_A 10 50.329 0 0 0 12500000
  append_result UDP A_TO_B 10 49.977 0 0.451964 0.205 12500000
  append_result UDP B_TO_A 10 49.997 0 0 0 12500000
  append_result TCP A_TO_B 20 93.771 328 0 0.019 25000000
  append_result TCP B_TO_A 20 100.133 0 0 0.107 25000000
  append_result UDP A_TO_B 20 99.960 0 0.811171 0 25000000
  append_result UDP B_TO_A 20 99.994 0 0 0 25000000
  assert_true 'A-E persistent directional quality must be asymmetric' detect_asymmetry
  diagnostic=$ASYMMETRY_REASON
  assert_contains 'UDP loss' "$diagnostic" 'A-E diagnostic evidence'
  assert_contains 'forward direction' "$diagnostic" 'A-E worse direction'
  calculate_results
  assert_equal '65' "$TCP_SCORE" 'A-E fixture TCP score'
  assert_equal '93' "$UDP_SCORE" 'A-E fixture UDP score remains unchanged'
  assert_equal '80' "$LINK_HEALTH" 'A-E fixture link health'
  assert_equal 'HEALTHY' "$STATUS" 'A-E fixture status'
  assert_equal 'HY2' "$PREFERRED" 'A-E fixture preferred transport'
  assert_contains 'ASYMMETRIC' "$LABELS" 'A-E asymmetric label'
  PEER=fixture-ae
  PORT=55000
  NOMINAL_MBPS=500
  output=$(print_results)
  assert_contains 'ASYMMETRIC: UDP loss is materially worse' "$output" \
    'A-E printed diagnostic reason'
  assert_contains 'A->B:        896.00 retrans / 100MB' "$output" \
    'A-E printed forward retransmission density'
  assert_contains 'Penalty:     34.91 / 50' "$output" \
    'A-E printed retransmission penalty'
  assert_contains 'materially worse in forward direction' "$output" \
    'A-E printed retransmission direction'

  # A<->F: a single severe reverse-loss sample is sufficient.
  reset_fixture
  append_result TCP A_TO_B 5 5.182 0 0 5.308 1250000
  append_result TCP B_TO_A 5 5.243 125 0 6.096 1250000
  append_result UDP A_TO_B 5 4.998 0 0 6.090 1250000
  append_result UDP B_TO_A 5 5.003 0 6.979405 5.921 1250000
  assert_true 'A-F severe reverse loss must be asymmetric' detect_asymmetry
  diagnostic=$ASYMMETRY_REASON
  assert_contains 'reverse direction' "$diagnostic" 'A-F worse direction'
  assert_contains '6.98%' "$diagnostic" 'A-F loss magnitude'
  calculate_results
  assert_equal '56' "$TCP_SCORE" 'A-F fixture TCP score'
  assert_equal '40' "$UDP_SCORE" 'A-F fixture UDP score remains unchanged'
  assert_equal '47' "$LINK_HEALTH" 'A-F fixture link health'
  assert_equal 'POOR' "$STATUS" 'A-F fixture status'
  assert_equal 'FIX LINK' "$PREFERRED" 'A-F fixture preferred transport'
  PEER=fixture-af
  PORT=55001
  NOMINAL_MBPS=100
  output=$(print_results)
  assert_contains 'B->A:        2500.00 retrans / 100MB' "$output" \
    'A-F printed reverse retransmission density'
  assert_contains 'Penalty:     43.79 / 50' "$output" \
    'A-F printed retransmission penalty'
  assert_contains 'materially worse in reverse direction' "$output" \
    'A-F printed retransmission direction'

  # TCP retransmission evidence must work without UDP-loss evidence.
  reset_fixture
  append_result TCP A_TO_B 5 5.0 0 0 5 1250000
  append_result TCP B_TO_A 5 5.0 125 0 5 1250000
  assert_true '0 vs 125 retransmissions must be asymmetric' detect_asymmetry
  assert_contains 'reverse TCP path' "$ASYMMETRY_REASON" \
    'TCP retransmission diagnostic direction'

  # Persistent A->E retransmissions also trigger without UDP evidence.
  reset_fixture
  append_result TCP A_TO_B 5 24.577 12 0 0.039 6250000
  append_result TCP B_TO_A 5 25.164 0 0 0.728 6250000
  append_result TCP A_TO_B 10 48.641 52 0 0.099 12500000
  append_result TCP B_TO_A 10 50.329 0 0 0 12500000
  append_result TCP A_TO_B 20 93.771 328 0 0.019 25000000
  append_result TCP B_TO_A 20 100.133 0 0 0.107 25000000
  assert_true 'A-E persistent retransmissions alone must be asymmetric' \
    detect_asymmetry
  assert_contains 'forward TCP path' "$ASYMMETRY_REASON" \
    'A-E TCP-only diagnostic direction'

  # Reliable, repeated load-RTT divergence is independent evidence.
  reset_fixture
  append_result TCP A_TO_B 5 10 0 0 5 2500000
  append_result TCP B_TO_A 5 10 0 0 45 2500000
  append_result TCP A_TO_B 10 20 0 0 6 5000000
  append_result TCP B_TO_A 10 20 0 0 50 5000000
  assert_true 'repeated material load RTT divergence must be asymmetric' \
    detect_asymmetry
  assert_contains 'load RTT' "$ASYMMETRY_REASON" 'load RTT diagnostic evidence'

  # Preserve the original achieved-throughput asymmetry behavior.
  reset_fixture
  append_result TCP A_TO_B 10 40 0 0 5 10000000
  append_result TCP B_TO_A 10 100 0 0 5 25000000
  assert_true 'material throughput ratio must remain asymmetric' detect_asymmetry
  assert_contains 'achieved throughput' "$ASYMMETRY_REASON" \
    'throughput diagnostic evidence'

  # A/B: clean bidirectional data must stay below every threshold.
  reset_fixture
  append_healthy_pair TCP 5 50
  append_healthy_pair TCP 10 100
  append_healthy_pair UDP 5 50
  append_healthy_pair UDP 10 100
  assert_false 'A-B healthy fixture must not be asymmetric' detect_asymmetry
  calculate_results
  assert_equal '100' "$TCP_SCORE" 'A-B healthy TCP score regression'
  assert_equal '100' "$UDP_SCORE" 'A-B healthy UDP score regression'
  assert_equal '100' "$LINK_HEALTH" 'A-B healthy link health regression'
  assert_equal 'HEALTHY' "$STATUS" 'A-B healthy status regression'
  assert_equal 'EITHER' "$PREFERRED" 'A-B healthy preference regression'

  # A/C: one incidental retransmission is statistical noise.
  reset_fixture
  append_result TCP A_TO_B 5 5.241 0 0 0 1250000
  append_result TCP B_TO_A 5 5.242 0 0 0 1250000
  append_result TCP A_TO_B 10 9.941 0 0 0 2500000
  append_result TCP B_TO_A 10 10.485 1 0 0 2500000
  append_result UDP A_TO_B 5 4.998 0 0 0 1250000
  append_result UDP B_TO_A 5 5.002 0 0 0 1250000
  assert_false 'A-C healthy fixture must not be asymmetric' detect_asymmetry
  calculate_results
  assert_equal '98' "$TCP_SCORE" 'A-C healthy TCP score regression'
  assert_equal '100' "$UDP_SCORE" 'A-C healthy UDP score regression'
  assert_equal '99' "$LINK_HEALTH" 'A-C healthy link health regression'
  assert_equal 'HEALTHY' "$STATUS" 'A-C healthy status regression'
  assert_equal 'EITHER' "$PREFERRED" 'A-C healthy preference regression'

  # A/D: near-identical throughput and clean quality must remain symmetric.
  reset_fixture
  append_result TCP A_TO_B 5 48.948 0 0 0.035 12500000
  append_result TCP B_TO_A 5 50.328 0 0 0 12500000
  append_result TCP A_TO_B 10 97.403 0 0 0 25000000
  append_result TCP B_TO_A 10 100.131 0 0 0 25000000
  append_result UDP A_TO_B 10 99.960 0 0 0 25000000
  append_result UDP B_TO_A 10 99.979 0 0 0 25000000
  assert_false 'A-D healthy fixture must not be asymmetric' detect_asymmetry
  calculate_results
  assert_equal '100' "$TCP_SCORE" 'A-D healthy TCP score regression'
  assert_equal '100' "$UDP_SCORE" 'A-D healthy UDP score regression'
  assert_equal '100' "$LINK_HEALTH" 'A-D healthy link health regression'
  assert_equal 'HEALTHY' "$STATUS" 'A-D healthy status regression'
  assert_equal 'EITHER' "$PREFERRED" 'A-D healthy preference regression'

  # Boundary noise: 99 vs 100 Mbps, tiny loss, and 10 retransmits stay quiet.
  reset_fixture
  append_result TCP A_TO_B 5 99 0 0 5 25000000
  append_result TCP B_TO_A 5 100 10 0 7 25000000
  append_result UDP A_TO_B 5 99 0 0 5 25000000
  append_result UDP B_TO_A 5 100 0 0.02 7 25000000
  append_result UDP A_TO_B 10 99 0 0 6 25000000
  append_result UDP B_TO_A 10 100 0 0.03 8 25000000
  assert_false 'minor throughput/loss/retrans/load noise must not be asymmetric' \
    detect_asymmetry
}

test_firewall_cleanup_exactness() {
  local log="$TEST_TEMP_DIR/ufw.log"
  local rules_present=true
  : >"$log"
  ufw() {
    if [[ "$*" == 'status numbered' ]]; then
      if [[ "$rules_present" == true ]]; then
        printf '[ 1] 55000/tcp ALLOW IN 192.0.2.9 # protocol-benchmark-test\n'
        printf '[ 2] 55000/udp ALLOW IN 192.0.2.9 # protocol-benchmark-test\n'
      fi
    else
      printf '%s\n' "$*" >>"$log"
      [[ "$(wc -l <"$log" | tr -d ' ')" != '2' ]] || rules_present=false
    fi
  }
  FIREWALL_RULE_ADDED=true
  ALLOW_PEER=192.0.2.9
  PORT=55000
  FIREWALL_COMMENT='protocol-benchmark-test'
  cleanup_firewall
  assert_equal 'false' "$FIREWALL_RULE_ADDED" 'firewall cleanup state'
  assert_equal '2' "$(wc -l <"$log" | tr -d ' ')" 'TCP and UDP rules removed'
  assert_equal '--force delete 2' "$(sed -n '1p' "$log")" \
    'higher unique rule number removed first'
  assert_equal '--force delete 1' "$(sed -n '2p' "$log")" \
    'lower unique rule number removed second'
}

test_firewall_server_semantics() {
  local helper="$TEST_TEMP_DIR/ufw-helper.sh"
  local case_dir
  local output
  local status

  cat >"$helper" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
benchmark_script=$1
scenario=$2
port=$3
allow_peer=$4
case_dir=$5
export PROTOCOL_BENCHMARK_SOURCE_ONLY=1
# shellcheck disable=SC1090
source "$benchmark_script"
rules_file="$case_dir/rules"
log_file="$case_dir/log"
: >"$rules_file"
: >"$log_file"
if [[ "$scenario" == existing ]]; then
  printf '[ 1] %s/tcp ALLOW IN Anywhere # user-rule\n' "$port" >>"$rules_file"
  printf '[ 2] 22/tcp ALLOW IN Anywhere # ssh-rule\n' >>"$rules_file"
fi
is_root() { return 0; }
command_exists() {
  if [[ "$1" == ufw ]]; then
    [[ "$scenario" != missing ]]
  else
    command -v "$1" >/dev/null 2>&1
  fi
}
EOF
  test_firewall_server_semantics_continued "$helper"
}

test_platform_and_dependency_bootstrap() {
  local os_file="$TEST_TEMP_DIR/os-release"
  local output
  local status
  local install_log="$TEST_TEMP_DIR/install.log"

  output=$(
    command_exists() { return 0; }
    sed() { printf 'This is not GNU sed version 4.0\n'; }
    if has_gnu_sed; then printf true; else printf false; fi
  )
  assert_equal 'false' "$output" \
    'BusyBox sed version text is not accepted as GNU sed'
  output=$(
    command_exists() { return 0; }
    sed() { printf 'sed (GNU sed) 4.9\n'; }
    if has_gnu_sed; then printf true; else printf false; fi
  )
  assert_equal 'true' "$output" 'GNU sed capability is accepted'
  output=$(
    command_exists() { return 0; }
    timeout() { printf 'timeout (GNU coreutils) 9.11\nadditional text\n'; }
    if has_coreutils_timeout; then printf true; else printf false; fi
  )
  assert_equal 'true' "$output" 'GNU timeout capability is accepted'
  output=$(
    command_exists() { return 0; }
    timeout() { printf 'BusyBox timeout\n'; }
    if has_coreutils_timeout; then printf true; else printf false; fi
  )
  assert_equal 'false' "$output" 'BusyBox timeout is rejected'
  output=$(
    command_exists() { return 0; }
    sort() { printf 'sort (GNU coreutils) 9.11\nadditional text\n'; }
    if has_coreutils_sort; then printf true; else printf false; fi
  )
  assert_equal 'true' "$output" 'GNU sort capability is accepted'
  output=$(
    command_exists() { return 0; }
    ping() { printf 'ping from iputils 20250605\n'; }
    if has_iputils_ping; then printf true; else printf false; fi
  )
  assert_equal 'true' "$output" 'iputils ping capability is accepted'

  for specification in 'debian 12 debian' 'debian 13 debian' \
    'alpine 3.21 alpine' 'alpine 3.22 alpine' 'alpine 3.23 alpine' \
    'alpine 3.24 alpine'; do
    read -r os_id version family <<<"$specification"
    printf 'ID=%s\nVERSION_ID=%s\n' "$os_id" "$version" >"$os_file"
    output=$(OS_RELEASE_FILE="$os_file" check_platform; \
      printf '%s|%s' "$PLATFORM_FAMILY" "$PLATFORM_VERSION")
    assert_equal "$family|$version" "$output" \
      "$os_id $version platform acceptance"
  done
  printf 'ID=alpine\nVERSION_ID=3.23.4\n' >"$os_file"
  output=$(OS_RELEASE_FILE="$os_file" check_platform; \
    printf '%s|%s' "$PLATFORM_FAMILY" "$PLATFORM_VERSION")
  assert_equal 'alpine|3.23' "$output" \
    'Alpine patch release normalizes to supported minor'
  for version in 3.24.0 3.24.1 3.24.999; do
    printf 'ID=alpine\nVERSION_ID=%s\n' "$version" >"$os_file"
    output=$(OS_RELEASE_FILE="$os_file" check_platform; \
      printf '%s|%s' "$PLATFORM_FAMILY" "$PLATFORM_VERSION")
    assert_equal 'alpine|3.24' "$output" \
      "Alpine $version normalizes to supported minor"
  done
  for version in 3.20 3.25 edge; do
    printf 'ID=alpine\nVERSION_ID=%s\n' "$version" >"$os_file"
    assert_false "unsupported Alpine $version is rejected" bash -c '
      export PROTOCOL_BENCHMARK_SOURCE_ONLY=1
      source "$1"
      OS_RELEASE_FILE=$2
      check_platform
    ' _ "$BENCHMARK_SCRIPT" "$os_file"
  done

  output=$(
    MODE=history
    PLATFORM_FAMILY=alpine
    command_exists() { [[ "$1" == jq ]]; }
    has_coreutils_sort() { return 1; }
    collect_missing_dependencies
    printf '%s|%s' "${MISSING_COMMANDS[*]}" "${MISSING_PACKAGES[*]}"
  )
  assert_equal 'coreutils sort|coreutils' "$output" \
    'history installs only its missing sort capability'
  assert_not_contains 'iperf3' "$output" 'history avoids iperf3'
  assert_not_contains 'ping' "$output" 'history avoids ping'
  assert_not_contains 'timeout' "$output" 'history avoids timeout'

  output=$(
    MODE=client
    PLATFORM_FAMILY=debian
    command_exists() { return 1; }
    has_gnu_sed() { return 1; }
    has_coreutils_date() { return 1; }
    has_coreutils_timeout() { return 1; }
    has_iputils_ping() { return 1; }
    collect_missing_dependencies
    printf '%s' "${MISSING_PACKAGES[*]}"
  )
  assert_equal 'mawk sed iperf3 coreutils jq iputils-ping' "$output" \
    'Debian dependency mapping and package deduplication'

  output=$(
    MODE=client
    PLATFORM_FAMILY=alpine
    command_exists() { return 1; }
    has_gnu_sed() { return 1; }
    has_coreutils_date() { return 1; }
    has_coreutils_timeout() { return 1; }
    has_iputils_ping() { return 1; }
    collect_missing_dependencies
    printf '%s' "${MISSING_PACKAGES[*]}"
  )
  assert_equal 'mawk sed iperf3 coreutils jq iputils' "$output" \
    'Alpine dependency mapping and package deduplication'

  : >"$install_log"
  (
    PLATFORM_FAMILY=debian
    MISSING_COMMANDS=(jq iperf3)
    MISSING_PACKAGES=(jq iperf3)
    is_root() { return 0; }
    apt-get() { printf '%s\n' "$*" >>"$install_log"; }
    install_runtime_packages
  )
  assert_equal '2' "$(wc -l <"$install_log" | tr -d ' ')" \
    'Debian uses one update and one install transaction'
  assert_equal 'update' "$(sed -n '1p' "$install_log")" \
    'Debian bootstrap runs apt-get update once'
  assert_equal 'install -y --no-install-recommends jq iperf3' \
    "$(sed -n '2p' "$install_log")" \
    'Debian bootstrap uses no recommends and one package transaction'

  : >"$install_log"
  (
    PLATFORM_FAMILY=debian
    MISSING_COMMANDS=()
    MISSING_PACKAGES=()
    is_root() { return 0; }
    apt-get() { printf '%s\n' "$*" >>"$install_log"; }
    install_runtime_packages
  )
  assert_equal '0' "$(wc -l <"$install_log" | tr -d ' ')" \
    'present dependencies perform no apt operation'

  : >"$install_log"
  (
    PLATFORM_FAMILY=alpine
    MISSING_COMMANDS=(jq mawk)
    MISSING_PACKAGES=(jq mawk)
    is_root() { return 0; }
    apk() { printf '%s\n' "$*" >>"$install_log"; }
    install_runtime_packages
  )
  assert_equal 'add --no-cache jq mawk' "$(cat "$install_log")" \
    'Alpine uses one apk no-cache transaction'

  : >"$install_log"
  (
    PLATFORM_FAMILY=alpine
    MISSING_COMMANDS=(iperf3)
    MISSING_PACKAGES=(iperf3)
    is_root() { return 0; }
    apk() { printf '%s\n' "$*" >>"$install_log"; }
    install_runtime_packages
  )
  assert_equal 'add --no-cache iperf3 !iperf3-openrc' \
    "$(cat "$install_log")" \
    'Alpine excludes the iperf3 OpenRC auto-install subpackage'

  : >"$install_log"
  (
    PLATFORM_FAMILY=debian
    MISSING_COMMANDS=(jq)
    MISSING_PACKAGES=(jq)
    is_root() { return 1; }
    command_exists() { [[ "$1" == sudo ]]; }
    sudo() { printf '%s\n' "$*" >>"$install_log"; }
    install_runtime_packages
  )
  assert_equal '2' "$(wc -l <"$install_log" | tr -d ' ')" \
    'sudo Debian bootstrap still uses two transactions'
  assert_contains 'env DEBIAN_FRONTEND=noninteractive apt-get update' \
    "$(sed -n '1p' "$install_log")" 'sudo preserves noninteractive apt environment'

  : >"$install_log"
  (
    PLATFORM_FAMILY=alpine
    MISSING_COMMANDS=(jq)
    MISSING_PACKAGES=(jq)
    is_root() { return 1; }
    command_exists() { [[ "$1" == doas ]]; }
    doas() { printf '%s\n' "$*" >>"$install_log"; }
    install_runtime_packages
  )
  assert_equal 'apk add --no-cache jq' "$(cat "$install_log")" \
    'Alpine non-root bootstrap uses doas'

  output=$(
    PLATFORM_FAMILY=alpine
    is_root() { return 1; }
    command_exists() { [[ "$1" == doas || "$1" == sudo ]]; }
    choose_privilege_helper
    printf '%s' "$PRIVILEGE_HELPER"
  )
  assert_equal 'doas' "$output" 'Alpine prefers doas over sudo'
  output=$(
    PLATFORM_FAMILY=alpine
    is_root() { return 1; }
    command_exists() { [[ "$1" == sudo ]]; }
    choose_privilege_helper
    printf '%s' "$PRIVILEGE_HELPER"
  )
  assert_equal 'sudo' "$output" 'Alpine falls back to sudo'
  set +e
  output=$( (
    PLATFORM_FAMILY=alpine
    MISSING_COMMANDS=(jq)
    MISSING_PACKAGES=(jq)
    is_root() { return 1; }
    command_exists() { return 1; }
    install_runtime_packages
  ) 2>&1)
  status=$?
  set -e
  assert_false 'missing privilege helper is fatal' test "$status" -eq 0
  assert_contains 'apk add --no-cache jq' "$output" \
    'privilege failure prints manual Alpine command'

  set +e
  (
    PLATFORM_FAMILY=debian
    MISSING_COMMANDS=(jq)
    MISSING_PACKAGES=(jq)
    is_root() { return 0; }
    apt-get() { return 1; }
    install_runtime_packages
  ) >/dev/null 2>&1
  status=$?
  set -e
  assert_false 'apt update failure is fatal' test "$status" -eq 0
  set +e
  (
    local_calls=0
    PLATFORM_FAMILY=debian
    MISSING_COMMANDS=(jq)
    MISSING_PACKAGES=(jq)
    is_root() { return 0; }
    apt-get() {
      (( local_calls += 1 ))
      (( local_calls == 1 ))
    }
    install_runtime_packages
  ) >/dev/null 2>&1
  status=$?
  set -e
  assert_false 'apt install failure is fatal' test "$status" -eq 0
  set +e
  (
    PLATFORM_FAMILY=alpine
    MISSING_COMMANDS=(jq)
    MISSING_PACKAGES=(jq)
    is_root() { return 0; }
    apk() { return 1; }
    install_runtime_packages
  ) >/dev/null 2>&1
  status=$?
  set -e
  assert_false 'apk failure is fatal' test "$status" -eq 0

  set +e
  (
    MODE=history
    PLATFORM_FAMILY=alpine
    command_exists() { return 0; }
    collect_missing_dependencies() {
      MISSING_COMMANDS=('coreutils sort')
      MISSING_PACKAGES=(coreutils)
    }
    install_runtime_packages() { :; }
    check_dependencies
  ) >/dev/null 2>&1
  status=$?
  set -e
  assert_false 'post-install capability recheck is fatal' test "$status" -eq 0

  : >"$install_log"
  (
    PLATFORM_FAMILY=debian
    IPERF3_INSTALLED_NOW=false
    systemctl() { printf '%s\n' "$*" >>"$install_log"; return 0; }
    ensure_new_iperf3_daemon_disabled
  )
  assert_equal '0' "$(wc -l <"$install_log" | tr -d ' ')" \
    'pre-existing iperf3 service is untouched'
  : >"$install_log"
  (
    PLATFORM_FAMILY=debian
    IPERF3_INSTALLED_NOW=true
    run_privileged() { "$@"; }
    systemctl() {
      printf '%s\n' "$*" >>"$install_log"
      case "$1" in
        is-active) return 1 ;;
        is-enabled) printf 'disabled\n'; return 1 ;;
      esac
    }
    ensure_new_iperf3_daemon_disabled
  )
  assert_contains 'stop iperf3.service' "$(cat "$install_log")" \
    'new Debian iperf3 service is stopped'
  assert_contains 'disable iperf3.service' "$(cat "$install_log")" \
    'new Debian iperf3 service is disabled'
  assert_contains "alpine_packages+=('!iperf3-openrc')" \
    "$(cat "$BENCHMARK_SCRIPT")" \
    'Alpine bootstrap blocks the OpenRC subpackage'
  assert_false 'Alpine bootstrap never enables OpenRC iperf3 service' \
    grep -Eq 'rc-update[[:space:]]+add|rc-service[[:space:]]+iperf3' \
    "$BENCHMARK_SCRIPT"
}

test_firewall_server_semantics_continued() {
  local helper=$1
  local case_dir
  local output
  local status

  cat >>"$helper" <<'EOF'
ufw() {
  local argument
  local protocol=''
  local marker=''
  local peer='Anywhere'
  local number
  if [[ "$*" == status ]]; then
    if [[ "$scenario" == inactive ]]; then
      printf 'Status: inactive\n'
    else
      printf 'Status: active\n'
    fi
    return 0
  fi
  if [[ "$*" == 'status numbered' ]]; then
    [[ "$scenario" == verify-fail ]] || cat "$rules_file"
    return 0
  fi
  if [[ "$1" == --force && "$2" == delete ]]; then
    if [[ "$3" =~ ^[0-9]+$ ]]; then
      number=$3
      awk -v drop="$number" 'NR != drop' "$rules_file" >"$rules_file.tmp"
    else
      marker=${*: -1}
      awk -v marker="$marker" 'index($0, "# " marker) == 0' \
        "$rules_file" >"$rules_file.tmp"
    fi
    mv -- "$rules_file.tmp" "$rules_file"
    printf '%s\n' "$*" >>"$log_file"
    return 0
  fi
  printf '%s\n' "$*" >>"$log_file"
  for argument in "$@"; do
    [[ "$argument" != tcp && "$argument" != udp ]] || protocol=$argument
  done
  if [[ "$*" == *' from '* ]]; then
    while (( $# > 0 )); do
      if [[ "$1" == from ]]; then peer=$2; break; fi
      shift
    done
  fi
  marker=${*: -1}
  if [[ "$scenario" == udp-fail && "$protocol" == udp ]]; then
    return 1
  fi
  number=$(( $(wc -l <"$rules_file") + 1 ))
  printf '[ %s] %s/%s ALLOW IN %s # %s\n' \
    "$number" "$port" "$protocol" "$peer" "$marker" >>"$rules_file"
}
MODE=server
PORT=$port
[[ "$port" != RANDOM ]] || PORT=$(random_port)
ALLOW_PEER=$allow_peer
setup_firewall
printf 'PORT=%s\nSTATUS=%s\nCOMMENT=%s\n' \
  "$PORT" "$FIREWALL_STATUS" "$FIREWALL_COMMENT"
if [[ "$scenario" == signal ]]; then
  printf 'ready\n' >"$case_dir/ready"
  while true; do sleep 1; done
fi
cleanup_firewall
printf 'ADDED=%s\n' "$FIREWALL_RULE_ADDED"
EOF
  chmod +x "$helper"

  case_dir="$TEST_TEMP_DIR/ufw-active"
  mkdir -p "$case_dir"
  output=$(bash "$helper" "$BENCHMARK_SCRIPT" active 55010 '' "$case_dir")
  assert_contains 'STATUS=temporary TCP/UDP allow added' "$output" \
    'plain server automatically opens active UFW'
  assert_contains 'allow to any port 55010 proto tcp' "$(cat "$case_dir/log")" \
    'plain server adds Anywhere TCP rule'
  assert_contains 'allow to any port 55010 proto udp' "$(cat "$case_dir/log")" \
    'plain server adds Anywhere UDP rule'
  assert_not_contains 'protocol-benchmark-' "$(cat "$case_dir/rules")" \
    'normal cleanup removes all benchmark comments'

  case_dir="$TEST_TEMP_DIR/ufw-peer"
  mkdir -p "$case_dir"
  output=$(bash "$helper" "$BENCHMARK_SCRIPT" active 55011 192.0.2.8 "$case_dir")
  assert_contains 'STATUS=temporary TCP/UDP allow from 192.0.2.8' "$output" \
    'allow-peer reports restricted rule'
  assert_contains 'allow from 192.0.2.8 to any port 55011 proto tcp' \
    "$(cat "$case_dir/log")" 'allow-peer restricts TCP source'
  assert_contains 'allow from 192.0.2.8 to any port 55011 proto udp' \
    "$(cat "$case_dir/log")" 'allow-peer restricts UDP source'

  case_dir="$TEST_TEMP_DIR/ufw-random"
  mkdir -p "$case_dir"
  output=$(bash "$helper" "$BENCHMARK_SCRIPT" active RANDOM '' "$case_dir")
  assert_true 'random server port is high and numeric' bash -c \
    'value=${1#PORT=}; [[ $value =~ ^[0-9]+$ ]] && (( value >= 49152 && value <= 65535 ))' \
    _ "$(printf '%s\n' "$output" | sed -n '1p')"
  assert_contains "port $(printf '%s\n' "$output" | sed -n '1s/PORT=//p')" \
    "$(cat "$case_dir/log")" 'UFW uses the generated random port'

  for scenario in inactive missing; do
    case_dir="$TEST_TEMP_DIR/ufw-$scenario"
    mkdir -p "$case_dir"
    output=$(bash "$helper" "$BENCHMARK_SCRIPT" "$scenario" 55012 '' \
      "$case_dir" 2>&1)
    assert_contains 'STATUS=unchanged' "$output" \
      "plain server continues when UFW is $scenario"
    assert_equal '0' "$(wc -l <"$case_dir/log" | tr -d ' ')" \
      "plain server does not modify $scenario UFW"
    set +e
    bash "$helper" "$BENCHMARK_SCRIPT" "$scenario" 55012 192.0.2.8 \
      "$case_dir" >/dev/null 2>&1
    status=$?
    set -e
    assert_false "allow-peer fails when UFW is $scenario" test "$status" -eq 0
  done

  for scenario in udp-fail verify-fail; do
    case_dir="$TEST_TEMP_DIR/ufw-$scenario"
    mkdir -p "$case_dir"
    set +e
    bash "$helper" "$BENCHMARK_SCRIPT" "$scenario" 55013 '' "$case_dir" \
      >/dev/null 2>&1
    status=$?
    set -e
    assert_false "$scenario is a hard setup failure" test "$status" -eq 0
    assert_not_contains 'protocol-benchmark-' "$(cat "$case_dir/rules")" \
      "$scenario rolls back every script-owned rule"
  done

  case_dir="$TEST_TEMP_DIR/ufw-existing"
  mkdir -p "$case_dir"
  bash "$helper" "$BENCHMARK_SCRIPT" existing 55014 '' "$case_dir" >/dev/null
  assert_contains '55014/tcp ALLOW IN Anywhere # user-rule' \
    "$(cat "$case_dir/rules")" 'same-port user rule is preserved'
  assert_contains '22/tcp ALLOW IN Anywhere # ssh-rule' \
    "$(cat "$case_dir/rules")" 'unrelated UFW rule is preserved'
  assert_not_contains 'protocol-benchmark-' "$(cat "$case_dir/rules")" \
    'existing-rule cleanup leaves no benchmark comment'

  if [[ ${OSTYPE:-} != msys* && ${OSTYPE:-} != cygwin* ]]; then
    case_dir="$TEST_TEMP_DIR/ufw-signal"
    mkdir -p "$case_dir"
    set +e
    timeout --preserve-status --signal=INT 2 \
      bash "$helper" "$BENCHMARK_SCRIPT" signal 55015 '' "$case_dir" \
      >/dev/null 2>&1
    status=$?
    set -e
    assert_equal '130' "$status" 'Ctrl+C preserves interrupt exit status'
    assert_not_contains 'protocol-benchmark-' "$(cat "$case_dir/rules")" \
      'Ctrl+C removes temporary UFW rules'
  fi

  output=$(bash -c '
    export PROTOCOL_BENCHMARK_SOURCE_ONLY=1
    source "$1"
    MODE=server; PORT=""; SERVER_WAIT=30
    random_port() { printf "54036\\n"; }
    setup_firewall() { FIREWALL_STATUS="temporary TCP/UDP allow added"; }
    timeout() { return 124; }
    run_server
  ' _ "$BENCHMARK_SCRIPT")
  assert_contains 'Port:         54036 (TCP and UDP)' "$output" \
    'server output shows generated port'
  assert_contains 'Firewall:     temporary TCP/UDP allow added' "$output" \
    'server output shows firewall lifecycle'
  assert_contains 'SERVER_IP --port 54036' "$output" \
    'server output gives copyable placeholder command'
  assert_contains 'idle timeout before the first client session' "$output" \
    'server distinguishes first-client idle timeout'
}

test_server_supervisor_lifecycle() {
  local helper="$TEST_TEMP_DIR/server-supervisor-helper.sh"
  local case_dir
  local output
  local status
  local index

  cat >"$helper" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
benchmark_script=$1
case_dir=$2
export PROTOCOL_BENCHMARK_SOURCE_ONLY=1
# shellcheck disable=SC1090
source "$benchmark_script"

next_value() {
  local value_file=$1
  local index_file="$value_file.index"
  local current=0
  [[ ! -s "$index_file" ]] || current=$(cat "$index_file")
  (( current += 1 ))
  printf '%s\n' "$current" >"$index_file"
  sed -n "${current}p" "$value_file"
}

date() {
  [[ "${1:-}" == '+%s' ]] || command date "$@"
  next_value "$case_dir/times"
}

timeout() {
  local result
  printf '%s\n' "$2" >>"$case_dir/waits"
  result=$(next_value "$case_dir/statuses")
  return "$result"
}

sleep() { :; }
setup_firewall() { FIREWALL_STATUS='unchanged (test)'; }
MODE=server
PORT=55120
SERVER_WAIT=600
run_server
EOF
  chmod +x "$helper"

  case_dir="$TEST_TEMP_DIR/server-complete"
  mkdir -p "$case_dir"
  : >"$case_dir/statuses"
  for (( index=1; index<=8; index++ )); do printf '0\n' >>"$case_dir/statuses"; done
  printf '124\n' >>"$case_dir/statuses"
  printf '1000\n1000\n' >"$case_dir/times"
  for (( index=1; index<=8; index++ )); do
    printf '%s\n%s\n' "$((1000 + index))" "$((1000 + index))" \
      >>"$case_dir/times"
  done
  output=$(bash "$helper" "$BENCHMARK_SCRIPT" "$case_dir" 2>&1)
  assert_contains 'Completed test 8; waiting 120s for the next stage.' "$output" \
    'complete multi-stage benchmark keeps restarting one-shot listener'
  assert_contains 'idle timeout after the last test (120s, 8 completed)' "$output" \
    'server reports last-test idle timeout explicitly'
  assert_equal '9' "$(wc -l <"$case_dir/waits" | tr -d ' ')" \
    'eight sessions plus final idle watchdog are supervised'

  case_dir="$TEST_TEMP_DIR/server-gap"
  mkdir -p "$case_dir"
  printf '0\n0\n124\n' >"$case_dir/statuses"
  printf '1000\n1000\n1002\n1027\n1029\n1029\n' >"$case_dir/times"
  output=$(bash "$helper" "$BENCHMARK_SCRIPT" "$case_dir" 2>&1)
  assert_equal $'600\n95\n120' "$(cat "$case_dir/waits")" \
    '25-second inter-test gap remains inside the 120-second watchdog'
  assert_contains 'Completed test 2' "$output" \
    'server remains available after a 25-second logical gap'

  case_dir="$TEST_TEMP_DIR/server-recoverable-error"
  mkdir -p "$case_dir"
  printf '0\n1\n0\n124\n' >"$case_dir/statuses"
  printf '1000\n1000\n1001\n1002\n1003\n1004\n1004\n' >"$case_dir/times"
  output=$(bash "$helper" "$BENCHMARK_SCRIPT" "$case_dir" 2>&1)
  assert_contains 'retrying listener (1/3)' "$output" \
    'one failed iperf3 session is recoverable'
  assert_contains 'Completed test 2' "$output" \
    'successful session after an error resets the error counter'
  assert_not_contains 'unrecoverable iperf3 server failure' "$output" \
    'single session error does not terminate supervisor'

  case_dir="$TEST_TEMP_DIR/server-unrecoverable-error"
  mkdir -p "$case_dir"
  printf '1\n1\n1\n' >"$case_dir/statuses"
  printf '1000\n1000\n1001\n1002\n' >"$case_dir/times"
  set +e
  output=$(bash "$helper" "$BENCHMARK_SCRIPT" "$case_dir" 2>&1)
  status=$?
  set -e
  assert_equal '1' "$status" 'three consecutive server errors are fatal'
  assert_contains 'unrecoverable iperf3 server failure after 3 consecutive error(s)' \
    "$output" 'unrecoverable server failure has a distinct exit reason'
}

test_listener_cleanup_traps() {
  local helper="$TEST_TEMP_DIR/listener-helper.sh"
  local mode
  local listener_pid
  local pid_file
  local status
  local -a modes=(normal interrupt)

  cat >"$helper" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
benchmark_script=$1
mode=$2
pid_file=$3
export PROTOCOL_BENCHMARK_SOURCE_ONLY=1
# shellcheck disable=SC1090
source "$benchmark_script"
TEMP_DIR=$(mktemp -d /tmp/protocol-benchmark-listener-test.XXXXXXXX)
sleep 60 &
ACTIVE_IPERF_PID=$!
printf '%s\n' "$ACTIVE_IPERF_PID" >"$pid_file"
if [[ "$mode" == 'normal' ]]; then
  exit 0
fi
while true; do
  sleep 1
done
EOF

  if [[ ${OSTYPE:-} == msys* || ${OSTYPE:-} == cygwin* ]]; then
    modes=(normal)
  fi
  for mode in "${modes[@]}"; do
    pid_file="$TEST_TEMP_DIR/$mode.pid"
    set +e
    if [[ "$mode" == 'normal' ]]; then
      bash "$helper" "$BENCHMARK_SCRIPT" "$mode" "$pid_file"
    else
      timeout --preserve-status --signal=INT 1 \
        bash "$helper" "$BENCHMARK_SCRIPT" "$mode" "$pid_file"
    fi
    status=$?
    set -e
    [[ -s "$pid_file" ]] || fail "$mode cleanup helper did not start"
    listener_pid=$(cat "$pid_file")
    if [[ "$mode" == 'normal' ]]; then
      assert_equal '0' "$status" 'normal exit status'
    else
      assert_equal '130' "$status" 'SIGINT exit status'
    fi
    assert_false "$mode exit must not retain the listener child" \
      process_exists "$listener_pid"
  done
}

test_baseline_save_and_compare() {
  local output
  reset_fixture
  PROTOCOL_BENCHMARK_STATE_DIR="$TEST_TEMP_DIR/state"
  export PROTOCOL_BENCHMARK_STATE_DIR
  PEER=192.0.2.10
  NOMINAL_MBPS=500
  STATUS=HEALTHY
  TCP_SCORE=92
  UDP_SCORE=95
  LINK_HEALTH=94
  IDLE_RTT=37.4
  save_baseline >/dev/null
  assert_true 'baseline JSON saved' test -f "$PROTOCOL_BENCHMARK_STATE_DIR/192.0.2.10.json"
  assert_equal '92' "$(jq -r '.tcp_score' "$PROTOCOL_BENCHMARK_STATE_DIR/192.0.2.10.json")" \
    'baseline TCP score'
  IDLE_RTT=39
  TCP_SCORE=91
  UDP_SCORE=94
  LINK_HEALTH=93
  STATUS=HEALTHY
  output=$(compare_baseline)
  assert_contains 'CURRENT vs BASELINE' "$output" 'baseline comparison heading'
  assert_contains 'insignificant' "$output" 'insignificant baseline change'
}

prepare_history_fixture() {
  reset_fixture
  PROTOCOL_BENCHMARK_STATE_DIR="$TEST_TEMP_DIR/history-state"
  export PROTOCOL_BENCHMARK_STATE_DIR
  PEER=history.example
  NOMINAL_MBPS=500
  PING_AVG=31.5
  TRAFFIC_ACTUAL_BYTES=8000000
  TCP_ADAPTIVE_STOP=true
  UDP_ADAPTIVE_STOP=false
  TCP_STOP_STAGE=10
  TCP_HIGHEST_STAGE=10
  UDP_HIGHEST_STAGE=20
  EARLY_STOP=false
  append_result TCP A_TO_B 5 25 2 0 4 1111111
  append_result TCP B_TO_A 5 25 0 0 5 2222222
  append_result TCP A_TO_B 10 50 3 0 6 3333333
  append_result TCP B_TO_A 10 50 0 0 7 4444444
  append_result UDP A_TO_B 5 25 0 0.02 4 5555555
  append_result UDP B_TO_A 5 25 0 0.03 5 6666666
  append_result UDP A_TO_B 20 100 0 0.04 6 7777777
  append_result UDP B_TO_A 20 100 0 0.05 7 8888888
  calculate_results
}

test_history_persistence_and_schema() {
  local directory
  local file
  local output
  local scores_before
  local scores_after
  local -a files=()

  prepare_history_fixture
  scores_before="$TCP_SCORE|$UDP_SCORE|$LINK_HEALTH|$STATUS|$PREFERRED|$EARLY_STOP"
  persist_history >/dev/null
  scores_after="$TCP_SCORE|$UDP_SCORE|$LINK_HEALTH|$STATUS|$PREFERRED|$EARLY_STOP"
  assert_equal "$scores_before" "$scores_after" \
    'history save does not mutate scoring recommendation or adaptive state'
  directory=$(history_peer_directory "$PEER")
  mapfile -t files < <(list_history_files "$directory")
  assert_equal '1' "${#files[@]}" 'HEALTHY result automatically persists history'
  file="$directory/${files[0]}"
  assert_true 'history entry is valid JSON' bash -c \
    'jq -e . "$1" >/dev/null' _ "$file"
  if [[ "$(uname -s)" != MINGW* ]]; then
    assert_equal '700' "$(stat -c %a "$directory")" \
      'history peer directory permission'
    assert_equal '600' "$(stat -c %a "$file")" 'history JSON permission'
  fi
  assert_equal 'history.example' "$(jq -r '.peer' "$file")" 'history peer metadata'
  assert_equal '500' "$(jq -r '.nominal_bandwidth_mbps' "$file")" \
    'history nominal bandwidth metadata'
  assert_equal 'LOW-IMPACT' "$(jq -r '.benchmark_mode' "$file")" \
    'history benchmark mode metadata'
  assert_equal '20' "$(jq -r '.highest_overall_stage_reached_percent' "$file")" \
    'history highest overall stage'
  assert_equal '6666666' \
    "$(jq -r '.tcp.directions.b_to_a.transferred_bytes' "$file")" \
    'history transferred bytes use summed raw scoring counters'
  assert_equal 'true|false|10|20' "$(jq -r '[.tcp.adaptive_stop,
    .udp.adaptive_stop,.tcp.highest_stage_reached_percent,
    .udp.highest_stage_reached_percent] | map(tostring) | join("|")' "$file")" \
    'history stores independent protocol adaptive stops'
  assert_true 'history contains TCP stage records' jq -e \
    '.tcp.stages | length == 4' "$file"
  assert_true 'history contains UDP stage records' jq -e \
    '.udp.stages | length == 4' "$file"
  assert_true 'history contains latency and overall fields' jq -e \
    '.latency.idle_rtt_ms == 30 and .overall.traffic_used_bytes == 8000000 and
      (.overall.preferred_reason | type == "string")' "$file"

  STATUS=DEGRADED
  LINK_HEALTH=60
  persist_history >/dev/null
  STATUS=POOR
  LINK_HEALTH=40
  PREFERRED='FIX LINK'
  persist_history >/dev/null
  mapfile -t files < <(list_history_files "$directory")
  assert_equal '3' "${#files[@]}" 'HEALTHY DEGRADED and POOR all persist'
  assert_equal 'DEGRADED,HEALTHY,POOR' "$(for file in "${files[@]}"; do
    jq -r '.overall.status' "$directory/$file"
  done | tr -d '\r' | sort | paste -sd, -)" \
    'all result statuses are present in history'

  PROTOCOL_BENCHMARK_STATE_DIR="$TEST_TEMP_DIR/history-write-failure"
  : >"$PROTOCOL_BENCHMARK_STATE_DIR"
  output=$(persist_history 2>&1)
  assert_contains 'History could not be saved' "$output" \
    'history write failure is only a warning'

  reset_fixture
  PROTOCOL_BENCHMARK_STATE_DIR="$TEST_TEMP_DIR/no-valid-result"
  export PROTOCOL_BENCHMARK_STATE_DIR
  PEER=unreachable.example
  NOMINAL_MBPS=100
  calculate_results
  persist_history
  assert_false 'no valid bidirectional samples create no history entry' \
    test -e "$(history_peer_directory "$PEER")"
}

test_history_peer_keys_and_cli() {
  local ipv4_key ipv6_key host_key traversal_key output

  ipv4_key=$(history_peer_key 192.0.2.1)
  ipv6_key=$(history_peer_key 2001:db8::1)
  host_key=$(history_peer_key edge.example)
  traversal_key=$(history_peer_key ../escape)
  assert_true 'IPv4 peer key is deterministic and safe' \
    test "$ipv4_key" = "$(history_peer_key 192.0.2.1)"
  assert_false 'IPv6 peer key has no path separator' grep -q '[/\\]' <<<"$ipv6_key"
  assert_false 'hostname peer key has no dot traversal' grep -q '[.]' <<<"$host_key"
  assert_false 'traversal input cannot escape peer directory' grep -q '[/\\.]' \
    <<<"$traversal_key"
  assert_false 'common peer forms do not collide' test "$ipv4_key" = "$ipv6_key"

  output=$(bash -c 'source "$1"; parse_args --history 192.0.2.1;
    printf "%s|%s|%s" "$MODE" "$PEER" "$HISTORY_LIMIT"' _ "$BENCHMARK_SCRIPT")
  assert_equal 'history|192.0.2.1|20' "$output" 'history CLI default limit'
  output=$(bash -c 'source "$1"; parse_args --history host.example --limit 10;
    printf "%s|%s|%s" "$MODE" "$PEER" "$HISTORY_LIMIT"' _ "$BENCHMARK_SCRIPT")
  assert_equal 'history|host.example|10' "$output" 'history CLI explicit limit'
  for invalid in 0 -1 abc 101; do
    assert_false "invalid history limit rejected: $invalid" bash -c \
      'source "$1"; parse_args --history host.example --limit "$2"' \
      _ "$BENCHMARK_SCRIPT" "$invalid"
  done
  assert_false 'history mode rejects benchmark port' bash -c \
    'source "$1"; parse_args --history host.example --port 55000' \
    _ "$BENCHMARK_SCRIPT"
}

test_history_display_and_retention() {
  local base_file
  local directory
  local filename
  local index
  local output
  local other_directory
  local baseline_marker
  local notes_file

  prepare_history_fixture
  persist_history >/dev/null
  base_file="$(history_peer_directory "$PEER")/$(list_history_files \
    "$(history_peer_directory "$PEER")" | head -n 1)"

  PEER=display.example
  directory=$(ensure_history_directory)
  for (( index=1; index<=25; index++ )); do
    printf -v filename '20260810T000000%09dZ.json' "$index"
    jq --arg timestamp "$(printf '2026-08-10T00:00:%02dZ' "$index")" \
      --argjson score "$index" '.timestamp=$timestamp | .tcp.score=$score' \
      "$base_file" >"$directory/$filename"
    chmod 0600 "$directory/$filename"
  done
  HISTORY_LIMIT=$DEFAULT_HISTORY_LIMIT
  output=$(show_history)
  assert_equal '21' "$(printf '%s\n' "$output" | awk 'END {print NR}')" \
    'history defaults to header plus 20 entries'
  assert_contains '2026-08-10 00:00:25' "$(printf '%s\n' "$output" | sed -n '2p')" \
    'history displays newest entry first'
  HISTORY_LIMIT=10
  output=$(show_history)
  assert_equal '11' "$(printf '%s\n' "$output" | awk 'END {print NR}')" \
    'history explicit limit restricts output'
  assert_equal '25' "$(printf '%s\n' "$output" | sed -n '2p' | awk '{print $3}')" \
    'newest history score is first'
  assert_equal '16' "$(printf '%s\n' "$output" | sed -n '11p' | awk '{print $3}')" \
    'history limit preserves descending order'
  local count_before
  count_before=$(find "$directory" -maxdepth 1 -type f | wc -l)
  show_history >/dev/null
  assert_equal "$count_before" "$(find "$directory" -maxdepth 1 -type f | wc -l)" \
    'history display creates no new entry'

  PEER=missing.example
  output=$(show_history)
  assert_contains 'No history found' "$output" 'missing history is a normal message'
  assert_false 'missing history view does not create peer directory' \
    test -e "$(history_peer_directory "$PEER")"

  PEER=other.example
  other_directory=$(ensure_history_directory)
  cp -- "$base_file" "$other_directory/20260810T000000000000001Z.json"
  baseline_marker="$(baseline_directory)/baseline-keep.json"
  notes_file="$(baseline_directory)/history/notes.txt"
  printf 'keep\n' >"$baseline_marker"
  printf 'keep\n' >"$notes_file"
  PEER=retention.example
  directory=$(ensure_history_directory)
  for (( index=1; index<=101; index++ )); do
    printf -v filename '20260810T000000%09dZ.json' "$index"
    cp -- "$base_file" "$directory/$filename"
  done
  persist_history >/dev/null
  assert_equal '100' "$(list_history_files "$directory" | wc -l)" \
    'retention keeps exactly 100 entries per peer'
  assert_false 'retention removes oldest history entry' \
    test -e "$directory/20260810T000000000000001Z.json"
  assert_true 'retention keeps newest history entry' \
    test -e "$directory/20260810T000000000000101Z.json"
  assert_true 'retention preserves baseline file' test -f "$baseline_marker"
  assert_true 'retention preserves other peer history' \
    test -f "$other_directory/20260810T000000000000001Z.json"
  assert_true 'retention preserves non-history files' test -f "$notes_file"
}

test_history_modes_are_read_only() {
  local marker="$TEST_TEMP_DIR/history-side-effect"

  rm -f -- "$marker"
  (
    MODE=client
    PEER=''
    PORT=''
    ALLOW_PEER=''
    NOMINAL_MBPS=''
    DEEP=false
    SAVE_BASELINE=false
    COMPARE_BASELINE=false
    HISTORY_LIMIT=$DEFAULT_HISTORY_LIMIT
    HISTORY_LIMIT_SET=false
    PROTOCOL_BENCHMARK_STATE_DIR="$TEST_TEMP_DIR/read-only-state"
    check_platform() { :; }
    check_dependencies() { :; }
    run_client() { : >"$marker"; }
    run_server() { : >"$marker"; }
    setup_firewall() { : >"$marker"; }
    save_history() { : >"$marker"; }
    main --history no-history.example >/dev/null
  )
  assert_false 'history mode starts no benchmark server client or UFW action' \
    test -e "$marker"

  (
    MODE=client
    PEER=''
    PORT=''
    ALLOW_PEER=''
    NOMINAL_MBPS=''
    DEEP=false
    SAVE_BASELINE=false
    COMPARE_BASELINE=false
    HISTORY_LIMIT=$DEFAULT_HISTORY_LIMIT
    HISTORY_LIMIT_SET=false
    check_platform() { :; }
    check_dependencies() { :; }
    run_server() { :; }
    save_history() { : >"$marker"; }
    main --server --server-wait 30 >/dev/null
  )
  assert_false 'server mode creates no history' test -e "$marker"

  assert_false 'fatal argument parsing creates no history' bash -c \
    'source "$1"; main --history' _ "$BENCHMARK_SCRIPT"
  assert_false 'fatal path has no history side effect' test -e "$marker"

  rm -f -- "$marker"
  (
    PEER=controller.example
    NOMINAL_MBPS=100
    DEEP=false
    SAVE_BASELINE=false
    COMPARE_BASELINE=false
    choose_bandwidth() { :; }
    collect_idle_baseline() { :; }
    run_adaptive_matrix() { :; }
    calculate_results() { :; }
    print_results() { :; }
    persist_history() { : >"$marker"; }
    run_client
    rm -rf -- "$TEMP_DIR"
    TEMP_DIR=''
  )
  assert_true 'normal controller flow invokes automatic history persistence' \
    test -f "$marker"
}

test_repository_invariants() {
  local content
  content=$(cat "$BENCHMARK_SCRIPT")
  assert_contains 'set -Eeuo pipefail' "$content" 'strict mode'
  assert_contains "levels=(5 10 20)" "$content" 'default adaptive levels'
  assert_contains "'A_TO_B'" "$content" 'forward direction'
  assert_contains "'B_TO_A'" "$content" 'reverse direction'
  assert_contains 'trap signal_exit INT TERM HUP' "$content" \
    'listener cleanup signal traps'
  assert_contains 'Server stopped: manual signal' "$content" \
    'server reports manual signal as a distinct exit reason'
  assert_contains "PLATFORM_FAMILY='debian'" "$content" \
    'Debian platform family is explicit'
  assert_contains "PLATFORM_FAMILY='alpine'" "$content" \
    'Alpine platform family is explicit'
  assert_contains 'apk add --no-cache' "$content" \
    'Alpine dependency bootstrap is bounded'
  assert_contains 'apt-get install -y' "$content" \
    'Debian dependency bootstrap is noninteractive and bounded'
  assert_contains 'temporary TCP/UDP allow added' "$content" \
    'plain server active-UFW behavior is explicit'
  assert_contains 'This does NOT prove the sing-box/proxy layer is healthy.' \
    "$content" 'layer distinction'
  assert_false 'must not query ASN' grep -Eqi 'whois|ipinfo|asn' "$BENCHMARK_SCRIPT"
  assert_false 'must not modify network tuning or proxies' \
    grep -Eqi 'sysctl|mtu|congestion|bbr|sing-box.*(install|config)' "$BENCHMARK_SCRIPT"
  assert_false 'must not run route probing' \
    grep -Eqi 'traceroute|mtr|nexttrace' "$BENCHMARK_SCRIPT"
  assert_false 'dependency bootstrap must not upgrade the OS' \
    grep -Eqi '(apt(-get)?|apk)[[:space:]]+(dist-upgrade|full-upgrade|upgrade)' \
    "$BENCHMARK_SCRIPT"
  assert_false 'dependency bootstrap must not install firewall packages' \
    grep -Eqi '(apt-get install|apk add).*(ufw|nftables|iptables)' \
    "$BENCHMARK_SCRIPT"
}

test_limits_and_scaling
test_validation
test_json_ping_parser
test_iperf_json_execution
test_adaptive_healthy_early_stop
test_udp_degradation_early_stop
test_independent_adaptive_stop_diagnostics
test_failure_control_flow_and_evaluability
test_server_disappearance_classification
test_failure_reason_and_reservation_lifecycle
test_scores_and_recommendation
test_preferred_transport_model
test_tcp_retransmission_scoring_model
test_directional_asymmetry_regressions
test_firewall_cleanup_exactness
test_firewall_server_semantics
test_platform_and_dependency_bootstrap
test_server_supervisor_lifecycle
test_listener_cleanup_traps
test_baseline_save_and_compare
test_history_persistence_and_schema
test_history_peer_keys_and_cli
test_history_display_and_retention
test_history_modes_are_read_only
test_repository_invariants

printf 'PASS: %d protocol benchmark assertions\n' "$TEST_COUNT"
