#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/clean_generated.py swift
test -x .build/fixture-venv/bin/python || python3 -m venv .build/fixture-venv
if ! .build/fixture-venv/bin/python -c "import importlib.metadata as m; assert m.version('pyftpdlib')=='2.1.0' and m.version('paramiko')=='4.0.0' and m.version('pyOpenSSL')=='26.4.0'" >/dev/null 2>&1; then
    .build/fixture-venv/bin/pip -q install pyftpdlib==2.1.0 paramiko==4.0.0 pyOpenSSL==26.4.0
fi
.build/fixture-venv/bin/python scripts/protocol_fixtures.py
