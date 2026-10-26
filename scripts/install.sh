#!/usr/bin/env bash
# Builds Lineup in release mode, wraps it in an app bundle and installs it in
# ~/Applications. The bundle is what macOS needs to ask for calendar access and to keep the
# app out of the Dock. The bundle also carries lineup-notify, linked from ~/.local/bin, for
# scripts and for Claude's MCP server. Pass --open to launch it once installed.
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="Lineup"
DEST="${BACKLOGBAR_DEST:-$HOME/Applications}"
BIN_DIR="${BACKLOGBAR_BIN_DIR:-$HOME/.local/bin}"
VERSION="$(sed -n 's/^## \[\([0-9][0-9.]*\)\].*/\1/p' CHANGELOG.md | head -1)"
VERSION="${VERSION:-0.0.0}"

swift build -c release --product "$APP_NAME"
swift build -c release --product lineup-notify
BIN="$(swift build -c release --show-bin-path)/$APP_NAME"

BUNDLE="$(mktemp -d)/$APP_NAME.app"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$BIN" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp "$(dirname "$BIN")/lineup-notify" "$BUNDLE/Contents/MacOS/lineup-notify"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$BUNDLE/Contents/Info.plist"
# An ad hoc signature: enough for a locally built app to run and keep its calendar grant. The
# helper is signed first, as the bundle's signature seals it.
codesign --force --sign - "$BUNDLE/Contents/MacOS/lineup-notify"
codesign --force --sign - "$BUNDLE"

mkdir -p "$DEST"
# Quit a running copy so the new one replaces it.
pkill -x "$APP_NAME" 2>/dev/null || true
rm -rf "${DEST:?}/$APP_NAME.app"
cp -R "$BUNDLE" "$DEST/"
echo "Installed $DEST/$APP_NAME.app ($VERSION)"

mkdir -p "$BIN_DIR"
ln -sf "$DEST/$APP_NAME.app/Contents/MacOS/lineup-notify" "$BIN_DIR/lineup-notify"
echo "Linked $BIN_DIR/lineup-notify"

if [[ "${1:-}" == "--open" ]]; then
  open "$DEST/$APP_NAME.app"
fi
