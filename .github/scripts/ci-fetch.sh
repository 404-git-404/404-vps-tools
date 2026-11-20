#!/usr/bin/env bash
# Bounded CI-only GET requests. Artifact URLs deliberately remain anonymous.
set -Eeuo pipefail

ci_fetch_header() {
  awk -v wanted="$1" '
    /^HTTP\// { value="" }
    { sub(/\r$/, ""); separator=index($0, ":")
      if (tolower(substr($0,1,separator-1)) == wanted) {
        value=substr($0,separator+1); sub(/^[[:space:]]+/,"",value)
      }
    } END { print value }
  ' "$2"
}

ci_fetch() (
  local api=false allow_missing=false
  while (( $# )); do
    case "$1" in
      --github-api) api=true; shift ;;
      --allow-not-found) allow_missing=true; shift ;;
      *) break ;;
    esac
  done
  [[ $# == 2 ]] || { echo 'Usage: ci-fetch.sh [--github-api] [--allow-not-found] URL OUTPUT' >&2; exit 2; }
  local url=$1 output=$2 work attempt status rc retry delay remaining reset after now message
  local attempts=${CI_FETCH_ATTEMPTS:-4} max_time=${CI_FETCH_MAX_TIME:-120}
  [[ "$attempts" =~ ^[1-4]$ && "$max_time" =~ ^[0-9]+$ ]] && (( max_time >= 1 && max_time <= 180 )) || exit 2
  [[ "$url" == https://* && "$url" != *$'\n'* && "$url" != *$'\r'* ]] || exit 2
  [[ "$allow_missing" == false || "$api" == true ]] || exit 2
  local -a headers=()
  if [[ "$api" == true ]]; then
    [[ "$url" == https://api.github.com/* && -n "${GH_TOKEN:-}" ]] || {
      echo 'GitHub API requests require api.github.com and a read-only GH_TOKEN.' >&2; exit 2;
    }
    headers=(-H "Authorization: Bearer $GH_TOKEN" -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28')
  fi
  work=$(mktemp -d "${output}.fetch.XXXXXXXX")
  trap 'rm -rf -- "$work"' EXIT
  for ((attempt=1; attempt<=attempts; attempt++)); do
    : >"$work/headers"
    : >"$work/body"
    if status=$(curl --silent --show-error --location --proto '=https' --proto-redir '=https' \
      --connect-timeout 10 --max-time "$max_time" "${headers[@]}" \
      --dump-header "$work/headers" --output "$work/body" --write-out '%{http_code}' \
      "$url" 2>"$work/error"); then rc=0; else rc=$?; fi
    if (( rc == 0 )) && { [[ "$status" == 200 ]] || [[ "$status" == 404 && "$allow_missing" == true ]]; }; then
      [[ "$status" == 404 || -s "$work/body" ]] || { echo "::error::Empty HTTP 200 response: $url" >&2; exit 22; }
      mv -- "$work/body" "$output"
      printf '%s\n' "$status"
      exit 0
    fi

    # Log response diagnostics, never Authorization or redirect Location headers.
    printf 'GET %s: attempt %s/%s, HTTP %s, curl exit %s\n' "$url" "$attempt" "$attempts" "$status" "$rc" >&2
    awk 'tolower($0) ~ /^(x-github-request-id|x-ratelimit-[a-z-]+|retry-after|content-type):/ { sub(/\r$/, ""); print }' "$work/headers" >&2
    head -c 1000 "$work/error" >&2
    message=''
    if [[ "$api" == true ]]; then
      message=$(jq -r '.message // empty' "$work/body" 2>/dev/null || true)
      printf 'API message: %.1000s\n' "$message" >&2
    fi
    retry=false
    delay=$((2 ** attempt))
    if (( rc != 0 )); then
      case "$rc" in 5|6|7|18|28|35|52|55|56|92) retry=true ;; esac
    else
      remaining=$(ci_fetch_header x-ratelimit-remaining "$work/headers")
      after=$(ci_fetch_header retry-after "$work/headers")
      case "$status" in
        408|429|5??) retry=true ;;
        403)
          if [[ "$remaining" == 0 || -n "$after" || "${message,,}" == *'rate limit'* ]]; then retry=true; fi ;;
      esac
      if [[ "$retry" == true ]]; then
        if [[ -n "$after" ]]; then
          # Unknown HTTP-date values are not guessed; fail with the header intact.
          if [[ "$after" =~ ^[0-9]{1,9}$ ]]; then delay=$((10#$after)); else retry=false; fi
        elif [[ "$remaining" == 0 ]]; then
          reset=$(ci_fetch_header x-ratelimit-reset "$work/headers")
          now=$(date +%s)
          if [[ "$reset" =~ ^[0-9]{1,12}$ ]]; then delay=$((10#$reset-now+1)); else delay=60; fi
        elif [[ "$status" == 403 || "$status" == 429 ]]; then
          delay=$((60 * (2 ** (attempt-1))))
        fi
      fi
    fi
    if (( delay < 0 )); then delay=0; fi
    if [[ "$retry" == false ]] || (( attempt == attempts || delay > 60 )); then
      printf '::error::GET failed: HTTP %s, curl exit %s, attempt %s/%s, required wait %ss: %s\n' \
        "$status" "$rc" "$attempt" "$attempts" "$delay" "$url" >&2
      if (( rc != 0 )); then exit "$rc"; else exit 22; fi
    fi
    printf 'Retrying in %ss (maximum 4 attempts; waits above 60s fail explicitly).\n' "$delay" >&2
    sleep "$delay"
  done
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then ci_fetch "$@"; fi
