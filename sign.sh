#!/bin/bash
# Signe une app ad hoc (sans certificat ni trousseau) avec une identité stable.
# Usage : ./sign.sh chemin/vers/Egaliseur.app
set -euo pipefail
APP="$1"
ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Contents/Info.plist")

# « -s - » : signature ad hoc. « -r » : exigence désignée explicite, limitée à l'identifiant.
codesign --force --sign - --requirements "=designated => identifier \"$ID\"" "$APP"
codesign --verify --strict "$APP"
echo "Signée ad hoc, identité stable : $ID (sans trousseau)."
