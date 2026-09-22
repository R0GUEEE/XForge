#!/usr/bin/env bash
#
# verify-rootfs.sh — check that a built Alpine root actually boots the console
# XForge expects, and fails loudly if it does not.
#
# The rootfs is the one thing in this repo the app's tests cannot cover: a root
# that is wrong looks exactly like a root that is right until `init` runs on a
# device, where the failure is a blank terminal. So the checks live here, and both
# callers use them:
#
#   * EmbeddedLinux/build-rootfs.sh runs it on the configured *tree*, before the
#     fakefs conversion — where the guest's own binaries can be executed;
#   * .github/workflows/build-rootfs.yml runs it on the packed *ZIP*, so the
#     artifact that is actually published is the thing that was checked.
#
# It accepts three shapes of input and says which checks apply to each:
#
#   plain tree     the configured root before conversion. Everything runs,
#                  including starting the console in a chroot of it.
#   fakefs ZIP     what gets published: `alpine-rootfs/data/` plus `meta.db`. The
#   fakefs dir     ZIP is read entry by entry (nothing is unpacked).
#
# A fakefs root is a directory tree *and* a database, and the engine reads the
# database: a file can sit in data/ and be invisible to the guest. Two consequences
# shape this script, and both cost a failed build to learn:
#
#   * every path is also looked up in `paths`, and the mode that matters (is the
#     console program executable?) is the one in `stats` — fakefs writes its data
#     files 0666 and keeps the real mode in the database;
#   * a fakefs root cannot be chrooted at all, so the console cannot be *run*
#     from it. fakefs does not store symlinks as symlinks: an `AE_IFLNK` entry
#     becomes a regular file whose contents are the link target, and the engine
#     turns it back into a symlink from `meta.db` (see tools/fakefs.c). So
#     `data/bin/sh` is a text file reading "/bin/busybox" and
#     `data/lib/ld-musl-aarch64.so.1` is one reading "/lib/libc.musl-aarch64.so.1"
#     — a chroot into that tree has no loader and no shell. The execution check
#     therefore belongs to the tree, and the ZIP is checked through the same
#     database the guest will use.
#
# Usage:
#     EmbeddedLinux/verify-rootfs.sh <alpine-rootfs.zip | rootfs-dir>
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
# How to read the root.
#
# Everything below asks only two questions — "is this path there?" and "what does
# it say?" — and answers them per shape, so the shape is settled once, here.
# ---------------------------------------------------------------------------
MODE=""
TREE=""
ZIP=""
BASE=""
ENTRIES=""
META_DB=""          # what a path is relative to: "" for a tree, "<root>/data/" in a ZIP

if [ -d "$TARGET" ]; then
    if [ -f "$TARGET/meta.db" ] && [ -d "$TARGET/data" ]; then
        MODE="fakefs-dir"
        TREE="$TARGET/data"
        note "input: a fakefs root directory"
    elif [ -d "$TARGET/data" ] && [ -e "$TARGET/data/etc/passwd" ]; then
        MODE="tree"
        TREE="$TARGET/data"
        note "input: a plain root tree"
    else
        MODE="tree"
        TREE="$TARGET"
        note "input: a plain root tree"
    fi
elif [ -f "$TARGET" ]; then
    command -v unzip >/dev/null 2>&1 || die "unzip is required to read the ZIP"
    MODE="zip"
    ZIP="$TARGET"
    BASE="$ROOTFS_NAME/data/"
    note "input: a packed fakefs ZIP (read entry by entry, nothing unpacked)"
else
    die "$TARGET is neither a directory nor a file"
fi

# path_exists <root-relative path>
path_exists() {
    if [ "$MODE" = "zip" ]; then
        grep -qx "$BASE$1" "$ENTRIES"
    else
        [ -e "$TREE/$1" ]
    fi
}

