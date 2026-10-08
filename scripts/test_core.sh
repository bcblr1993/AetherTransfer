#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/clean_generated.py swift
python3 scripts/verify_localizations.py
./scripts/build_protocol_runtime.sh
swift test
