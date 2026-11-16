#!/bin/bash
# Compile l'app et l'empaquette dans « build/Enki Audio.app »
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Enki Audio.app"
rm -rf "$APP" build/Egaliseur.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/Egaliseur" "$APP/Contents/MacOS/EnkiAudio"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] || swift Resources/make_icon.swift
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Traductions (anglais ; le français est la langue des textes de l'app).
cp -R Resources/*.lproj "$APP/Contents/Resources/"

# Signature ad hoc : aucun certificat, aucun accès au trousseau.
# L'identité est fixée sur l'identifiant de l'app (et non sur l'empreinte du code, qui change
# à chaque compilation) : macOS reconnaît ainsi la même app d'une version à l'autre et
# n'a pas de raison de redemander l'autorisation de capter le son après une mise à jour.
./sign.sh "$APP"

echo "OK : $APP"
