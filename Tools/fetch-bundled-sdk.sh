#!/usr/bin/env bash
set -euo pipefail

# Put the Darwin SDK that will be bundled inside the XForge IPA into BundledSDK/.
#
#   Tools/fetch-bundled-sdk.sh                 # the pinned release, verified
#   Tools/fetch-bundled-sdk.sh darwin-sdk-8 --sha256 <hex>   # a different one
#
# The archive is Apple SDK content (headers, tbd stubs, the Swift runtime taken
# from Xcode), so it is checked against a recorded size and SHA-256 before it is
# accepted: the point of bundling is that the app installs an artifact it can name
# and verify, not "whatever the newest release happened to contain".
#
# Output, both gitignored:
#
#   BundledSDK/darwin.artifactbundle.zip   the release asset, byte-identical
#   BundledSDK/bundled-sdk.json           tag / source / size / sha256 manifest
#
# `project.yml` picks the folder up as a folder-reference resource, so `make ipa`
# and `.github/workflows/build-ipa.yml` produce an IPA that carries it. Run this
# from the repository root or anywhere — paths are resolved from the script.
#
# Reinstalling over an existing copy is fine: the download is verified first and
# only replaces the archive once it matches.

REPO="${XFORGE_REPO:-R0GUEEE/XForge}"
PINNED_TAG="darwin-sdk-7"
PINNED_ASSET="darwin.artifactbundle.zip"
# 456,769,875 bytes — measured from the published darwin-sdk-7 asset.
PINNED_BYTES="456769875"
PINNED_SHA256="b44165c16a5cebf13ae85af4d630f49b863e342b84f864b4dc1bbba5789d4d9b"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/BundledSDK"
ASSET="${DARWIN_SDK_ASSET:-$PINNED_ASSET}"
TAG=""
SHA=""
FILE=""
REUSE=0

usage() {
  cat >&2 <<EOF
usage: $0 [TAG] [--sha256 HEX] [--repo owner/name] [--asset NAME] [--out DIR]

  TAG            a darwin-sdk-* release tag (default: $PINNED_TAG, pinned)
  --sha256 HEX   SHA-256 of the asset; required when TAG is not the pinned one
  --file PATH    verify and bundle an archive already on disk instead of fetching
  --reuse        verify the file already in BundledSDK/ without copying it
  --repo         repository to fetch from (default: $REPO)
  --asset        asset name (default: $ASSET)
  --out          destination folder (default: <repo>/BundledSDK)

The environment variables DARWIN_SDK_TAG, DARWIN_SDK_SHA256, DARWIN_SDK_BYTES and
DARWIN_SDK_ASSET are honoured, which is how build-ipa.yml passes its pins through.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --sha256) SHA="${2:-}"; shift 2 ;;
    --file)   FILE="${2:-}"; shift 2 ;;
    --reuse)  REUSE=1; shift ;;
    --repo)   REPO="${2:-}"; shift 2 ;;
    --asset)  ASSET="${2:-}"; shift 2 ;;
    --out)    DEST="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown option $1" >&2; usage; exit 64 ;;
    *)  TAG="$1"; shift ;;
  esac
done

TAG="${TAG:-${DARWIN_SDK_TAG:-$PINNED_TAG}}"
if [ "$TAG" = "$PINNED_TAG" ]; then
  SHA="${SHA:-${DARWIN_SDK_SHA256:-$PINNED_SHA256}}"
  EXPECTED_BYTES="${DARWIN_SDK_BYTES:-$PINNED_BYTES}"
else
  SHA="${SHA:-${DARWIN_SDK_SHA256:-}}"
  EXPECTED_BYTES="${DARWIN_SDK_BYTES:-}"
fi

if [ -z "$SHA" ]; then
  echo "error: no SHA-256 known for $TAG; pass --sha256 <hex> (or DARWIN_SDK_SHA256)." >&2
  echo "       An unpinned SDK is not something this script will bundle." >&2
  exit 65
fi

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

mkdir -p "$DEST"
URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"
TMP="$DEST/.$ASSET.part"
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

