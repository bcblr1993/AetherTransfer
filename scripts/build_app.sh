#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="outputs/AetherTransfer.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp .build/release/AetherTransfer "$APP/Contents/MacOS/AetherTransfer"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AetherTransfer</string>
<key>CFBundleIdentifier</key><string>com.aethernative.AetherTransfer</string>
<key>CFBundleName</key><string>AetherTransfer</string>
<key>CFBundleDisplayName</key><string>AetherTransfer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>2026100701</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
</dict></plist>
PLIST
python3 scripts/bundle_dependencies.py "$APP"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
file "$APP/Contents/MacOS/AetherTransfer"
echo "Development app: $APP (ad-hoc signed; not a public release)"
