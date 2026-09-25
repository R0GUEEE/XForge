#!/usr/bin/env bash
set -euo pipefail

# usage: install-bundle.sh <archive.tar.gz>
#        install-bundle.sh --release [tag]
#        install-bundle.sh --release artifact      # newest workflow artifact
#
# The bundle is built by the `Native iOS Toolchain` workflow, which publishes it as
# a release asset whose tag names its contents (`toolchain-<llvm>-swift-<ref>-ios…`).
# `--release` fetches that asset, so a machine that has never run the workflow — or
# came to it after the workflow artifact expired — can still install the compiler.
# With no tag, the newest published `toolchain-*` release is installed.

REPO="${XFORGE_REPO:-R0GUEEE/XForge}"
ASSET="XForgeNativeToolchain-arm64-ios.tar.gz"
ARTIFACT_NAME="XForgeNativeToolchain-arm64-ios"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/NativeToolchain"

TMP=""
# `if` rather than `[ … ] && …`: a false test would leave the trap returning
# non-zero, which is not something to have running at exit.
cleanup() { if [ -n "$TMP" ]; then rm -rf "$TMP"; fi; }
trap cleanup EXIT

usage() {
  cat >&2 <<EOF
usage: $0 <archive.tar.gz>
       $0 --release [tag]
       $0 --release artifact

  --release [tag]   fetch a published toolchain release asset (default: newest)
  artifact          the newest workflow artifact instead (needs the GitHub CLI)
EOF
}

have_gh() { command -v gh >/dev/null 2>&1; }

# The newest `toolchain-*` release. `gh release list` is newest-first; without the
# CLI this asks the API directly, which is rate-limited for anonymous callers but
# fine for the one-off case this is for.
api() {
  # A token is only used when one happens to be in the environment: it is what makes
  # this work against a private fork, and it raises the API's rate limit otherwise.
  local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [ -n "$token" ]; then
    curl -fsSL -H "Authorization: Bearer $token" "$1"
  else
    curl -fsSL "$1"
  fi
}

newest_tag() {
  if have_gh; then
    gh release list --repo "$REPO" --limit 100 --json tagName \
      --jq '[.[] | select(.tagName | startswith("toolchain-"))][0].tagName'
    return
  fi
  command -v python3 >/dev/null 2>&1 || {
    echo "error: need either the GitHub CLI or python3 to find the newest release" >&2
    exit 69
  }
  api "https://api.github.com/repos/$REPO/releases?per_page=100" \
    | python3 -c 'import json,sys
try:
    releases = json.load(sys.stdin)
except ValueError:
    releases = []
if not isinstance(releases, list):
    releases = []
print(next((r["tag_name"] for r in releases
            if isinstance(r, dict) and r.get("tag_name", "").startswith("toolchain-")), ""))'
}

case "${1:-}" in
  "")
    usage
    exit 64
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  --release)
    TAG="${2:-}"
    TMP="$(mktemp -d)"

    if [ "$TAG" = "artifact" ]; then
      have_gh || { echo "error: --release artifact needs the GitHub CLI" >&2; exit 69; }
      gh run download --repo "$REPO" --name "$ARTIFACT_NAME" --dir "$TMP"
    else
      if [ -z "$TAG" ]; then
        TAG="$(newest_tag)"
      fi
      [ -n "$TAG" ] && [ "$TAG" != "null" ] || {
        echo "error: no published toolchain release in $REPO" >&2
        echo "       run the 'Native iOS Toolchain' workflow by hand, with_swift=true" >&2
        exit 66
      }
      echo "installing toolchain bundle from release $TAG"
      if have_gh; then
        gh release download "$TAG" --repo "$REPO" \
          --pattern "XForgeNativeToolchain-*.tar.gz" --dir "$TMP" || {
          echo "error: no $ASSET asset in release $TAG of $REPO" >&2
          exit 66
        }
      else
        curl -fSL --retry 3 -o "$TMP/$ASSET" \
          "https://github.com/$REPO/releases/download/$TAG/$ASSET" || {
          echo "error: no $ASSET asset in release $TAG of $REPO" >&2
          exit 66
        }
      fi
    fi
    ARCHIVE="$TMP/$ASSET"
    ;;
  -*)
    usage
    exit 64
    ;;
  *)
    ARCHIVE="$1"
    ;;
esac

[ -f "$ARCHIVE" ] || { echo "error: archive not found: $ARCHIVE" >&2; exit 66; }

rm -rf "$DEST"
mkdir -p "$DEST"
tar -xzf "$ARCHIVE" -C "$DEST"

for required in manifest.txt include include-generated lib; do
  [ -e "$DEST/$required" ] || {
    echo "error: native toolchain bundle is missing $required" >&2
    rm -rf "$DEST"
    exit 65
  }
done

bash "$ROOT/NativeToolchain/prepare-xcode.sh"
echo "Installed native toolchain:"
cat "$DEST/manifest.txt"
