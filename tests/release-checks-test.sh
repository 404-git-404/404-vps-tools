#!/usr/bin/env bash
# shellcheck disable=SC2016 # Single quotes keep searched or generated shell code literal.
# The four release gates (tag on main, tag == script versions, checks pass, Release absent), the
# Release notes and the shape of release.yml, simulated without GitHub.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
checks="$repo/.github/scripts/release-checks.sh"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
passes() { local name=$1; shift; "$@" >"$work/out" 2>&1 || { cat "$work/out" >&2; fail "$name: expected success"; }; }
rejects() {
  local name=$1; shift
  if "$@" >"$work/out" 2>&1; then cat "$work/out" >&2; fail "$name: expected failure"; fi
  grep -Fq '::error::' "$work/out" || { cat "$work/out" >&2; fail "$name: failed without an error annotation"; }
}

# Tag format: only plain vMAJOR.MINOR.PATCH.
for tag in v0.1.0 v1.2.3 v10.20.30 v0.0.0; do passes "tag $tag" bash "$checks" tag-format "$tag"; done
for tag in '' 0.1.0 v1 v1.2 v1.2.3.4 v1.2.3-rc1 v1.2.3+build v01.2.3 v1.02.3 vx.y.z 'v1.2.3 ' $'v1.2.3\n' v1.2.3/../x; do
  rejects "tag '$tag'" bash "$checks" tag-format "$tag"
done

# (a) The tagged commit must be on main.
git init -q -b main "$work/repo"
(
  cd "$work/repo"
  git config user.email test@example.invalid
  git config user.name test
  git config commit.gpgsign false
  git config tag.gpgsign false
  git commit -q --allow-empty -m one
  git tag v0.1.0
  git commit -q --allow-empty -m two
  git tag -a v0.2.0 -m annotated
  git checkout -q -b feature
  git commit -q --allow-empty -m side
  git tag v0.3.0
  git tag -a v0.3.1 -m annotated-side
  git checkout -q main
  git commit -q --allow-empty -m three
  # origin/main is what the workflow compares against; mirror that name here.
  git update-ref refs/remotes/origin/main main
)
git_in() { (cd "$work/repo" && "$@"); }
passes 'lightweight tag on main' git_in bash "$checks" on-main refs/tags/v0.1.0 origin/main
passes 'annotated tag on main' git_in bash "$checks" on-main refs/tags/v0.2.0 origin/main
passes 'main tip itself' git_in bash "$checks" on-main main origin/main
rejects 'lightweight tag on a side branch' git_in bash "$checks" on-main refs/tags/v0.3.0 origin/main
rejects 'annotated tag on a side branch' git_in bash "$checks" on-main refs/tags/v0.3.1 origin/main
rejects 'unknown tag' git_in bash "$checks" on-main refs/tags/v9.9.9 origin/main
rejects 'missing main ref' git_in bash "$checks" on-main refs/tags/v0.1.0 origin/nonexistent
rejects 'no argument' git_in bash "$checks" on-main

