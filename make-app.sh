#!/bin/bash
# Compile Plume et l'installe dans ~/Applications (trouvable par Spotlight).
# Usage : ./make-app.sh
#
# Réglages propres à ce Mac, lus dans ~/.config/plume/local.json s'il existe :
#   "bundleIdentifier" : identifiant de l'app (sinon celui d'Info.plist) ;
#   "signingIdentity"  : certificat de signature (sinon signature ad hoc).
# Un certificat stable garde les autorisations Micro et Accessibilité d'une
# compilation à l'autre ; avec la signature ad hoc, macOS les redemande.
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
PKG="$ROOT/Plume"
APP="$HOME/Applications/Plume.app"
LOCAL="$HOME/.config/plume/local.json"

local_value() { [ -f "$LOCAL" ] && plutil -extract "$1" raw -o - "$LOCAL" 2>/dev/null || true; }
BUNDLE_ID="$(local_value bundleIdentifier)"
SIGN_ID="$(local_value signingIdentity)"

echo "Compilation (release)…"
(cd "$PKG" && swift build -c release 2>&1 | tail -1)

# Si Plume tourne, on l'arrête (elle arrête alors le moteur qu'elle a lancé).
pkill -TERM -x Plume 2>/dev/null || true
sleep 1

echo "Emballage de $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PKG/.build/release/Plume" "$APP/Contents/MacOS/Plume"
cp "$PKG/Info.plist" "$APP/Contents/Info.plist"
cp "$PKG/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$PKG/Resources/"*.lproj "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"
[ -n "$BUNDLE_ID" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"

codesign --force --deep --sign "${SIGN_ID:--}" "$APP"
touch "$APP"
echo "✅ $APP ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist"))"
