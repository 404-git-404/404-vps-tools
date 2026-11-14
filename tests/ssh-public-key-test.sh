#!/usr/bin/env bash
# shellcheck disable=SC2329,SC2034 # Installer functions invoke these test doubles.
set -Eeuo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf -- "$TEST_TMP"' EXIT
export TEST_AUTHORIZED_KEYS="$TEST_TMP/root/.ssh/authorized_keys"
# shellcheck disable=SC2016 # Expand the test path when sourcing the fixture.
sed 's|^readonly AUTHORIZED_KEYS=.*|readonly AUTHORIZED_KEYS="$TEST_AUTHORIZED_KEYS"|' \
  "$REPO_ROOT/debian-init.sh" >"$TEST_TMP/installer.sh"
# shellcheck disable=SC1091
source "$TEST_TMP/installer.sh"
trap - ERR HUP INT TERM
trap 'rm -rf -- "$TEST_TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

for type in ed25519 rsa ecdsa; do
  ssh-keygen -q -t "$type" -N '' -C fixture -f "$TEST_TMP/$type"
done
key=$(cat "$TEST_TMP/ed25519.pub")
rsa=$(cat "$TEST_TMP/rsa.pub")
ecdsa=$(cat "$TEST_TMP/ecdsa.pub")
directory=${AUTHORIZED_KEYS%/*}
mkdir -p "$directory"
TMP_DIR="$TEST_TMP/staging"
BACKUP_DIR="$TEST_TMP/backup"
mkdir -p "$TMP_DIR" "$BACKUP_DIR"
fingerprint=$(ssh_public_key_fingerprints <<<"$key")
restricted='restrict,command="echo \"two words\"",from="192.0.2.0/24"'

# Use real ssh-keygen and filesystem reads/writes with portable metadata mocks.
install() {
  [[ "$1" == -d ]] || fail 'unexpected install invocation'
  shift
  while [[ "$1" == -o || "$1" == -g || "$1" == -m ]]; do shift 2; done
  mkdir -p -- "$@"
}
chown() { :; }
stat() { printf '0 %s\n' "${test_mode:-700}"; }
make_mutable() { :; }
read_tty() {
  [[ "$prompt_index" -lt ${#replies[@]} ]] || fail "unexpected prompt: $1"
  printf '%s\n' "$1" >>"$TEST_TMP/prompts"
  printf -v "$2" '%s' "${replies[prompt_index]}"
  prompt_index=$((prompt_index + 1))
}

for scenario in reuse-many reuse-one decline first empty comments corrupt duplicate pasted pubkey file unsafe; do
  (
    INSTALL_MODE=quick
    prompt_index=0
    : >"$TEST_TMP/prompts"
    rm -f -- "$AUTHORIZED_KEYS" "$BACKUP_DIR/ssh/authorized_keys"
    case "$scenario" in
      reuse-many)
        INSTALL_MODE=custom
        printf '  # comment\n\n%s\n%s %s\n%s\nnot-a-real-option %s\nssh-rsa !!!\n' \
          "$key" "$restricted" "$rsa" "$ecdsa" "$key" >"$AUTHORIZED_KEYS"
        replies=('' Y) ;;
      reuse-one|unsafe) printf '%s\n' "$key" >"$AUTHORIZED_KEYS"; replies=('' '');;
      decline) printf '%s' "$key" >"$AUTHORIZED_KEYS"; replies=('' n "$rsa") ;;
      first) replies=('' 'invalid' "$key") ;;
      empty) : >"$AUTHORIZED_KEYS"; replies=('' "$key") ;;
      comments) printf '# only a comment\n\n' >"$AUTHORIZED_KEYS"; replies=('' "$key") ;;
      corrupt)
        printf 'ssh-ed25519 AAAA\nunknown-option %s\ncommand="unterminated %s\n' "$key" "$rsa" >"$AUTHORIZED_KEYS"
        replies=('' "$key") ;;
      duplicate) printf '%s %s\n' "$restricted" "$key" >"$AUTHORIZED_KEYS"; replies=("${key% fixture} different-comment") ;;
      pasted) printf '%s\n' "$key" >"$AUTHORIZED_KEYS"; replies=("$rsa") ;;
      pubkey) parse_args --pubkey "$key"; replies=() ;;
      file) printf '# comment\n%s\r\n' "$rsa" >"$TEST_TMP/input.pub"; parse_args --pubkey-file "$TEST_TMP/input.pub"; replies=() ;;
    esac
    if [[ -f "$AUTHORIZED_KEYS" ]]; then cp -- "$AUTHORIZED_KEYS" "$TEST_TMP/before"; fi
    if [[ "$scenario" == unsafe ]]; then
      test_mode=777
      if (collect_public_key); then fail 'accepted writable authorized_keys'; fi
      cmp "$TEST_TMP/before" "$AUTHORIZED_KEYS"
      exit 0
    fi
    collect_public_key >"$TEST_TMP/output"
    install_authorized_key
    [[ "$prompt_index" == "${#replies[@]}" ]] || fail "$scenario: prompts did not match"
    case "$scenario" in
      reuse-one|reuse-many)
        [[ "$REUSE_PUBLIC_KEY" == true && -z "$PUBLIC_KEY" ]]
        cmp "$TEST_TMP/before" "$AUTHORIZED_KEYS"
        [[ ! -e "$BACKUP_DIR/ssh/authorized_keys" ]]
        grep -Fxq "$fingerprint" "$TEST_TMP/output"
        if [[ "$scenario" == reuse-many ]]; then
          grep -Fq '检测到 3 个有效 SSH 公钥' "$TEST_TMP/output"
          [[ "$(grep -c '^SHA256:' "$TEST_TMP/output")" == 3 ]]
        else
          grep -Fq '检测到 1 个有效 SSH 公钥' "$TEST_TMP/output"
          (
            prompt_index=0
            # Reach the actual quick-install dispatch and stop after the key step.
            preflight() { :; }
            acquire_lock() { :; }
            install_early_dependencies() { :; }
            confirm_ssh_listener_change() { :; }
            configure_swap() {
              [[ "$REUSE_PUBLIC_KEY" == true && "$prompt_index" == 2 ]]
              exit 0
            }
            main --ssh-port 53651 --network-stack auto
          )
          cmp "$TEST_TMP/before" "$AUTHORIZED_KEYS"
        fi ;;
      duplicate) cmp "$TEST_TMP/before" "$AUTHORIZED_KEYS" ;;
      decline|pasted)
        cmp "$TEST_TMP/before" "$BACKUP_DIR/ssh/authorized_keys"
        grep -Fxq "$key" "$AUTHORIZED_KEYS"
        grep -Fxq "$rsa" "$AUTHORIZED_KEYS" ;;
      file) grep -Fxq "$rsa" "$AUTHORIZED_KEYS" ;;
      *) grep -Fxq "$key" "$AUTHORIZED_KEYS" ;;
    esac
  )
done

for arg in --pubkey --pubkey-file; do
  if (parse_args "$arg"); then fail "accepted missing $arg"; fi
  if (parse_args "$arg" ''); then fail "accepted empty $arg"; fi
done
printf '%s\n' "$key" >"$AUTHORIZED_KEYS"
printf '# empty\n' >"$TEST_TMP/empty.pub"
printf 'not a key\n' >"$TEST_TMP/invalid.pub"
for value in ' ' invalid $'invalid\nsecond line'; do
  if (parse_args --pubkey "$value"; collect_public_key); then fail 'accepted invalid explicit key'; fi
done
for file in empty.pub invalid.pub nonexistent.pub; do
  if (parse_args --pubkey-file "$TEST_TMP/$file"; collect_public_key); then fail 'accepted invalid explicit key file'; fi
done
if [[ "$(uname -s)" == Linux ]]; then
  mv "$AUTHORIZED_KEYS" "$TEST_TMP/symlink-target"
  ln -s "$TEST_TMP/symlink-target" "$AUTHORIZED_KEYS"
  if (parse_args --pubkey "$key"; collect_public_key); then fail 'accepted symlink'; fi
fi
echo 'PASS: SSH public key reuse, validation, append and CLI inputs'
