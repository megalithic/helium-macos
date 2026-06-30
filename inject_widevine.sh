#!/usr/bin/env bash
# inject_widevine.sh — Download Firefox Widevine CDM and install into Helium.app
#
# Ported from pkgs/helium-browser.nix postUnpack logic.
# Must run AFTER ninja produces Helium.app and BEFORE sign_and_package_app.sh.
#
# Usage:
#   ./inject_widevine.sh [path/to/Helium.app]
#   Default: out/Default/Helium.app

set -euo pipefail

APP="${1:-out/Default/Helium.app}"

if [ ! -d "$APP" ]; then
  echo "ERROR: Helium.app not found at $APP" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WIDEVINE_DIR="$SCRIPT_DIR/build/widevine_cache"
mkdir -p "$WIDEVINE_DIR"

echo "=== inject_widevine: fetching Widevine metadata ==="
WIDEVINE_JSON_URL="https://raw.githubusercontent.com/mozilla-firefox/firefox/main/toolkit/content/gmp-sources/widevinecdm.json"

if ! curl --fail -sL "$WIDEVINE_JSON_URL" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
v = d["vendors"]["gmp-widevinecdm"]["platforms"]["Darwin_aarch64-gcc3"]
print(v["fileUrl"], v["hashValue"], d["vendors"]["gmp-widevinecdm"]["version"], sep="|")
' > "$WIDEVINE_DIR/info"; then
  echo "ERROR: failed to fetch or parse widevinecdm.json" >&2
  exit 1
fi

IFS='|' read -r URL HASH VERSION < "$WIDEVINE_DIR/info"
echo "  Widevine version: $VERSION"
echo "  URL: $URL"

CRX="$WIDEVINE_DIR/WidevineCdm.crx"

# Only re-download if hash changed (or file missing)
NEED_DOWNLOAD=true
if [ -f "$WIDEVINE_DIR/last_hash" ]; then
  LAST_HASH=$(cat "$WIDEVINE_DIR/last_hash")
  if [ "$LAST_HASH" = "$HASH" ] && [ -f "$CRX" ]; then
    NEED_DOWNLOAD=false
    echo "  CRX already cached with matching hash, skipping download"
  fi
fi

if $NEED_DOWNLOAD; then
  echo "=== inject_widevine: downloading Widevine CRX ==="
  if ! curl --fail -sL -o "$CRX" "$URL"; then
    echo "ERROR: failed to download Widevine CRX from $URL" >&2
    exit 1
  fi
fi

echo "=== inject_widevine: verifying SHA-512 ==="
ACTUAL=$(sha512sum "$CRX" | awk '{print $1}')
if [ "$ACTUAL" != "$HASH" ]; then
  echo "ERROR: Widevine hash mismatch" >&2
  echo "  expected: $HASH" >&2
  echo "  actual:   $ACTUAL" >&2
  exit 1
fi
echo "  hash OK"
echo "$HASH" > "$WIDEVINE_DIR/last_hash"

echo "=== inject_widevine: extracting CRX3 payload ==="
OFFSET=$(python3 -c "
import struct
with open('$CRX', 'rb') as f:
    f.seek(8)
    print(12 + struct.unpack('<I', f.read(4))[0])")

EXTRACT_DIR="$WIDEVINE_DIR/extracted"
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"

dd if="$CRX" bs=1 skip="$OFFSET" of="$WIDEVINE_DIR/WidevineCdm.zip" 2>/dev/null
if ! unzip -o "$WIDEVINE_DIR/WidevineCdm.zip" -d "$EXTRACT_DIR" > /dev/null; then
  echo "ERROR: failed to extract Widevine CRX ZIP payload" >&2
  exit 1
fi

echo "=== inject_widevine: installing CDM into app bundle ==="
FW="$APP/Contents/Frameworks/Helium Framework.framework/Versions"
if [ ! -d "$FW" ]; then
  echo "ERROR: Framework versions directory not found at $FW" >&2
  exit 1
fi

VER=""
for d in "$FW"/*/; do
  dirname=$(basename "$d")
  if [[ "$dirname" =~ ^[0-9]+\. ]]; then
    VER="$dirname"
    break
  fi
done
if [ -z "$VER" ]; then
  echo "ERROR: no version directory found in $FW" >&2
  exit 1
fi

DEST="$FW/$VER/Libraries/WidevineCdm"
mkdir -p "$DEST"
cp -R "$EXTRACT_DIR"/* "$DEST/"

echo "  Installed to: $DEST"

# Verify the dylib is there
DYLIB=$(find "$DEST" -name 'libwidevinecdm.dylib' -type f 2>/dev/null | head -1)
if [ -z "$DYLIB" ]; then
  echo "ERROR: libwidevinecdm.dylib not found after extraction" >&2
  exit 1
fi
echo "  CDM dylib: $DYLIB"

# Clear quarantine xattrs (does not affect embedded LC_CODE_SIGNATURE)
echo "=== inject_widevine: clearing quarantine xattrs ==="
xattr -cr "$APP" 2>/dev/null || true

echo "=== inject_widevine: done ==="
