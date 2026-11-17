#!/bin/bash
# Builds dist/Mulligan.app (menu-bar app + bundled `mulligan` CLI), ad-hoc signed, plus dist/mulligan and a zip.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${VERSION:-1.0.0}"
swift build -c release 2>&1 | grep -E "error|Compiling|Build complete" | tail -3
BIN=.build/release
APP=dist/Mulligan.app
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN/MulliganBar" "$APP/Contents/MacOS/MulliganBar"
cp "$BIN/mulligan" "$APP/Contents/Resources/bin/mulligan"
cp "$BIN/mulligan" dist/mulligan

ICONSET="$(mktemp -d)/Mulligan.iconset"
"$BIN/MulliganBar" --make-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>app.mulligan.mac</string>
  <key>CFBundleName</key><string>Mulligan</string>
  <key>CFBundleDisplayName</key><string>Mulligan</string>
  <key>CFBundleExecutable</key><string>MulliganBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDesktopFolderUsageDescription</key><string>Mulligan keeps instant copies of the files in the folders you choose, so you can undo deletions and overwrites.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Mulligan keeps instant copies of the files in the folders you choose, so you can undo deletions and overwrites.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Mulligan keeps instant copies of the files in the folders you choose, so you can undo deletions and overwrites.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>Mulligan can protect folders on external drives you choose.</string>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null
codesign --force --deep --sign - "$APP" 2>&1 | tail -1
codesign --verify --deep --strict "$APP" && echo "signature OK (ad-hoc)"
(cd dist && ditto -c -k --keepParent Mulligan.app Mulligan.zip && ditto -c -k --keepParent Mulligan.app "Mulligan-$VERSION.zip")
echo "built: $APP ($(du -sh "$APP" | cut -f1)), dist/mulligan, dist/Mulligan-$VERSION.zip"
