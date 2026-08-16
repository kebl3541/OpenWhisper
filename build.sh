#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

APP="OpenWhisper.app"

swiftc -O -parse-as-library -target arm64-apple-macos26.0 Sources/main.swift -o OpenWhisper

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp docs/USER-GUIDE.md "$APP/Contents/Resources/USER-GUIDE.md"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
mv OpenWhisper "$APP/Contents/MacOS/OpenWhisper"
# A stable self-signed cert keeps TCC grants (mic/accessibility) across
# rebuilds. Any cert named "OpenWhisper Dev" is used if present (legacy
# "TalkToClaude Dev" also accepted); otherwise ad-hoc, which works but
# resets the Accessibility grant on every rebuild (see README).
if security find-identity -v -p codesigning 2>/dev/null | grep -q "OpenWhisper Dev"; then
  codesign --force --sign "OpenWhisper Dev" "$APP"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "TalkToClaude Dev"; then
  codesign --force --sign "TalkToClaude Dev" "$APP"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1
fi

echo "Built $APP"
