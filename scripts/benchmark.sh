#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/clean_generated.py swift
./scripts/build_protocol_runtime.sh
swift run -c release AetherTransferBenchmarks