# (b) The tag must equal the version constant of all three scripts.
mkdir "$work/scripts"
cp "$repo/debian-init.sh" "$repo/alpine-init.sh" "$repo/gg-status" "$work/scripts/"
current=$(bash "$repo/debian-init.sh" --version)
current=${current#debian-init.sh }
passes 'tag equals every script version' bash "$checks" versions "v$current" "$work/scripts"
rejects 'tag newer than the scripts' bash "$checks" versions v9.9.9 "$work/scripts"
rejects 'tag older than the scripts' bash "$checks" versions v0.0.1 "$work/scripts"
rejects 'tag with a prerelease suffix' bash "$checks" versions "v$current-rc1" "$work/scripts"
for script in debian-init.sh alpine-init.sh gg-status; do
  mkdir "$work/mismatch-$script"
  cp "$work/scripts/"* "$work/mismatch-$script/"
  sed -i "s/SCRIPT_VERSION='$current'/SCRIPT_VERSION='9.9.9'/" "$work/mismatch-$script/$script"
  rejects "only $script differs" bash "$checks" versions "v$current" "$work/mismatch-$script"
  mkdir "$work/missing-$script"
  cp "$work/scripts/"* "$work/missing-$script/"
  rm "$work/missing-$script/$script"
  rejects "$script is missing" bash "$checks" versions "v$current" "$work/missing-$script"
  mkdir "$work/nodef-$script"
  cp "$work/scripts/"* "$work/nodef-$script/"
  sed -i '/SCRIPT_VERSION=/d' "$work/nodef-$script/$script"
  rejects "$script has no constant" bash "$checks" versions "v$current" "$work/nodef-$script"
  mkdir "$work/twice-$script"
  cp "$work/scripts/"* "$work/twice-$script/"
  printf "SCRIPT_VERSION='%s'\n" "$current" >>"$work/twice-$script/$script"
  rejects "$script defines the constant twice" bash "$checks" versions "v$current" "$work/twice-$script"
done

# (4) The tag must point at the checked-out commit.
git_in git checkout -q --detach refs/tags/v0.2.0
passes 'checked out exactly the lightweight/annotated tag' git_in bash "$checks" tag-matches-head v0.2.0
rejects 'checked out a different commit than the tag' git_in bash "$checks" tag-matches-head v0.1.0
rejects 'tag of a side branch' git_in bash "$checks" tag-matches-head v0.3.0
rejects 'unknown tag is not matched' git_in bash "$checks" tag-matches-head v9.9.9
rejects 'bad tag name is not matched' git_in bash "$checks" tag-matches-head 'v0.2'
git_in git checkout -q --detach refs/tags/v0.1.0
passes 'lightweight tag at HEAD' git_in bash "$checks" tag-matches-head v0.1.0
git_in git checkout -q main
rejects 'HEAD (main tip) is ahead of the tag' git_in bash "$checks" tag-matches-head v0.2.0
git_in git checkout -q --detach refs/tags/v0.3.1
rejects 'annotated side tag is at HEAD but not on main' git_in bash "$checks" on-main HEAD origin/main
passes 'annotated side tag at HEAD matches itself' git_in bash "$checks" tag-matches-head v0.3.1
git_in git checkout -q main
passes 'HEAD on main' git_in bash "$checks" on-main HEAD origin/main

# (d) Release absent, and the version must beat the latest Release: decided by HTTP status of the
# GitHub API (through ci-fetch.sh), never by message text. A fake curl plays GitHub.
mkdir "$work/bin"
cat >"$work/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -Eeuo pipefail
url='' output='' headers=''
while (( $# )); do
  case "$1" in
    --output) output=$2; shift 2 ;;
    --dump-header) headers=$2; shift 2 ;;
    https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
: >"$headers"
case "$url" in
  https://api.github.com/repos/example/fixture/releases/tags/*) status=$TAG_STATUS body=$TAG_BODY ;;
  https://api.github.com/repos/example/fixture/releases/latest) status=$LATEST_STATUS body=$LATEST_BODY ;;
  *) echo "unexpected URL $url" >&2; exit 91 ;;
esac
printf '%s' "$body" >"$output"
printf '%s' "$status"
exit "${CURL_EXIT:-0}"
CURL
chmod +x "$work/bin/curl"
# api NAME-OF-SCENARIO ...: run release-checks with the fake GitHub; env VARS are passed as arguments.
api() { env PATH="$work/bin:$PATH" GH_TOKEN=test-only GITHUB_REPOSITORY=example/fixture CI_FETCH_ATTEMPTS=1 "$@"; }
released='{"tag_name":"v0.1.0"}'

