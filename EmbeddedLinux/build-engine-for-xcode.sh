#!/bin/bash
#
# build-engine-for-xcode.sh — the XForge target's first build phase.
#
# The app cannot compile without the embedded Linux engine: ISHBridge.c includes
# the engine's headers, and a device build links libish.a / libish_emu.a /
# libfakefs.a out of Vendor/ish-arm64-build/lib. Both come from
# EmbeddedLinux/build-ish-core.sh, and until now *only* the IPA workflow ran it —
# so any other way of building the project (Xcode itself, another CI pipeline)
# failed part-way through compiling the bridge with
#
#     App/EmbeddedVM/ISHBridge.c:123:10: error: 'kernel/init.h' file not found
#
# which says nothing about the engine being missing. This phase closes that gap:
# it fetches the engine, builds it once per engine revision, and skips itself for
# builds that do not link the engine at all.
#
# Builds that link the engine:      iphoneos (`-lish` in OTHER_LDFLAGS[sdk=iphoneos*])
# Builds that do not:               the simulator, which compiles the stub branch
#                                   in ISHBridge.c (the unit tests use it)
#
# Environment:
#     XFORGE_REBUILD_ENGINE=1   force a rebuild even if the engine is up to date
#     XFORGE_SKIP_ENGINE=1      skip the engine entirely (a fast check that the
#                               rest of the app compiles for the simulator)
#
set -euo pipefail

if [ "${XFORGE_SKIP_ENGINE:-0}" = "1" ]; then
    echo "note: XFORGE_SKIP_ENGINE=1 — not building the embedded Linux engine"
    exit 0
fi

# The engine is device-only. A simulator build compiles the stub branch instead,
# so there is nothing to fetch or build, and doing it anyway would make every unit
# test build spend minutes on an engine it will not link.
if [ "${PLATFORM_NAME:-}" != "iphoneos" ]; then
    echo "note: ${PLATFORM_NAME:-unknown} build — the engine is not linked, nothing to do"
    exit 0
fi

cd "${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# Xcode hands a script phase a bare PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), which
# contains neither Homebrew nor anything Homebrew installs — so `command -v meson`
# and even `command -v brew` would come back empty on a machine that has both. Put
# the usual prefixes on PATH first.
for prefix in /opt/homebrew/bin /usr/local/bin /opt/local/bin; do
    if [ -d "$prefix" ]; then
        case ":$PATH:" in
            *":$prefix:"*) ;;
            *) PATH="$prefix:$PATH" ;;
        esac
    fi
done
export PATH

# ---------------------------------------------------------------------------
# The engine's sources
#
# A fresh clone has the submodule empty (`git submodule update --init` is a
# separate step in every CI pipeline, and easy to forget in a new one). Fetching
# it here is cheap — one shallow clone — and turns "error: 'kernel/init.h' file
# not found" into a build that just works.
# ---------------------------------------------------------------------------
if [ ! -f Vendor/ish-arm64/meson.build ]; then
    echo "note: Vendor/ish-arm64 is empty — fetching the engine submodule"
    git submodule update --init --depth 1 Vendor/ish-arm64
    git -C Vendor/ish-arm64 submodule update --init --depth 1 deps/libarchive
fi
if [ ! -d Vendor/ish-arm64/deps/libarchive ] || [ -z "$(ls -A Vendor/ish-arm64/deps/libarchive 2>/dev/null)" ]; then
    echo "note: fetching the engine's libarchive submodule (fakefsify and the archive reader need it)"
    git -C Vendor/ish-arm64 submodule update --init --depth 1 deps/libarchive
fi

# ---------------------------------------------------------------------------
# The build tools
#
# meson/ninja build it, libarchive is what the engine links against, and llvm
# provides the clang+lld the arm64 VDSO needs (Apple's clang cannot link a Linux
# target). On a machine with Homebrew, install what is missing rather than failing
# a build the user cannot act on from inside Xcode.
# ---------------------------------------------------------------------------
missing=""
for tool in meson ninja; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done

if [ -n "$missing" ]; then
    if command -v brew >/dev/null 2>&1; then
        echo "note: installing the engine's build tools:$missing (plus llvm/lld/libarchive) with Homebrew"
        for formula in meson ninja llvm lld libarchive; do
            brew list "$formula" >/dev/null 2>&1 || brew install "$formula"
        done
    else
        printf 'error: the embedded Linux engine needs meson and ninja, and this machine\n' >&2
        printf '       has neither (missing:%s) nor Homebrew to install them.\n' "$missing" >&2
        printf '       Install them and build the engine once:\n' >&2
        printf '           brew install meson ninja llvm lld libarchive\n' >&2
        printf '           EmbeddedLinux/build-ish-core.sh\n' >&2
        exit 1
    fi
fi
command -v meson >/dev/null 2>&1 || {
    printf 'error: meson is installed but not on this build phase'"'"'s PATH.\n' >&2
    printf '       Add %s/bin to it (Xcode does not read your shell profile).\n' "$(brew --prefix 2>/dev/null)" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Build (the script is a no-op when the engine is already up to date)
# ---------------------------------------------------------------------------
exec bash EmbeddedLinux/build-ish-core.sh
