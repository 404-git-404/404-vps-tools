#!/usr/bin/env bash
# Release gates shared by .github/workflows/release.yml and tests/release-checks-test.sh.
#   release-checks.sh tag-format TAG
#   release-checks.sh on-main REV [MAIN_REF]     (MAIN_REF defaults to origin/main)
#   release-checks.sh versions TAG [DIR]         (DIR defaults to the repository root)
#   release-checks.sh tag-matches-head TAG       (the tag must point at the checked-out commit)
#   release-checks.sh release-absent TAG         (GitHub API by HTTP status; needs GH_TOKEN and GITHUB_REPOSITORY)
#   release-checks.sh latest-newer TAG           (TAG must be strictly newer than the latest vX.Y.Z Release)
set -Eeuo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

readonly TAG_PATTERN='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
readonly VERSION_PATTERN="^(readonly )?SCRIPT_VERSION='((0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*))'\$"
readonly -a VERSIONED_SCRIPTS=(debian-init.sh alpine-init.sh gg-status)

fail() {
  printf '::error::%s\n' "$*" >&2
  exit 1
}

check_tag_format() {
  local tag=${1:-}
  [[ -n "$tag" ]] || fail 'Missing tag name.'
  [[ "$tag" =~ $TAG_PATTERN ]] || fail "Tag '$tag' is not a plain vMAJOR.MINOR.PATCH version."
}

check_on_main() {
  local rev=${1:-} main_ref=${2:-origin/main} commit
  [[ -n "$rev" ]] || fail 'Missing commit to check.'
  commit=$(git rev-parse --verify --quiet "$rev^{commit}") || fail "Cannot resolve '$rev' to a commit."
  git rev-parse --verify --quiet "$main_ref^{commit}" >/dev/null || fail "Cannot resolve '$main_ref'; fetch the full history first."
  git merge-base --is-ancestor "$commit" "$main_ref" ||
    fail "Commit $commit is not on $main_ref; only commits merged into main can be released."
  printf 'OK: %s is on %s\n' "$commit" "$main_ref"
}

script_version() {
  local file=$1 matches
  [[ -f "$file" ]] || fail "Missing $file."
  matches=$(tr -d '\r' <"$file" | grep -E "$VERSION_PATTERN" || true)
  [[ -n "$matches" && "$(wc -l <<<"$matches")" -eq 1 ]] ||
    fail "$file must define SCRIPT_VERSION exactly once as a plain X.Y.Z string."
  sed -E "s/$VERSION_PATTERN/\\2/" <<<"$matches"
}

check_versions() {
  local tag=${1:-} dir=${2:-.} version script
  check_tag_format "$tag"
  for script in "${VERSIONED_SCRIPTS[@]}"; do
    version=$(script_version "$dir/$script")
    [[ "$version" == "${tag#v}" ]] ||
      fail "$script has SCRIPT_VERSION=$version, but the tag is $tag."
    printf 'OK: %s SCRIPT_VERSION=%s\n' "$script" "$version"
  done
}


check_tag_matches_head() {
  local tag=${1:-} tag_commit head_commit
  check_tag_format "$tag"
  tag_commit=$(git rev-parse --verify --quiet "refs/tags/$tag^{commit}") || fail "Tag $tag does not exist in this checkout."
  head_commit=$(git rev-parse --verify --quiet 'HEAD^{commit}') || fail 'Cannot resolve HEAD.'
  [[ "$tag_commit" == "$head_commit" ]] ||
    fail "Tag $tag points at $tag_commit, but the checked-out commit is $head_commit."
  printf 'OK: tag %s points at the checked-out commit %s\n' "$tag" "$head_commit"
}

# GET a GitHub API path of this repository through ci-fetch.sh. Prints the HTTP status, which is
# only ever 200 or 404: ci-fetch.sh fails on every other status and on network errors.
api_status() {
  local path=$1 output=$2 status
  [[ "${GITHUB_REPOSITORY:-}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || fail 'GITHUB_REPOSITORY is missing or malformed.'
  status=$(bash "$here/ci-fetch.sh" --github-api --allow-not-found \
    "https://api.github.com/repos/$GITHUB_REPOSITORY/$path" "$output") ||
    fail "GitHub API request for $path failed; refusing to guess."
  [[ "$status" == 200 || "$status" == 404 ]] || fail "Unexpected HTTP status '$status' for $path."
  printf '%s\n' "$status"
}

check_release_absent() {
  local tag=${1:-} work status
  check_tag_format "$tag"
  work=$(mktemp -d)
  status=$(api_status "releases/tags/$tag" "$work/release.json") || { rm -rf -- "$work"; exit 1; }
  rm -rf -- "$work"
  case "$status" in
    200) fail "Release $tag already exists; a published version is never overwritten. Publish a new version number instead." ;;
    404) printf 'OK: Release %s does not exist yet\n' "$tag" ;;
  esac
}

# True when dotted version $1 is strictly greater than $2. Both are X.Y.Z without leading zeros, so
# comparing length first and then the digits is a numeric comparison that cannot overflow.
version_greater() {
  local -a a b
  local i
  IFS=. read -r -a a <<<"$1"
  IFS=. read -r -a b <<<"$2"
  for i in 0 1 2; do
    if (( ${#a[i]} != ${#b[i]} )); then (( ${#a[i]} > ${#b[i]} )); return; fi
    if [[ "${a[i]}" != "${b[i]}" ]]; then [[ "${a[i]}" > "${b[i]}" ]]; return; fi
  done
  return 1
}

check_latest_newer() {
  local tag=${1:-} work status latest
  check_tag_format "$tag"
  work=$(mktemp -d)
  status=$(api_status releases/latest "$work/latest.json") || { rm -rf -- "$work"; exit 1; }
  if [[ "$status" == 404 ]]; then
    rm -rf -- "$work"
    printf 'OK: no latest Release yet\n'
    return 0
  fi
  latest=$(jq -r '.tag_name // empty' "$work/latest.json") || { rm -rf -- "$work"; fail 'The latest Release response is not valid JSON.'; }
  rm -rf -- "$work"
  if [[ ! "$latest" =~ $TAG_PATTERN ]]; then
    # For example the SmartDNS pre-release: it is not one of our versions, so it cannot be outranked.
    printf "OK: latest Release '%s' is not a vX.Y.Z version; nothing to compare\n" "$latest"
    return 0
  fi
  version_greater "${tag#v}" "${latest#v}" ||
    fail "Tag $tag is not newer than the latest Release $latest; versions must strictly increase."
  printf 'OK: %s is newer than the latest Release %s\n' "$tag" "$latest"
}

main() {
  local command=${1:-}
  shift || true
  case "$command" in
    tag-format) check_tag_format "$@" ;;
    on-main) check_on_main "$@" ;;
    versions) check_versions "$@" ;;
    tag-matches-head) check_tag_matches_head "$@" ;;
    release-absent) check_release_absent "$@" ;;
    latest-newer) check_latest_newer "$@" ;;
    *) fail "Unknown command '$command'." ;;
  esac
}

main "$@"
