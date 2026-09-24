#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 XForgeNativeToolchain-arm64-ios.tar.gz" >&2
  exit 64
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVE="$1"
DEST="$ROOT/Vendor/NativeToolchain"

[ -f "$ARCHIVE" ] || { echo "error: archive not found: $ARCHIVE" >&2; exit 66; }

rm -rf "$DEST"
mkdir -p "$DEST"
tar -xzf "$ARCHIVE" -C "$DEST"

for required in manifest.txt include include-generated lib; do
  [ -e "$DEST/$required" ] || {
    echo "error: native toolchain bundle is missing $required" >&2
    rm -rf "$DEST"
    exit 65
  }
done

bash "$ROOT/NativeToolchain/prepare-xcode.sh"
echo "Installed native toolchain:"
cat "$DEST/manifest.txt"
