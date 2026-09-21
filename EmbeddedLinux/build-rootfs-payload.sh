#!/usr/bin/env bash
#
# build-rootfs-payload.sh — turn the plain Alpine minirootfs into a *provisioned*
# one, so an app built with it ships with the whole toolchain already installed.
#
# The app bundles an Alpine aarch64 root filesystem and imports it into the engine's
# `fakefs` format on first launch. With the plain minirootfs the user still has to
# run EmbeddedLinux/install-toolchain.sh on the device afterwards: hundreds of
# megabytes of downloads, an apk build environment, a glibc compatibility layer
# and a Swift toolchain — all inside an emulator, on a phone.
#
# This script does that provisioning **at build time** instead, on native aarch64
# Linux, and packs the result:
#
#     alpine-minirootfs-3.24.2-aarch64-provisioned.tar.gz
#
# It runs the app's OWN provisioning script inside a `chroot` of the unpacked
# root filesystem — there is deliberately no second implementation that could
# drift from what a device installs. That is also why this needs aarch64 Linux:
# the guest's apk, swiftly, the Swift toolchain and xtool are all arm64 binaries,
# and the chroot is where they run at full speed instead of under the emulator.
#
# Usage:
#     sudo EmbeddedLinux/build-rootfs-payload.sh [output-dir]      # default: dist
#
# Environment:
#     XFORGE_ROOTFS_URL       plain minirootfs to start from (default: Alpine 3.24.2)
#     XFORGE_ROOTFS_SHA256    checksum for a custom rootfs URL
#     XFORGE_INCLUDE_SDK      auto | 1 | 0 — bake the darwin Swift SDK in too
#                             (default: auto = include when a release has one)
#     XFORGE_INSTALL_XTOOL   1 | 0 — install xtool in the payload (default: 1)
#     XFORGE_SDK_URL          explicit darwin.artifactbundle.tar.xz URL (implies 1)
#     XFORGE_SDK_TAG_PREFIX   release series holding the SDK (default: darwin-sdk-)
#     XFORGE_REPOSITORY       owner/repo whose releases hold the SDK (R0GUEEE/XForge)
#     XFORGE_PAYLOAD_NAME     output file name (default: <base>-provisioned.tar.gz)
#     XFORGE_GZIP_LEVEL       gzip compression level 1-9 (default: 9)
#     XFORGE_WORK_DIR         work directory (default: <repo>/.payload-work)
#     XFORGE_KEEP_WORK        1 — leave the work directory behind for inspection
#
# The test this has to pass is not "tar exited 0": every tool is executed inside
# the finished rootfs before it is packed, and the result is recorded in
# /usr/local/share/xforge/payload-manifest.txt *inside* the archive — so the IPA
# build can prove from the packed artifact alone what the guest can do.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

OUT_DIR="${1:-$REPO/dist}"
DEFAULT_ROOTFS_URL="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/alpine-minirootfs-3.24.2-aarch64.tar.gz"
DEFAULT_ROOTFS_SHA256="9bf70a7f18ea44094cbb5f70c58f9af129c8214745743db0e68e5502cc2ce773"
ROOTFS_URL="${XFORGE_ROOTFS_URL:-$DEFAULT_ROOTFS_URL}"
ROOTFS_SHA256="${XFORGE_ROOTFS_SHA256:-}"
[ -n "$ROOTFS_SHA256" ] || [ "$ROOTFS_URL" != "$DEFAULT_ROOTFS_URL" ] || ROOTFS_SHA256="$DEFAULT_ROOTFS_SHA256"
BASE_NAME="$(basename "$ROOTFS_URL" .tar.gz)"
PAYLOAD_NAME="${XFORGE_PAYLOAD_NAME:-$BASE_NAME-provisioned.tar.gz}"
INCLUDE_SDK="${XFORGE_INCLUDE_SDK:-auto}"
INSTALL_XTOOL="${XFORGE_INSTALL_XTOOL:-1}"
GZIP_LEVEL="${XFORGE_GZIP_LEVEL:-9}"
SDK_TAG_PREFIX="${XFORGE_SDK_TAG_PREFIX:-darwin-sdk-}"
REPOSITORY="${XFORGE_REPOSITORY:-R0GUEEE/XForge}"
SDK_ASSET="darwin.artifactbundle.tar.xz"
WORK="${XFORGE_WORK_DIR:-$REPO/.payload-work}"
ROOTFS="$WORK/rootfs"
LOG="$WORK/provision.log"
MANIFEST_GUEST=/usr/local/share/xforge/payload-manifest.txt
STAMP_GUEST=/usr/local/share/xforge/build-environment-v2
# The guest's PATH, with /usr/local/bin first: that is where XForge's wrappers
# for swift/swiftc/xtool live, and a non-interactive `sh -c` has no profile.
GUEST_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

