#!/bin/bash
# Builds SubieScope.app (with subiescope-cli inside) into ./build.
#
#   scripts/build-app.sh                         development build, ad-hoc signed
#   SIGN_IDENTITY="Developer ID Application: …" STRIP_DEFINITIONS=1 scripts/build-app.sh
#                                                release build (see scripts/release.sh)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
STRIP_DEFINITIONS="${STRIP_DEFINITIONS:-0}"
APP="build/SubieScope.app"
VERSION="$(cat VERSION 2>/dev/null || echo 0.1.0)"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"

# Development builds may bundle the definitions; release builds download them on first launch.
if [ "$STRIP_DEFINITIONS" != "1" ]; then
  scripts/fetch-definitions.sh || echo "warning: no definitions bundled; the app downloads them on first launch"
fi
# Universal binary: Apple Silicon and Intel Macs. ARCHS=arm64 builds a faster, native-only dev build.
ARCHS="${ARCHS:-arm64 x86_64}"
[ -n "${ARCHS// /}" ] || { echo "ARCHS must not be empty" >&2; exit 1; }
ARCH_FLAGS=()
for a in $ARCHS; do ARCH_FLAGS+=(--arch "$a"); done
swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --product SubieScope
swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --product subiescope-cli
BIN="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SubieScope" "$APP/Contents/MacOS/SubieScope"
cp "$BIN/subiescope-cli" "$APP/Contents/MacOS/subiescope-cli"
cp -R "$BIN/SubieScope_SSMKit.bundle" "$APP/Contents/Resources/"
if [ "$STRIP_DEFINITIONS" = "1" ]; then
  rm -f "$APP/Contents/Resources/SubieScope_SSMKit.bundle/Definitions/"*.xml
fi
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SubieScope</string>
  <key>CFBundleDisplayName</key><string>SubieScope</string>
  <key>CFBundleIdentifier</key><string>nl.marvinvisser.subiescope</string>
  <key>CFBundleExecutable</key><string>SubieScope</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>GPL-3.0. Not affiliated with Subaru Corporation.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Data log</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.comma-separated-values-text</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Standalone CLI next to the app for development use.
cp "$BIN/subiescope-cli" build/subiescope-cli
rm -rf build/SubieScope_SSMKit.bundle && cp -R "$BIN/SubieScope_SSMKit.bundle" build/

if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP/Contents/MacOS/subiescope-cli" >/dev/null
  codesign --force --sign - "$APP" >/dev/null
  codesign --force --sign - build/subiescope-cli >/dev/null
else
  # Hardened runtime and secure timestamps are required for notarization. Inner code first.
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/subiescope-cli"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
fi
echo "Built $APP ($VERSION, build $BUILD_NUMBER) and build/subiescope-cli"
