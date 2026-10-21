#!/usr/bin/env bash
# Unsigned Linux regression checks, shared by local development and PR CI.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

suite="${1:-all}"
case "$suite" in
  all|flutter|core) ;;
  *) echo "Usage: $0 [all|flutter|core]" >&2; exit 2 ;;
esac

if [[ "$suite" == all || "$suite" == flutter ]]; then
  flutter pub get --enforce-lockfile
  cargo test --locked --manifest-path plugins/code_forge/rust/Cargo.toml
  # Editor Flutter tests load this exact release library (see test support.dart).
  cargo build --locked --release --manifest-path plugins/code_forge/rust/Cargo.toml
  flutter analyze --no-pub
  flutter test --no-pub --concurrency=1 --reporter expanded
  python3 -m unittest discover -s tools -p 'test_*.py' -v
fi

if [[ "$suite" == all || "$suite" == core ]]; then
  (
    cd core
    # Do not silently rewrite dependency locks during a regression check.
    export GOFLAGS="${GOFLAGS:+$GOFLAGS }-mod=readonly"
    export CGO_ENABLED=1
    go test ./... -count=1 -timeout=10m
    go test -race ./... -count=1 -timeout=10m
    go vet ./...
    go test -tags=with_gvisor ./... -count=1 -timeout=10m
  )
fi