log()  { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\nerror: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
[ "$(uname -s)" = "Linux" ] || die "this needs Linux: it uses chroot to run the guest's own binaries"
case "$(uname -m)" in
    aarch64|arm64) ;;
    *) die "$(uname -m) cannot run the guest's arm64 binaries natively — use an arm64 Linux host (GitHub's ubuntu-24.04-arm)" ;;
esac
[ "$(id -u)" -eq 0 ] || die "run this with root (sudo $0)"
case "$GZIP_LEVEL" in
    1|2|3|4|5|6|7|8|9) ;;
    *) die "XFORGE_GZIP_LEVEL must be between 1 and 9 (got '$GZIP_LEVEL')" ;;
esac

command -v curl >/dev/null || die "curl is required"
command -v tar  >/dev/null || die "tar is required"

# ---------------------------------------------------------------------------
# Mount bookkeeping
#
# The binds have to be undone in reverse order before packing, and they must be
# undone even when provisioning fails half-way — a leftover /proc bind inside the
# rootfs would end up in the archive.
# ---------------------------------------------------------------------------
MOUNTS=()
unmount_all() {
    local target
    for (( i=${#MOUNTS[@]}-1; i>=0; i-- )); do
        target="${MOUNTS[$i]}"
        umount -l "$target" 2>/dev/null || umount "$target" 2>/dev/null || true
    done
    MOUNTS=()
}
cleanup() {
    local status=$?
    unmount_all
    if [ "$status" -ne 0 ]; then
        # Keep everything on failure: the provisioning log and the half-built
        # rootfs are the only evidence of what went wrong.
        printf '\nFailed (exit %d). Work directory kept at %s (provisioning log: %s)\n' \
            "$status" "$WORK" "$LOG" >&2
    elif [ "${XFORGE_KEEP_WORK:-0}" != "1" ]; then
        rm -rf "$WORK"
    fi
    return $status
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Start from the plain minirootfs
# ---------------------------------------------------------------------------
log "Preparing a work rootfs at $ROOTFS"
rm -rf "$WORK"
mkdir -p "$ROOTFS" "$OUT_DIR"

ARCHIVE="$WORK/$(basename "$ROOTFS_URL")"
log "Fetching $ROOTFS_URL"
curl -fL --retry 3 --retry-delay 2 -o "$ARCHIVE" "$ROOTFS_URL"
if [ -n "$ROOTFS_SHA256" ]; then
    printf '%s  %s\n' "$ROOTFS_SHA256" "$ARCHIVE" | sha256sum -c -
fi
tar -tzf "$ARCHIVE" >/dev/null || die "the downloaded rootfs is not a valid .tar.gz"
note "$(du -h "$ARCHIVE" | cut -f1) → $ARCHIVE"

tar -xzf "$ARCHIVE" -C "$ROOTFS"
[ -x "$ROOTFS/bin/sh" ] || die "the archive does not look like an Alpine rootfs (no /bin/sh)"
[ -f "$ROOTFS/etc/alpine-release" ] || die "the archive has no /etc/alpine-release"
note "base rootfs: $(cat "$ROOTFS/etc/alpine-release")"

# ---------------------------------------------------------------------------
# 2. Make the chroot usable
# ---------------------------------------------------------------------------
log "Mounting /proc, /sys, /dev and /dev/pts inside the chroot"
for dir in proc sys dev dev/pts; do
    mkdir -p "$ROOTFS/$dir"
done
mount -t proc     none "$ROOTFS/proc"
MOUNTS+=("$ROOTFS/proc")
mount --rbind /sys "$ROOTFS/sys"
MOUNTS+=("$ROOTFS/sys")
mount --rbind /dev "$ROOTFS/dev"
MOUNTS+=("$ROOTFS/dev")
mount --rbind /dev/pts "$ROOTFS/dev/pts"
MOUNTS+=("$ROOTFS/dev/pts")

# DNS: name resolution happens inside the guest (musl reads /etc/resolv.conf),
# and the minirootfs ships no nameservers at all. Take the host's, and keep a
# public resolver for hosts that have none of their own.
if [ -s /etc/resolv.conf ] && grep -q '^nameserver' /etc/resolv.conf; then
    grep '^nameserver' /etc/resolv.conf | sed -n '1,3p' > "$ROOTFS/etc/resolv.conf"
else
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$ROOTFS/etc/resolv.conf"
fi
note "guest resolv.conf: $(tr '\n' ' ' < "$ROOTFS/etc/resolv.conf")"

# The app's own provisioning script, exactly the copy the app bundles.
install -m 0755 "$HERE/install-toolchain.sh" "$ROOTFS/root/install-toolchain.sh"

# ---------------------------------------------------------------------------
# 3. Provision, by running the app's script inside the chroot
# ---------------------------------------------------------------------------
log "Running install-toolchain.sh all inside the chroot (this is the slow part)"
set +e
chroot "$ROOTFS" /bin/sh -c "export PATH=$GUEST_PATH HOME=/root XFORGE_INSTALL_XTOOL=$INSTALL_XTOOL; sh /root/install-toolchain.sh all" 2>&1 | tee "$LOG"
status="${PIPESTATUS[0]}"
set -e
[ "$status" -eq 0 ] || die "install-toolchain.sh failed with exit $status — see $LOG"

# The script's own verdicts decide, not its exit status: it reports each tool it
# executed as a XFORGE-VERIFY line, and "installed but does not run" is a failure
# here — a payload whose swift traps on the device is worse than no payload.
# swift-sdk is a separate binary (`swift sdk list`) and is what installs the
# darwin SDK, so it has to run before the SDK step can be trusted.
verify_tools="swift swiftly swift-sdk"
[ "$INSTALL_XTOOL" = "0" ] || verify_tools="xtool $verify_tools"
for tool in $verify_tools; do
    grep -qE "^XFORGE-VERIFY[[:space:]]+${tool}[[:space:]]+ok" "$LOG" \
        || die "$tool did not verify inside the chroot — see $LOG"
done
[ -f "$ROOTFS$STAMP_GUEST" ] || die "the provisioning stamp $STAMP_GUEST was not written"

# Run the tools again, outside the script, and keep what they said. This is the
# text a device-side install would produce, and it goes into the manifest.
log "Checking the provisioned rootfs from the outside"
probe() { chroot "$ROOTFS" /bin/sh -c "export PATH=$GUEST_PATH HOME=/root; $1" 2>&1 || true; }
SWIFT_VERSION="$(probe 'swift --version' | sed -n 1p)"
XTOOL_VERSION="not bundled"
[ "$INSTALL_XTOOL" = "0" ] || XTOOL_VERSION="$(probe 'xtool --version' | sed -n 1p)"
SWIFTLY_VERSION="$(probe 'swiftly --version' | sed -n 1p)"
APK_PROBE="$(probe 'apk info -e clang lld cmake ninja git && echo present')"
GLIBC_LD="$(probe 'ls -l /lib/ld-linux-aarch64.so.1' | sed 's/.*-> //')"

[ -n "$SWIFT_VERSION" ] || die "swift --version printed nothing in the provisioned rootfs"
[ "$INSTALL_XTOOL" = "0" ] || [ -n "$XTOOL_VERSION" ] || die "xtool --version printed nothing in the provisioned rootfs"
case "$APK_PROBE" in
    *present*) ;;
    *) die "the build dependencies (clang lld cmake ninja git) are not in the provisioned rootfs" ;;
esac
note "swift:  $SWIFT_VERSION"
note "xtool:  $XTOOL_VERSION"
note "glibc:  $GLIBC_LD"

# Printing a version is not compiling. XForge exists to *build* a package in this
# rootfs, and a toolchain whose frontend cannot find its own resource directory
# still answers `swift --version` happily — it only fails when the compiler runs
# ("missing required module 'SwiftShims'"). So compile and run something.
log "Checking what a link sees (the layer's paths and the linker's defaults)"
cat > "$ROOTFS/root/link-diagnose.sh" <<'DIAG'
for f in /lib/aarch64-linux-gnu/libc.so /usr/lib/aarch64-linux-gnu/libc.so \
         /usr/lib/libc.so /usr/lib/libstdc++.so /lib/aarch64-linux-gnu/libc.so.6 \
         /usr/lib/aarch64-linux-gnu/libstdc++.so.6; do
    if [ -e "$f" ]; then
        printf '%-46s -> %s\n' "$f" "$(readlink -f "$f" 2>/dev/null || echo file)"
    else
        printf '%-46s MISSING\n' "$f"
    fi
done
# Where the linker looks when nothing on the command line says otherwise.
ld --verbose 2>&1 | sed -n 's/^SEARCH_DIR("=\?\(.*\)");.*/ld SEARCH_DIR: \1/p' | head -3
DIAG
chroot "$ROOTFS" /bin/sh /root/link-diagnose.sh 2>&1 | sed 's/^/    /'
rm -f "$ROOTFS/root/link-diagnose.sh"

log "Compiling and running a Swift program in the provisioned rootfs"
cat > "$ROOTFS/root/swift-probe.swift" <<'SWIFT'
print("xforge-swift-compile-ok")
SWIFT
# -v so a failure shows the linker command the driver actually ran: the last
# attempt to fix this was guessed at, and the guess could not be checked.
SWIFT_RUN="$(chroot "$ROOTFS" /bin/sh -c "export PATH=$GUEST_PATH HOME=/root; cd /root && swiftc -v -o swift-probe swift-probe.swift && ./swift-probe" 2>&1 || true)"
printf '%s\n' "$SWIFT_RUN" | tail -40 | sed 's/^/    /'
case "$SWIFT_RUN" in
    *xforge-swift-compile-ok*) ;;
    *) die "the Swift toolchain in the payload cannot compile a program (see above)" ;;
