#!/bin/bash
# Builds a signed, notarized SubieScope DMG and (with PUBLISH=1) a GitHub release.
#
#   scripts/release.sh               build + notarize build/SubieScope.dmg
#   PUBLISH=1 scripts/release.sh     also create the GitHub release v$(cat VERSION)
#
# The Windows version is built on a PC (scripts/dev/windows-pc.sh sync, package, fetch). When its zip is
# in build/ it goes into the release too, as SubieScope-windows-x64.zip: a name without the version, so
# the website's link to the latest one keeps working.
#
# Needs a "Developer ID Application" certificate in the keychain and a notarytool
# keychain profile (xcrun notarytool store-credentials).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Marvin Visser (X385H5BWN7)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-claude-resumer-notary}"
PUBLISH="${PUBLISH:-0}"
DMG="build/SubieScope.dmg"
NOTES="docs/release-notes/${VERSION}.md"
WINDOWS_ZIP="build/SubieScope-${VERSION}-windows-x64.zip"

if ! security find-identity -v -p codesigning | grep -qF "$SIGN_IDENTITY"; then
  echo "Signing identity not found: $SIGN_IDENTITY" >&2
  exit 1
fi

if [ "$PUBLISH" = "1" ]; then
  if [ ! -f "$NOTES" ]; then
    echo "Missing release notes: $NOTES" >&2
    exit 1
  fi
  # GitHub makes the release's tag on the main branch, so what is built here has to be what is there.
  git fetch -q origin main
  if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
    echo "This commit is not the newest one on origin/main: push it first." >&2
    exit 1
  fi
fi

swift test
SIGN_IDENTITY="$SIGN_IDENTITY" STRIP_DEFINITIONS=1 scripts/build-app.sh

# The definitions must not ship inside the app.
if ls build/SubieScope.app/Contents/Resources/SubieScope_SSMKit.bundle/Definitions/*.xml >/dev/null 2>&1; then
  echo "RomRaider definitions found inside the app bundle; refusing to release." >&2
  exit 1
fi

STAGING="build/dmg"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
ditto build/SubieScope.app "$STAGING/SubieScope.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "SubieScope" -srcfolder "$STAGING" -ov -format UDZO -imagekey zlib-level=9 "$DMG" >/dev/null
rm -rf "$STAGING"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
echo "Notarized $DMG"

if [ "$PUBLISH" = "1" ]; then
  FILES=("$DMG")
  if [ -f "$WINDOWS_ZIP" ]; then
    cp "$WINDOWS_ZIP" build/SubieScope-windows-x64.zip
    FILES+=(build/SubieScope-windows-x64.zip)
  else
    echo "No $WINDOWS_ZIP: this release goes out without the Windows version." >&2
  fi
  gh release create "v${VERSION}" "${FILES[@]}" --title "SubieScope ${VERSION}" --notes-file "$NOTES"
fi
