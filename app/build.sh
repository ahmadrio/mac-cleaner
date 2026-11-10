#!/bin/bash
# Build "Mac Cleaner.app" and a distributable zip into <repo>/build/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SRC="$ROOT/app"
OUT="$ROOT/build"
APP="$OUT/Mac Cleaner.app"

VERSION="$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$ROOT/mac-cleaner.command" | head -1)"
[ -n "$VERSION" ] || { echo "build.sh: cannot read VERSION from mac-cleaner.command" >&2; exit 1; }
case "$VERSION" in   # it goes into Info.plist through sed, and into the zip name: digits and dots only
  *[!0-9.]*|.*|*.|*..*) echo "build.sh: VERSION must look like 2.0.1, got '$VERSION'" >&2; exit 1 ;;
esac

swift build -c release --arch arm64 --package-path "$APP_SRC"
BIN_DIR="$(swift build -c release --arch arm64 --package-path "$APP_SRC" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MacCleaner" "$APP/Contents/MacOS/MacCleaner"

cp "$ROOT/mac-cleaner.command" "$APP/Contents/Resources/mac-cleaner.command"
if [ -f "$APP_SRC/Resources/askpass.sh" ]; then
  cp "$APP_SRC/Resources/askpass.sh" "$APP/Contents/Resources/askpass.sh"
  chmod +x "$APP/Contents/Resources/askpass.sh"
fi
if [ -f "$APP_SRC/Resources/AppIcon.icns" ]; then
  cp "$APP_SRC/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
if [ -d "$APP_SRC/Resources/demo" ]; then
  cp -R "$APP_SRC/Resources/demo" "$APP/Contents/Resources/demo"
fi

sed "s/__VERSION__/$VERSION/g" "$APP_SRC/Resources/Info.plist" > "$APP/Contents/Info.plist"

codesign --force --deep -s - "$APP"

ZIP="$OUT/Mac-Cleaner-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "App: $APP"
echo "Zip: $ZIP"
