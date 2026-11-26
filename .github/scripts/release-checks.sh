#!/usr/bin/env bash
# Release gates shared by .github/workflows/release.yml and tests/release-checks-test.sh.
#   release-checks.sh tag-format TAG
#   release-checks.sh on-main REV [MAIN_REF]     (MAIN_REF defaults to origin/main)
#   release-checks.sh versions TAG [DIR]         (DIR defaults to the repository root)
#   release-checks.sh release-absent TAG         (needs gh; GITHUB_REPOSITORY selects the repository)
set -Eeuo pipefail

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

check_release_absent() {
  local tag=${1:-} out rc=0
  local -a repo=()
  check_tag_format "$tag"
  if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then repo=(--repo "$GITHUB_REPOSITORY"); fi
  out=$(gh release view "$tag" "${repo[@]}" 2>&1) || rc=$?
  if (( rc == 0 )); then
    fail "Release $tag already exists; a published version is never overwritten. Publish a new version number instead."
  fi
  # Fail closed: only an explicit "not found" counts as absent, never an API or network error.
  grep -Fqi 'release not found' <<<"$out" || fail "Could not confirm that Release $tag is absent: $out"
  printf 'OK: Release %s does not exist yet\n' "$tag"
}

main() {
  local command=${1:-}
  shift || true
  case "$command" in
    tag-format) check_tag_format "$@" ;;
    on-main) check_on_main "$@" ;;
    versions) check_versions "$@" ;;
    release-absent) check_release_absent "$@" ;;
    *) fail "Unknown command '$command'." ;;
  esac
}

main "$@"