passes 'Release is absent (404)' api TAG_STATUS=404 TAG_BODY='{}' LATEST_STATUS=404 LATEST_BODY='{}' bash "$checks" release-absent v0.1.0
rejects 'Release already exists (200)' api TAG_STATUS=200 TAG_BODY="$released" LATEST_STATUS=404 LATEST_BODY='{}' bash "$checks" release-absent v0.1.0
rejects 'forbidden (403) is not read as absent' api TAG_STATUS=403 TAG_BODY='{"message":"Forbidden"}' LATEST_STATUS=404 LATEST_BODY='{}' bash "$checks" release-absent v0.1.0
rejects 'server error (500) is not read as absent' api TAG_STATUS=500 TAG_BODY='' LATEST_STATUS=404 LATEST_BODY='{}' bash "$checks" release-absent v0.1.0
rejects 'unauthenticated (401) is not read as absent' api TAG_STATUS=401 TAG_BODY='{"message":"Bad credentials"}' LATEST_STATUS=404 LATEST_BODY='{}' bash "$checks" release-absent v0.1.0
rejects 'network failure is not read as absent' api CURL_EXIT=6 TAG_STATUS=000 TAG_BODY='' LATEST_STATUS=404 LATEST_BODY='{}' bash "$checks" release-absent v0.1.0
rejects 'a "release not found" text with status 200 is still an existing Release' api TAG_STATUS=200 TAG_BODY='release not found' LATEST_STATUS=404 LATEST_BODY='{}' bash "$checks" release-absent v0.1.0
rejects 'bad tag never reaches the API' api TAG_STATUS=404 TAG_BODY='{}' LATEST_STATUS=404 LATEST_BODY='{}' bash "$checks" release-absent 'v0.1.0;x'
rejects 'missing repository' env -u GITHUB_REPOSITORY PATH="$work/bin:$PATH" GH_TOKEN=test-only TAG_STATUS=404 TAG_BODY='{}' bash "$checks" release-absent v0.1.0

latest_is() { api TAG_STATUS=404 TAG_BODY='{}' LATEST_STATUS=200 "LATEST_BODY={\"tag_name\":\"$1\"}" bash "$checks" latest-newer "$2"; }
passes 'no latest Release (404)' api TAG_STATUS=404 TAG_BODY='{}' LATEST_STATUS=404 LATEST_BODY='{}' bash "$checks" latest-newer v0.1.0
passes 'patch bump' latest_is v0.1.0 v0.1.1
passes 'minor bump' latest_is v0.1.9 v0.2.0
passes 'major bump' latest_is v0.9.9 v1.0.0
passes 'numeric, not text, comparison (v0.1.10 > v0.1.9)' latest_is v0.1.9 v0.1.10
passes 'numeric, not text, comparison (v0.10.0 > v0.9.0)' latest_is v0.9.0 v0.10.0
rejects 'same version as latest' latest_is v0.1.0 v0.1.0
rejects 'older patch' latest_is v0.1.1 v0.1.0
rejects 'older minor' latest_is v0.2.0 v0.1.9
rejects 'older major' latest_is v1.0.0 v0.9.9
rejects 'numeric, not text, comparison (v0.1.9 < v0.1.10)' latest_is v0.1.10 v0.1.9
rejects 'numeric, not text, comparison (v0.9.0 < v0.10.0)' latest_is v0.10.0 v0.9.0
passes 'latest is a pre-release tag, not vX.Y.Z' latest_is smartdns-debian-pinned-2026-07 v0.1.0
passes 'latest is vX.Y.Z-rc1, not vX.Y.Z' latest_is v9.9.9-rc1 v0.1.0
passes 'latest has an empty tag name' latest_is '' v0.1.0
rejects 'latest lookup fails (500)' api TAG_STATUS=404 TAG_BODY='{}' LATEST_STATUS=500 LATEST_BODY='' bash "$checks" latest-newer v0.1.0
rejects 'latest lookup forbidden (403)' api TAG_STATUS=404 TAG_BODY='{}' LATEST_STATUS=403 LATEST_BODY='{}' bash "$checks" latest-newer v0.1.0
rejects 'latest lookup network failure' api CURL_EXIT=6 TAG_STATUS=404 TAG_BODY='{}' LATEST_STATUS=000 LATEST_BODY='' bash "$checks" latest-newer v0.1.0
rejects 'latest response is not JSON' api TAG_STATUS=404 TAG_BODY='{}' LATEST_STATUS=200 LATEST_BODY='<html>' bash "$checks" latest-newer v0.1.0
rejects 'bad tag name' latest_is v0.1.0 'v0.2'
rejects 'unknown command' bash "$checks" publish v0.1.0

# Release notes pin every README command to the tag.
bash "$repo/.github/scripts/release-notes.sh" v1.2.3 "$repo/README.md" >"$work/notes"
[[ "$(grep -c 'releases/download/v1.2.3' "$work/notes")" == 3 ]] || fail 'notes must pin all three commands to the tag'
if grep -Fq 'latest' "$work/notes"; then fail 'notes still point at latest'; fi
grep -Fq 'SHA256SUMS' "$work/notes" || fail 'notes do not mention SHA256SUMS'
if bash "$repo/.github/scripts/release-notes.sh" 'v1.2' "$repo/README.md" >/dev/null 2>&1; then fail 'notes accepted a bad tag'; fi
printf '```sh\necho no download url here\n```\n' >"$work/bad-readme"
if bash "$repo/.github/scripts/release-notes.sh" v1.2.3 "$work/bad-readme" >/dev/null 2>&1; then fail 'notes accepted a command that cannot be pinned'; fi

