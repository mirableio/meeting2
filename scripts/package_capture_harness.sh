#!/usr/bin/env bash
set -euo pipefail

# SwiftPM emits a raw executable, but system-audio capture is permissioned as an
# app capability. This script wraps the harness in the smallest signed .app that
# can own stable TCC grants while still keeping the spike fast to rebuild.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-debug}"
BINARY="$ROOT/.build/arm64-apple-macosx/$CONFIG/CaptureHarness"
APP="$ROOT/.build/$CONFIG/CaptureHarness.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
INFO="$CONTENTS/Info.plist"

cd "$ROOT"
swift build ${CONFIG:+--configuration "$CONFIG"}

# System-audio capture is TCC-gated as an app capability, not just as a raw
# executable capability. The harness must therefore run inside a signed .app with
# NSAudioCaptureUsageDescription/NSMicrophoneUsageDescription, otherwise the Core
# Audio tap can hang or fail without a useful OSStatus.
rm -rf "$APP"
mkdir -p "$MACOS"
cp "$BINARY" "$MACOS/CaptureHarness"

cat > "$INFO" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>CaptureHarness</string>
    <key>CFBundleIdentifier</key>
    <string>com.mirable.Meeting2.CaptureHarness</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>CaptureHarness</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.2</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Capture system audio so Meeting2 can save the sound played by this Mac during meetings.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Capture microphone audio so Meeting2 can save your side of meetings.</string>
</dict>
</plist>
PLIST

IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Development/ { print $2; exit }')"
fi

if [[ -n "$IDENTITY" ]]; then
    codesign --force --sign "$IDENTITY" "$APP" >/dev/null
    echo "Signed with: $IDENTITY"
else
    codesign --force --sign - "$APP" >/dev/null
    echo "Signed ad-hoc (set CODE_SIGN_IDENTITY for stable TCC permissions)"
fi

echo "$APP"
