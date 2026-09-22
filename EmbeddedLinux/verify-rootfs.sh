#!/usr/bin/env bash
#
# verify-rootfs.sh — check that a built Alpine root actually boots the console
# XForge expects, and fails loudly if it does not.
#
# The rootfs is the one thing in this repo that cannot be exercised by the app's
# own tests: a root that is wrong looks exactly like a root that is right until
# `init` runs on a device, where the failure is a blank terminal. So the checks
# live here, and both callers use them:
#
#   * EmbeddedLinux/build-rootfs.sh runs it on the configured *tree*, before the
#     fakefs conversion, so a bad root fails the build that produced it;
#   * .github/workflows/build-rootfs.yml runs it on the packed *ZIP*, so the
#     artifact that is actually published is the thing that was checked.
#
# What it checks, in order of how far the answer reaches:
#   1. the files init needs exist and are executable;
#   2. /etc/inittab starts exactly one console session, the guest's own;
#   3. /etc/passwd names the login shell the manifest promised;
#   4. the console program actually starts that shell — run in a chroot of the
#      root, the way init runs it, on the build machine.
#
# (4) is the one that matters, and it is why this runs where it does: it executes
# the guest's own binaries out of the tree, so the answer is about the root and
# not about this script's reading of it. It needs root (to chroot) and a host of
# the same architecture as the root (aarch64); without both, set
# XFORGE_VERIFY_SKIP_CONSOLE=1 to accept the file-level checks alone.
#
# Usage:
#     EmbeddedLinux/verify-rootfs.sh <alpine-rootfs.zip | rootfs-dir>
#
# Environment:
#     XFORGE_VERIFY_SKIP_CONSOLE  1 to skip the chroot run (see above)
#
set -euo pipefail

TARGET="${1:-dist/rootfs/alpine-rootfs.zip}"
ROOTFS_NAME="alpine-rootfs"
MANIFEST="usr/local/share/xforge/rootfs-manifest.txt"

