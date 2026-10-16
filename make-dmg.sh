#!/bin/bash
# Fabrique l'image disque à distribuer : dist/Plume-<version>.dmg, plus une
# copie dist/Plume.dmg (nom stable pour le lien « dernière version »).
# On l'ouvre, on glisse Plume dans Applications.
#
# Les moteurs sont rangés DANS l'app (Contents/MacOS) : parakeet-server
# (compilé ici) et whisper-server (whisper.cpp, compilé par
# Tools/build-whisper-server.sh). Les modèles se téléchargent au premier
# lancement, avec contrôle des empreintes.
#
# Signature : "signingIdentity" de ~/.config/plume/local.json, sinon ad hoc.
# Sans compte développeur Apple, macOS demande « Ouvrir quand même » dans
# Réglages Système → Confidentialité et sécurité au premier lancement.
# Usage : ./make-dmg.sh
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
PKG="$ROOT/Plume"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PKG/Info.plist")
OUT="$ROOT/dist"
STAGE=$(mktemp -d)/Plume
DMG="$OUT/Plume-$VERSION.dmg"
LOCAL="$HOME/.config/plume/local.json"
SIGN_ID="$([ -f "$LOCAL" ] && plutil -extract signingIdentity raw -o - "$LOCAL" 2>/dev/null || true)"
SIGN_ID="${SIGN_ID:--}"

# Compilé dans un dossier neutre : les binaires gardent le chemin de
# compilation, et il ne doit pas contenir le nom de compte du Mac.
BUILD=/tmp/plume-build
mkdir -p "$BUILD"
rsync -a --delete --exclude .build "$PKG/" "$BUILD/Plume/"
rsync -a --delete --exclude .build "$ROOT/ParakeetServer/" "$BUILD/ParakeetServer/"
echo "Compilation de Plume (release)…"
(cd "$BUILD/Plume" && swift build -c release 2>&1 | tail -1)
echo "Compilation de parakeet-server (release)…"
(cd "$BUILD/ParakeetServer" && swift build -c release 2>&1 | tail -1)
WHISPER="$("$ROOT/Tools/build-whisper-server.sh" | tail -1)"

APP=$STAGE/Plume.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/Plume/.build/release/Plume" "$APP/Contents/MacOS/Plume"
cp "$BUILD/ParakeetServer/.build/release/parakeet-server" "$APP/Contents/MacOS/parakeet-server"
cp "$WHISPER" "$APP/Contents/MacOS/whisper-server"
cp "$PKG/Info.plist" "$APP/Contents/Info.plist"
cp "$PKG/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$PKG/Resources/"*.lproj "$APP/Contents/Resources/"
cp "$ROOT/LICENSE" "$ROOT/THIRD-PARTY-NOTICES.md" "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Les moteurs d'abord, puis l'app qui les contient.
codesign --force --sign "$SIGN_ID" "$APP/Contents/MacOS/parakeet-server"
codesign --force --sign "$SIGN_ID" "$APP/Contents/MacOS/whisper-server"
codesign --force --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP"

ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.fond"
cp "$ROOT/dmg/fond.tiff" "$STAGE/.fond/fond.tiff"   # 1x + 2x (Retina), source : dmg/fond.svg

# Image modifiable → mise en page de la fenêtre par le Finder → image compressée.
mkdir -p "$OUT"
RW=$(mktemp -d)/rw.dmg
hdiutil create -quiet -volname "Plume" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
MOUNT=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk -F'\t' '/\/Volumes\//{print $NF}')
sleep 1
osascript <<APPLESCRIPT || echo "(mise en page Finder ignorée)"
tell application "Finder"
  tell disk "Plume"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 860, 520}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".fond:fond.tiff"
    set position of item "Plume.app" of container window to {170, 200}
    set position of item "Applications" of container window to {490, 200}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
SetFile -a V "$MOUNT/.fond" 2>/dev/null || true
sync
hdiutil detach -quiet "$MOUNT"
rm -f "$DMG"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -rf "$(dirname "$RW")" "$(dirname "$STAGE")"
cp "$DMG" "$OUT/Plume.dmg"
echo "✅ $DMG ($(du -h "$DMG" | cut -f1)), copie : $OUT/Plume.dmg"