esac
rm -f "$ROOTFS/root/swift-probe.swift" "$ROOTFS/root/swift-probe"

# ---------------------------------------------------------------------------
# 4. The darwin Swift SDK
#
# Optional, because it is a 200 MB release asset the app can also fetch on first
# use — but with it baked in the app needs no network at all to build an IPA.
# ---------------------------------------------------------------------------
SDK_VERSION="not bundled"
if [ "$INCLUDE_SDK" != "0" ]; then
    log "Adding the darwin Swift SDK"

    sdk_url="${XFORGE_SDK_URL:-}"
    if [ -z "$sdk_url" ]; then
        api="https://api.github.com/repos/$REPOSITORY/releases?per_page=50"
        auth=()
        [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ] && \
            auth=(-H "Authorization: Bearer ${GH_TOKEN:-${GITHUB_TOKEN}}")
        sdk_url="$(curl -fsSL "${auth[@]}" -H 'Accept: application/vnd.github+json' "$api" \
            | python3 -c '
import json, sys
prefix, asset = sys.argv[1], sys.argv[2]
for release in json.load(sys.stdin):
    if not release.get("tag_name", "").startswith(prefix):
        continue
    for a in release.get("assets", []):
        if a.get("name") == asset:
            print(a["browser_download_url"]); raise SystemExit
