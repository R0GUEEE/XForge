#!/usr/bin/env bash
#
# apply-engine-patches.sh — apply XForge's local fixes to the vendored iSH-AOK
# checkout.
#
# The engine is a pinned git submodule, so a fix upstream does not have (yet)
# lives here as a script that edits the checkout in place: the pin stays
# upstream's commit, the fix travels with XForge, and rebasing the submodule does
# not quietly drop it. Each script is idempotent and fails loudly when it cannot
# find the code it means to change, rather than producing a subtly wrong kernel.
#
# Both the iOS core build and the engine-smoke harness run this, so the harness
# tests the engine the app actually ships.
#
# Usage: EmbeddedLinux/apply-engine-patches.sh [ish-AOK-checkout]
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ISH="${1:-${ISH_AOK_ROOT:-$HERE/../Vendor/ish-AOK}}"

if [ ! -d "$ISH/kernel" ]; then
    echo "error: no iSH-AOK checkout at $ISH" >&2
    echo "       run: git submodule update --init --depth 1 Vendor/ish-AOK" >&2
    exit 1
fi

for patch in "$HERE"/patches/*.py; do
    [ -e "$patch" ] || continue
    printf '==> %s\n' "$(basename "$patch")"
    python3 "$patch" "$ISH"
done
