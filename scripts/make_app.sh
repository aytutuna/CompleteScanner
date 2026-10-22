#!/bin/bash
# Builds CompleteScanner in release mode and packages dist/CompleteScanner.app
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Building (release)…"
swift build -c release

APP=dist/CompleteScanner.app
BIN=".build/release/CompleteScanner"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/CompleteScanner"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>CompleteScanner</string>
    <key>CFBundleDisplayName</key>       <string>CompleteScanner</string>
    <key>CFBundleIdentifier</key>        <string>local.completescanner.app</string>
    <key>CFBundleExecutable</key>        <string>CompleteScanner</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
    <key>NSApplicationSupportsSecureRestorableState</key> <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>CompleteScanner receives documents from your paired phone on your local network.</string>
    <key>NSBonjourServices</key>
    <array><string>_completescan._tcp</string></array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>      <string>CompleteScanner document</string>
            <key>CFBundleTypeRole</key>      <string>Viewer</string>
            <key>LSHandlerRank</key>         <string>Owner</string>
            <key>LSItemContentTypes</key>    <array><string>com.completescanner.package</string></array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>      <string>com.completescanner.package</string>
            <key>UTTypeDescription</key>     <string>CompleteScanner document</string>
            <key>UTTypeConformsTo</key>      <array><string>public.data</string><string>public.content</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key> <array><string>csdoc</string></array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

# App icon (optional — skipped if generation fails)
if [ ! -f dist/icon_1024.png ]; then
  mkdir -p dist
  swift scripts/MakeIcon.swift dist/icon_1024.png || true
fi
if [ -f dist/icon_1024.png ]; then
  echo "==> Building icon…"
  ICONSET=dist/AppIcon.iconset
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s dist/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s*2))
    sips -z $d $d dist/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" && rm -rf "$ICONSET"
fi

echo "==> Signing (ad-hoc)…"
codesign --force --deep -s - "$APP"

echo "==> Done: $APP"
echo "    Launch with:  open $APP"
