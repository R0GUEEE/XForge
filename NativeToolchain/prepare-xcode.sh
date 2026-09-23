#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="$ROOT/Vendor/NativeToolchain"
OUT="$ROOT/Support/NativeToolchain.generated.xcconfig"

mkdir -p "$(dirname "$OUT")"

if [ ! -f "$BUNDLE/manifest.txt" ] || [ ! -d "$BUNDLE/include" ] || [ ! -d "$BUNDLE/lib" ]; then
  cat >"$OUT" <<EOF
XFORGE_NATIVE_TOOLCHAIN_AVAILABLE = 0
XFORGE_NATIVE_HEADER_SEARCH_PATHS =
XFORGE_NATIVE_LIBRARY_SEARCH_PATHS =
XFORGE_NATIVE_CFLAGS =
XFORGE_NATIVE_LDFLAGS =
EOF
  echo "Native toolchain: disabled (Vendor/NativeToolchain not installed)"
  exit 0
fi

ARCHIVES=()
while IFS= read -r -d '' lib; do
  ARCHIVES+=("\$(SRCROOT)/\${lib#"$ROOT/"}")
done < <(find "$BUNDLE/lib" -maxdepth 1 -type f -name '*.a' -print0 | sort -z)

if [ "\${#ARCHIVES[@]}" -eq 0 ]; then
  echo "error: Native toolchain bundle has no static libraries in $BUNDLE/lib" >&2
  exit 1
fi

{
  echo "XFORGE_NATIVE_TOOLCHAIN_AVAILABLE = 1"
  echo "XFORGE_NATIVE_HEADER_SEARCH_PATHS = \$(SRCROOT)/Vendor/NativeToolchain/include"
  echo "XFORGE_NATIVE_LIBRARY_SEARCH_PATHS = \$(SRCROOT)/Vendor/NativeToolchain/lib"
  echo "XFORGE_NATIVE_CFLAGS = -DXFORGE_HAS_LLVM=1"
  printf "XFORGE_NATIVE_LDFLAGS ="
  for archive in "\${ARCHIVES[@]}"; do
    printf " %s" "$archive"
  done
  echo " -lc++ -lz -liconv -lsqlite3 -framework Foundation"
} >"$OUT"

echo "Native toolchain: enabled (\${#ARCHIVES[@]} archives)"
