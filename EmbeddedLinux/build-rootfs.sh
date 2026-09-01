#!/usr/bin/env bash
#
# build-rootfs.sh — assemble the embedded Alpine aarch64 Linux userspace for XForge.
#
# Runs on any Linux host (or CI). Downloads the official Alpine aarch64 minirootfs
# (apk + alpine-base preconfigured), then adds gcompat (Swift/xtool are glibc) + the
# Swift toolchain + xtool. Produces a rootfs ready to tar/xz and bundle; the multi-GB
# darwin SDK is fetched on first use.
#
# Usage:  ./build-rootfs.sh [output-dir]

set -euo pipefail

OUT="${1:-./alpine-rootfs}"
rm -rf "$OUT"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
ARCH="aarch64"
ALPINE_VERSION="3.21"
ALPINE_RELEASE="3.21.7"
SWIFT_REL="swift-6.1.2-release"
SWIFT_VER="swift-6.1.2-RELEASE"
XTOOL_VER="1.17.0"

MIRROR="https://dl-cdn.alpinelinux.org/alpine"

echo "==> Fetching Alpine $ALPINE_VERSION aarch64 minirootfs"
MINIROOT="alpine-minirootfs-$ALPINE_RELEASE-$ARCH.tar.gz"
curl -fL "$MIRROR/v$ALPINE_VERSION/releases/$ARCH/$MINIROOT" -o /tmp/$MINIROOT
tar -xzf /tmp/$MINIROOT -C "$OUT"
rm -f /tmp/$MINIROOT
printf '%s/v%s/main\n%s/v%s/community\n' "$MIRROR" "$ALPINE_VERSION" "$MIRROR" "$ALPINE_VERSION" \
    > "$OUT/etc/apk/repositories"

echo "==> Installing base packages (via apk.static)"
APK_STATIC="$(command -v apk.static || true)"
if [[ -z "$APK_STATIC" ]]; then
    echo "    downloading apk-tools-static"
    set +e
    curl -fsSL "$MIRROR/v$ALPINE_VERSION/main/$ARCH/APKINDEX.tar.gz" -o /tmp/APKINDEX.tar.gz 2>/dev/null
    APK_VER="$(tar xzf /tmp/APKINDEX.tar.gz -O 2>/dev/null \
        | awk '/^P:apk-tools-static$/{f=1;next} f&&/^V:/{print substr($0,3); exit}')"
    set -e
    APK_VER="${APK_VER:-2.14.6-r3}"
    curl -fL "$MIRROR/v$ALPINE_VERSION/main/$ARCH/apk-tools-static-$APK_VER.apk" -o /tmp/apk-static.apk
    mkdir -p /tmp/apkstatic && cd /tmp/apkstatic && tar -xzf /tmp/apk-static.apk
    chmod +x sbin/apk.static
    APK_STATIC="$(pwd)/sbin/apk.static"
fi

"$APK_STATIC" --root "$OUT" --arch "$ARCH" --initdb --update-cache add \
    bash curl wget tar xz zip unzip git ca-certificates \
    gcompat libc6-compat zlib-static openssl \
    >/dev/null

echo "==> Installing Swift toolchain ($SWIFT_VER) [glibc; via gcompat]"
SWIFT_URL="https://download.swift.org/${SWIFT_REL}/ubuntu2404/${ARCH}/${SWIFT_VER}/${SWIFT_VER}-ubuntu24.04-${ARCH}.tar.gz"
curl -fL "$SWIFT_URL" -o /tmp/swift.tar.gz
tar -xzf /tmp/swift.tar.gz -C "$OUT/opt" --strip-components=1
ln -sf /opt/usr/bin/swift "$OUT/usr/bin/swift"
ln -sf /opt/usr/bin/swiftc "$OUT/usr/bin/swiftc"
ln -sf /opt/usr/bin/clang "$OUT/usr/bin/clang"
ln -sf /opt/usr/bin/ld.lld "$OUT/usr/bin/ld.lld"
rm -f /tmp/swift.tar.gz

echo "==> Installing xtool ($XTOOL_VER)"
curl -fL "https://github.com/xtool-org/xtool/releases/download/${XTOOL_VER}/xtool-${ARCH}.AppImage" \
    -o "$OUT/usr/local/bin/xtool"
chmod +x "$OUT/usr/local/bin/xtool"

echo "==> Writing install-toolchain.sh (first-boot provisioning)"
mkdir -p "$OUT/root"
cp "$(dirname "$0")/install-toolchain.sh" "$OUT/root/install-toolchain.sh"
chmod +x "$OUT/root/install-toolchain.sh"

echo "==> Done. Rootfs at $OUT"
du -sh "$OUT"
