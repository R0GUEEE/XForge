#!/bin/bash
#
# fetch-rootfs.sh — put the pinned Alpine rootfs where the app target bundles it.
#
# The guest root is a release asset, not a committed file: `alpine-rootfs.zip` is
# ~165 MB of already-converted fakefs, published by the rootfs workflow, and
# `.github/workflows/build-ipa.yml` pins the tag it was built from (`ROOTFS_TAG`).
# It has to be in place *before* the Xcode project is generated — the app target
# lists it as a resource, and a build phase cannot add a file to a resource list
# that was fixed when XcodeGen walked the directory.
#
# Anything that builds this repo therefore needs this step before XcodeGen (or
# before opening the project in Xcode):
#
#     EmbeddedLinux/fetch-rootfs.sh
#
# The workflow that publishes the IPA uses the same script, so there is one
# implementation of "which rootfs, verified how".
#
# Environment:
#     XFORGE_ROOTFS_TAG        override the pinned tag (default: ROOTFS_TAG in
#                              .github/workflows/build-ipa.yml)
#     XFORGE_ROOTFS_FORCE=1    re-download even if the file is already there
#     XFORGE_ROOTFS_DIR        where it lands (default: <repo>/Support/Resources)
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
DEST="${XFORGE_ROOTFS_DIR:-$REPO/Support/Resources}"
ASSET="alpine-rootfs.zip"

log()  { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\nerror: %s\n' "$*" >&2; exit 1; }

# The pinned tag lives in the IPA workflow, which is where someone upgrading the
# root changes it. Reading it from there keeps this from becoming a second place
# that has to be edited in step.
TAG="${XFORGE_ROOTFS_TAG:-$(sed -n 's/^[[:space:]]*ROOTFS_TAG:[[:space:]]*//p' \
    "$REPO/.github/workflows/build-ipa.yml" | head -1)}"
[ -n "$TAG" ] || die "could not read ROOTFS_TAG from .github/workflows/build-ipa.yml
       (set XFORGE_ROOTFS_TAG to name the release yourself)"
# Which repository publishes the rootfs: this one. Ask git, so a fork fetches its
# own — and *not* `.gitmodules`, whose first entry is the engine (that mistake
# resolved the engine's URL and 404ed). A tarball export has no remote, so fall back
# to the app's release repository; keep in step with XForgeReleases.repository.
SLUG="$(git -C "$REPO" config --get remote.origin.url 2>/dev/null \
    | sed -e 's|^.*github\.com[:/]||' -e 's|\.git$||')"
[ -n "$SLUG" ] || SLUG="R0GUEEE/XForge"

mkdir -p "$DEST"
TARGET="$DEST/$ASSET"

if [ -f "$TARGET" ] && [ "${XFORGE_ROOTFS_FORCE:-0}" != "1" ]; then
    log "The pinned rootfs is already staged"
    note "$TARGET ($(du -h "$TARGET" | cut -f1))"
    exit 0
fi

log "Fetching the pinned Alpine rootfs: $TAG"
note "into $TARGET"

# `gh` when it is installed *and* has a token, plain curl otherwise. These releases
# are public, so no credential is needed — and a `gh` with no token is not an error
# to report, it is a reason to use curl (which is how a pipeline that does not pass
# GH_TOKEN gets its rootfs; treating that as fatal is how this step failed once).
BASE="https://github.com/$SLUG/releases/download/$TAG"

if command -v gh >/dev/null 2>&1 \
   && { [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]; }; then
    note "using gh (a token is in the environment)"
    rm -f "$TARGET"
    if ! gh release download "$TAG" --repo "$SLUG" \
            --pattern "$ASSET" --pattern "$ASSET.sha256" \
            --dir "$DEST" --clobber; then
        note "gh could not fetch it — falling back to curl"
    fi
fi

if [ ! -f "$TARGET" ]; then
    # A half-downloaded asset must not survive a failure: the next run (or a human)
    # would find a plausible-looking file of the wrong size.
    trap 'rm -f "$TARGET.partial"' EXIT
    note "downloading $BASE/$ASSET"
    curl -fL --retry 3 --retry-delay 2 -o "$TARGET.partial" "$BASE/$ASSET" \
        || die "could not download $BASE/$ASSET"
    mv "$TARGET.partial" "$TARGET"
    curl -fL --retry 3 -o "$DEST/$ASSET.sha256" "$BASE/$ASSET.sha256" 2>/dev/null || true
fi

[ -f "$TARGET" ] || die "$ASSET was not downloaded"

# The checksum is the point of pinning a tag: a re-uploaded or truncated asset has
# to fail here rather than inside the guest on someone's phone.
if [ -f "$TARGET.sha256" ]; then
    ( cd "$DEST" && shasum -a 256 -c "$ASSET.sha256" >/dev/null 2>&1 ) \
        || die "the downloaded $ASSET does not match its published sha256"
    note "sha256 verified"
else
    note "warning: no .sha256 beside the asset — not verified"
fi

# And it has to be the *shape* the app unpacks: a fakefs ZIP, not a tarball.
command -v unzip >/dev/null 2>&1 || { note "$ASSET ($(du -h "$TARGET" | cut -f1)), not inspected"; exit 0; }
unzip -Z1 "$TARGET" > /tmp/xforge-rootfs-entries.txt
for entry in "alpine-rootfs/data/" "alpine-rootfs/meta.db"; do
    grep -qx "$entry" /tmp/xforge-rootfs-entries.txt \
        || die "$TARGET has no $entry — that is not a fakefs root"
done
rm -f /tmp/xforge-rootfs-entries.txt

log "Rootfs staged"
note "$TARGET ($(du -h "$TARGET" | cut -f1))"
