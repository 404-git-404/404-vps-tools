```bash
bash <(curl -fsSL https://raw.githubusercontent.com/404-git-404/404notfound/main/404notfound.sh)
```

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/404-git-404/404notfound/main/scripts/update-smartdns.sh)
```

```bash
bash -c 'set -Eeuo pipefail; case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) printf "Unsupported architecture: %s\n" "$(uname -m)" >&2; exit 1 ;; esac; asset="domain-check-linux-$arch"; base="https://github.com/404-git-404/404notfound/releases/latest/download"; dir=$(mktemp -d); trap '\''rm -rf -- "$dir"'\'' EXIT; curl -fsSL "$base/$asset" -o "$dir/$asset"; curl -fsSL "$base/SHA256SUMS" -o "$dir/SHA256SUMS"; checksum=$(grep -E "^[[:xdigit:]]{64}  ${asset}$" "$dir/SHA256SUMS"); printf "%s\n" "$checksum" | (cd "$dir" && sha256sum --check --status -); install -m 0755 "$dir/$asset" /usr/local/bin/domain-check; /usr/local/bin/domain-check --version'
```

```bash
domain-check domain1.com/domain2.com
```

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/404-git-404/404notfound/main/node-config-wizard.sh)
```

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/404-git-404/404notfound/main/protocol-benchmark.sh) --server
```

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/404-git-404/404notfound/main/protocol-benchmark.sh) <server-IP> --port <PORT>
```

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/404-git-404/404notfound/main/protocol-benchmark.sh) --history <peer-IP>
```

```sh
curl -fsSL https://raw.githubusercontent.com/404-git-404/404notfound/main/gg-status -o gg-status && chmod +x gg-status && ./gg-status
```
