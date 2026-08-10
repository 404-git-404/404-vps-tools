#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2329

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
  : >"$log"
  ufw() {
    if [[ "$*" == 'status numbered' ]]; then
      printf '[ 1] 55000/tcp ALLOW IN 192.0.2.9 # protocol-benchmark-test\n'
      printf '[ 2] 55000/udp ALLOW IN 192.0.2.9 # protocol-benchmark-test\n'
    else
      printf '%s\n' "$*" >>"$log"
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
  assert_contains 'This does NOT prove the sing-box/proxy layer is healthy.' \
    "$content" 'layer distinction'
  assert_false 'must not query ASN' grep -Eqi 'whois|ipinfo|asn' "$BENCHMARK_SCRIPT"
  assert_false 'must not modify network tuning or proxies' \
    grep -Eqi 'sysctl|mtu|congestion|bbr|sing-box.*(install|config)' "$BENCHMARK_SCRIPT"
  assert_false 'must not run route probing' \
    grep -Eqi 'traceroute|mtr|nexttrace' "$BENCHMARK_SCRIPT"
}

test_limits_and_scaling
test_validation
test_json_ping_parser
test_iperf_json_execution
test_adaptive_healthy_early_stop
test_udp_degradation_early_stop
test_independent_adaptive_stop_diagnostics
test_scores_and_recommendation
test_preferred_transport_model
test_tcp_retransmission_scoring_model
test_directional_asymmetry_regressions
test_firewall_cleanup_exactness
test_listener_cleanup_traps
test_baseline_save_and_compare
test_history_persistence_and_schema
test_history_peer_keys_and_cli
test_history_display_and_retention
test_history_modes_are_read_only
test_repository_invariants

printf 'PASS: %d protocol benchmark assertions\n' "$TEST_COUNT"
