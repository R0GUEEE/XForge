#!/usr/bin/env bash
#
# build-rootfs.sh — assemble the embedded Alpine aarch64 Linux userspace for XForge.
#
# This runs on a Linux host (or CI) with apk available. It produces an Alpine aarch64
# rootfs that already contains the base system; the Swift toolchain + xtool are added
# here too so first-boot on-device is fast (only the multi-GB darwin SDK is fetched
# on demand later).
#
# Why Alpine + gcompat: the base is Alpine (musl) — tiny (~8 MB) and ideal for bundling
# in an iOS app. The Swift Linux toolchain and xtool are glibc binaries, so we install
# Alpine's `gcompat` + `libc6-compat` to run them.
#
# Usage:  ./build-rootfs.sh [output-dir]

set -euo pipefail

OUT="${1:-./alpine-rootfs}"
ARCH="aarch64"
ALPINE_VERSION="3.21"
SWIFT_BRANCH="swift-6.1.2-RELEASE"
SWIFT_REL="swift-6.1.2-release"
SWIFT_VER="swift-6.1.2-RELEASE"
XTOOL_VER="1.17.0"

MIRROR="https://dl-cdn.alpinelinux.org/alpine"

echo "==> Initializing Alpine aarch64 rootfs at $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/etc/apk"
printf '%s/v%s/main\n%s/v%s/community\n' "$MIRROR" "$ALPINE_VERSION" "$MIRROR" "$ALPINE_VERSION" \
    > "$OUT/etc/apk/repositories"

# apk.static bootstraps a foreign-arch rootfs from any host.
APK_STATIC="$(command -v apk.static || true)"
if [[ -z "$APK_STATIC" ]]; then
    echo "==> Downloading apk.static"
    # Resolve the current apk-tools-static version from the repo index.
    APK_VER="$(curl -fsSL "$MIRROR/v$ALPINE_VERSION/main/$ARCH/APKINDEX.tar.gz" | tar xzO 2>/dev/null \
        | awk '/^P:apk-tools-static$/{f=1;next} f&&/^V:/{print substr($0,3); exit}')"
    APK_VER="${APK_VER:-2.14.6-r3}"
    echo "    using apk-tools-static-$APK_VER"
    curl -fL "$MIRROR/v$ALPINE_VERSION/main/$ARCH/apk-tools-static-$APK_VER.apk" -o /tmp/apk-static.apk
    mkdir -p /tmp/apkstatic && cd /tmp/apkstatic && tar -xzf /tmp/apk-static.apk
    chmod +x sbin/apk.static
    APK_STATIC="$(pwd)/sbin/apk.static"
fi

# Global signing keys so apk verifies packages.
"$APK_STATIC" --root "$OUT" --initdb --arch "$ARCH" add --repository "$MIRROR/v$ALPINE_VERSION/main" alpine-keys

echo "==> Installing base packages"
"$APK_STATIC" --root "$OUT" --arch "$ARCH" add \
    alpine-base bash curl wget tar xz zip unzip git ca-certificates \
    gcompat libc6-compat zlib-static openssl \
    >/dev/null

echo "==> Installing Swift toolchain ($SWIFT_VER) [glibc; run via gcompat]"
SWIFT_URL="https://download.swift.org/${SWIFT_REL}/ubuntu2404/${ARCH}/${SWIFT_VER}/${SWIFT_VER}-ubuntu24.04-${ARCH}.tar.gz"
curl -fL "$SWIFT_URL" -o /tmp/swift.tar.gz
mkdir -p "$OUT/opt"
tar -xzf /tmp/swift.tar.gz -C "$OUT/opt" --strip-components=1
ln -sf /opt/usr/bin/swift "$OUT/usr/bin/swift"
ln -sf /opt/usr/bin/swiftc "$OUT/usr/bin/swiftc"
ln -sf /opt/usr/bin/clang "$OUT/usr/bin/clang"
ln -sf /opt/usr/bin/ld.lld "$OUT/usr/bin/ld.lld"
rm /tmp/swift.tar.gz

echo "==> Installing xtool ($XTOOL_VER)"
curl -fL "https://github.com/xtool-org/xtool/releases/download/${XTOOL_VER}/xtool-${ARCH}.AppImage" \
    -o "$OUT/usr/local/bin/xtool"
chmod +x "$OUT/usr/local/bin/xtool"

echo "==> Writing install-toolchain.sh (first-boot provisioning)"
mkdir -p "$OUT/root"
cp "$(dirname "$0")/install-toolchain.sh" "$OUT/root/install-toolchain.sh"
chmod +x "$OUT/root/install-toolchain.sh"

echo "==> Done. Rootfs at $OUT"
echo "    Next: tar + xz it, bundle it in the app, then fetch the darwin SDK on first use."
du -sh "$OUT"
