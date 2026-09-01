#!/usr/bin/env bash
#
# install-toolchain.sh — provision the XForge embedded Linux INSIDE the guest.
# The guest is Alpine aarch64 (musl). The Swift toolchain and xtool are glibc
# binaries, so we install Alpine's `gcompat` to run them.
#
# If the rootfs was assembled by build-rootfs.sh, the Swift toolchain + xtool are
# already present; this script only finishes setup (darwin SDK, symlinks) and can be
# re-run safely. If run on a bare Alpine, it also installs the toolchain.

set -euo pipefail

[[ "$(uname -m)" == "aarch64" ]] || { echo "Expected aarch64 guest, got $(uname -m)" >&2; exit 1; }

echo "==> Alpine base packages"
apk add --no-cache \
    bash curl wget tar xz zip unzip git ca-certificates \
    gcompat libc6-compat zlib-static openssl

echo "==> Swift toolchain"
if command -v swift >/dev/null 2>&1; then
    echo "Swift already present: $(swift --version | head -1)"
else
    SWIFT_BRANCH="swift-6.1.2-RELEASE"
    SWIFT_REL="swift-6.1.2-release"
    SWIFT_VER="swift-6.1.2-RELEASE"
    SWIFT_URL="https://download.swift.org/${SWIFT_REL}/ubuntu2404/aarch64/${SWIFT_VER}/${SWIFT_VER}-ubuntu24.04-aarch64.tar.gz"
    echo "Downloading $SWIFT_URL"
    curl -fL "$SWIFT_URL" -o /tmp/swift.tar.gz
    tar -xzf /tmp/swift.tar.gz -C /opt --strip-components=1
    rm /tmp/swift.tar.gz
fi
ln -sf /opt/usr/bin/swift /usr/local/bin/swift
ln -sf /opt/usr/bin/swiftc /usr/local/bin/swiftc
ln -sf /opt/usr/bin/clang /usr/local/bin/clang
ln -sf /opt/usr/bin/ld.lld /usr/local/bin/ld.lld
swift --version

echo "==> xtool"
if [[ -f /usr/local/bin/xtool ]]; then
    echo "xtool present"
else
    XTOOL_VER="1.17.0"
    curl -fL "https://github.com/xtool-org/xtool/releases/download/${XTOOL_VER}/xtool-aarch64.AppImage" \
        -o /usr/local/bin/xtool
    chmod +x /usr/local/bin/xtool
fi
# AppImage needs FUSE; extract-and-run avoids it entirely.
export APPIMAGE_EXTRACT_AND_RUN=1
xtool --version

echo "==> darwin Swift SDK"
# The darwin.artifactbundle is NOT shipped in the rootfs; it is built in CI from
# Xcode (see .github/workflows/build-darwin-sdk.yml) and fetched on first use, then
# staged here by the host app. Optional at provisioning time.
SDK_BUNDLE="/opt/darwin.artifactbundle"
if [[ -d "$SDK_BUNDLE" ]]; then
    swift sdk install "$SDK_BUNDLE"
    swift sdk configure darwin arm64-apple-ios --show-configuration
else
    echo "WARNING: $SDK_BUNDLE not found — the darwin SDK will be fetched by the app on first build."
fi

echo "==> Done. XForge embedded Linux (Alpine aarch64) is ready."
