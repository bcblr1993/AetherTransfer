#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Replacing the bundle of a running app can invalidate its executable/resources.
python3 - <<'PY_CHECK_RUNNING'
from pathlib import Path
import re, subprocess, sys
binary = str(Path.cwd() / "outputs/AetherTransfer.app/Contents/MacOS/AetherTransfer")
result = subprocess.run(["pgrep", "-f", "^" + re.escape(binary) + r"( |$)"], stdout=subprocess.DEVNULL).returncode
if result not in (0, 1):
    sys.exit("Unable to check the running application; bundle replacement was not started.")
if result == 0:
    sys.exit("AetherTransfer is running. Quit it normally before building a replacement app.")
PY_CHECK_RUNNING
python3 scripts/clean_generated.py app
./scripts/build_protocol_runtime.sh
swift build -c release
APP="outputs/AetherTransfer.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp .build/release/AetherTransfer "$APP/Contents/MacOS/AetherTransfer"
cp -R .build/release/AetherTransfer_AetherTransferCore.bundle "$APP/Contents/Resources/"
# Keep TLS trust available outside the developer's Homebrew installation.
cp /opt/homebrew/etc/ca-certificates/cert.pem "$APP/Contents/Resources/cacert.pem"
cp "${AT_CURL_PREFIX:-$PWD/.build/protocol-runtime}/curl-LICENSE.txt" "$APP/Contents/Resources/curl-LICENSE.txt"
bash scripts/build_icon.sh
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AetherTransfer</string>
<key>CFBundleIdentifier</key><string>com.aethernative.AetherTransfer</string>
<key>CFBundleName</key><string>AetherTransfer</string>
<key>CFBundleDisplayName</key><string>AetherTransfer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>2026100701</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
</dict></plist>
PLIST
python3 scripts/verify_localizations.py "$APP"
python3 scripts/bundle_dependencies.py "$APP"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
file "$APP/Contents/MacOS/AetherTransfer"
echo "Development app: $APP (ad-hoc signed; not a public release)"
