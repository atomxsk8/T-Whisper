#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="T-Whisper"
BUNDLE_ID="app.twhisper.mac"
CERT_NAME="T-Whisper Dev"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

# Ad-hoc signing (`--sign -`) gives every rebuild a fresh signature hash, so macOS TCC
# (Accessibility/Input Monitoring grants) treats each build as a new app and silently
# stops honoring permissions granted to the previous binary. A stable self-signed identity
# keeps the same signature across rebuilds, so permissions granted once in System Settings
# keep working.
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "Creating self-signed code signing certificate '$CERT_NAME' (one-time)..."
    CERT_CFG="$(mktemp)"
    CERT_KEY="$(mktemp)"
    CERT_CRT="$(mktemp)"
    cat > "$CERT_CFG" <<CFG_EOF
[ req ]
distinguished_name = req_dn
[ req_dn ]
CN = $CERT_NAME
[ extensions ]
keyUsage = digitalSignature
extendedKeyUsage = codeSigning
CFG_EOF
    openssl req -x509 -newkey rsa:2048 \
        -keyout "$CERT_KEY" -out "$CERT_CRT" \
        -days 3650 -nodes \
        -config "$CERT_CFG" -extensions extensions \
        -subj "/CN=$CERT_NAME" 2>/dev/null
    security import "$CERT_CRT" -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
    security import "$CERT_KEY" -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
    security add-trusted-cert -d -r trustRoot -k ~/Library/Keychains/login.keychain-db "$CERT_CRT"
    rm -f "$CERT_CFG" "$CERT_KEY" "$CERT_CRT"
    echo "Certificate '$CERT_NAME' created and trusted for code signing."
fi

echo "Building $APP_NAME (release)..."
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/TWhisper"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "error: built executable not found at $BIN_PATH" >&2
    exit 1
fi

echo "Assembling $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/TWhisper"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT_DIR/Resources/TWhisperIcon.icns" "$APP_BUNDLE/Contents/Resources/TWhisperIcon.icns"

echo "Signing $APP_BUNDLE with '$CERT_NAME'..."
codesign --force --deep --sign "$CERT_NAME" "$APP_BUNDLE"

echo "Built $APP_BUNDLE (bundle id: $BUNDLE_ID)"
