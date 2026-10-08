#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/clean_generated.py swift
./scripts/build_protocol_runtime.sh
test -x .build/fixture-venv/bin/python || python3 -m venv .build/fixture-venv
.build/fixture-venv/bin/pip -q --disable-pip-version-check install --no-cache-dir pyftpdlib==2.1.0 paramiko==4.0.0 pyOpenSSL==26.4.0 WsgiDAV==4.3.5 cheroot==11.1.2
.build/fixture-venv/bin/python scripts/protocol_fixtures.py
