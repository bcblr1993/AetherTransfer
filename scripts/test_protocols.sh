#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test -x .build/fixture-venv/bin/python || python3 -m venv .build/fixture-venv
.build/fixture-venv/bin/pip -q install pyftpdlib==2.1.0 paramiko==4.0.0
.build/fixture-venv/bin/python scripts/protocol_fixtures.py
