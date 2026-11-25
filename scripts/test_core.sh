#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/clean_generated.py swift
swift test
