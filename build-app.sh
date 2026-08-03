#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
APP_NAME="MacScriptRunner"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
ICON_FILE="$ROOT_DIR/Assets/AppIcon.icns"

cd "$ROOT_DIR"
mkdir -p "$ROOT_DIR/.cache/clang" "$ROOT_DIR/.cache/swiftpm"
CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.cache/clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.cache/clang" \
swift build -c release --disable-sandbox --cache-path "$ROOT_DIR/.cache/swiftpm"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"

if [[ -f "$ICON_FILE" ]]; then
  mkdir -p "$APP_DIR/Contents/Resources"
  cp "$ICON_FILE" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>MacScriptRunner</string>
  <key>CFBundleIdentifier</key><string>local.codex.MacScriptRunner</string>
  <key>CFBundleName</key><string>MacScriptRunner</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

codesign --force --deep --sign - "$APP_DIR"
echo "$APP_DIR"
