#!/bin/bash
# Gera dist/Jeske Looper.dmg com o app e um atalho para Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Jeske Looper"
STAGE="build/dmg"
rm -rf "$STAGE" "dist/$APP_NAME.dmg"
mkdir -p "$STAGE"
ditto "dist/$APP_NAME.app" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "dist/$APP_NAME.dmg" >/dev/null
rm -rf "$STAGE"
echo "✓ dist/$APP_NAME.dmg"
