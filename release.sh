#!/bin/bash
# Publie une nouvelle version sur GitHub : les apps installées la proposeront d'elles-mêmes.
#
# Avant : augmentez CFBundleShortVersionString (et CFBundleVersion) dans Resources/Info.plist,
#         et enregistrez vos changements (git commit).
# Usage : ./release.sh "Ce qui change dans cette version"
set -euo pipefail
cd "$(dirname "$0")"

REPO="claudeLimonin/Enki"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
TAG="v$VERSION"
NOTES="${1:-}"

command -v gh >/dev/null || { echo "Installez l'outil GitHub : brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Connectez-vous à GitHub : gh auth login"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Des modifications ne sont pas enregistrées (git commit d'abord)."; exit 1; }
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    echo "La version $VERSION est déjà publiée : augmentez le numéro dans Resources/Info.plist."; exit 1
fi
[ -n "$NOTES" ] || NOTES="Égaliseur $VERSION"

echo "→ Image disque $VERSION…"
./package.sh
DMG="dist/Egaliseur-$VERSION.dmg"

echo "→ Envoi du code et de l'étiquette $TAG…"
git tag -a "$TAG" -m "Égaliseur $VERSION" 2>/dev/null || true
git push origin HEAD "$TAG"

echo "→ Création de la version sur GitHub…"
gh release create "$TAG" "$DMG" -R "$REPO" --title "Égaliseur $VERSION" --notes "$NOTES"

echo
echo "Publiée : https://github.com/$REPO/releases/tag/$TAG"
echo "Les apps installées la proposeront à leur prochaine vérification (au lancement, puis une fois par jour)."
