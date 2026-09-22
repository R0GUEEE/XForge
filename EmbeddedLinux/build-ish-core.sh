#!/usr/bin/env bash
#
# build-ish-core.sh — build the embedded Linux engine (OpenMinis/ish-arm64) for
# iOS and stage the static libraries where XForge's linker finds them.
#
# XForge embeds **ish-arm64** (Vendor/ish-arm64, a git submodule) as its
# in-process Linux runtime. It is a fork of ish-app/ish that adds a native
# AArch64 guest backend to the threaded-code interpreter, so the Alpine aarch64
# rootfs runs as a same-architecture guest instead of being cross-translated.
#
# This script produces, for the iOS device (arm64):
#
#   libish.a      the emulator + kernel
#   libish_emu.a  per-arch instruction translation
#   libfakefs.a   the SQLite-backed filesystem
#
# into Vendor/ish-arm64-build/lib, plus libfakefsify.a — tools/fakefs.c, whose
# fakefs_import() unpacks an archive into a fakefs root on first launch.
#
# Requires: macOS, Xcode command line tools, meson, ninja, python3, libarchive.
#   brew install meson ninja llvm lld libarchive
#
# Usage: EmbeddedLinux/build-ish-core.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

ISH="${ISH_ROOT:-$REPO/Vendor/ish-arm64}"
BUILD="${ISH_BUILD_DIR:-$REPO/Vendor/ish-arm64-build}"
OUT="${ISH_LIB_DIR:-$BUILD/lib}"

# The guest is aarch64 (the bundled Alpine rootfs), so only that backend is
# built. Must match the -DGUEST_ARM64=1 in project.yml: the guest-arch defines
# select struct layouts, so engine and app have to agree.
GUEST_ARCH="${ISH_GUEST_ARCH:-arm64}"
MIN_SDK="${IPHONEOS_DEPLOYMENT_TARGET:-16.0}"

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -f "$ISH/meson.build" ] || die "ish-arm64 sources not found at $ISH
       run: git submodule update --init --depth 1 Vendor/ish-arm64"

# ish-arm64's own submodules: libarchive builds the archive reader, libapps is
# only used by the native (host) shell programs, which XForge does not embed.
for sub in deps/libarchive; do
    [ -d "$ISH/$sub" ] && [ -n "$(ls -A "$ISH/$sub" 2>/dev/null)" ] || die \
        "ish-arm64's $sub submodule is missing
       run: git -C Vendor/ish-arm64 submodule update --init --depth 1 $sub"
done

for tool in meson ninja xcrun python3; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found in PATH"
done

# ---------------------------------------------------------------------------
# Already built?
#
# The libraries are a function of the engine's sources and of the flags this
# script passes, so the engine revision (the submodule commit) plus a hash of this
# script and of project.yml — which carries -DGUEST_ARM64=1, and has to agree with
# the engine or struct layouts differ — is enough to decide. That matters because
# this script is run from two places now: the IPA workflow, and the app target's
# first build phase (EmbeddedLinux/build-engine-for-xcode.sh), which runs on every
# Xcode build. A cold engine build takes minutes; the stamp makes the common case
# a couple of file reads.
#
# XFORGE_REBUILD_ENGINE=1 forces the build. So does deleting the lib directory.
# ---------------------------------------------------------------------------
stamp_value() {
    local revision script_hash project_hash
    revision="$(git -C "$ISH" rev-parse HEAD 2>/dev/null \
        || git -C "$REPO" rev-parse HEAD:Vendor/ish-arm64 2>/dev/null \
        || echo unknown)"
    script_hash="$(shasum -a 256 "$HERE/build-ish-core.sh" | cut -d' ' -f1)"
    project_hash="$(shasum -a 256 "$REPO/project.yml" 2>/dev/null | cut -d' ' -f1)"
    printf '%s %s %s %s %s' "$revision" "$script_hash" "${project_hash:-none}" "$GUEST_ARCH" "$MIN_SDK"
}

