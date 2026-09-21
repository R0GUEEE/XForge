#!/usr/bin/env bash
#
# fetch-rootfs.sh — put the Alpine aarch64 root filesystem that ships *inside*
# the XForge app into Support/Resources.
#
# Two flavours exist, and the app prefers the first one it finds:
#
#   alpine-minirootfs-3.24.2-aarch64-provisioned.tar.gz
#       Built by EmbeddedLinux/build-rootfs-payload.sh: the minirootfs with the
#       whole toolchain already installed in it (apk build environment, the glibc
#       layer, xtool, swiftly + the Swift toolchain, optionally the darwin SDK).
#       An app built with this has the Alpine dependencies and Swift ready;
#       xtool and the Darwin SDK remain explicit on-device installs.
#
#   alpine-minirootfs-3.24.2-aarch64.tar.gz
#       The plain Alpine minirootfs. Small, and the user runs
#       install-toolchain.sh in the guest afterwards.
#
# Usage:  EmbeddedLinux/fetch-rootfs.sh [dest-dir]
#         (default dest: <repo>/Support/Resources)
#
# Environment:
#     XFORGE_ROOTFS          auto (default) | payload | plain
#                            auto = payload when one can be found, else plain;
#                            payload = fail if there is no provisioned archive.
#     XFORGE_ROOTFS_ARCHIVE  path to an already-built archive (usually what the
#                            CI job just produced); skips every download.
#     ROOTFS_URL / ROOTFS_SHA256  custom plain-rootfs source and checksum.
#     XFORGE_PAYLOAD_URL     explicit provisioned archive URL (implies payload).
#     XFORGE_PAYLOAD_TAG_PREFIX  release series holding payloads
#                            (default: xforge-payload-)
#     XFORGE_REPOSITORY      owner/repo whose releases hold payloads
#                            (default: R0GUEEE/XForge)
#
# gzip is used deliberately rather than xz: the iOS-linked libarchive includes
# zlib, whereas xz filter support may try to spawn `xz`, which does not exist
# inside an app sandbox.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
DEST="${1:-$REPO/Support/Resources}"

BASE_NAME="alpine-minirootfs-3.24.2-aarch64"
DEFAULT_PLAIN_URL="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/$BASE_NAME.tar.gz"
DEFAULT_PLAIN_SHA256="9bf70a7f18ea44094cbb5f70c58f9af129c8214745743db0e68e5502cc2ce773"
PLAIN_URL="${ROOTFS_URL:-$DEFAULT_PLAIN_URL}"
PLAIN_SHA256="${ROOTFS_SHA256:-}"
[ -n "$PLAIN_SHA256" ] || [ "$PLAIN_URL" != "$DEFAULT_PLAIN_URL" ] || PLAIN_SHA256="$DEFAULT_PLAIN_SHA256"
PAYLOAD_NAME="$BASE_NAME-provisioned.tar.gz"
PAYLOAD_TAG_PREFIX="${XFORGE_PAYLOAD_TAG_PREFIX:-xforge-payload-}"
REPOSITORY="${XFORGE_REPOSITORY:-R0GUEEE/XForge}"

MODE="${XFORGE_ROOTFS:-auto}"
[ -n "${XFORGE_ROOTFS_ARCHIVE:-}" ] && MODE=payload
[ -n "${XFORGE_PAYLOAD_URL:-}" ] && MODE=payload

