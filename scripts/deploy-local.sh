#!/bin/bash
# Deploy Claude Island locally (build Release + install in /Applications)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="Claude Island"
APP_DEST="/Applications/$APP_NAME.app"

echo "=== Deploy local : $APP_NAME ==="
echo ""

cd "$PROJECT_DIR"

# Build Release
echo "Build Release..."
xcodebuild -project ClaudeIsland.xcodeproj \
    -scheme ClaudeIsland \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    build 2>&1 | tail -5

APP_SRC="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"

if [ ! -d "$APP_SRC" ]; then
    echo "Erreur : build échoué, $APP_SRC introuvable."
    exit 1
fi

# Fermer l'app si elle tourne
echo "Fermeture de $APP_NAME..."
osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
sleep 1

# Installer
echo "Installation dans /Applications..."
rm -rf "$APP_DEST"
cp -R "$APP_SRC" "$APP_DEST"

# Extraire les entitlements du binaire buildé et ajouter disable-library-validation.
# Nécessaire car le signing ad-hoc (sans Team ID) + hardened runtime active la
# library validation, ce qui bloque le chargement de Sparkle.framework.
ENTITLEMENTS_TEMP=$(mktemp)
codesign -d --entitlements :- "$APP_SRC" > "$ENTITLEMENTS_TEMP" 2>/dev/null
/usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$ENTITLEMENTS_TEMP"

# Re-signer ad-hoc (deep) avec hardened runtime + entitlements.
# --options runtime : conserve le flag runtime (CodeDirectory v=20500)
# --entitlements : appliqué uniquement au binaire principal (pas aux frameworks)
echo "Signature ad-hoc..."
codesign --force --deep --sign - --options runtime --entitlements "$ENTITLEMENTS_TEMP" "$APP_DEST"
rm -f "$ENTITLEMENTS_TEMP"

# Lancer
echo "Lancement..."
open "$APP_DEST"

echo ""
echo "=== $APP_NAME déployée ==="
