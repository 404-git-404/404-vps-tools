#!/usr/bin/env bash

set -Eeuo pipefail

case "$(uname -m)" in
  x86_64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *)
    printf 'Unsupported architecture: %s\n' "$(uname -m)" >&2
    exit 1
    ;;
esac

asset="domain-check-linux-$arch"
base="${DOMAIN_CHECK_RELEASE_BASE:-https://github.com/404-git-404/404-vps-tools/releases/download/domain-check-latest}"
dir=$(mktemp -d)
trap 'rm -rf -- "$dir"' EXIT

curl -fsSL "$base/$asset" -o "$dir/$asset"
curl -fsSL "$base/SHA256SUMS" -o "$dir/SHA256SUMS"
checksum=$(grep -E "^[[:xdigit:]]{64}  ${asset}$" "$dir/SHA256SUMS")
printf '%s\n' "$checksum" |
  (cd "$dir" && sha256sum -c - >/dev/null)
install -m 0755 "$dir/$asset" /usr/local/bin/domain-check
/usr/local/bin/domain-check --version
