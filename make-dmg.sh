#!/bin/bash
# NotchStatus - dağıtılabilir .dmg üretici (sürükle-bırak kurulum)
set -euo pipefail
cd "$(dirname "$0")"

APP="NotchStatus.app"
DMG="NotchStatus.dmg"
STAGE="dmg-stage"

./build-app.sh

echo "-> .dmg oluşturuluyor…"
rm -rf "$STAGE" "$DMG"
mkdir "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"          # sürükle-bırak için Applications kısayolu

hdiutil create -volname "NotchStatus" \
  -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "✓ $DMG ($(du -h "$DMG" | cut -f1)) - Releases'e yükle"