STAMP="$OUT/.engine-stamp"
WANT_STAMP="$(stamp_value)"
if [ "${XFORGE_REBUILD_ENGINE:-0}" != "1" ] && [ -f "$STAMP" ] \
   && [ "$(cat "$STAMP")" = "$WANT_STAMP" ]; then
    complete=1
    for lib in libish.a libish_emu.a libfakefs.a libfakefsify.a libarchive.a; do
        [ -f "$OUT/$lib" ] || complete=""
    done
    if [ -n "$complete" ]; then
        log "The engine is already built ($OUT) — nothing to do"
        note "engine revision: $(printf '%s' "$WANT_STAMP" | cut -d' ' -f1)"
        note "force a rebuild with XFORGE_REBUILD_ENGINE=1"
        exit 0
    fi
    note "the stamp matches but libraries are missing — rebuilding"
fi

# The VDSO step compiles a 32-bit i386-linux object with `-fuse-ld=lld`, which
# Apple's clang cannot do; it needs an LLVM clang with lld. Put Homebrew's LLVM
# first and make sure ld.lld is reachable (newer `llvm` bottles ship clang but
# not ld.lld — the separate `lld` formula provides it).
if command -v brew >/dev/null 2>&1; then
    LLVM_BIN="$(brew --prefix llvm 2>/dev/null)/bin"
    [ -d "$LLVM_BIN" ] && { export PATH="$LLVM_BIN:$PATH"; log "Using Homebrew LLVM: $LLVM_BIN"; }
    LLD_BIN="$(brew --prefix lld 2>/dev/null)/bin"
    [ -d "$LLD_BIN" ] && export PATH="$LLD_BIN:$PATH"
fi
if ! clang -target i386-linux -fuse-ld=lld -shared -nostdlib -x c /dev/null -o /dev/null 2>/dev/null; then
    printf 'warning: clang cannot build the VDSO (needs LLVM + lld). Install: brew install llvm lld\n' >&2
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
ar = 'ar'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[built-in options]
c_args = ['-target', '$TRIPLE', '-isysroot', '$SDK']
c_link_args = ['-target', '$TRIPLE', '-isysroot', '$SDK']

[properties]
needs_exe_wrapper = true
EOF

# --- engine core -------------------------------------------------------------
# -Dkernel=ish is ish-arm64's own kernel (not the Linux-kernel build), and
# -Dengine=asbestos is its threaded-code interpreter — no JIT, no executable
# memory, so it runs in a sideloaded app with no special entitlement.
# -Dlog_handler=nslog routes the engine's printk through NSLog, which is what
# the engine's own app does and what makes a crash explain itself in the device
# console; the dprintf handler writes to a descriptor nothing opens.
# -Dlog='' keeps the DEBUG_* log channels off (meson takes a space-separated
# list; empty means none), matching the reference build.
#
# -Db_ndebug=true is NOT optional. meson's `release` buildtype only implies -O3;
# it does not define NDEBUG — that is this separate option. Without it every
# assert() in the kernel stays live in a shipping build, so a failed assertion
# calls abort() *on the user's device* instead of being a development check.
# The engine's own build documents that this exact mistake shipped to TestFlight
# as a SIGABRT in sys_execve/args_copy (the mem_ptr() copy-on-write assert).
log "Configuring ish-arm64 (guest_arch=$GUEST_ARCH, kernel=ish, engine=asbestos)"
meson setup "$MESON_BUILD" "$ISH" \
    --cross-file "$CROSS" \
    --buildtype=release \
    -Db_ndebug=true \
    -Ddefault_library=static \
    -Dguest_arch="$GUEST_ARCH" \
    -Dkernel=ish \
    -Dengine=asbestos \
    -Dlog_handler=nslog \
    -Dlog=''

# The aarch64 gadget sources alias registers with `.req` (`_cpu .req x1`,
# `_pc .req x28`, …) and then use those names as operands. Only clang's
# integrated assembler supports that; GNU as rejects every such instruction
# ("expected a register or register list at operand 1"). This build therefore
# requires clang — which the iOS cross-file selects — and cannot be reproduced
# with a GNU binutils toolchain. Say so here rather than letting the failure
# surface as a wall of assembler errors.
if ! printf '_r .req x5\n.text\n_f: add _r, x0, #8\n' > "$MESON_BUILD/req-probe.S" 2>/dev/null; then
    die "could not write the assembler capability probe"