# The shape of release.yml.
workflow="$repo/.github/workflows/release.yml"
called="$repo/.github/workflows/shellcheck.yml"
grep -Fxq "      - 'v*.*.*'" "$workflow" || fail 'release.yml must trigger on v*.*.* tags'
if grep -Eq '^\s*(branches|pull_request|workflow_dispatch|schedule|release):' "$workflow"; then fail 'release.yml has a trigger besides tags'; fi
awk '/^permissions:/{getline; print; exit}' "$workflow" | grep -Fxq '  contents: read' || fail 'top-level permissions must be contents: read'
[[ "$(grep -c 'contents: write' "$workflow")" == 1 ]] || fail 'exactly one job may have contents: write'
publish_line=$(grep -n '^  publish:' "$workflow" | cut -d: -f1)
write_line=$(grep -n 'contents: write' "$workflow" | cut -d: -f1)
[[ -n "$publish_line" && "$write_line" -gt "$publish_line" ]] || fail 'contents: write must belong to the publish job'
if grep -Eq '(id-token|packages|actions|pull-requests|issues):\s*write' "$workflow"; then fail 'release.yml has an unexpected write permission'; fi
grep -Fq 'needs: [verify-tag, shell-checks, smartdns-checks]' "$workflow" || fail 'publish must wait for every check'
grep -Fq 'uses: ./.github/workflows/shellcheck.yml' "$workflow" || fail 'release.yml must call shellcheck.yml'
grep -Fq 'uses: ./.github/workflows/smartdns-pinned.yml' "$workflow" || fail 'release.yml must call smartdns-pinned.yml'
grep -Eq '^\s+workflow_call:' "$called" || fail 'shellcheck.yml must support workflow_call'
grep -Eq '^\s+workflow_call:' "$repo/.github/workflows/smartdns-pinned.yml" || fail 'smartdns-pinned.yml must support workflow_call'
for gate in tag-format tag-matches-head on-main versions release-absent latest-newer; do
  grep -Eq "release-checks.sh $gate" "$workflow" || fail "release.yml does not run the $gate gate"
done
grep -Fq 'release-checks.sh versions "$TAG" dist' "$workflow" || fail 'the packaged files are not version-checked'
grep -Fq 'release-checks.sh on-main HEAD origin/main' "$workflow" || fail 'the checked-out commit must be tested for being on main'
# One repository-wide, serial queue; nothing is ever cancelled mid-publish.
[[ "$(awk '/^concurrency:/{getline a; getline b; print a "|" b; exit}' "$workflow")" == '  group: release|  cancel-in-progress: false' ]] ||
  fail 'concurrency must be group release with cancel-in-progress: false'
if grep -Eq '\b(curl|wget|pip|npm|npx|go install|go run|apt-get|apt install|docker pull|git clone|nc)\b' "$workflow"; then fail 'release.yml must not download anything'; fi
if grep -Eq '(--clobber|--draft|--prerelease|gh release (delete|edit|upload)|--delete-tag|git push|git tag)' "$workflow"; then fail 'release.yml must never overwrite, edit or delete'; fi
grep -Fq -- '--latest' "$workflow" || fail 'the Release must be marked latest'
grep -Fq -- '--verify-tag' "$workflow" || fail 'gh release create must verify the tag'
# The tag name reaches shell code only through an environment variable.
if grep -n 'github.ref_name' "$workflow" | grep -Ev 'TAG: \$\{\{ github.ref_name \}\}' ; then fail 'github.ref_name is used outside an env assignment'; fi
if grep -nE '^\s+run:.*\$\{\{' "$workflow"; then fail 'expression interpolated into run:'; fi
# Third-party code is pinned to a full commit SHA.
if grep -E '^\s+uses: [^.]' "$workflow" | grep -Ev '@[0-9a-f]{40}$'; then fail 'actions in release.yml must be pinned to a commit SHA'; fi

echo 'PASS: release gates, Release notes and release.yml structure'
