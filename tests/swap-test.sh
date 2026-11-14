#!/usr/bin/env bash
# shellcheck disable=SC2329,SC2034 # Mocks and state used by the sourced installer.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export SWAP_TEST_DIR
SWAP_TEST_DIR=$(mktemp -d)
# shellcheck disable=SC2016
sed -e 's|^readonly SWAPFILE=.*|readonly SWAPFILE="$SWAP_TEST_DIR/swapfile"|' \
    -e 's|^readonly SWAP_FSTAB=.*|readonly SWAP_FSTAB="$SWAP_TEST_DIR/fstab"|' \
    "$repo/debian-init.sh" >"$SWAP_TEST_DIR/installer"
# shellcheck disable=SC1091
source "$SWAP_TEST_DIR/installer"
trap - ERR HUP INT TERM
trap 'rm -rf -- "$SWAP_TEST_DIR"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
CONTAINER_KIND=none
BACKUP_DIR="$SWAP_TEST_DIR/backup"
if [[ "${1:-}" == --kernel ]]; then
  # GitHub's disposable VM provides CAP_SYS_ADMIN and a real filesystem.
  trap 'swapoff "$SWAPFILE" 2>/dev/null || true; rm -rf -- "$SWAP_TEST_DIR"' EXIT
  printf '# test fstab\n' >"$SWAP_FSTAB"
  # Limit the actual allocation and isolate the test from the runner's SwapTotal.
  swap_total_mib() { echo 0; }
  create_swap 512
  swapon --show=NAME --noheadings --raw | grep -Fx "$SWAPFILE"
  grep -Fx "$SWAPFILE none swap sw 0 0" "$SWAP_FSTAB"
  create_swap 512
  [[ "$(grep -Fc "$SWAPFILE " "$SWAP_FSTAB")" == 1 ]]
  echo 'PASS: real Swap activation and fstab on the CI VM'
  exit 0
fi
mem_total_kib() { echo "$ram"; }
swap_total_mib() { echo "$existing"; }
root_free_kib() { echo "$disk"; }
swapon() {
  if [[ "$1" == --show=NAME ]]; then
    if [[ -f "$SWAP_TEST_DIR/active" ]]; then echo "$SWAPFILE"; fi
  elif [[ "$1" == "$SWAPFILE" && "$failure" != swapon ]]; then
    [[ -f "$SWAPFILE" ]]
    touch "$SWAP_TEST_DIR/active"
  else
    return 1
  fi
}
swapoff() { [[ "$1" == "$SWAPFILE" ]] && rm -- "$SWAP_TEST_DIR/active"; }
make_mutable() { :; }
restore_attrs() { :; }
install() { [[ "$1" == -d && "$2" == -m ]] && mkdir -p -- "${@:4}"; }
blkid() { echo swap; }
stat() {
  if [[ "$2" == '%u %a %h %s' ]]; then
    printf '%s 600 1 %s\n' "$mock_owner" "$old_size"
  else
    command stat "$@"
  fi
}
dd() {
  echo "${4#count=}" >>"$SWAP_TEST_DIR/allocations"
  printf 'new file\n' >"${2#of=}"
  [[ "$failure" != allocation ]]
}
mkswap() { [[ "$failure" != mkswap ]]; }
mv() {
  if [[ "${*: -1}" == "$SWAP_FSTAB" && "$failure" == fstab ]]; then return 1; fi
  command mv "$@"
}
ask_yes_no() {
  printf '%s\n' "$1" >>"$SWAP_TEST_DIR/prompts"
  disk=$after_prompt
  [[ "$answer" == yes ]]
}

ram=$((967*1024)) existing=0 disk=0 mock_owner=0 old_size=0 failure=none
for scenario in '2950 1024' '4096 2048' '2048 1024' '1536 512' '1535 0'; do
  IFS=' ' read -r free expected <<<"$scenario"
  disk=$((free*1024))
  recommend_swap
  [[ "$SWAP_RECOMMENDED_MIB" == "$expected" ]] || fail "unexpected recommendation at ${free}MiB"
