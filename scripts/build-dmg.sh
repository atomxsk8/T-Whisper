#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="T-Whisper"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT

"$ROOT_DIR/scripts/build-app.sh"

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "error: $APP_BUNDLE not found after build-app.sh" >&2
    exit 1
fi

echo "Staging $APP_NAME.dmg contents..."
cp -R "$APP_BUNDLE" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

echo "Building $DMG_PATH..."
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"

echo "Built $DMG_PATH"
