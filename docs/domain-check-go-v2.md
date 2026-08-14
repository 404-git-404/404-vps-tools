# domain-check Go v2

The Go implementation is the production native-network successor to
`domain-check.sh`. The Bash implementation remains available as the legacy
reference implementation.

## Build

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
  -trimpath -ldflags='-s -w' -o domain-check ./cmd/domain-check
```

For Linux arm64, replace `GOARCH=amd64` with `GOARCH=arm64`.

## Run

```bash
./domain-check domain1.com/domain2.com/domain3.com
```

Worker concurrency defaults to 24. Override it with a validated positive integer:

```bash
DOMAIN_CHECK_CONCURRENCY=12 ./domain-check domain1.com/domain2.com
```

READY timing concurrency defaults to 4 and can be overridden independently:

```bash
DOMAIN_CHECK_READY_CONCURRENCY=2 ./domain-check domain1.com/domain2.com
```

The detector writes a self-contained HTML report below
`${HOME}/domain-check-logs/` before returning its final status.

## Benchmark

Use the same input lists used to benchmark the Bash implementation:

```bash
scripts/domain-check-go-benchmark.sh ./domain-check 'pass1.example/pass2.example/...'
scripts/domain-check-go-benchmark.sh ./domain-check 'full1.example/full2.example/...'
```

The harness runs worker counts 2, 4, 8, 12, and 16. A 100-domain run uses the
same command with a slash-delimited 100-domain argument.