' "$SDK_TAG_PREFIX" "$SDK_ASSET" 2>/dev/null || true)"
    fi

    if [ -z "$sdk_url" ]; then
        [ "$INCLUDE_SDK" = "1" ] && die "no $SDK_ASSET found in any $SDK_TAG_PREFIX* release of $REPOSITORY"
        note "no darwin SDK release found — skipping it (XFORGE_INCLUDE_SDK=1 to require it)"
    else
        note "$sdk_url"
        sdk_archive="$WORK/$(basename "$sdk_url")"
        curl -fL --retry 3 --retry-delay 2 -o "$sdk_archive" "$sdk_url"

        sdk_dir="$ROOTFS/root/.cache/xforge-sdk"
        mkdir -p "$sdk_dir"
        cp "$sdk_archive" "$sdk_dir/$SDK_ASSET"
        chroot "$ROOTFS" /bin/sh -c "
            set -eu
            export PATH=$GUEST_PATH HOME=/root
            cd /root/.cache/xforge-sdk
            tar -xJf $SDK_ASSET
            test -f darwin.artifactbundle/info.json
            swift sdk install /root/.cache/xforge-sdk/darwin.artifactbundle
            rm -rf /root/.cache/xforge-sdk
            swift sdk list
        " || die "installing the darwin SDK into the rootfs failed"

        SDK_VERSION="$(probe 'swift sdk list' | grep -i darwin | sed -n 1p)"
        [ -n "$SDK_VERSION" ] || die "swift sdk list does not mention darwin after installing it"
        note "darwin: $SDK_VERSION"
    fi
