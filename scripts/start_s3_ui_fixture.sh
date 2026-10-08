#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/clean_generated.py fixtures
trap 'python3 scripts/clean_generated.py fixtures' EXIT
./scripts/build_s3_fixture.sh
test -x .build/fixture-venv/bin/python || python3 -m venv .build/fixture-venv
.build/fixture-venv/bin/pip -q --disable-pip-version-check install --no-cache-dir pyOpenSSL==26.4.0
.build/fixture-venv/bin/python scripts/s3_fixtures.py --ui
