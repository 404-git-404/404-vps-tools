#!/usr/bin/env bash
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/bin"
export HTTP_FIXTURE_DIR="$work" HTTP_FIXTURE_SCENARIO=ok
cat >"$work/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -Eeuo pipefail
count=$(cat "$HTTP_FIXTURE_DIR/count")
count=$((count+1))
echo "$count" >"$HTTP_FIXTURE_DIR/count"
auth=no headers='' output=''
while (( $# )); do
  case "$1" in
    -H)
      if [[ "$2" == 'Authorization: Bearer '* ]]; then auth=yes; fi
      shift 2 ;;
    --dump-header) headers=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    --connect-timeout) [[ "$2" == 10 ]]; shift 2 ;;
    --max-time) [[ "$2" == 20 ]]; shift 2 ;;
    *) shift ;;
  esac
done
echo "$auth" >>"$HTTP_FIXTURE_DIR/auth"
printf 'HTTP/2 200\r\nx-github-request-id: fixture-request\r\n' >"$headers"
printf 'location: https://example.invalid/%s\r\n' "$GH_TOKEN" >>"$headers"
printf 'verified fixture\n' >"$output"
status=200 rc=0
case "$HTTP_FIXTURE_SCENARIO" in
  ok) ;;
  transient) if (( count < 3 )); then status=503; fi ;;
  network)
    if (( count < 2 )); then printf partial >"$output"; echo 'connection reset' >&2; status=000; rc=18; fi ;;
  timeout) status=000; rc=28; echo 'operation timed out' >&2 ;;
  bad-certificate) status=000; rc=60 ;;
  local-io) status=000; rc=23 ;;
  primary)
    if (( count < 2 )); then
      status=403
      printf 'x-ratelimit-remaining: 0\r\nx-ratelimit-reset: 1002\r\n' >>"$headers"
      printf '{"message":"API rate limit exceeded"}' >"$output"
    fi ;;
  secondary)
    if (( count < 2 )); then status=403; printf '{"message":"secondary rate limit exceeded"}' >"$output"; fi ;;
  forbidden) status=403; printf '{"message":"Resource not accessible by integration"}' >"$output" ;;
  redirect-forbidden)
    status=403
    printf 'HTTP/2 301\r\nx-ratelimit-remaining: 0\r\n\r\nHTTP/2 403\r\n' >"$headers"
    printf '{"message":"Resource not accessible by integration"}' >"$output" ;;
  unauthenticated) status=401; printf '{"message":"Bad credentials"}' >"$output" ;;
  throttled)
    if (( count < 2 )); then status=429; printf 'retry-after: 2\r\n' >>"$headers"; fi ;;
  long-wait) status=429; printf 'retry-after: 120\r\n' >>"$headers" ;;
  permanent) status=500 ;;
  missing) status=404; printf '{"message":"Not Found"}' >"$output" ;;
  empty) : >"$output" ;;
  *) exit 88 ;;
esac
printf '%s' "$status"
exit "$rc"
CURL
cat >"$work/bin/sleep" <<'SLEEP'
#!/usr/bin/env bash
set -Eeuo pipefail
echo "$1" >>"$HTTP_FIXTURE_DIR/sleeps"
SLEEP
cat >"$work/bin/date" <<'DATE'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == +%s ]]
echo 1000
DATE
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"
export CI_FETCH_ATTEMPTS=3 CI_FETCH_MAX_TIME=20
# A made-up credential must be used only for API requests and never printed.
export GH_TOKEN='test-only-not-a-real-credential'
fail() { echo "FAIL: $*" >&2; exit 1; }

