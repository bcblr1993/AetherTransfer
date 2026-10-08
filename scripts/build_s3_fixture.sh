#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Test-only AGPLv3 server, never copied into the application bundle.
version=7aac2a2c5b7c882e68c1ce017d8256be2feea27f
python3 scripts/clean_generated.py s3
if test -x .build/s3-fixture/minio && test "$(cat .build/s3-fixture/source-version 2>/dev/null)" = "$version"; then
    exit 0
fi
trap 'python3 scripts/clean_generated.py s3' EXIT
mkdir -p .build/s3-fixture-build .build/s3-fixture
env GOPATH="$PWD/.build/s3-fixture-build/go" \
    GOFLAGS=-modcacherw \
    GOMODCACHE="$PWD/.build/s3-fixture-build/modules" \
    GOCACHE="$PWD/.build/s3-fixture-build/cache" \
    GOBIN="$PWD/.build/s3-fixture-build/bin" \
    go install "github.com/minio/minio@$version"
mv .build/s3-fixture-build/bin/minio .build/s3-fixture/minio
printf '%s\n' "$version" > .build/s3-fixture/source-version
