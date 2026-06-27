#!/bin/bash
# NotchStatus - .app bundle üretici (optimize edilmiş release derleme)
set -euo pipefail
cd "$(dirname "$0")"

APP="NotchStatus.app"
EXE="NotchStatus"

echo "-> Derleniyor (universal: arm64 + x86_64, release -O)…"
swiftc NotchApp.swift -O -whole-module-optimization -target arm64-apple-macos13  -o "$EXE-arm64"  -framework Cocoa -framework SwiftUI
swiftc NotchApp.swift -O -whole-module-optimization -target x86_64-apple-macos13 -o "$EXE-x86_64" -framework Cocoa -framework SwiftUI
lipo -create -output "$EXE" "$EXE-arm64" "$EXE-x86_64"   # Apple Silicon + Intel tek binary
rm -f "$EXE-arm64" "$EXE-x86_64"

echo "-> .app bundle oluşturuluyor…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$EXE" "$APP/Contents/MacOS/$EXE"
cp Info.plist "$APP/Contents/Info.plist"
cp notch_update.py "$APP/Contents/Resources/notch_update.py"   # hook - app ilk açılışta ~/.claude'a kurar
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" || echo "  (AppIcon.icns yok - atlandı)"

echo "-> Ad-hoc imzalama (Gatekeeper için)…"
codesign --force --deep --sign - "$APP"

rm -f "$EXE"
echo "✓ Hazır: $APP"
echo "  Test: open $APP"