shopt -s nullglob
uses_key="^[[:space:]]*(-[[:space:]]+)?['\"]?uses['\"]?[[:space:]]*:[[:space:]]*(.*)$"
uses_value="^['\"]?([^[:space:]'\"#]+)['\"]?([[:space:]]+#.*|[[:space:]]*)$"
for workflow in "$repo"/.github/workflows/*.{yml,yaml}; do
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ $uses_key ]] || continue
    value=${BASH_REMATCH[2]}
    [[ "$value" =~ $uses_value ]] || fail "$workflow: invalid uses entry: $line"
    target=${BASH_REMATCH[1]}
    if [[ "$target" != ./* && ! "$target" =~ @([0-9a-f]{40})$ ]]; then
      fail "$workflow: external uses entry is not pinned to a full commit SHA: $target"
    fi
  done <"$workflow"
done
shopt -u nullglob

publish_job=$(awk '/^  publish:$/ { publish=1; next } publish && /^  [^ ]/ { exit } publish' \
  "$repo/.github/workflows/release.yml")
expected_publish_checkout=$(cat <<'YAML'
      - name: Check out the tagged commit
        # actions/checkout v6
        uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803
        with:
          ref: ${{ github.sha }}

      - name: Checked-out commit is the verified commit
        run: test "$(git rev-parse HEAD)" = "$GITHUB_SHA"
YAML
)
[[ "$publish_job" == *"$expected_publish_checkout"$'\n'*'      - name: Package scripts and checksums'* ]] || fail 'publish must check out github.sha and verify HEAD before packaging'
echo 'PASS: workflow action SHA pins and verified release checkout'

for scenario in ok transient network timeout bad-certificate local-io primary secondary forbidden redirect-forbidden unauthenticated throttled long-wait permanent missing allow-missing empty anonymous; do
  HTTP_FIXTURE_SCENARIO=$scenario
  args=(--github-api)
  expected_rc=0 expected_count=1
  case "$scenario" in
    transient) expected_count=3 ;;
    network|primary|secondary|throttled) expected_count=2 ;;
    timeout) expected_count=3; expected_rc=28 ;;
    bad-certificate) expected_rc=60 ;;
    local-io) expected_rc=23 ;;
    permanent) expected_count=3; expected_rc=22 ;;
    forbidden|redirect-forbidden|unauthenticated|long-wait|missing|empty) expected_rc=22 ;;
    allow-missing) HTTP_FIXTURE_SCENARIO=missing; args+=(--allow-not-found) ;;
    anonymous) HTTP_FIXTURE_SCENARIO=ok; args=() ;;
  esac
  export HTTP_FIXTURE_SCENARIO
  echo 0 >"$work/count"
  : >"$work/auth"
  : >"$work/sleeps"
  echo original-output >"$work/download"
  result=0
  bash "$repo/.github/scripts/ci-fetch.sh" "${args[@]}" https://api.github.com/repos/example/fixture "$work/download" \
    >"$work/stdout" 2>"$work/stderr" || result=$?
  [[ "$result" == "$expected_rc" && "$(cat "$work/count")" == "$expected_count" ]] || {
    cat "$work/stderr"; fail "$scenario: rc=$result, requests=$(cat "$work/count")";
  }
  if (( result )); then
    grep -Fxq original-output "$work/download" || fail 'failed request published a partial response'
    grep -Fq '::error::' "$work/stderr"
  else
    [[ -s "$work/download" ]]
    if [[ "$scenario" == allow-missing ]]; then
      grep -Fxq 404 "$work/stdout"
    else
      grep -Fxq 200 "$work/stdout"
      grep -Fxq 'verified fixture' "$work/download"
    fi
  fi
  if [[ "$scenario" == anonymous ]]; then
    grep -Fxq no "$work/auth"
  else
    if grep -Fxq no "$work/auth"; then fail 'API request lacked authentication'; fi
  fi
  if grep -Fq "$GH_TOKEN" "$work/stdout" "$work/stderr"; then fail 'credential leaked'; fi
  case "$scenario" in
    primary) grep -Fxq 3 "$work/sleeps" ;;
    secondary) grep -Fxq 60 "$work/sleeps" ;;
    throttled) grep -Fxq 2 "$work/sleeps" ;;
    long-wait) [[ ! -s "$work/sleeps" ]] ;;
    forbidden) grep -Fq 'Resource not accessible' "$work/stderr"; grep -Fq fixture-request "$work/stderr" ;;
  esac
done

# Bad token/host/options fail before curl, rather than sending a secret elsewhere.
for variant in no-token wrong-host invalid-attempts; do
  echo 0 >"$work/count"
  result=0
  case "$variant" in
    no-token) GH_TOKEN='' bash "$repo/.github/scripts/ci-fetch.sh" --github-api https://api.github.com/ "$work/download" 2>/dev/null || result=$? ;;
    wrong-host) bash "$repo/.github/scripts/ci-fetch.sh" --github-api https://example.invalid/ "$work/download" 2>/dev/null || result=$? ;;
    invalid-attempts) CI_FETCH_ATTEMPTS=99 bash "$repo/.github/scripts/ci-fetch.sh" https://example.invalid/ "$work/download" 2>/dev/null || result=$? ;;
  esac
  [[ "$result" == 2 && "$(cat "$work/count")" == 0 ]] || fail "$variant reached curl"
done

for state in success failure cancelled skipped missing empty; do
  NEEDS_JSON=$(jq -cn --arg state "$state" '{"migration":{"result":"success"},"release-assets":{"result":"success"},"release-package":{"result":$state}}')
  if [[ "$state" == missing ]]; then NEEDS_JSON='{"migration":{"result":"success"},"release-assets":{"result":"success"}}'; fi
  if [[ "$state" == empty ]]; then NEEDS_JSON='{}'; fi
  export NEEDS_JSON
  result=0
  bash "$repo/.github/scripts/ci-required-checks.sh" >"$work/gate-output" 2>&1 || result=$?
  if [[ "$state" == success ]]; then
    [[ "$result" == 0 ]] || fail 'gate rejected success'
  else
    (( result != 0 )) || fail "gate accepted $state matrix"
  fi
done
echo 'PASS: bounded CI HTTP retries, rate limits, diagnostics, anonymous artifacts, failure preservation and required gate'