# path_contents <root-relative path>
path_contents() {
    if [ "$MODE" = "zip" ]; then
        unzip -p "$ZIP" "$BASE$1"
    else
        cat "$TREE/$1"
    fi
}

# path_link_target <root-relative symlink path>
#
# In a tree this is a symlink and `readlink` is the answer; in fakefs the target is
# the file's contents. (Reading it as a file in tree mode would dump the target's
# binary, which is why this is not just `path_contents`.)
path_link_target() {
    if [ "$MODE" = "zip" ] || [ "$MODE" = "fakefs-dir" ]; then
        path_contents "$1"
    else
        readlink "$TREE/$1" || true
    fi
}

if [ "$MODE" = "zip" ]; then
    ENTRIES="$(mktemp)"              # the ZIP's entry list, read once
    META_DB="$(mktemp)"
    trap 'rm -f "$ENTRIES" "$META_DB"' EXIT
    unzip -Z1 "$ZIP" > "$ENTRIES"
    for entry in "$ROOTFS_NAME/data/" "$ROOTFS_NAME/meta.db"; do
        grep -qx "$entry" "$ENTRIES" || die "the ZIP has no $entry"
    done
    # SQLite's WAL/SHM sidecars are transient and must not be captured: a stale
    # `-wal` next to a fresh meta.db is a database that looks corrupt to the guest.
    ! grep -qE '\.db-(wal|shm)$' "$ENTRIES" \
        || die "the ZIP contains SQLite WAL/SHM sidecars"
    unzip -p "$ZIP" "$ROOTFS_NAME/meta.db" > "$META_DB"
    note "entries: $(wc -l < "$ENTRIES" | tr -d ' ')"
elif [ "$MODE" = "fakefs-dir" ]; then
    META_DB="$TARGET/meta.db"
fi

# ---------------------------------------------------------------------------
# 1. What init needs
# ---------------------------------------------------------------------------
log "Files"
for path in \
    sbin/init \
    bin/sh \
    sbin/xforge-login \
    etc/inittab \
    etc/init.d/rcS \
    etc/passwd \
    etc/shadow \
    etc/profile \
    etc/apk/repositories \
    "$MANIFEST" \
    root/install-toolchain.sh ; do
    path_exists "$path" || die "the root has no /$path"
done
note "11 required paths present"

if [ "$MODE" = "tree" ]; then
    # In a tree the modes are the files' own. In a fakefs root they are not (see
    # the header): that is what the meta.db section below checks.
    [ -x "$TREE/sbin/xforge-login" ] || die "/sbin/xforge-login is not executable"
    [ -x "$TREE/bin/sh" ] || die "/bin/sh is not executable"
    note "/sbin/xforge-login and /bin/sh are executable"
fi