fi
if ! clang -c "$MESON_BUILD/req-probe.S" -o "$MESON_BUILD/req-probe.o" 2>/dev/null; then
    rm -f "$MESON_BUILD/req-probe.S" "$MESON_BUILD/req-probe.o"
    die "this clang cannot assemble the engine's aarch64 gadgets (no .req register
       alias support). Build the engine on macOS with Xcode's clang — the IPA
       workflow does exactly that — rather than with a GNU binutils toolchain."
fi
rm -f "$MESON_BUILD/req-probe.S" "$MESON_BUILD/req-probe.o"

log "Building libish / libish_emu / libfakefs"
ninja -C "$MESON_BUILD" libish.a libish_emu.a libfakefs.a

# The VDSO is not a separate artifact to ship: kernel/vdso.c `.incbin`s
# libvdso.so.elf straight into libish.a, so building libish already built it.
# But the build degrades silently — if meson cannot find an aarch64-linux
# cross-compiler it substitutes a target that just `touch`es an empty file, and
# the guest then gets a bogus VDSO with nothing in the log to say so. Verify the
# file is a real aarch64 ELF shared object rather than trusting the build.
VDSO="$MESON_BUILD/vdso/arm64/libvdso.so.elf"
if [ ! -s "$VDSO" ]; then
    die "the arm64 VDSO was not built: $VDSO is missing or empty.
       meson falls back to an EMPTY placeholder when it cannot find an
       aarch64-linux cross-compiler, so this is a silent failure otherwise.
       Install one (brew install llvm lld) — clang must support
       '-target aarch64-linux-gnu -fuse-ld=lld'."
fi
if command -v file >/dev/null 2>&1; then
    file "$VDSO" | grep -q 'ELF 64-bit.*aarch64' || die \
        "$VDSO is not an aarch64 ELF (got: $(file -b "$VDSO"))"
fi
note "VDSO: $(du -h "$VDSO" | cut -f1) (embedded into libish.a)"

for lib in libish.a libish_emu.a libfakefs.a; do
    [ -f "$MESON_BUILD/$lib" ] || die "$lib was not produced"
    cp "$MESON_BUILD/$lib" "$OUT/$lib"
done

# --- libfakefsify (fakefs_import) -------------------------------------------
# tools/fakefs.c is a standalone program upstream. XForge links fakefs_import()
# into the app to unpack the bundled rootfs on first launch, so it is compiled
# here as a plain object rather than built as the `fakefsify` executable (which
# could not run on iOS anyway). The progress callback it takes is exactly what
# XForge's import screen reports from.
log "Compiling tools/fakefs.c (fakefs_import)"
clang -c "$ISH/tools/fakefs.c" -o "$MESON_BUILD/xforge-fakefs.o" \
    -target "$TRIPLE" -isysroot "$SDK" -O2 \
    -I"$ISH" -I"$ISH/deps/libarchive/libarchive" \
    -DGUEST_ARM64=1
ar rcs "$OUT/libfakefsify.a" "$MESON_BUILD/xforge-fakefs.o"

# --- libarchive (unpacking the rootfs archive) -------------------------------
# Built from ish-arm64's own vendored copy so the app and the engine agree on a
# single libarchive. The iOS SDK ships none.
log "Building libarchive for iOS"
ARCHIVE_PROJ="$ISH/deps/libarchive.xcodeproj"
if [ -d "$ARCHIVE_PROJ" ]; then
    # One native target. Avoid `xcodebuild -list`, whose target discovery
    # initialises Simulator services and can fail on a headless build host even
    # though the device build is valid.
    xcodebuild -project "$ARCHIVE_PROJ" -target libarchive \
        -configuration Release -sdk iphoneos ARCHS=arm64 \
        CONFIGURATION_BUILD_DIR="$MESON_BUILD/archive" \
        CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO build >/dev/null
    cp "$MESON_BUILD/archive/libarchive.a" "$OUT/libarchive.a"
else
    die "$ARCHIVE_PROJ missing (init the deps/libarchive submodule)"
fi

log "Staged into $OUT"
ls -lh "$OUT"

# Record what was built, so the next run (Xcode's build phase runs this on every
# build) can tell in a moment that there is nothing to do.
printf '%s\n' "$WANT_STAMP" > "$STAMP"
