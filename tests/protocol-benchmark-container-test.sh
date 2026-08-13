#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly TEST_DIR
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd)
readonly REPO_ROOT
readonly RUN_ID="protocol-benchmark-${RANDOM}-$$"
readonly NETWORK_NAME="$RUN_ID-network"
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/protocol-container-tests.XXXXXXXX")
readonly TEMP_DIR
FINAL_STATUS=0
declare -a CONTAINERS=()

fail() {
  FINAL_STATUS=1
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local container
  local status=$?

  (( FINAL_STATUS == 0 )) || status=$FINAL_STATUS
  trap - EXIT INT TERM HUP
  for container in "${CONTAINERS[@]}"; do
    docker rm -f "$container" >/dev/null 2>&1 || true
  done
  docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
  if [[ "$TEMP_DIR" == "${TMPDIR:-/tmp}"/* && -d "$TEMP_DIR" ]]; then
    docker run --rm --mount "type=bind,src=$TEMP_DIR,dst=/cleanup" \
      alpine:3.22 sh -ec 'chmod -R a+rwx /cleanup' >/dev/null 2>&1 || true
    rm -rf -- "$TEMP_DIR"
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT TERM HUP

command -v docker >/dev/null 2>&1 || fail 'Docker is required for container validation.'
docker info >/dev/null 2>&1 || fail 'Docker daemon is unavailable.'
docker network create "$NETWORK_NAME" >/dev/null

bootstrap_command() {
  case "$1" in
    alpine:*) printf '%s\n' 'apk add --no-cache bash >/dev/null' ;;
    debian:*) printf '%s\n' ':' ;;
    *) return 1 ;;
  esac
}

run_closed_port_failure() {
  local image=$1
  local label=$2
  local bootstrap
  local log="$TEMP_DIR/$label-closed-port.log"
  local status

  bootstrap=$(bootstrap_command "$image") || return 1
  set +e
  docker run --rm --network "$NETWORK_NAME" \
    --mount "type=bind,src=$REPO_ROOT,dst=/work,readonly" \
    "$image" sh -ec "$bootstrap; bash /work/protocol-benchmark.sh \
      127.0.0.1 --port 65534 --bandwidth 10" >"$log" 2>&1
  status=$?
  set -e
  (( status != 0 )) || fail "$label closed-port benchmark unexpectedly succeeded."
  grep -Fq 'FAILED:' "$log" || fail "$label did not print an iperf3 failure reason."
  grep -Fq 'TEST RESULT:   FAILED' "$log" || fail "$label did not enter no-data failure state."
  grep -Fq 'No valid bidirectional TCP or UDP' "$log" || fail "$label did not explain no valid data."
  grep -Fq 'Traffic used:  0.0 MB' "$log" || fail "$label reported traffic for immediate refusal."
  grep -Fq 'Budget stop:   false' "$log" || fail "$label did not distinguish failure from budget denial."
  ! grep -Fq 'Budget stop: no further' "$log" || fail "$label produced a false budget stop."
  ! grep -Fq 'TCP SCORE:' "$log" || fail "$label produced a false TCP score."
  ! grep -Fq 'UDP SCORE:' "$log" || fail "$label produced a false UDP score."
  ! grep -Fq 'LINK HEALTH:' "$log" || fail "$label produced a false link score."
  ! grep -Fq 'FIX LINK' "$log" || fail "$label produced a false transport recommendation."
  ! grep -Eq '^  (TCP|UDP)[[:space:]]+[^[:space:]]+[[:space:]]+10%' "$log" ||
    fail "$label escalated after every 5 percent test failed."
  printf 'PASS: %s closed-port failure semantics\n' "$label"
}

run_alpine324_dependency_probe() {
  local log="$TEMP_DIR/alpine324-dependencies.log"

  docker run --rm --network "$NETWORK_NAME" \
    --mount "type=bind,src=$REPO_ROOT,dst=/work,readonly" \
    alpine:3.24 sh -ec '
      apk add --no-cache bash openrc >/dev/null
      set +e
      bash /work/protocol-benchmark.sh 127.0.0.1 \
        --port 65534 --bandwidth 10 >/tmp/benchmark.log 2>&1
      benchmark_status=$?
      set -e
      test "$benchmark_status" -ne 0
      grep -Fq "TEST RESULT:   FAILED" /tmp/benchmark.log
      for package in jq mawk sed iperf3 iputils coreutils; do
        apk info -e "$package"
      done
      command -v jq >/dev/null
      command -v mawk >/dev/null
      sed --version 2>/dev/null | head -n 1 | grep -Fq "sed (GNU sed)"
      iperf3 --version >/dev/null
      ping -V 2>&1 | grep -qi "iputils"
      timeout --version 2>/dev/null | grep -Fq "GNU coreutils"
      ! apk info -e iperf3-openrc
      test ! -e /etc/init.d/iperf3
      ! pidof iperf3 >/dev/null 2>&1
      printf "PASS: Alpine 3.24 dependency capabilities and service state\\n"
    ' >"$log" 2>&1 || {
      cat "$log" >&2
      fail 'Alpine 3.24 dependency capability probe failed.'
    }
  cat "$log"
}

run_real_pair() {
  local image=$1
  local label=$2
  local bootstrap
  local server="$RUN_ID-$label-server"
  local client="$RUN_ID-$label-client"
  local server_log="$TEMP_DIR/$label-server.log"
  local client_log="$TEMP_DIR/$label-client.log"
  local state_dir="$TEMP_DIR/$label-state"
  local port=''
  local status
  local attempt
  local history_permissions

  bootstrap=$(bootstrap_command "$image") || return 1
  mkdir -p "$state_dir"
  CONTAINERS+=("$server" "$client")
  docker run -d --name "$server" --network "$NETWORK_NAME" \
    --mount "type=bind,src=$REPO_ROOT,dst=/work,readonly" \
    "$image" sh -ec "$bootstrap; exec bash /work/protocol-benchmark.sh \
      --server --server-wait 300" >/dev/null
  for (( attempt=1; attempt<=120; attempt++ )); do
    docker logs "$server" >"$server_log" 2>&1 || true
    port=$(sed -n 's/^Port:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
      "$server_log" | head -n 1)
    [[ -z "$port" ]] || break
    docker inspect -f '{{.State.Running}}' "$server" 2>/dev/null | grep -qx true ||
      fail "$label server exited before publishing its random port."
    sleep 1
  done
  [[ "$port" =~ ^[0-9]+$ ]] || fail "$label server did not publish a random port."
  (( port >= 49152 && port <= 65535 )) || fail "$label server port is outside the high range."
  grep -Fq 'Firewall:     unchanged (UFW is not active)' "$server_log" ||
    fail "$label server did not report absent/inactive UFW safely."

  set +e
  docker run --name "$client" --network "$NETWORK_NAME" \
    --mount "type=bind,src=$REPO_ROOT,dst=/work,readonly" \
    --mount "type=bind,src=$state_dir,dst=/state" \
    -e PROTOCOL_BENCHMARK_STATE_DIR=/state \
    "$image" sh -ec "$bootstrap; exec bash /work/protocol-benchmark.sh \
      $server --port $port --bandwidth 10" >"$client_log" 2>&1
  status=$?
  set -e
  (( status == 0 )) || {
    cat "$server_log" >&2
    cat "$client_log" >&2
    fail "$label real client benchmark failed."
  }
  for expected in 'TCP CLIENT->SERVER' 'TCP SERVER->CLIENT' \
    'UDP CLIENT->SERVER' 'UDP SERVER->CLIENT' \
    'TCP SCORE:' 'UDP SCORE:' 'LINK HEALTH:' 'TCP retransmissions:' \
    'loss=' 'jitter=' 'Peak CPU:'; do
    grep -Fq "$expected" "$client_log" ||
      fail "$label output is missing: $expected"
  done
  history_permissions=$(docker run --rm \
    --mount "type=bind,src=$state_dir,dst=/state" "$image" sh -ec '
      file=$(find /state/history -type f -name "*.json" -print -quit)
      test -n "$file"
      printf "%s|%s\n" "$(stat -c %a "${file%/*}")" "$(stat -c %a "$file")"
    ') || fail "$label did not persist compatible history."
  [[ "$history_permissions" == '700|600' ]] ||
    fail "$label history permissions changed: $history_permissions"

  set +e
  timeout 45 docker wait "$server" >"$TEMP_DIR/$label-server-status"
  status=$?
  set -e
  (( status == 0 )) || fail "$label server did not auto-close after idle timeout."
  [[ "$(cat "$TEMP_DIR/$label-server-status")" == '0' ]] ||
    fail "$label server exited unsuccessfully."
  docker logs "$server" >"$server_log" 2>&1 || true
  grep -Fq 'no listener retained' "$server_log" ||
    fail "$label server did not confirm listener cleanup."
  [[ "$(docker inspect -f '{{.State.Running}}' "$server")" == false ]] ||
    fail "$label retained a running server container."
  printf 'PASS: %s real bidirectional TCP/UDP benchmark\n' "$label"
}

run_closed_port_failure 'debian:13-slim' 'debian13'
run_closed_port_failure 'alpine:3.21' 'alpine321'
run_closed_port_failure 'alpine:3.22' 'alpine322'
run_alpine324_dependency_probe
run_real_pair 'debian:12-slim' 'debian12'
run_real_pair 'alpine:3.23' 'alpine323'
run_real_pair 'alpine:3.24' 'alpine324'

printf 'PASS: Debian 12/13 and Alpine 3.21-3.24 container validation\n'
