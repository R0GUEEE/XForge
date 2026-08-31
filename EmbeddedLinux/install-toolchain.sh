#!/usr/bin/env bash
#
# install-toolchain.sh
#
# Assemble the embedded Linux userspace for XForge INSIDE the guest once it is
# booted. This script runs *in* the embedded Linux (Alpine / aarch64), not on iOS.
#
# It installs, in order:
#   1. Swift aarch64 Linux toolchain   (from swift.org)
#   2. xtool (aarch64 binary)          (from the xtool GitHub release)
#   3. the `darwin` Swift SDK          (darwin.artifactbundle — built in CI, see below)
#
# Requires network access from the guest. Run as root.

set -euo pipefail

ARCH="$(uname -m)"
[[ "$ARCH" == "aarch64" ]] || { echo "Expected aarch64 guest, got $ARCH" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive

echo "==> Installing base packages"
apk add --no-cache \
    curl wget tar xz zip unzip git bash \
    gcc clang libc6-compat libcurl openssl-libs-static \
    zlib-static lld llvm-libs pkgconfig

# Swift toolchain (static URL updated for the current Swift release)
SWIFT_BRANCH="swift-6.1.2-RELEASE"
SWIFT_REL="swift-6.1.2-release"
SWIFT_VER="swift-6.1.2-RELEASE"
SWIFT_URL="https://download.swift.org/${SWIFT_REL}/ubuntu2404/aarch64/${SWIFT_VER}/${SWIFT_VER}-ubuntu24.04-aarch64.tar.gz"

echo "==> Installing Swift toolchain: $SWIFT_VER"
curl -fL "$SWIFT_URL" -o /tmp/swift.tar.gz
tar -xzf /tmp/swift.tar.gz -C /opt --strip-components=1
ln -sf /opt/usr/bin/swift /usr/local/bin/swift
ln -sf /opt/usr/bin/swiftc /usr/local/bin/swiftc
ln -sf /opt/usr/bin/clang /usr/local/bin/clang
ln -sf /opt/usr/bin/ld.lld /usr/local/bin/ld.lld
rm /tmp/swift.tar.gz
swift --version

echo "==> Installing xtool"
XTOOL_VER="1.17.0"
curl -fL "https://github.com/xtool-org/xtool/releases/download/${XTOOL_VER}/xtool-aarch64.AppImage" \
    -o /usr/local/bin/xtool
chmod +x /usr/local/bin/xtool
# AppImage needs FUSE; extract-and-run avoids it entirely.
export APPIMAGE_EXTRACT_AND_RUN=1
xtool --version

echo "==> Installing darwin Swift SDK"
# The darwin.artifactbundle is NOT shipped in this repo; it is built in CI from
# Xcode (see .github/workflows/build-darwin-sdk.yml) and staged into the guest
# filesystem by the host app. Path below is where the host copies it.
SDK_BUNDLE="/opt/darwin.artifactbundle"
if [[ -d "$SDK_BUNDLE" ]]; then
    swift sdk install "$SDK_BUNDLE"
    swift sdk configure darwin arm64-apple-ios --show-configuration
else
    echo "WARNING: $SDK_BUNDLE not found — run the darwin-SDK CI job first." >&2
fi

echo "==> Done. XForge embedded Linux is ready."