fi

# ---------------------------------------------------------------------------
# 5. Slim the image and write the manifest the IPA build checks
# ---------------------------------------------------------------------------
#
# Keep this list deliberately conservative. Headers, pkg-config files, Swift
# modules, runtime libraries and package metadata are all required by builds or
# by the in-guest toolchain updater. Documentation and generated caches are not
# — this rootfs is provisioned to run as XForge's embedded Linux, not as a
# general-purpose Alpine desktop.
log "Slimming the image"
# Measure with the pseudo-filesystems out of the way. `-x` keeps du from
# *descending* into another filesystem, but it still walks the directory entries
# of a bind-mounted /proc — and /proc/<pid> and /proc/<pid>/task/<tid>/fd/* exist
# only for as long as the process they describe, so they vanish mid-traversal and
# du reports `cannot access …` for them. Under `set -e` a nonzero du inside a
# command substitution aborts the whole build, which is exactly how a payload
# that had already provisioned and verified its toolchain died in the slimming
# step. Sizes are also the one number in the manifest that nothing depends on, so
# measuring must never be able to fail the build: hence `|| true`, and a fallback
# to the apparent size when the walk still cannot be completed.
rootfs_size_kib() {
    local kib
    kib="$( { du -skx "$ROOTFS" 2>/dev/null || true; } | awk '{print $1}' )"
    if [ -z "$kib" ]; then
        kib="$( { du -sk --apparent-size "$ROOTFS" 2>/dev/null || true; } \
                | awk 'END {print $1}' )"
    fi
    printf '%s' "${kib:-0}"
}
ROOTFS_SIZE_BEFORE_KIB="$(rootfs_size_kib)"
rm -rf "$ROOTFS"/var/cache/apk/* "$ROOTFS"/tmp/* "$ROOTFS"/root/.cache/* \
       "$ROOTFS"/var/cache/misc/* "$ROOTFS"/var/tmp/* "$ROOTFS"/run/* \
       "$ROOTFS"/var/log/* 2>/dev/null || true

for tree in \
    "$ROOTFS"/usr/share/doc \
    "$ROOTFS"/usr/share/man \
    "$ROOTFS"/usr/share/info \
    "$ROOTFS"/usr/share/gtk-doc \
    "$ROOTFS"/usr/share/locale \
    "$ROOTFS"/usr/share/i18n \
    "$ROOTFS"/opt/glibc/usr/share/doc \
    "$ROOTFS"/opt/glibc/usr/share/man \
    "$ROOTFS"/opt/glibc/usr/share/info \
    "$ROOTFS"/root/.local/share/swiftly/*/usr/share/doc \
    "$ROOTFS"/root/.local/share/swiftly/*/usr/share/man \
    "$ROOTFS"/root/.local/share/swiftly/*/usr/share/info; do
    rm -rf "$tree" 2>/dev/null || true
done

# These are generated by Python and are never imported by the build tools.
find "$ROOTFS" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
find "$ROOTFS" -type f -name '*.py[co]' -delete 2>/dev/null || true

# gnupg is no longer installed in the guest (see step_deps in
# install-toolchain.sh), so this only clears whatever a prior provisioning left
# behind — a directory, not sockets, since there is no gpg-agent to leave one.
rm -rf "$ROOTFS"/root/.gnupg 2>/dev/null || true

ROOTFS_SIZE_AFTER_KIB="$(rootfs_size_kib)"
ROOTFS_SAVED_KIB="$((ROOTFS_SIZE_BEFORE_KIB - ROOTFS_SIZE_AFTER_KIB))"
note "rootfs: ${ROOTFS_SIZE_BEFORE_KIB} KiB → ${ROOTFS_SIZE_AFTER_KIB} KiB (saved ${ROOTFS_SAVED_KIB} KiB)"

