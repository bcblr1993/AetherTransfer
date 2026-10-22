#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.1}"
BUILD_NUMBER="${BUILD_NUMBER:-2026102201}"
FEED_URL="${FEED_URL:-https://github.com/bcblr1993/AetherTransfer/releases/latest/download/appcast.json}"
ENTITLEMENTS="scripts/Entitlements.plist"

# Auto-detect Developer ID Application identity unless CODESIGN_IDENTITY is explicitly set
if [ -z "${CODESIGN_IDENTITY:-}" ]; then
    DETECTED_ID=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application:/ {print $2; exit}')
    CODESIGN_IDENTITY="${DETECTED_ID:--}"
fi

echo "==> Building AetherTransfer v${VERSION} (${BUILD_NUMBER}) in release mode..."
swift build -c release

APP="outputs/AetherTransfer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp .build/release/AetherTransfer "$APP/Contents/MacOS/AetherTransfer"

# Generate AppIcon.icns
ICONSET_DIR="outputs/AppIcon.iconset"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
MASTER_PNG="outputs/icon_master.png"
swift scripts/create_icon.swift "$MASTER_PNG"
for sz in 16 32 128 256 512; do
    sips -z $sz $sz "$MASTER_PNG" --out "$ICONSET_DIR/icon_${sz}x${sz}.png" >/dev/null
    sz2=$((sz * 2))
    sips -z $sz2 $sz2 "$MASTER_PNG" --out "$ICONSET_DIR/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET_DIR" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET_DIR" "$MASTER_PNG"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AetherTransfer</string>
<key>CFBundleIdentifier</key><string>com.aethernative.AetherTransfer</string>
<key>CFBundleName</key><string>AetherTransfer</string>
<key>CFBundleDisplayName</key><string>AetherTransfer</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${VERSION}</string>
<key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 AetherNative. All rights reserved.</string>
<key>NSAppleEventsUsageDescription</key><string>AetherTransfer 需要控制「终端」以在当前本地目录或远程 SSH 会话中快速打开命令行窗口。</string>
<key>ATUpdateFeedURL</key><string>${FEED_URL}</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
<key>UTExportedTypeDeclarations</key><array><dict>
<key>UTTypeIdentifier</key><string>com.aethernative.aethertransfer.item</string>
<key>UTTypeDescription</key><string>AetherTransfer Item</string>
<key>UTTypeConformsTo</key><array><string>public.data</string></array>
</dict></array>
</dict></plist>
PLIST

echo "==> Embedding dylib closure..."
python3 scripts/bundle_dependencies.py "$APP"

echo "==> Signing with identity: ${CODESIGN_IDENTITY}"
if [ "$CODESIGN_IDENTITY" = "-" ]; then
    for dylib in "$APP/Contents/Frameworks"/*.dylib; do
        [ -f "$dylib" ] && codesign --force --sign - "$dylib"
    done
    codesign --force --entitlements "$ENTITLEMENTS" --sign - "$APP"
else
    for dylib in "$APP/Contents/Frameworks"/*.dylib; do
        [ -f "$dylib" ] && codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$dylib"
    done
    codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$CODESIGN_IDENTITY" "$APP"
fi

codesign --verify --deep --strict "$APP"
file "$APP/Contents/MacOS/AetherTransfer"

# Package ZIP for in-app online update
ZIP_OUT="outputs/AetherTransfer-${VERSION}-arm64.zip"
rm -f "$ZIP_OUT"
ditto -c -k --keepParent "$APP" "$ZIP_OUT"

# Optional Apple Notarization for .app (if NOTARY_PROFILE is configured)
if [ -n "${NOTARY_PROFILE:-}" ] && [ "$CODESIGN_IDENTITY" != "-" ]; then
    echo "==> Submitting $ZIP_OUT for Apple Notarization (profile: $NOTARY_PROFILE)..."
    xcrun notarytool submit "$ZIP_OUT" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP_OUT"
    ditto -c -k --keepParent "$APP" "$ZIP_OUT"
fi

# Package DMG for standalone distribution
DMG_STAGING="outputs/dmg_staging"
DMG_OUT="outputs/AetherTransfer-${VERSION}-arm64.dmg"
rm -rf "$DMG_STAGING" "$DMG_OUT"
mkdir -p "$DMG_STAGING"
cp -R "$APP" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create -volname "AetherTransfer" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_OUT" >/dev/null 2>&1
rm -rf "$DMG_STAGING"
if [ "$CODESIGN_IDENTITY" != "-" ]; then
    codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG_OUT"
fi

if [ -n "${NOTARY_PROFILE:-}" ] && [ "$CODESIGN_IDENTITY" != "-" ]; then
    echo "==> Submitting $DMG_OUT for Apple Notarization (profile: $NOTARY_PROFILE)..."
    xcrun notarytool submit "$DMG_OUT" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_OUT"
fi

# Generate SHA256SUMS.txt and appcast.json
ZIP_SHA256=$(shasum -a 256 "$ZIP_OUT" | awk '{print $1}')
DMG_SHA256=$(shasum -a 256 "$DMG_OUT" | awk '{print $1}')
ZIP_SIZE=$(stat -f%z "$ZIP_OUT")

cat > "outputs/SHA256SUMS.txt" <<SUMS
${DMG_SHA256}  AetherTransfer-${VERSION}-arm64.dmg
${ZIP_SHA256}  AetherTransfer-${VERSION}-arm64.zip
SUMS

cat > "outputs/appcast.json" <<JSON
{
  "appName": "AetherTransfer",
  "bundleIdentifier": "com.aethernative.AetherTransfer",
  "latest": {
    "version": "${VERSION}",
    "buildNumber": "${BUILD_NUMBER}",
    "publishedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "downloadURL": "https://github.com/bcblr1993/AetherTransfer/releases/download/v${VERSION}/AetherTransfer-${VERSION}-arm64.zip",
    "sha256": "${ZIP_SHA256}",
    "sizeBytes": ${ZIP_SIZE},
    "minimumSystemVersion": "26.0",
    "releaseNotesZh": "AetherTransfer v${VERSION}：修复书签密码未保存到钥匙串；支持拖到任意文件夹上传下载、把远程文件直接拖到访达。",
    "releaseNotesEn": "AetherTransfer v${VERSION}: fixes bookmark passwords not being saved to Keychain; drag onto any folder to upload or download, and drag remote files straight into Finder."
  }
}
JSON

echo "==> Build & packaging complete:"
echo "    App:     $APP"
echo "    DMG:     $DMG_OUT (SHA-256: $DMG_SHA256)"
echo "    ZIP:     $ZIP_OUT (SHA-256: $ZIP_SHA256)"
echo "    Appcast: outputs/appcast.json"