echo "bundling $ASSET from $TAG ($REPO)"
if [ -n "$FILE" ]; then
  # Offline/air-gapped and cache hits still pass through the exact same digest and
  # metadata checks. --reuse avoids a second 456 MB copy when FILE is the destination.
  test -f "$FILE" || { echo "error: $FILE does not exist" >&2; exit 66; }
  if [ "$REUSE" = 1 ]; then
    [ "$FILE" = "$DEST/$ASSET" ] || {
      echo "error: --reuse requires --file to name the destination asset" >&2
      exit 64
    }
  else
    cp "$FILE" "$TMP"
    mv "$TMP" "$DEST/$ASSET"
  fi
elif command -v gh >/dev/null 2>&1 && [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]; then
  # The workflow's path: the authenticated CLI, scoped to the repository and the
  # exact asset name.
  gh release download "$TAG" --repo "$REPO" --pattern "$ASSET" --dir "$DEST" --clobber
else
  curl -fsSL --retry 3 --retry-delay 2 -o "$TMP" "$URL"
  mv "$TMP" "$DEST/$ASSET"
fi

if [ ! -f "$DEST/$ASSET" ]; then
  echo "error: $DEST/$ASSET was not downloaded" >&2
  exit 66
fi

bytes="$(wc -c < "$DEST/$ASSET" | tr -d '[:space:]')"
if [ -n "$EXPECTED_BYTES" ] && [ "$bytes" != "$EXPECTED_BYTES" ]; then
  rm -f "$DEST/$ASSET"
  echo "error: $ASSET is $bytes bytes, expected $EXPECTED_BYTES." >&2
  echo "       The release asset changed or the download was truncated; nothing was bundled." >&2
  exit 67
fi

digest="$(sha256_of "$DEST/$ASSET")"
if [ "$digest" != "$SHA" ]; then
  rm -f "$DEST/$ASSET"
  echo "error: $ASSET has sha256 $digest, expected $SHA." >&2
  echo "       Refusing to bundle an artifact that does not match the pin." >&2
  exit 67
fi

# Read the archive with Python rather than `unzip -p`: the bundle entry can sit
# at the root or under a wrapper directory, and the SDK metadata is the thing that
# says whether this is an iPhoneOS SDK at all.
python3 - "$DEST/$ASSET" "$DEST/bundled-sdk.json" "$TAG" "$ASSET" "$URL" "$digest" "$bytes" <<'PY'
import datetime
import json
import sys
import zipfile

archive, manifest_path, tag, asset, url, digest, size = sys.argv[1:8]

with zipfile.ZipFile(archive) as zf:
    names = zf.namelist()
    metadata = next((n for n in names if n.endswith("swift-sdk.json")), None)
    if metadata is None:
        sys.exit(f"error: {asset} contains no swift-sdk.json — not a darwin.artifactbundle")
    definition = json.loads(zf.read(metadata))
    if "arm64-apple-ios" not in definition.get("targetTriples", {}):
        sys.exit("error: the SDK defines no arm64-apple-ios target")
    marker = next((n for n in names if n.endswith("darwin-sdk-version.txt")), None)
    version = zf.read(marker).decode("utf-8", "replace").strip() if marker else None
    unpacked = sum(info.file_size for info in zf.infolist())

manifest = {
    "schemaVersion": 1,
    "releaseTag": tag,
    "assetName": asset,
    "sourceURL": url,
    "sha256": digest,
    "byteCount": int(size),
    "installedByteCount": unpacked,
    "sdkVersion": version,
    "license": "Apple SDK content from Xcode; redistribution is governed by Apple's "
               "license terms and has NOT been verified — see Docs/BUNDLED-SDK.md",
    "generatedAt": datetime.datetime.now(datetime.timezone.utc)
                          .replace(microsecond=0).isoformat().replace("+00:00", "Z"),
}
with open(manifest_path, "w") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")

print(f"  sdk version: {version or 'unknown'}")
print(f"  archive:     {int(size):,} bytes")
print(f"  unpacked:    {unpacked:,} bytes (uncompressed)")
print(f"  manifest:    {manifest_path}")
PY

echo "bundled $TAG into $DEST"
echo "note: this is Apple SDK content. Bundling and redistributing it is a licensing"
echo "      question that has not been verified here — see Docs/BUNDLED-SDK.md."