log()  { printf '==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

mkdir -p "$DEST"

# Only one archive may be present: the app bundles the whole directory, and a
# stale plain rootfs next to a payload would double the app's size on a build
# that means to ship the payload.
discard() {
    local target="$DEST/$1"
    [ -e "$target" ] || return 0
    log "Removing the unused $1"
    rm -f "$target"
}

verify_archive() {
    tar -tzf "$1" >/dev/null 2>&1 || die "$1 is not a readable .tar.gz"
}

verify_plain_checksum() {
    local archive="$1" actual
    [ -n "$PLAIN_SHA256" ] || return 0
    if command -v sha256sum >/dev/null 2>&1; then
        actual="$(sha256sum "$archive" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
    else
        die "sha256sum or shasum is required to verify $(basename "$archive")"
    fi
    [ "$actual" = "$PLAIN_SHA256" ] || die "$(basename "$archive") SHA-256 mismatch (got $actual)"
}

# A payload is only usable if the provisioning actually landed in it — the app
# imports this archive as its build environment, so a half-provisioned one would
# fail on the device with nothing to explain it.
verify_payload() {
    local archive="$1" member
    verify_archive "$archive"
    member="$(tar -tzf "$archive" | grep -E "/usr/local/share/xforge/payload-manifest\.txt$" | head -1 || true)"
    [ -n "$member" ] || die "$(basename "$archive") has no payload manifest — it was not built by build-rootfs-payload.sh"
    for path in usr/local/bin/swift usr/local/bin/xtool usr/local/share/xforge/glibc.env; do
        tar -tzf "$archive" | grep -qE "(^|/)$path$" || die "$(basename "$archive") is missing $path"
    done
    tar -tzf "$archive" | grep -qE "(^|/)swiftly/toolchains/" || die "$(basename "$archive") has no Swift toolchain"
    echo "$member"
}

resolve_payload_url() {
    local api="https://api.github.com/repos/$REPOSITORY/releases?per_page=50" auth=()
    [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ] && auth=(-H "Authorization: Bearer ${GH_TOKEN:-${GITHUB_TOKEN}}")
    curl -fsSL "${auth[@]}" -H 'Accept: application/vnd.github+json' "$api" \
        | python3 -c '
import json, sys
prefix, asset = sys.argv[1], sys.argv[2]
for release in json.load(sys.stdin):
    if not release.get("tag_name", "").startswith(prefix):
        continue
    for a in release.get("assets", []):
        if a.get("name") == asset:
            print(a["browser_download_url"]); raise SystemExit
' "$PAYLOAD_TAG_PREFIX" "$PAYLOAD_NAME" 2>/dev/null || true
}

install_payload() {
    local source="$1"
    local target="$DEST/$PAYLOAD_NAME"
    local member

    if [ "$source" != "$target" ]; then
        log "Installing $(basename "$source") into $DEST"
        cp -f "$source" "$target.partial"
        mv "$target.partial" "$target"
    fi
    member="$(verify_payload "$target")"
    note "verified: $(du -h "$target" | cut -f1), provisioning recorded at ${member#./}"
    discard "$BASE_NAME.tar.gz"
    echo "$target"
}

install_plain() {
    local target="$DEST/$BASE_NAME.tar.gz"
    if [ -f "$target" ] && verify_plain_checksum "$target" && tar -tzf "$target" >/dev/null 2>&1; then
        log "$BASE_NAME.tar.gz already present and valid ($(du -h "$target" | cut -f1))"
    else
        log "Fetching $BASE_NAME.tar.gz"
        note "$PLAIN_URL"
        curl -fL --retry 3 --retry-delay 2 "$PLAIN_URL" -o "$target.partial"
        verify_plain_checksum "$target.partial"
        verify_archive "$target.partial" || { rm -f "$target.partial"; die "downloaded file is not a valid .tar.gz"; }
        mv "$target.partial" "$target"
        note "verified $(du -h "$target" | cut -f1)"
    fi
    discard "$PAYLOAD_NAME"
    echo "$target"
}

# ---------------------------------------------------------------------------
# Choose a flavour
# ---------------------------------------------------------------------------
if [ "$MODE" = "payload" ]; then
    if [ -n "${XFORGE_ROOTFS_ARCHIVE:-}" ]; then
        [ -f "$XFORGE_ROOTFS_ARCHIVE" ] || die "XFORGE_ROOTFS_ARCHIVE=$XFORGE_ROOTFS_ARCHIVE does not exist"
        install_payload "$XFORGE_ROOTFS_ARCHIVE"
        exit 0
    fi
    if [ -f "$DEST/$PAYLOAD_NAME" ]; then
        install_payload "$DEST/$PAYLOAD_NAME"
        exit 0
    fi
    url="${XFORGE_PAYLOAD_URL:-$(resolve_payload_url)}"
    [ -n "$url" ] || die "no $PAYLOAD_NAME in any $PAYLOAD_TAG_PREFIX* release of $REPOSITORY — build it with build-rootfs-payload.sh, or pass XFORGE_ROOTFS_ARCHIVE"
    log "Downloading the provisioned rootfs payload"
    note "$url"
    curl -fL --retry 3 --retry-delay 2 "$url" -o "$DEST/$PAYLOAD_NAME.partial"
    mv "$DEST/$PAYLOAD_NAME.partial" "$DEST/$PAYLOAD_NAME"
    install_payload "$DEST/$PAYLOAD_NAME"
    exit 0
fi

if [ "$MODE" = "plain" ]; then
    install_plain
    exit 0
fi

[ "$MODE" = "auto" ] || die "XFORGE_ROOTFS must be auto, payload or plain (got '$MODE')"

# auto: prefer the provisioned payload — an app that ships it needs no in-guest
# install at all — but stay buildable when no payload has been published yet.
if [ -f "$DEST/$PAYLOAD_NAME" ]; then
    install_payload "$DEST/$PAYLOAD_NAME"
else
    url="$(resolve_payload_url)"
    if [ -n "$url" ]; then
        log "Downloading the provisioned rootfs payload"
        note "$url"
        if curl -fL --retry 3 --retry-delay 2 "$url" -o "$DEST/$PAYLOAD_NAME.partial"; then
            mv "$DEST/$PAYLOAD_NAME.partial" "$DEST/$PAYLOAD_NAME"
            install_payload "$DEST/$PAYLOAD_NAME"
        else
            rm -f "$DEST/$PAYLOAD_NAME.partial"
            note "download failed — falling back to the plain rootfs"
            install_plain
        fi
    else
        note "no published payload found — falling back to the plain rootfs"
        install_plain
    fi
fi
