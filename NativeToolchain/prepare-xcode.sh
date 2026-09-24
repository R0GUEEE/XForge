#!/usr/bin/env bash
set -euo pipefail

# Turns Vendor/NativeToolchain — the bundle the `Native iOS Toolchain` workflow
# uploads — into the xcconfig the app target is built with. Nothing here runs on
# iOS: this is a build-time step, and what it really decides is whether the C
# bridge compiles the compiler in or the "not available" stub.
#
# A missing bundle is not an error. A clone without one still builds, and the
# Toolchain screen says the compiler is not linked; that is a better default than
# refusing to build.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="$ROOT/Vendor/NativeToolchain"
OUT="$ROOT/Support/NativeToolchain.generated.xcconfig"
MANIFEST="$BUNDLE/manifest.txt"

mkdir -p "$(dirname "$OUT")"

if [ ! -f "$MANIFEST" ] || [ ! -d "$BUNDLE/include" ] || [ ! -d "$BUNDLE/lib" ]; then
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
# A temp file rather than `< <(find …)`: process substitution needs /dev/fd, which
# is not universally available. One path per line, read with -r so a space in a
# checkout path survives.
ARCHIVE_LIST="$(mktemp)"
trap 'rm -f "$ARCHIVE_LIST"' EXIT
find "$BUNDLE/lib" -maxdepth 1 -type f -name '*.a' >"$ARCHIVE_LIST"
while IFS= read -r lib; do
  [ -n "$lib" ] || continue
  ARCHIVES+=("\$(SRCROOT)/\${lib#"$ROOT/"}")
done <"$ARCHIVE_LIST"

if [ "${#ARCHIVES[@]}" -eq 0 ]; then
  echo "error: Native toolchain bundle has no static libraries in $BUNDLE/lib" >&2
  exit 1
fi

# The bundle declares what it contains, and the bridge needs the matching defines:
# XFORGE_HAS_LLVM gates the Clang/LLD entry points, XFORGE_HAS_SWIFT_FRONTEND the
# one that calls swift::performFrontend. Without the second, a bundle that carries
# the Swift libraries still reports "swift-frontend: missing".
CFLAGS="-DXFORGE_HAS_LLVM=1"
if grep -q '^swift_frontend=1' "$MANIFEST" 2>/dev/null; then
  CFLAGS="$CFLAGS -DXFORGE_HAS_SWIFT_FRONTEND=1"
  SWIFT_REF="$(sed -n 's/^swift_ref=//p' "$MANIFEST" 2>/dev/null)"
  echo "Native toolchain: Swift frontend included (${SWIFT_REF:-unknown revision})"
else
  echo "Native toolchain: Clang and LLD only (no Swift frontend in this bundle)"
fi

{
  echo "XFORGE_NATIVE_TOOLCHAIN_AVAILABLE = 1"
  echo "XFORGE_NATIVE_HEADER_SEARCH_PATHS = \$(SRCROOT)/Vendor/NativeToolchain/include"
  echo "XFORGE_NATIVE_LIBRARY_SEARCH_PATHS = \$(SRCROOT)/Vendor/NativeToolchain/lib"
  echo "XFORGE_NATIVE_CFLAGS = $CFLAGS"
  printf "XFORGE_NATIVE_LDFLAGS ="
  for archive in "${ARCHIVES[@]}"; do
    printf " %s" "$archive"
  done
  echo " -lc++ -lz -liconv -lsqlite3 -framework Foundation"
} >"$OUT"

echo "Native toolchain: enabled (${#ARCHIVES[@]} archives)"
