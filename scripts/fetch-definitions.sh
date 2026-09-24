#!/bin/bash
# Downloads RomRaider's logger definitions (v370) into the SSMKit resources.
# The file has no explicit license, so it is fetched at build time instead of
# being committed.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="Sources/SSMKit/Resources/Definitions/logger_METRIC_EN_v370.xml"
[ -f "$DEST" ] && { echo "Definitions present: $DEST"; exit 0; }
mkdir -p "$(dirname "$DEST")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Pinned mirror of the official v370 file (LF line endings).
MIRROR="https://raw.githubusercontent.com/zhuker/dash22b/3a9f6fa45a2a2885733fca185ae2c2490338dac0/app/src/main/assets/logger_METRIC_EN_v370.xml"
SHA_LF="1fb44a6438bf64979ea44e4302306d598da3bd33009da13cf383d7acaa5a964c"

if curl -fsSL "$MIRROR" -o "$TMP/defs.xml" \
   && [ "$(tr -d '\r' < "$TMP/defs.xml" | shasum -a 256 | cut -d' ' -f1)" = "$SHA_LF" ]; then
  mv "$TMP/defs.xml" "$DEST"
  echo "Downloaded definitions from the pinned mirror."
  exit 0
fi

echo "Mirror unavailable or changed; trying romraider.com…"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"
curl -fsSL -A "$UA" -c "$TMP/cj" -b "$TMP/cj" https://www.romraider.com/forum/ -o /dev/null
curl -fsSL -A "$UA" -c "$TMP/cj" -b "$TMP/cj" "https://www.romraider.com/forum/download/file.php?id=38909" -o "$TMP/defs.zip"
unzip -o -q "$TMP/defs.zip" -d "$TMP/zip"
cp "$(find "$TMP/zip" -name 'logger_METRIC_EN_v370.xml' | head -1)" "$DEST"
echo "Downloaded definitions from romraider.com."