mkdir -p "$(dirname "$ROOTFS$MANIFEST_GUEST")"
log "Recording the payload manifest at $MANIFEST_GUEST"
{
    echo "XForge provisioned rootfs payload"
    echo "base:         $(basename "$ROOTFS_URL")"
    echo "rootfs:       $(cat "$ROOTFS/etc/alpine-release")"
    echo "provisioning: install-toolchain.sh all"
    echo "built-at:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "built-from:   ${GITHUB_SHA:-$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)}"
    echo "swift:        $SWIFT_VERSION"
    echo "xtool:        $XTOOL_VERSION"
    echo "swiftly:      $SWIFTLY_VERSION"
    echo "darwin-sdk:   $SDK_VERSION"
    echo "glibc-loader: $GLIBC_LD"
    echo "rootfs-size-before-kib: $ROOTFS_SIZE_BEFORE_KIB"
    echo "rootfs-size-after-kib:  $ROOTFS_SIZE_AFTER_KIB"
    echo "rootfs-saved-kib:       $ROOTFS_SAVED_KIB"
    echo "stamp:        build-environment-v2"
} > "$ROOTFS$MANIFEST_GUEST"

note "rootfs  size on disk: $( { du -shx "$ROOTFS" 2>/dev/null || true; } | cut -f1)"
du -sh "$ROOTFS"/root/.local/share/swiftly "$ROOTFS"/opt/glibc "$ROOTFS"/opt/xtool 2>/dev/null | sed 's/^/    /' || true

# ---------------------------------------------------------------------------
# 6. Pack
# ---------------------------------------------------------------------------
log "Unmounting and packing $PAYLOAD_NAME"
unmount_all

PAYLOAD="$OUT_DIR/$PAYLOAD_NAME"
rm -f "$PAYLOAD"
# gzip on purpose (the iOS-linked libarchive has zlib, xz support may try to
# spawn an `xz` that does not exist in an app sandbox). Use deterministic tar
# metadata so repeated builds do not carry host uid, gid, or timestamp noise
# into the IPA.
TAR_FLAGS=(--sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner)
if command -v pigz >/dev/null 2>&1; then
    note "compressing with pigz -$GZIP_LEVEL"
    tar -cf - "${TAR_FLAGS[@]}" -C "$ROOTFS" . | pigz "-$GZIP_LEVEL" > "$PAYLOAD"
else
    note "compressing with gzip -$GZIP_LEVEL"
    tar -czpf "$PAYLOAD" "${TAR_FLAGS[@]}" -C "$ROOTFS" .
fi

# The contents are checked by name — a payload that lost its wrappers or its
# toolchain would otherwise only fail on a device. The listing is taken *once*:
# decompressing a 1 GB archive for each of six checks cost five minutes, and
# `tar -tzf | grep -q` is not safe under `set -o pipefail` — grep exits at the
# first match, tar dies of SIGPIPE, and the pipeline reports failure for a
# payload that is complete.
CONTENTS="$WORK/payload-contents.txt"
tar -tzf "$PAYLOAD" > "$CONTENTS" || die "the packed payload is not a readable .tar.gz"
grep -qE "(^|/)usr/local/bin/swift$"    "$CONTENTS" || die "the payload is missing /usr/local/bin/swift"
grep -qE "(^|/)usr/local/share/xforge/glibc.env$" "$CONTENTS" || die "the payload is missing the glibc layer"
[ "$INSTALL_XTOOL" = "0" ] || {
    grep -qE "(^|/)usr/local/bin/xtool$" "$CONTENTS" || die "the payload is missing /usr/local/bin/xtool"
    grep -qE "(^|/)opt/xtool/usr/bin/xtool$" "$CONTENTS" || die "the payload has no unpacked xtool"
}
grep -qE "(^|/)swiftly/toolchains/"      "$CONTENTS" || die "the payload has no Swift toolchain"
grep -qE "(^|/)usr/local/share/xforge/payload-manifest.txt$" "$CONTENTS" || die "the payload has no manifest"

log "Done"
note "payload: $PAYLOAD"
note "size:    $(du -h "$PAYLOAD" | cut -f1)"
note "entries: $(wc -l < "$CONTENTS")"
echo
cat "$ROOTFS$MANIFEST_GUEST"

# GitHub Actions picks these up in the run summary.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "payload=$PAYLOAD"
        echo "payload_name=$PAYLOAD_NAME"
        echo "payload_size=$(stat -c %s "$PAYLOAD")"
    } >> "$GITHUB_OUTPUT"
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "### Provisioned rootfs payload"
        echo
        echo '```'
        cat "$ROOTFS$MANIFEST_GUEST"
        echo '```'
        echo
        echo "\`$(basename "$PAYLOAD")\` — $(du -h "$PAYLOAD" | cut -f1)"
    } >> "$GITHUB_STEP_SUMMARY"
fi
