#!/bin/bash
#
# test-payload-sizing.sh — the payload builder must never die measuring sizes.
#
# Regression test for a real CI failure: `ROOTFS_SIZE_BEFORE_KIB="$(du -skx … |
# awk …)"` aborted the payload build under `set -euo pipefail`. `-x` stops du
# *descending* into another filesystem, but du still walks the entries of the
# bind-mounted /proc inside the chroot, and /proc/<pid> (plus
# /proc/<pid>/task/<tid>/fd/*) disappears as the process it describes exits — so
# du exits 1 with `cannot access …`, and the assignment killed a build whose
# toolchain had already been provisioned and verified.
#
# The test runs the shipped helper against a rootfs with a real /proc bind mount
# and asserts it returns a number instead of aborting.
#
# Usage: bash Tools/test-payload-sizing.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SCRIPT="$REPO/EmbeddedLinux/build-rootfs-payload.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$*"; }

[ -f "$SCRIPT" ] || fail "cannot find $SCRIPT"

WORK="$(mktemp -d)"
cleanup() { umount -l "$WORK/rootfs/proc" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

ROOTFS="$WORK/rootfs"
mkdir -p "$ROOTFS"/proc "$ROOTFS"/usr/share/doc "$ROOTFS"/data
printf 'x' > "$ROOTFS"/data/file
printf 'doc' > "$ROOTFS"/usr/share/doc/readme

# 1. The helper must exist in the script.
grep -q '^rootfs_size_kib() {' "$SCRIPT" \
    || fail "build-rootfs-payload.sh has no rootfs_size_kib() helper"

# 2. Extract and source it, so the test exercises the shipped implementation.
sed -n '/^rootfs_size_kib() {/,/^}/p' "$SCRIPT" > "$WORK/helper.sh"
grep -q 'rootfs_size_kib' "$WORK/helper.sh" || fail "could not extract the helper"
# shellcheck disable=SC1090
. "$WORK/helper.sh"
command -v rootfs_size_kib >/dev/null || fail "rootfs_size_kib is not a function"

# 3. With /proc mounted — the condition that broke CI — it must still return a
#    number and not abort the caller.
if mount -t proc none "$ROOTFS"/proc 2>/dev/null; then
    with_proc="mounted"
else
    with_proc="unavailable"
    printf 'skip: could not bind-mount /proc (need root); testing unmounted\n'
fi

ROOTFS_SIZE_BEFORE_KIB="$(rootfs_size_kib)"
case "$ROOTFS_SIZE_BEFORE_KIB" in
    ''|*[!0-9]*) fail "helper returned '$ROOTFS_SIZE_BEFORE_KIB' with /proc $with_proc" ;;
esac
[ "$ROOTFS_SIZE_BEFORE_KIB" -gt 0 ] \
    || fail "helper returned $ROOTFS_SIZE_BEFORE_KIB (expected > 0) with /proc $with_proc"
pass "helper returned ${ROOTFS_SIZE_BEFORE_KIB} KiB with /proc $with_proc"

ROOTFS_SIZE_AFTER_KIB="$(rootfs_size_kib)"
ROOTFS_SAVED_KIB="$((ROOTFS_SIZE_BEFORE_KIB - ROOTFS_SIZE_AFTER_KIB))"
pass "the manifest arithmetic still works (saved ${ROOTFS_SAVED_KIB} KiB)"

# 4. Guard the shape of the bug, not just its symptom: no unguarded `du` may sit
#    inside a command substitution in this script, because under `set -e` the
#    first inaccessible entry aborts the build.
if grep -nE '^\s*[A-Z_]+="\$\(du ' "$SCRIPT" >/dev/null; then
    fail "an unguarded \$(du …) assignment is back in build-rootfs-payload.sh:"
    grep -nE '^\s*[A-Z_]+="\$\(du ' "$SCRIPT" >&2
fi
pass "no unguarded \$(du …) assignment in the payload builder"

# 5. And prove the control: the old form really does abort under set -e, so the
#    test is actually testing something.
if bash -c 'set -euo pipefail
X="$(du -skx /definitely-missing-path-xforge-test | awk "{print \$1}")"
echo reached' >/dev/null 2>&1; then
    fail "the old \$(du …) form did not abort — the test proves nothing"
fi
pass "the old \$(du …) form aborts under set -e, as it did in CI"

# 6. shellcheck must not object to the extraction either.
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -S error "$SCRIPT" >"$WORK/sc.log" 2>&1; then
        pass "shellcheck -S error is clean"
    else
        cat "$WORK/sc.log" >&2
        fail "shellcheck -S error reports problems"
    fi
else
    printf 'skip: shellcheck not installed\n'
fi

printf '\nAll payload sizing checks passed.\n'
