#!/usr/bin/env bash
#
# payload-key.sh — print the identity of the provisioned rootfs payload this
# checkout would produce.
#
# The key is a hash of everything that decides what ends up *inside* the payload:
# the provisioning script, the payload builder, the base rootfs, and whether the
# darwin SDK is baked in. Two builds with the same key produce the same payload,
# which is what makes it safe to reuse one — as a cached GitHub Actions cache
# entry or as a release asset — instead of re-provisioning a whole Swift
# toolchain on every IPA build.
#
# Usage:  XFORGE_INCLUDE_SDK=auto EmbeddedLinux/payload-key.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

{
    cat "$HERE/install-toolchain.sh"
    cat "$HERE/build-rootfs-payload.sh"
    echo "rootfs=${XFORGE_ROOTFS_URL:-default}"
    echo "sdk=${XFORGE_INCLUDE_SDK:-auto}"
    echo "sdk-url=${XFORGE_SDK_URL:-latest}"
} | sha256sum | cut -c1-12
