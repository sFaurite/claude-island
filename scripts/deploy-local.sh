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

# Re-signer (Sparkle + ad-hoc)
echo "Signature ad-hoc..."
codesign --force --deep --sign - "$APP_DEST" 2>/dev/null

# Lancer
echo "Lancement..."
open "$APP_DEST"

echo ""
echo "=== $APP_NAME déployée ==="