# /bin/sh has to lead somewhere that exists, or nothing can start at all. It is a
# symlink to busybox in every Alpine root, and fakefs will have stored the target
# as text — either way, the target has to be in the root.
SH_TARGET="$(path_link_target bin/sh)"
case "$SH_TARGET" in
    /*) path_exists "${SH_TARGET#/}" \
            || die "/bin/sh points at $SH_TARGET, which is not in the root" ;;
    *)  die "/bin/sh is not where it should be: expected a symlink, got '${SH_TARGET:0:40}'" ;;
esac
note "/bin/sh → $SH_TARGET"

# The login shell the root promises, from the root's own manifest — not from this
# script, so a root built with a different XFORGE_DEFAULT_SHELL is checked against
# what it was built to be.
EXPECTED_SHELL="$(path_contents "$MANIFEST" | awk '/^[[:space:]]*shell:/ { print $2 }')"
[ -n "$EXPECTED_SHELL" ] || die "the manifest does not name a login shell"
path_exists "${EXPECTED_SHELL#/}" \
    || die "the manifest promises $EXPECTED_SHELL, which is not in the root"
note "login shell in the manifest: $EXPECTED_SHELL"

# The session's terminal has to be one curses knows about. /etc/profile is where
# the root names it, and an unknown TERM is an error nowhere — it just makes `less`,
# `top` and every full-screen program behave as if there were no terminal, which
# reads as a broken console rather than as a missing package.
TERM_VALUE="$(path_contents etc/profile | sed -n 's/^export TERM=//p' | tail -1 | tr -d "'\"")"
if [ -n "$TERM_VALUE" ]; then
    ENTRY="${TERM_VALUE%${TERM_VALUE#?}}/$TERM_VALUE"
    FOUND_TERMINFO=""
    for dir in usr/share/terminfo etc/terminfo; do
        if path_exists "$dir/$ENTRY"; then FOUND_TERMINFO="$dir/$ENTRY"; fi
    done
    if [ -z "$FOUND_TERMINFO" ]; then
        die "TERM=$TERM_VALUE is exported but the root has no terminfo entry for it
       (looked for $ENTRY). Every curses program in the guest would run against an
       unknown terminal."
    fi
    note "TERM=$TERM_VALUE → $FOUND_TERMINFO"
fi

# ---------------------------------------------------------------------------
# 2. The console
#
# One session, on the one terminal that exists, started by the guest's own program.
# The stock Alpine inittab fails all three: it starts openrc (not in this root) and
# respawns six gettys on terminals the engine does not provide.
# ---------------------------------------------------------------------------
log "inittab"
INITTAB="$(path_contents etc/inittab)"
grep_q() { printf '%s\n' "$INITTAB" | grep -q "$@"; }
grep_q -x '::sysinit:/etc/init.d/rcS' \
    || die "inittab does not run the sysinit step"
grep_q -x 'tty1::respawn:/sbin/xforge-login root' \
    || die "inittab does not respawn /sbin/xforge-login root on tty1"
if grep_q 'openrc'; then
    die "inittab starts openrc, which this root does not contain"
fi
if grep_q -E '^tty[2-6]::'; then
    die "inittab respawns gettys on terminals this guest does not have"
fi
note "pid 1 is /sbin/init; tty1 respawns /sbin/xforge-login root"

# ---------------------------------------------------------------------------
# 3. Root's shell, in the file the console program reads
# ---------------------------------------------------------------------------
log "Root's shell"
PASSWD_ROOT="$(path_contents etc/passwd | awk -F: '$1 == "root" { print; exit }')"
[ -n "$PASSWD_ROOT" ] || die "there is no root in /etc/passwd"
PASSWD_SHELL="$(printf '%s\n' "$PASSWD_ROOT" | cut -d: -f7)"
[ "$PASSWD_SHELL" = "$EXPECTED_SHELL" ] || die \
    "root's shell in /etc/passwd is $PASSWD_SHELL, not the $EXPECTED_SHELL the manifest promises"
note "$PASSWD_ROOT"

# ---------------------------------------------------------------------------
# 4. What the engine will resolve
#
# The tree is only half of a fakefs root; the other half is the database, and the
# paths above existing in data/ is not the same as the guest being able to see
# them. A root once shipped with 568 glibc files on disk and zero rows in `paths`
# for them, which the guest reads as "not there at all" — so everything the console
# needs is looked up here, along with the mode it will have.
# ---------------------------------------------------------------------------
if [ -n "$META_DB" ]; then
    log "meta.db"
    command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 is required to check a fakefs root"

    # `CAST(path AS TEXT)` is not decoration: fakefs stores paths as BLOB, and
    # comparing a BLOB against a string literal is version-dependent — the same
    # query that matched every row locally matched zero rows on an older SQLite, so
    # a correct root failed its own check.
    # fakefs stores paths in its normalized form, `( '/' path-component )*`:
    # "/bin/sh", not "bin/sh" and not "/bin/sh/" (see `path_normalize` in
    # tools/fakefs.c). The lookup is on that form, so this takes a root-relative
    # path and looks up its absolute spelling.
    indexed() {
        sqlite3 "$META_DB" \
            "SELECT COUNT(*) FROM paths WHERE CAST(path AS TEXT) = '/$1';"
    }
    for path in \
        bin/sh \
        sbin/xforge-login \
        etc/inittab \
        etc/passwd \
        etc/profile \
        "${EXPECTED_SHELL#/}" ; do
        [ "$(indexed "$path")" -gt 0 ] || die "/$path is in the tree but not indexed
       in meta.db — the guest would not see it. Anything the root needs has to be in
       place *before* the fakefs conversion."
    done
    note "6 console paths indexed in meta.db"

    # The mode the engine will apply, which is the one fakefs kept (its data files
    # are all written 0666). `stats.stat` is a binary `struct ish_stat` — mode, uid,
    # gid, rdev as four little-endian uint32s — so the mode is the first two bytes of
    # hex(), low byte first.
    mode_of() {
        local hex lo hi
        hex="$(sqlite3 "$META_DB" "SELECT hex(substr(stats.stat, 1, 2)) FROM paths
                 JOIN stats ON paths.inode = stats.inode
                 WHERE CAST(paths.path AS TEXT) = '/$1';")"
        [ -n "$hex" ] || return 1
        lo="${hex%??}"
        hi="${hex#??}"
        printf '%s' "$(( 0x${hi}${lo} ))"
    }
    for path in sbin/xforge-login "${EXPECTED_SHELL#/}"; do
        mode="$(mode_of "$path")" || die "/$path has no stats row in meta.db"
        # 8#111 is 0o111: any execute bit.
        [ "$(( mode & 8#111 ))" -ne 0 ] || die "/$path is not executable in
       meta.db (mode $(printf '%o' "$mode")) — the console would not start."
    done
    note "/sbin/xforge-login and $EXPECTED_SHELL are executable in meta.db"

    total="$(sqlite3 "$META_DB" 'SELECT COUNT(*) FROM paths;')"
    note "meta.db: $total paths"
fi

# ---------------------------------------------------------------------------
# 5. Run it — a tree only, and say plainly why it cannot be done otherwise
# ---------------------------------------------------------------------------
log "The console path"
if [ "$MODE" != "tree" ]; then
    note "not run here: a fakefs root cannot be chrooted (its symlinks are files"
    note "whose contents are the link target, and only the engine resolves them),"
    note "so this root's console was run for real on the tree by build-rootfs.sh,"
    note "before the conversion. The checks above are the database the guest reads."
    log "Done"
    note "$TARGET checks out (console run: on the tree, before conversion)"
    exit 0
fi

[ "$(id -u)" -eq 0 ] || die "checking the console needs root (it chroots into the
       root). Re-run with sudo, or set XFORGE_VERIFY_SKIP_CONSOLE=1."
case "$(uname -m)" in
    aarch64|arm64) ;;
    *) die "this host is $(uname -m) and the root is aarch64, so its binaries cannot
       run here. Run this on an aarch64 machine, or set XFORGE_VERIFY_SKIP_CONSOLE=1
       to check only the files." ;;
esac

if [ "${XFORGE_VERIFY_SKIP_CONSOLE:-0}" = "1" ]; then
    note "skipped (XFORGE_VERIFY_SKIP_CONSOLE=1)"
    log "Done"
    note "$TARGET checks out"
    exit 0
fi

# A working /dev/null is not optional: every shell opens it, and a chroot without
# /dev is a chroot where commands fail for reasons that have nothing to do with what
# is being checked.
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
trap 'cleanup_mounts' EXIT

# Fed from a pipe, not a terminal: the shell is non-interactive and exits, so the
# session ends on its own. What is being read is the part that can silently be
# wrong — which shell runs, as a login shell (the leading dash in $0), in which
# directory, and with which environment.
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

log "Done"
note "$TARGET checks out"
