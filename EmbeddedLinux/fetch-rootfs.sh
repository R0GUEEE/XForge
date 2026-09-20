#!/usr/bin/env bash
#
# fetch-rootfs.sh — download the Alpine aarch64 root filesystem that ships
# *inside* the XForge app.
#
# The archive is the one iSH-AOK publishes in its `working` branch. It is bundled
# as an app resource so XForge never has to download a root filesystem after
# install; on first boot it is imported into iSH-AOK's fakefs format.
#
# Usage:  EmbeddedLinux/fetch-rootfs.sh [dest-dir]
#         (default dest: <repo>/Support/Resources)
#
set -euo pipefail

# gzip is deliberately used here rather than xz: the iOS-linked libarchive
# includes zlib, whereas xz filter support may attempt to spawn `xz` (which
# does not exist in an app sandbox).
ROOTFS_URL="${ROOTFS_URL:-https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/aarch64/alpine-minirootfs-3.23.3-aarch64.tar.gz}"
ARCHIVE_NAME="alpine-minirootfs-3.23.3-aarch64.tar.gz"

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
DEST="${1:-$REPO/Support/Resources}"

mkdir -p "$DEST"
TARGET="$DEST/$ARCHIVE_NAME"

if [[ -f "$TARGET" ]] && tar -tzf "$TARGET" >/dev/null 2>&1; then
    echo "==> $ARCHIVE_NAME already present and valid ($(du -h "$TARGET" | cut -f1))"
    exit 0
fi

echo "==> Fetching $ARCHIVE_NAME"
echo "    $ROOTFS_URL"
curl -fL --retry 3 --retry-delay 2 "$ROOTFS_URL" -o "$TARGET.partial"
mv "$TARGET.partial" "$TARGET"

# Verify it is a readable gzip-compressed tar before we trust it.
if ! tar -tzf "$TARGET" >/dev/null 2>&1; then
    echo "error: downloaded file is not a valid .tar.gz" >&2
    rm -f "$TARGET"
    exit 1
fi

echo "==> Verified $(du -h "$TARGET" | cut -f1) at $TARGET"
