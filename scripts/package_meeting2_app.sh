#!/usr/bin/env bash
set -euo pipefail

# Wrap the SwiftPM menu-bar executable in a real signed .app. Running the raw
# executable is useful for compiler checks, but TCC grants attach to the bundle
# identity and code signature; manual recording must be tested through this app.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-debug}"
BINARY="$ROOT/.build/arm64-apple-macosx/$CONFIG/Meeting2"
if [[ ! -x "$BINARY" ]]; then
    BINARY="$ROOT/.build/$CONFIG/Meeting2"
fi

APP="$ROOT/.build/$CONFIG/Meeting2.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
INFO="$CONTENTS/Info.plist"

cd "$ROOT"
swift build ${CONFIG:+--configuration "$CONFIG"} --product Meeting2

rm -rf "$APP"
mkdir -p "$MACOS"
cp "$BINARY" "$MACOS/Meeting2"

cat > "$INFO" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Meeting2</string>
    <key>CFBundleIdentifier</key>
    <string>com.mirable.Meeting2</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Meeting2</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.2</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Capture system audio so Meeting2 can save the sound played by this Mac during meetings.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Capture microphone audio so Meeting2 can save your side of meetings.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Read your calendar to name recorded meetings.</string>
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
