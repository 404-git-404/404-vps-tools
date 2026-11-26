#!/usr/bin/env bash
# shellcheck disable=SC2016 # Single quotes keep searched or generated shell code literal.
# Run the README one-line commands for real against a local HTTP server (with a redirect, like the
# GitHub download URLs have). The final "run the script" step of each command is replaced by a marker.
#   readme-commands-test.sh            Debian 12, Debian 13 and Alpine containers (needs docker)
#   readme-commands-test.sh --local    this machine's own shell and tools
#   readme-commands-test.sh --inside BASE_URL   used inside a container by the default mode
# Per command: valid downloads reach the marker; a tampered script or a SHA256SUMS without the
# script's line must fail before the marker.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly OFFICIAL_BASE='https://github.com/404-git-404/404-vps-tools/releases/latest/download'
readonly -a NAMES=(debian-init.sh alpine-init.sh gg-status)
readonly -a FINALS=('bash debian-init.sh' 'sh alpine-init.sh' 'sh gg-status')
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

run_commands() {
  local base=$1 mode=$2 line lang command verified scenario index shell_name out err rc scenarios strict_name
  local -a lines=()
  mapfile -t lines < <(bash "$repo/.github/scripts/readme-commands.sh" "$repo/README.md")
  [[ ${#lines[@]} -eq 3 ]] || fail "README must contain exactly three commands, found ${#lines[@]}"
  for index in 0 1 2; do
    line=${lines[$index]}
    lang=${line%%$'\t'*}
    command=${line#*$'\t'}
    [[ "$command" == "cd \"\$(mktemp -d)\" && B=$OFFICIAL_BASE && "* ]] || fail "command $index does not start with the temp dir and the official base URL"
    # Two spaces (the sha256sum text format) and the file name with its dots escaped, anchored at the end.
    strict_name=${NAMES[$index]//./\\.}
    [[ "$command" == *"grep '  ${strict_name}\$' SHA256SUMS | sha256sum -c - && "* ]] || fail "command $index does not strictly verify ${NAMES[$index]}"
    if [[ "$command" == *chmod* || "$command" == *'&& ./'* ]]; then fail "command $index must run the script with its interpreter, not chmod and ./"; fi
    [[ "$command" == *" && ${FINALS[$index]}" ]] || fail "command $index does not end by running ${NAMES[$index]}"
    # Each verification must come before the final run step.
    [[ "${command%% && "${FINALS[$index]}"}" == *'sha256sum -c -'* ]] || fail "command $index runs the script before verifying it"
    if [[ "$mode" == local && "${NAMES[$index]}" == alpine-init.sh ]] && ! command -v wget >/dev/null; then
      printf 'SKIP: command %s needs wget, which this machine does not have\n' "$index"
      continue
    fi
    verified=${command% && *}' && echo VERIFIED'
    [[ "$verified" == *' && echo VERIFIED' && "$verified" != *"${FINALS[$index]}"* ]] || fail "marker was not substituted for command $index"
    shell_name='sh'
    if [[ "$lang" == bash ]]; then shell_name=bash; fi
    for scenario in ok tampered "missing-${NAMES[$index]}"; do
      local_command=${verified//"$OFFICIAL_BASE"/"$base/$scenario/download"}
      [[ "$local_command" != *github.com* ]] || fail 'the official URL was not replaced'
      out=$(mktemp) err=$(mktemp)
      rc=0
      timeout 120 "$shell_name" -c "$local_command" >"$out" 2>"$err" || rc=$?
      if [[ "$scenario" == ok ]]; then
        [[ "$rc" == 0 ]] || { cat "$out" "$err" >&2; fail "${NAMES[$index]} ($shell_name): valid download failed (rc=$rc)"; }
        [[ "$(tail -n 1 "$out")" == VERIFIED ]] || { cat "$out" "$err" >&2; fail "${NAMES[$index]}: marker not reached"; }
        grep -Fq "${NAMES[$index]}: OK" "$out" || fail "${NAMES[$index]}: checksum success was not reported"
      else
        scenarios=$scenario
        [[ "$rc" != 0 ]] || { cat "$out" "$err" >&2; fail "${NAMES[$index]}: $scenarios was accepted"; }
        if grep -Fq VERIFIED "$out"; then fail "${NAMES[$index]}: $scenarios still reached the marker"; fi
      fi
      rm -f "$out" "$err"
      printf 'ok: command %s (%s) %s\n' "$index" "${NAMES[$index]}" "$scenario"
    done
  done
}

start_server() {
  local root=$1 index scenario name
  mkdir -p "$root"
  for scenario in ok tampered; do
    mkdir "$root/$scenario"
    cp "$repo/debian-init.sh" "$repo/alpine-init.sh" "$repo/gg-status" "$root/$scenario/"
  done
  for name in "${NAMES[@]}"; do
    mkdir "$root/missing-$name"
    cp "$repo/debian-init.sh" "$repo/alpine-init.sh" "$repo/gg-status" "$root/missing-$name/"
  done
  (cd "$root/ok" && sha256sum --text "${NAMES[@]}" >SHA256SUMS)
  grep -Eq '^[0-9a-f]{64}  ' "$root/ok/SHA256SUMS" || fail 'SHA256SUMS is not in the two-space sha256sum format'
  # The scripts change after SHA256SUMS was made.
  cp "$root/ok/SHA256SUMS" "$root/tampered/SHA256SUMS"
  for name in "${NAMES[@]}"; do printf '\n# tampered\n' >>"$root/tampered/$name"; done
  for index in 0 1 2; do
    name=${NAMES[$index]}
    grep -v " $name\$" "$root/ok/SHA256SUMS" >"$root/missing-$name/SHA256SUMS"
    [[ "$(wc -l <"$root/missing-$name/SHA256SUMS")" -eq 2 ]] || fail "could not drop the $name line"
  done
  python3 -I - "$root" "$root/port" >"$root/server.log" 2>&1 <<'PY' &
import http.server, os, sys
root, port_file = sys.argv[1], sys.argv[2]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parts = self.path.split('/')
        if len(parts) != 4 or parts[0] != '' or not all(parts[1:]) or '..' in parts or parts[2] not in ('download', 'blob'):
            self.send_error(404)
            return
        if parts[2] == 'download':
            # GitHub answers download URLs with an absolute redirect to another host.
            self.send_response(302)
            self.send_header('Location', 'http://127.0.0.1:%d/%s/blob/%s' % (self.server.server_address[1], parts[1], parts[3]))
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        path = os.path.join(root, parts[1], parts[3])
        if not os.path.isfile(path):
            self.send_error(404)
            return
        with open(path, 'rb') as handle:
            data = handle.read()
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *args):
        pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
with open(port_file, 'w') as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
PY
  SERVER_PID=$!
  for _ in $(seq 1 50); do
    [[ -s "$root/port" ]] && return 0
    sleep 0.1
  done
  cat "$root/server.log" >&2
  fail 'the local HTTP server did not start'
}

check_versions_inside() {
  local name
  # busybox ash on Alpine, dash on Debian: the POSIX scripts must answer --version before any work.
  for name in alpine-init.sh gg-status; do
    sh "$repo/$name" --version | grep -Eq "^$name [0-9]+\\.[0-9]+\\.[0-9]+\$" || fail "$name --version under sh"
  done
  bash "$repo/debian-init.sh" --version | grep -Eq '^debian-init.sh [0-9]+\.[0-9]+\.[0-9]+$' || fail 'debian-init.sh --version'
  echo 'ok: --version under this container shell'
}

root=
main() {
  local mode=${1:-docker} image base
  case "$mode" in
    --inside)
      [[ $# -eq 2 ]] || fail 'usage: --inside BASE_URL'
      check_versions_inside
      run_commands "$2" inside
      ;;
    --local|docker)
      root=$(mktemp -d)
      trap 'kill "${SERVER_PID:-0}" 2>/dev/null || true; rm -rf -- "${root:?}"' EXIT
      start_server "$root/served"
      base="http://127.0.0.1:$(cat "$root/served/port")"
      if [[ "$mode" == --local ]]; then
        run_commands "$base" local
      else
        for image in debian:12 debian:13 alpine:latest; do
          printf '== %s\n' "$image"
          docker run --rm --network host --volume "$repo:/repo:ro" "$image" sh -eu -c '
            if command -v apk >/dev/null 2>&1; then
              apk add --no-cache bash curl >/dev/null
            else
              export DEBIAN_FRONTEND=noninteractive
              apt-get update -qq
              apt-get install -y -qq --no-install-recommends ca-certificates curl wget >/dev/null
            fi
            bash /repo/tests/readme-commands-test.sh --inside "$1"' sh "$base"
        done
      fi
      ;;
    *) fail "unknown mode $mode" ;;
  esac
  echo 'PASS: README commands verify SHA256SUMS before running anything'
}

main "$@"
