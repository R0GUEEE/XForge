#!/usr/bin/env bash
#
# build-ish-aok-core.sh — build iSH-AOK's Linux engine for iOS and stage the
# static libraries where XForge's linker finds them.
#
# XForge embeds iSH-AOK (Vendor/ish-AOK, a git submodule) as its in-process Linux
# runtime. This script produces, for the iOS device (arm64):
#
#   libish.a                  the emulator + kernel
#   libish_emu.a              per-arch instruction translation
#   libfakefs.a               the SQLite-backed filesystem
#   libxforge-fakefsimport.a  iSH-AOK's tools/fakefs.c (fakefs_import)
#   libarchive.a, liblzma.a   archive reading for the rootfs import
#
# into Vendor/ish-AOK-build/lib.
#
# Requires: macOS, Xcode command line tools, meson, ninja, python3.
#   brew install meson ninja
#
# Usage: EmbeddedLinux/build-ish-aok-core.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

ISH="${ISH_AOK_ROOT:-$REPO/Vendor/ish-AOK}"
OUT="${ISH_AOK_LIB_DIR:-$REPO/Vendor/ish-AOK-build/lib}"
BUILD="$REPO/Vendor/ish-AOK-build"

# arm64 only: the bundled rootfs is aarch64, and trimming the guest archs keeps
# the engine small and the build fast. Must match OTHER_CFLAGS in project.yml.
GUEST_ARCHS="${ISH_GUEST_ARCHS:-arm64}"
MIN_SDK="${IPHONEOS_DEPLOYMENT_TARGET:-16.0}"

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }

if [[ ! -f "$ISH/meson.build" ]]; then
    echo "error: iSH-AOK sources not found at $ISH" >&2
    echo "       run: git submodule update --init --depth 1 Vendor/ish-AOK" >&2
    exit 1
fi

for tool in meson ninja xcrun python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool not found in PATH" >&2; exit 1; }
done

# iSH-AOK's VDSO step compiles i386-linux with `-fuse-ld=lld`, which Apple's
# clang cannot do. It needs an LLVM clang with lld, so put Homebrew's LLVM first
# and make sure `ld.lld` is reachable (brew install llvm lld).
if command -v brew >/dev/null 2>&1; then
    LLVM_BIN="$(brew --prefix llvm 2>/dev/null)/bin"
    if [[ -d "$LLVM_BIN" ]]; then
        export PATH="$LLVM_BIN:$PATH"
        log "Using Homebrew LLVM: $LLVM_BIN"
    fi
    # Newer `llvm` bottles ship clang but not ld.lld; the `lld` formula does.
    LLD_BIN="$(brew --prefix lld 2>/dev/null)/bin"
    if [[ -d "$LLD_BIN" ]]; then
        export PATH="$LLD_BIN:$PATH"
    fi
fi
if ! clang -target i386-linux -fuse-ld=lld -shared -nostdlib -x c /dev/null -o /dev/null 2>/dev/null; then
    echo "warning: clang cannot build the VDSO (needs LLVM + lld). Install it with: brew install llvm" >&2
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
TRIPLE="arm64-apple-ios${MIN_SDK}"
MESON_BUILD="$BUILD/meson"

rm -rf "$MESON_BUILD"
mkdir -p "$MESON_BUILD" "$OUT"

# --- meson cross file for iOS ------------------------------------------------
CROSS="$MESON_BUILD/ios-arm64.txt"
cat > "$CROSS" <<EOF
[binaries]
c = 'clang'
objc = 'clang'
ar = 'ar'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[built-in options]
c_args = ['-target', '$TRIPLE', '-isysroot', '$SDK']
c_link_args = ['-target', '$TRIPLE', '-isysroot', '$SDK']
objc_args = ['-target', '$TRIPLE', '-isysroot', '$SDK']
objc_link_args = ['-target', '$TRIPLE', '-isysroot', '$SDK']

[properties]
needs_exe_wrapper = true
EOF

# --- iSH-AOK core ------------------------------------------------------------
# Native programs (bash/zsh/dash/helix/rust) are host code compiled into the
# app; XForge only needs a guest shell (Alpine's busybox), so they stay off.
log "Configuring iSH-AOK core (guest_archs=$GUEST_ARCHS)"
meson setup "$MESON_BUILD" "$ISH" \
    --cross-file "$CROSS" \
    --buildtype=release \
    -Ddefault_library=static \
    -Dguest_archs="$GUEST_ARCHS" \
    -Dnative_bash=disabled \
    -Dnative_zsh=disabled \
    -Dnative_dash=disabled \
    -Dnative_rust=disabled \
    -Dnative_helix=disabled

log "Building libish / libish_emu / libfakefs"
ninja -C "$MESON_BUILD" libish.a libish_emu.a libfakefs.a

for lib in libish.a libish_emu.a libfakefs.a; do
    cp "$MESON_BUILD/$lib" "$OUT/$lib"
done

# --- fakefs import helper (tools/fakefs.c) -----------------------------------
# Kept out of the app target's own compile so it uses iSH-AOK's include layout
# and the same guest-arch defines as the core.
log "Compiling tools/fakefs.c (fakefs_import)"
clang -c "$ISH/tools/fakefs.c" -o "$MESON_BUILD/xforge-fakefs.o" \
    -target "$TRIPLE" -isysroot "$SDK" -O2 \
    -I"$ISH" -I"$ISH/deps/libarchive/libarchive" \
    -DISH_GUEST_ARM64=1 -DISH_GUEST_I386=0 -DISH_GUEST_AMD64=0 -DISH_GUEST_RISCV64=0
ar rcs "$OUT/libxforge-fakefsimport.a" "$MESON_BUILD/xforge-fakefs.o"

# --- libarchive (rootfs archives) -------------------------------------------
log "Building libarchive for iOS"
ARCHIVE_PROJ="$ISH/deps/libarchive.xcodeproj"
if [[ -d "$ARCHIVE_PROJ" ]]; then
    TARGET="$(xcodebuild -list -json -project "$ARCHIVE_PROJ" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["project"]["targets"][0])')"
    xcodebuild -project "$ARCHIVE_PROJ" -target "$TARGET" \
        -configuration Release -sdk iphoneos ARCHS=arm64 \
        CONFIGURATION_BUILD_DIR="$MESON_BUILD/archive" \
        CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO build >/dev/null
    cp "$MESON_BUILD/archive/libarchive.a" "$OUT/libarchive.a"
else
    echo "error: $ARCHIVE_PROJ missing (init the deps/libarchive submodule)" >&2
    exit 1
fi

# --- liblzma (prebuilt xcframework in the iSH-AOK tree) ----------------------
LZMA="$ISH/deps/liblzma-static/liblzma.xcframework/ios-arm64/liblzma-ios-arm64.a"
if [[ -f "$LZMA" ]]; then
    cp "$LZMA" "$OUT/liblzma.a"
else
    echo "warning: liblzma xcframework slice not found at $LZMA" >&2
    echo "         libarchive's .xz support will fail to link." >&2
fi

log "Staged into $OUT"
ls -lh "$OUT"