done
disk=$((2048*1024-1))
recommend_swap
[[ "$SWAP_RECOMMENDED_MIB" == 512 ]] || fail 'one KiB below 2048 MiB'
if (check_root_space) >"$SWAP_TEST_DIR/preflight" 2>&1; then fail 'preflight accepted less than 2 GiB'; fi
grep -Fq '还需释放：0.0009765625MiB' "$SWAP_TEST_DIR/preflight"
disk=$((2048*1024))
check_root_space
ram=$((1973*1024)) disk=$((4096*1024))
recommend_swap
[[ "$SWAP_RECOMMENDED_MIB" == 1024 ]]
existing=512
recommend_swap
[[ "$SWAP_RECOMMENDED_MIB" == 0 ]]
existing=0 ram=$((967*1024))

for scenario in success decline downgrade skip reuse replacement allocation mkswap swapon fstab unsafe changed; do
  (
    failure=$scenario answer=yes mock_owner=0
    disk=$((4096*1024))
    after_prompt=$disk
    : >"$SWAP_TEST_DIR/allocations"
    : >"$SWAP_TEST_DIR/prompts"
    rm -f -- "$SWAP_TEST_DIR/active" "$SWAPFILE"
    printf '# untouched\n%s none swap defaults 0 0\n%s none swap sw 0 0\n' "$SWAPFILE" "$SWAPFILE" >"$SWAP_FSTAB"
    cp -- "$SWAP_FSTAB" "$SWAP_TEST_DIR/before"
    case "$scenario" in
      decline) answer=no ;;
      downgrade) after_prompt=$((2950*1024)) ;;
      skip) after_prompt=$((1536*1024-1)) ;;
      reuse)
        printf 'old file\n' >"$SWAPFILE"
        old_size=$((1024*1024*1024))
        disk=$((2048*1024))
        after_prompt=$disk ;;
      replacement|fstab|unsafe)
        printf 'old file\n' >"$SWAPFILE"
        old_size=$((512*1024*1024))
        if [[ "$scenario" == unsafe ]]; then mock_owner=1000; fi ;;
      changed)
        ask_yes_no() { printf 'new operator file\n' >"$SWAPFILE"; } ;;
    esac
    configure_swap
    case "$scenario" in
      success|downgrade|reuse|replacement)
        [[ -f "$SWAP_TEST_DIR/active" ]]
        [[ "$(grep -Fc "$SWAPFILE " "$SWAP_FSTAB")" == 1 ]]
        grep -Fxq "$SWAPFILE none swap sw 0 0" "$SWAP_FSTAB"
        grep -Fxq '# untouched' "$SWAP_FSTAB"
        cmp "$SWAP_TEST_DIR/before" "$BACKUP_DIR/swap/fstab"
        if [[ "$scenario" == reuse ]]; then
          [[ ! -s "$SWAP_TEST_DIR/allocations" && "$(cat "$SWAPFILE")" == 'old file' ]]
        elif [[ "$scenario" == downgrade ]]; then
          grep -Fxq 1024 "$SWAP_TEST_DIR/allocations"
        else
          grep -Fxq 2048 "$SWAP_TEST_DIR/allocations"
        fi
        cp "$SWAP_FSTAB" "$SWAP_TEST_DIR/once"
        : >"$SWAP_TEST_DIR/prompts"
        configure_swap
        [[ ! -s "$SWAP_TEST_DIR/prompts" ]]
        cmp "$SWAP_TEST_DIR/once" "$SWAP_FSTAB" ;;
      *)
        [[ ! -e "$SWAP_TEST_DIR/active" ]]
        cmp "$SWAP_TEST_DIR/before" "$SWAP_FSTAB"
        case "$scenario" in
          fstab|unsafe) [[ "$(cat "$SWAPFILE")" == 'old file' ]] ;;
          changed) [[ "$(cat "$SWAPFILE")" == 'new operator file' ]] ;;
          *) [[ ! -e "$SWAPFILE" ]] ;;
        esac ;;
    esac
    if compgen -G "$SWAP_TEST_DIR/*.vps-init.*" >/dev/null; then fail "$scenario left staging files"; fi
  )
done
echo 'PASS: Swap capacity, recheck, reuse, idempotency and rollback'
