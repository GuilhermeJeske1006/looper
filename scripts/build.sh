#!/bin/bash
# Compila o Jeske Looper (arm64, release) e monta dist/Jeske Looper.app com assinatura ad hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Jeske Looper"
EXECUTABLE="JeskeLooper"
APP="dist/$APP_NAME.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # "-" = ad hoc; defina SIGN_IDENTITY para usar um certificado

echo "→ Compilando (release, arm64)…"
swift build -c release --arch arm64 --product "$EXECUTABLE"
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

echo "→ Gerando ícone…"
mkdir -p build
if [ ! -f build/AppIcon.icns ] || [ scripts/make_icon.swift -nt build/AppIcon.icns ]; then
    swiftc -O scripts/make_icon.swift -o build/make_icon
    rm -rf build/AppIcon.iconset
    build/make_icon build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

echo "→ Montando ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/pt-BR.lproj "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "→ Assinando (${SIGN_IDENTITY/#-/ad hoc})…"
codesign --force --options runtime --timestamp=none \
    --entitlements Resources/JeskeLooper.entitlements \
    --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=1 "$APP"

echo "✓ Pronto: $APP ($(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE"))"