log()  { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\nerror: %s\n' "$*" >&2; exit 1; }

[ -e "$TARGET" ] || die "$TARGET does not exist"

# ---------------------------------------------------------------------------
# Materialise the root as a tree to check.
#
# The ZIP case is unpacked rather than read entry by entry: the checks below are
# about a filesystem, and the shipped artifact is a filesystem — the point is to
# look at what a device will mount, not at what the archive claims.
# ---------------------------------------------------------------------------
if [ -d "$TARGET" ]; then
    TREE="$TARGET"
elif [ -f "$TARGET" ]; then
    command -v unzip >/dev/null 2>&1 || die "unzip is required to check the ZIP"
    # The published ZIP is a fakefs root, so the tree we want is `data/`.
    log "Checking the packed root: $TARGET"
    unzip -Z1 "$TARGET" > /tmp/xforge-verify-entries.txt
    for entry in "$ROOTFS_NAME/data/" "$ROOTFS_NAME/meta.db"; do
        grep -qx "$entry" /tmp/xforge-verify-entries.txt \
            || die "the ZIP has no $entry"
    done
    # SQLite's WAL/SHM sidecars are transient and must not be captured by the
    # pack — a stale `-wal` next to a fresh meta.db is a database that looks
    # corrupt to the guest.
    ! grep -qE '\.db-(wal|shm)$' /tmp/xforge-verify-entries.txt \
        || die "the ZIP contains SQLite WAL/SHM sidecars"
    UNPACK="$(mktemp -d "${TMPDIR:-/tmp}/xforge-verify.XXXXXX")"
    trap 'rm -rf "$UNPACK"' EXIT
    unzip -q "$TARGET" -d "$UNPACK"
    TREE="$UNPACK/$ROOTFS_NAME/data"
    note "meta:  $(du -h "$UNPACK/$ROOTFS_NAME/meta.db" | cut -f1)"
    note "data:  $(du -sh "$TREE" | cut -f1)"
else
    die "$TARGET is neither a directory nor a file"
fi

# Accept either the fakefs root (data/) or the plain tree it was made from.
[ -d "$TREE/data" ] && [ -x "$TREE/data/bin/sh" ] && TREE="$TREE/data"
[ -x "$TREE/bin/sh" ] || die "$TREE does not look like an Alpine root (no bin/sh)"

# ---------------------------------------------------------------------------
# 1. What init needs
# ---------------------------------------------------------------------------
log "Files"
REQUIRED="
sbin/init
bin/sh
sbin/xforge-login
etc/inittab
etc/init.d/rcS
etc/passwd
etc/shadow
etc/profile
etc/apk/repositories
$MANIFEST
root/install-toolchain.sh
"
for path in $REQUIRED; do
    [ -e "$TREE/$path" ] || die "the root has no /$path"
done
[ -x "$TREE/sbin/xforge-login" ] || die "/sbin/xforge-login is not executable"
note "$(printf '%s' "$REQUIRED" | wc -l | tr -d ' ') required paths present"

# The login shell the root promises, from the root's own manifest — not from this
# script, so a root built with a different XFORGE_DEFAULT_SHELL is checked against
# what it was built to be.
[ -f "$TREE/$MANIFEST" ] || die "the root has no manifest"
EXPECTED_SHELL="$(awk '/^[[:space:]]*shell:/ { print $2 }' "$TREE/$MANIFEST")"
[ -n "$EXPECTED_SHELL" ] || die "the manifest does not name a login shell"
[ -x "$TREE$EXPECTED_SHELL" ] || die "the manifest promises $EXPECTED_SHELL, which is not installed"
note "login shell in the manifest: $EXPECTED_SHELL"

# ---------------------------------------------------------------------------
# 2. The console
#
# One session, on the one terminal that exists, started by the guest's own
# program. The stock Alpine inittab fails all three: it starts openrc (not in
# this root) and respawns six gettys on terminals the engine does not provide.
# ---------------------------------------------------------------------------
log "inittab"
grep -qx '::sysinit:/etc/init.d/rcS' "$TREE/etc/inittab" \
    || die "inittab does not run the sysinit step"
grep -qx 'tty1::respawn:/sbin/xforge-login root' "$TREE/etc/inittab" \
    || die "inittab does not respawn /sbin/xforge-login root on tty1"
! grep -q 'openrc' "$TREE/etc/inittab" \
    || die "inittab starts openrc, which this root does not contain"
! grep -qE '^tty[2-6]::' "$TREE/etc/inittab" \
    || die "inittab respawns gettys on terminals this guest does not have"
note "pid 1 is /sbin/init; tty1 respawns /sbin/xforge-login root"

# ---------------------------------------------------------------------------
# 3. The shell that session will start
# ---------------------------------------------------------------------------
log "Root's shell"
PASSWD_ROOT="$(awk -F: '$1 == "root" { print; exit }' "$TREE/etc/passwd")"
[ -n "$PASSWD_ROOT" ] || die "there is no root in /etc/passwd"
PASSWD_SHELL="$(printf '%s\n' "$PASSWD_ROOT" | cut -d: -f7)"
[ "$PASSWD_SHELL" = "$EXPECTED_SHELL" ] || die \
    "root's shell in /etc/passwd is $PASSWD_SHELL, not the $EXPECTED_SHELL the manifest promises"
note "$PASSWD_ROOT"

# The shell session's terminal has to be one curses knows about. /etc/profile is
# where the root names it, and an unknown TERM is not an error anywhere — it just
# makes `less`, `top` and every full-screen program behave as if there were no
# terminal at all, which reads as a broken console rather than a missing package.
TERM_VALUE="$(sed -n 's/^export TERM=//p' "$TREE/etc/profile" | tail -1 | tr -d "'\"")"
if [ -n "$TERM_VALUE" ]; then
    ENTRY="${TERM_VALUE%${TERM_VALUE#?}}/$TERM_VALUE"
    FOUND_TERMINFO=""
    for dir in usr/share/terminfo etc/terminfo; do
        if [ -e "$TREE/$dir/$ENTRY" ]; then
            FOUND_TERMINFO="$dir/$ENTRY"
        fi
    done
    if [ -z "$FOUND_TERMINFO" ]; then
        die "TERM=$TERM_VALUE is exported but the root has no terminfo entry for
       it (looked for $ENTRY). Every curses program in the guest would run
       against an unknown terminal."
    fi
    note "TERM=$TERM_VALUE → $FOUND_TERMINFO"
fi

# ---------------------------------------------------------------------------
# 4. Run it
# ---------------------------------------------------------------------------
log "The console path"
if [ "${XFORGE_VERIFY_SKIP_CONSOLE:-0}" = "1" ]; then
    note "skipped (XFORGE_VERIFY_SKIP_CONSOLE=1)"
else
    [ "$(id -u)" -eq 0 ] || die "checking the console needs root (it chroots into
       the root). Re-run with sudo, or set XFORGE_VERIFY_SKIP_CONSOLE=1."
    HOST_ARCH="$(uname -m)"
    case "$HOST_ARCH" in
        aarch64|arm64) ;;
        *) die "this host is $HOST_ARCH and the root is aarch64, so its binaries
       cannot run here. Run this on an aarch64 machine, or set
       XFORGE_VERIFY_SKIP_CONSOLE=1 to check only the files." ;;
    esac

    # A working /dev/null is not optional: every shell opens it, and a chroot
    # without /dev is a chroot where commands fail for reasons that have nothing
    # to do with what is being checked.
    BOUND_DEV=""
    MOUNTED_PROC=""
    if ! grep -qs " $TREE/dev " /proc/mounts; then
        mount --bind /dev "$TREE/dev" 2>/dev/null && BOUND_DEV="$TREE/dev"
    fi
    if ! grep -qs " $TREE/proc " /proc/mounts; then
        mount -t proc none "$TREE/proc" 2>/dev/null && MOUNTED_PROC="$TREE/proc"
    fi
    cleanup_mounts() {
        [ -n "$MOUNTED_PROC" ] && umount -l "$MOUNTED_PROC" 2>/dev/null || true
        [ -n "$BOUND_DEV" ] && umount -l "$BOUND_DEV" 2>/dev/null || true
        return 0
    }
    trap 'cleanup_mounts; [ -n "${UNPACK:-}" ] && rm -rf "$UNPACK"' EXIT

    # Fed from a pipe, the way the build does it: the shell is non-interactive and
    # exits, so the session terminates on its own. What is being read is the part
    # that can silently be wrong — which shell runs, as a login shell (the leading
    # dash in $0), in which directory.
    CONSOLE_OUTPUT="$(printf 'echo XFORGE-CONSOLE-OK; echo "0=$0"; echo "SHELL=$SHELL"; pwd\n' \
        | chroot "$TREE" /sbin/xforge-login root 2>&1)" || true
    printf '%s\n' "$CONSOLE_OUTPUT" | sed 's/^/    /'

    case "$CONSOLE_OUTPUT" in
        *XFORGE-CONSOLE-OK*) ;;
        *) die "/sbin/xforge-login did not start a shell — the console would be blank" ;;
    esac
    case "$CONSOLE_OUTPUT" in
        *"0=-${EXPECTED_SHELL##*/}"*) ;;
        *) die "/sbin/xforge-login did not start $EXPECTED_SHELL as a login shell" ;;
    esac
    case "$CONSOLE_OUTPUT" in
        *"SHELL=$EXPECTED_SHELL"*) ;;
        *) die "the console session's SHELL is not $EXPECTED_SHELL" ;;
    esac
    case "$CONSOLE_OUTPUT" in
        *"not executable"*) die "/sbin/xforge-login fell back instead of running $EXPECTED_SHELL" ;;
    esac
    note "ok: /sbin/xforge-login root → $EXPECTED_SHELL, as a login shell"
    cleanup_mounts
fi

log "Done"
note "$TARGET checks out"
