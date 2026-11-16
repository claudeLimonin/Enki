#!/bin/bash
# Produit dist/Egaliseur-<version>.dmg, prêt à partager (installation classique,
# sans App Store) : app universelle (Apple Silicon + Intel), raccourci « Applications »
# pour l'installer par glisser-déposer, et notice.
#
# Signature ad hoc à identité stable (voir sign.sh) : aucun certificat ni trousseau.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)

# Note : l'avertissement « x86_64 is deprecated » de Xcode est sans effet,
# le binaire cible bien macOS 14.2 (voir Package.swift).
echo "→ Compilation universelle (arm64 + x86_64)…"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Egaliseur"

STAGE="dist/Egaliseur"
APP="$STAGE/Egaliseur.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Egaliseur"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] || swift Resources/make_icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Traductions (anglais ; le français est la langue des textes de l'app).
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp Resources/LISEZMOI.txt "$STAGE/LISEZMOI.txt"

echo "→ Signature…"
./sign.sh "$APP"

# Raccourci vers Applications : on glisse l'app dessus pour l'installer.
ln -s /Applications "$STAGE/Applications"

echo "→ Image disque…"
DMG="dist/Egaliseur-$VERSION.dmg"
hdiutil create -volname "Égaliseur $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"

echo
echo "Architectures : $(lipo -archs "$BIN")"
echo "OK : $DMG ($(du -h "$DMG" | cut -f1))"
