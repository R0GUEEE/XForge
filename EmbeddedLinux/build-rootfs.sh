#!/usr/bin/env bash
#
# build-rootfs.sh — build the Alpine aarch64 root filesystem that XForge boots,
# and pack it as a ZIP of an already-converted fakefs root.
#
# This follows OpenMinis's own recipe (deps/prepare_alpine_rootfs.sh in
# github.com/OpenMinis/OpenMinis), which is the reference implementation for
# this engine:
#
#   1. download the *plain* Alpine aarch64 minirootfs
#   2. build the engine's own `tools/fakefsify` for the build machine
#      (NOT cross-compiled: it runs here, on this host)
#   3. unpack it as a plain tree, install the glibc layer into it, and install the
#      packages the console session needs (bash/coreutils/less/terminfo)
#   4. configure the root in place (passwd, profile, motd, inittab, DNS, apk repos)
#      — including the console program, EmbeddedLinux/xforge-login
#   5. convert the configured tree to fakefs — a `data/` tree + `meta.db`
#   6. `zip -r` the result, excluding the SQLite WAL/SHM sidecars
#
# Why a ZIP of a fakefs and not a tarball the app imports at runtime: the
# conversion is the expensive part (thousands of files into SQLite), and doing it
# here means the app's first launch is a plain unzip — no multi-minute import on
# a phone. This is the same reason OpenMinis ships `alpine-rootfs.zip` and its
# app only calls unzip + mount_root.
#
# The root is deliberately SMALL: plain Alpine, no Swift toolchain, no xtool. The
# guest installs tooling itself on demand (EmbeddedLinux/install-toolchain.sh, run
# inside the guest), which is what keeps this under a size that can be stored and
# fetched cheaply. Baking a toolchain in made the payload ~1.4 GB. What the root
# does carry beyond plain Alpine is the shell session the app opens onto (see
# XFORGE_CONSOLE_PACKAGES below) — a few MB, and the difference between a console
# that works on first launch and one that has to be provisioned first.
#
# Output:
#     dist/rootfs/alpine-rootfs.zip        the root (data/ + meta.db)
#     dist/rootfs/alpine-rootfs.sha256     checksum, for pinning
#
# Usage:
#     EmbeddedLinux/build-rootfs.sh [output-dir]        # default: dist/rootfs
#
# Environment:
#     XFORGE_ALPINE_VERSION   Alpine release (default: 3.21, matching the
#                             reference; the engine is built for this guest)
#     XFORGE_ALPINE_MINOR     minor version (default: 0)
#     XFORGE_ISH_ROOT         engine checkout (default: <repo>/Vendor/ish-arm64)
#     XFORGE_WORK_DIR         scratch dir (default: <repo>/.rootfs-work)
#     XFORGE_KEEP_WORK        1 to keep the scratch dir
#     XFORGE_SKIP_GLIBC       1 to build a root without the glibc layer
#     XFORGE_DEFAULT_SHELL    login shell root's console starts (default:
#                             /bin/bash). Must be a shell the package list below
#                             installs; if it is not, the build falls back to
#                             /bin/sh and says so.
#     XFORGE_CONSOLE_PACKAGES Alpine packages baked into the root for the console
#                             session (default: bash coreutils less
#                             ncurses-terminfo). Space-separated.
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

# Resolve the output directory to an absolute path up front. Packing happens
# from inside the work directory (so the ZIP holds relative paths), and a
# relative OUT_DIR would then resolve against the wrong directory — which is
# exactly how a CI run failed with "Could not create output file" while the same
# script worked locally with an absolute path.
OUT_DIR="${1:-$REPO/dist/rootfs}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
ALPINE_VERSION="${XFORGE_ALPINE_VERSION:-3.21}"
ALPINE_MINOR="${XFORGE_ALPINE_MINOR:-0}"
ALPINE_ARCH="aarch64"
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
ISH="${XFORGE_ISH_ROOT:-$REPO/Vendor/ish-arm64}"
WORK="${XFORGE_WORK_DIR:-$REPO/.rootfs-work}"

# The guest's console session, and what it needs from the root.
#
# XFORGE_DEFAULT_SHELL is the shell root's console starts in: it is written into
# /etc/passwd, and /etc/inittab runs xforge-login, which reads that field — so
# this is the one place the shell is chosen, and the guest can change it at
# runtime (`apk add zsh` + the passwd field).
#
# The package list is the shell's own environment, and every entry earns its
# place:
#   bash                  the default shell (pulls readline, ncurses-libs)
#   coreutils             the tools a shell session expects to exist
#   less                  a pager for them
#   ncurses-terminfo      terminfo entries — xterm/xterm-256color are NOT in
#                         ncurses-terminfo-base, and /etc/profile exports
#                         TERM=xterm-256color, so without this every curses
#                         program (less, top, vim) runs against an unknown
#                         terminal
DEFAULT_SHELL="${XFORGE_DEFAULT_SHELL:-/bin/bash}"
CONSOLE_PACKAGES="${XFORGE_CONSOLE_PACKAGES:-bash coreutils less ncurses-terminfo}"

ROOTFS_NAME="alpine-rootfs"
ZIP_NAME="$ROOTFS_NAME.zip"

log()  { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\nerror: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Running things *inside* the root being built
#
# Two steps need this: installing the glibc layer (step 4) and installing the
# guest's own packages (step 5). Both run the guest's own apk in a chroot of the
# tree, which needs the kernel's /proc and a /dev with a working /dev/null — apk
# opens it, and so does every shell — plus /etc/resolv.conf, because the
# minirootfs ships no nameservers at all and every one of those commands
# downloads something.
#
# The mounts are recorded so the exit trap can undo them: a failed build must not
# leave a mount behind, or the next run's `rm -rf $WORK` walks into a live /proc.
# ---------------------------------------------------------------------------
GUEST_MOUNTS=""

guest_mount() {
    [ "$(id -u)" -eq 0 ] || die "building the root needs root: the guest's own
       installer and apk are run in a chroot of the tree being built, and a chroot
       needs mounts. Re-run with sudo."

    mount -t proc none "$DATA/proc" || die "could not mount /proc in $DATA"
    GUEST_MOUNTS="$DATA/proc"
    mount --rbind /dev "$DATA/dev" 2>/dev/null || true
    GUEST_MOUNTS="$DATA/dev $GUEST_MOUNTS"
    mount --rbind /sys "$DATA/sys" 2>/dev/null || true
    GUEST_MOUNTS="$DATA/sys $GUEST_MOUNTS"

    # Name resolution for anything the chroot runs: the minirootfs ships no
    # nameservers at all, and both steps below download (apk indexes, packages).
    #
    # Written with awk rather than `grep … | sed …`, and with the fallback keyed on
    # the *result* rather than on the host file's contents: a pipeline whose output
    # is redirected leaves an empty file behind if it produces nothing, and a
    # truncated /etc/resolv.conf inside the chroot turns a network failure into a
    # name-resolution failure three steps away. (Seen for real: iSH wedged the
    # pipeline and the root being built got a 0-byte resolv.conf.)
    awk '/^nameserver/ { print; if (++n == 3) exit }' /etc/resolv.conf \
        > "$DATA/etc/resolv.conf" 2>/dev/null || true
    if ! [ -s "$DATA/etc/resolv.conf" ]; then
        printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$DATA/etc/resolv.conf"
    fi
}

guest_umount() {
    for m in $GUEST_MOUNTS; do
        umount -l "$m" 2>/dev/null || true
    done
    GUEST_MOUNTS=""
}

cleanup() {
    local status=$?
    guest_umount
    if [ "$status" -ne 0 ]; then
        printf '\nFailed (exit %d). Work directory kept at %s\n' "$status" "$WORK" >&2
    elif [ "${XFORGE_KEEP_WORK:-0}" != "1" ]; then
        rm -rf "$WORK"
    fi
    return $status
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
[ -f "$ISH/meson.build" ] || die "the engine is not checked out at $ISH
       run: git submodule update --init --depth 1 Vendor/ish-arm64"

# fakefsify needs libarchive; it is a submodule of the engine.
[ -d "$ISH/deps/libarchive" ] && [ -n "$(ls -A "$ISH/deps/libarchive" 2>/dev/null)" ] || die \
    "the engine's deps/libarchive submodule is missing (fakefsify needs it)
       run: git -C Vendor/ish-arm64 submodule update --init --depth 1 deps/libarchive"

for tool in curl meson ninja python3 zip; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done

mkdir -p "$WORK"

# ---------------------------------------------------------------------------
# 1. Download the plain minirootfs
# ---------------------------------------------------------------------------
ROOTFS_FILE="alpine-minirootfs-${ALPINE_VERSION}.${ALPINE_MINOR}-${ALPINE_ARCH}.tar.gz"
ROOTFS_PATH="$WORK/$ROOTFS_FILE"
ROOTFS_URL="$ALPINE_MIRROR/v${ALPINE_VERSION}/releases/${ALPINE_ARCH}/${ROOTFS_FILE}"

log "Fetching $ROOTFS_FILE"
if [ -f "$ROOTFS_PATH" ] && tar -tzf "$ROOTFS_PATH" >/dev/null 2>&1; then
    note "using the cached copy"
else
    curl -fL --retry 3 --retry-delay 2 -o "$ROOTFS_PATH.partial" "$ROOTFS_URL"
    mv "$ROOTFS_PATH.partial" "$ROOTFS_PATH"
fi
tar -tzf "$ROOTFS_PATH" >/dev/null || die "$ROOTFS_FILE is not a readable .tar.gz"
note "$ROOTFS_FILE: $(du -h "$ROOTFS_PATH" | cut -f1)"

# ---------------------------------------------------------------------------
# 2. Build fakefsify for the build machine
#
# A *native* build, deliberately: this tool only ever runs here, never on a
# device, and it is what converts the tarball into fakefs. Note the absent
# `-Db_ndebug` — unlike the device build, asserts stay ENABLED, so a broken
# assumption fails loudly at build time instead of quietly producing a wrong
# rootfs.
# ---------------------------------------------------------------------------
FAKEFSIFY_BUILD="$WORK/build-native"
FAKEFSIFY="$FAKEFSIFY_BUILD/tools/fakefsify"

log "Building tools/fakefsify for this machine"
if [ -x "$FAKEFSIFY" ]; then
    note "already built"
else
    if [ ! -f "$FAKEFSIFY_BUILD/build.ninja" ]; then
        meson setup "$FAKEFSIFY_BUILD" "$ISH" \
            --buildtype=release \
            -Dlog='' \
            -Dkernel=ish \
            -Dengine=asbestos \
            -Dguest_arch=arm64
    fi
    ninja -C "$FAKEFSIFY_BUILD" tools/fakefsify
fi
[ -x "$FAKEFSIFY" ] || die "fakefsify was not produced at $FAKEFSIFY"
note "$FAKEFSIFY"

# ---------------------------------------------------------------------------
# 3. Unpack the plain rootfs we will shape
#
# Everything happens on this tree — configuration and the glibc layer both —
# and it is converted to fakefs exactly once, at the end. That ordering is not
# cosmetic: `fakefsify` builds `meta.db` as an index of the files present when
# it runs, and the engine reads *the database*, not the directory. Files copied
# into `data/` after conversion exist on disk and are invisible in the guest —
# a first attempt installed the glibc layer that way and the layer did not exist
# as far as the engine was concerned (568 files on disk, 0 rows in meta.db).
# ---------------------------------------------------------------------------
DATA="$WORK/rootfs-tree"

log "Unpacking $ROOTFS_FILE into the root tree"
rm -rf "$DATA"
mkdir -p "$DATA"
tar -xzf "$ROOTFS_PATH" -C "$DATA"
[ -x "$DATA/bin/sh" ] || die "the unpacked root has no /bin/sh"

# Mount points the guest expects. The engine mounts /proc and /dev/pts itself;
# these directories have to exist first.
for dir in dev proc sys tmp run root home; do
    mkdir -p "$DATA/$dir"
done

# ---------------------------------------------------------------------------
# 4. Install the glibc compatibility layer
#
# Alpine is musl-based, but every tool XForge builds with is a *glibc* binary:
# xtool is a Swift program built on Ubuntu, and the Swift toolchain is too.
# `gcompat` is not enough for them (they die on strptime_l, fts_*, fcntl64 …), so
# the layer takes Ubuntu's own glibc and its libraries and points the loader at
# them.
#
# Baking it in rather than letting the guest install it removes the most
# failure-prone step of an on-device provision: a package renamed between Ubuntu
# releases produces a layer that loads but cannot resolve a symbol, which
# surfaces much later as a tool dying on an undefined symbol. It costs ~95 MB
# compressed, so the root stays small.
#
# This runs the *same* `install-toolchain.sh glibc` step the guest would run, in
# a chroot of this very tree, so there is only ever one implementation of the
# layer. The chroot is what makes it work: the step unpacks Ubuntu packages with
# `ar`/`zstd` and writes to /lib, /usr/lib and /opt/glibc, and those paths have
# to mean the guest root.
# ---------------------------------------------------------------------------
if [ "${XFORGE_SKIP_GLIBC:-0}" = "1" ]; then
    log "Skipping the glibc layer (XFORGE_SKIP_GLIBC=1)"
else
    log "Installing the glibc compatibility layer (this is the slow part)"

    # The step runs the guest's installer in a chroot, which needs /proc, /dev and
    # DNS. guest_mount() sets those up (and refuses to run unless we are root:
    # otherwise this surfaces as "mount: must be superuser to use mount" from
    # somewhere in the middle of a long install).
    guest_mount

    # The Alpine-side prerequisites for the step itself (it fetches packages with
    # curl and unpacks them with ar/zstd), and its copy of the installer.
    install -m 0755 "$HERE/install-toolchain.sh" "$DATA/root/install-toolchain.sh"
    chroot "$DATA" /bin/sh -c \
        "apk add --no-cache curl tar xz zstd binutils ca-certificates" \
        || die "could not install the glibc step's own prerequisites in the chroot"

    chroot "$DATA" /bin/sh -c \
        "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root; \
         sh /root/install-toolchain.sh glibc" \
        || die "installing the glibc layer in the chroot failed"

    # The layer is only useful if the guest can resolve it, so check the entry
    # points a Swift or xtool binary loads rather than trusting the step's status.
    #
    # `-L` rather than `-e` on the symlinks, deliberately: they are absolute and
    # point into the *guest's* /opt/glibc, which does not exist on the build
    # machine, so `-e` (which follows the link) reports them missing here even
    # though they resolve perfectly inside the guest. What has to exist at build
    # time is the link itself.
    for required in \
        opt/glibc/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1 \
        usr/local/share/xforge/glibc.env; do
        [ -e "$DATA/$required" ] || die "the glibc layer is incomplete: $required is missing"
    done
    for link in lib/ld-linux-aarch64.so.1 lib/aarch64-linux-gnu usr/lib/aarch64-linux-gnu; do
        [ -L "$DATA/$link" ] || die "the glibc layer is not wired in: $link is missing"
    done

    guest_umount

    # The layer's own prerequisite packages are no longer needed: they were
    # installed to run the step, not to run the guest.
    chroot "$DATA" /bin/sh -c "apk del --no-cache zstd binutils" >/dev/null 2>&1 || true

    note "glibc layer installed at /opt/glibc"
fi

# ---------------------------------------------------------------------------
# 5. Install the guest's own packages
#
# The shell session XForge's Terminal *is* has dependencies, and they belong in
# the root rather than in an on-device install: the console is the first thing a
# new install shows, and a shell whose pager is missing (or whose TERM is unknown
# to curses) is a broken-looking guest, not a hint to run `apk add`.
#
# Installed with the guest's own apk, in a chroot of this tree, so the packages
# land in the root's own database (/lib/apk/db) and `apk del`/`apk upgrade` in the
# guest stay consistent with them. This is also why it runs *before* the fakefs
# conversion below: the conversion indexes the tree, and anything installed
# afterwards would be on disk and invisible to the engine.
# ---------------------------------------------------------------------------
log "Installing the guest's console packages: $CONSOLE_PACKAGES"
guest_mount
chroot "$DATA" /bin/sh -c "apk add --no-cache $CONSOLE_PACKAGES" \
    || die "installing the guest's own packages in the chroot failed"
guest_umount

for package in $CONSOLE_PACKAGES; do
    chroot "$DATA" /bin/sh -c "apk info -e $package" >/dev/null 2>&1 \
        || die "$package is not installed in the built root"
done
note "$(chroot "$DATA" /bin/sh -c 'apk info 2>/dev/null | wc -l' | tr -d ' ') packages in the root"

# ---------------------------------------------------------------------------
# 6. Configure the root
#
# A bare Alpine minirootfs is not quite bootable as XForge's guest: it has no
# mount points, no DNS, no apk repositories, and root may not have a usable
# shell. These are the same adjustments the reference makes.
# ---------------------------------------------------------------------------
log "Configuring the root"

# The shell the console starts is a property of /etc/passwd — /sbin/xforge-login
# reads this field and execs what it names, so this one line is the whole
# "default shell" setting. `chsh` is not needed and is not in the root; editing
# the field (or `apk add shadow` for chsh) is the way to change it in the guest.
if [ -f "$DATA/etc/passwd" ]; then
    if [ -x "$DATA$DEFAULT_SHELL" ]; then
        sed -i "s|^root:.*|root:x:0:0:root:/root:$DEFAULT_SHELL|" "$DATA/etc/passwd"
    else
        # Not a hard failure: a root without the shell it promised is worse than a
        # root that boots into the one it certainly has. Say which it is, loudly.
        printf 'warning: %s is not installed in the root (add its package to\n' "$DEFAULT_SHELL" >&2
        printf '         XFORGE_CONSOLE_PACKAGES, or set XFORGE_DEFAULT_SHELL)\n' >&2
        printf '         — falling back to /bin/sh\n' >&2
        DEFAULT_SHELL=/bin/sh
        sed -i 's|^root:.*|root:x:0:0:root:/root:/bin/sh|' "$DATA/etc/passwd"
    fi
fi
note "root's login shell: $DEFAULT_SHELL"

# /etc/profile: the non-interactive environment is built by XForge's exec layer,
# but an interactive shell (the terminal tab) reads this.
cat >> "$DATA/etc/profile" <<'EOF'

# XForge guest configuration
export PS1='\u@xforge:\w\$ '
export TERM=xterm-256color
export HOME=/root
export LANG=C.UTF-8
export CHARSET=UTF-8
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/bin

alias ll='ls -la'
alias la='ls -A'
alias l='ls -CF'

cd ~
EOF

cat > "$DATA/etc/motd" <<EOF

  XForge — Alpine Linux aarch64 on ish-arm64

  This console starts root's login shell: $DEFAULT_SHELL
  Change it by editing root's shell field in /etc/passwd
  (the login script reads that field — any shell you install will do).

  Swift and xtool are not installed yet. Install them in the guest with:
      sh /root/install-toolchain.sh all

EOF

# ---------------------------------------------------------------------------
# The console.
#
# XForge runs /sbin/init as pid 1 and drives exactly one terminal: tty1, which is
# the same terminal as /dev/console, which is what the app displays.
#
# The minirootfs ships an inittab written for a full Alpine installation. It
# starts openrc — which this root does not contain — and respawns six gettys that
# have no terminals behind them, so on this guest every one of those lines fails
# or spins. Replace it with what XForge's guest actually is: a busybox system with
# one console, where the root shell is the point.
#
# The console program is /sbin/xforge-login, not a getty and not `/bin/login -f
# root`: it starts the shell configured for root in /etc/passwd directly. See that
# script for why login is not in this path, and for what the session it creates
# looks like. `login -f` itself would work here — it is what this line used to be
# — but it authenticates, allocates utmp and takes over the terminal, none of
# which this guest has a use for, and none of which it can report failing.
# ---------------------------------------------------------------------------
install -m 0755 "$HERE/xforge-login" "$DATA/sbin/xforge-login"
cat > "$DATA/etc/inittab" <<'EOF'
# /etc/inittab — XForge
#
# pid 1 is /sbin/init. There is one console: tty1, the same terminal as
# /dev/console, and the one the app shows.
::sysinit:/etc/init.d/rcS

# Respawned, so logging out (or a crash) gives a fresh session rather than a dead
# screen. No password, no getty: xforge-login execs the login shell configured for
# root in /etc/passwd.
tty1::respawn:/sbin/xforge-login root

::ctrlaltdel:/sbin/reboot
::shutdown:/bin/umount -a -r
EOF
note "inittab: pid 1 is /sbin/init, tty1 respawns /sbin/xforge-login root"

mkdir -p "$DATA/etc/init.d"
cat > "$DATA/etc/init.d/rcS" <<'EOF'
#!/bin/sh
# XForge: the sysinit step, run by init before it starts the console login.
#
# /proc and /dev/pts are already mounted by the engine before pid 1 exists, and
# this root has no openrc and no services, so there is nothing to start — rcS
# only has to finish the runtime layout a login expects.
mkdir -p /run /tmp /dev/pts /dev/shm
chmod 1777 /tmp
mount -t proc proc /proc 2>/dev/null
mount -t devpts devpts /dev/pts 2>/dev/null
hostname xforge 2>/dev/null
exit 0
EOF
chmod 0755 "$DATA/etc/init.d/rcS"

# apk needs to know where packages come from; this is what makes the in-guest
# toolchain install (and any `apk add`) work at all.
mkdir -p "$DATA/etc/apk"
cat > "$DATA/etc/apk/repositories" <<EOF
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community
EOF

# A first-boot default. XForge overwrites this from the device's own DNS on every
# boot (see App/Services/HostDNS.c), but a rootfs with no nameservers at all fails
# names lookups before that runs.
cat > "$DATA/etc/resolv.conf" <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

# The provisioning script is what the guest runs to install Swift/xtool. It ships
# inside the app and is written to /host by the host side, but a copy in the root
# makes the command in the motd work without the app.
if [ -f "$HERE/install-toolchain.sh" ]; then
    install -m 0755 "$HERE/install-toolchain.sh" "$DATA/root/install-toolchain.sh"
    note "install-toolchain.sh staged at /root/install-toolchain.sh"
fi

# A stamp the app can check to know which root this is. XForge's installer reads
# it to decide whether an existing install can be reused.
mkdir -p "$DATA/usr/local/share/xforge"
{
    echo "base:      alpine-minirootfs-${ALPINE_VERSION}.${ALPINE_MINOR}-${ALPINE_ARCH}.tar.gz"
    echo "rootfs:    ${ALPINE_VERSION}.${ALPINE_MINOR}"
    echo "engine:    ish-arm64"
    echo "format:    fakefs-zip"
    echo "shell:     $DEFAULT_SHELL"
    echo "console:   /sbin/xforge-login root (tty1, respawned by init)"
    echo "built-at:  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # Bump this whenever anything about the guest's own setup changes — the app
    # compares it with the root it already installed and replaces the root when
    # they differ (see RootfsInstaller.installedRootIsStale). It must match the
    # release tag the root is published under.
    echo "stamp:     rootfs-v4"
} > "$DATA/usr/local/share/xforge/rootfs-manifest.txt"

# ---------------------------------------------------------------------------
# The console, exercised.
#
# Everything above is configuration, and configuration that looks right reads
# exactly like configuration that works. So the root is handed to
# EmbeddedLinux/verify-rootfs.sh, which runs the guest's own login program in a
# chroot of this tree — the way init runs it — and checks which shell ends up
# running. The same script checks the ZIP that gets published, so a device and
# this build agree on what "correct" means.
# ---------------------------------------------------------------------------
log "Checking the finished root"
guest_mount
"$HERE/verify-rootfs.sh" "$DATA"
guest_umount

# ---------------------------------------------------------------------------
# 7. Convert to fakefs
#
# Last, after everything that adds, removes or links anything — the conversion
# builds `meta.db` as an index of the tree as it stands, and the engine reads
# the database rather than scanning the directory. Anything added afterwards
# would be on disk and invisible in the guest.
#
# `fakefs_import` reads an *archive* (libarchive, gzip+tar), not a directory, so
# the configured tree is packed once here and converted from that.
# ---------------------------------------------------------------------------
OUT_ROOTFS="$WORK/$ROOTFS_NAME"

log "Converting to fakefs"
rm -rf "$OUT_ROOTFS"
STAGED_TAR="$WORK/$ROOTFS_NAME.tar.gz"
tar -czf "$STAGED_TAR" -C "$DATA" .
# Report what is being converted. The conversion is where a mistake in the
# ordering shows up (the engine reads meta.db, not the directory), so the tree's
# own numbers are worth having in the log next to the result.
note "tree: $(du -sh "$DATA" | cut -f1), $(find "$DATA" -mindepth 1 | wc -l) entries"
note "staged: $(du -h "$STAGED_TAR" | cut -f1)"
"$FAKEFSIFY" "$STAGED_TAR" "$OUT_ROOTFS"
rm -f "$STAGED_TAR"

[ -d "$OUT_ROOTFS/data" ] || die "fakefsify produced no data/ directory"
[ -f "$OUT_ROOTFS/meta.db" ] || die "fakefsify produced no meta.db"
note "data: $(du -sh "$OUT_ROOTFS/data" | cut -f1)"
note "meta: $(du -h "$OUT_ROOTFS/meta.db" | cut -f1)"

# The glibc layer must be *indexed*, not merely present. This is the check that
# would have caught installing it after conversion: the files existed on disk and
# the guest could not see them at all.
#
# `CAST(path AS TEXT)` is not decoration. fakefs stores paths as BLOB, and a
# LIKE against a BLOB only works through SQLite's implicit coercion — which is
# version-dependent, so the same query that matched every row locally matched
# zero rows on the runner's older SQLite. Comparing as text removes the
# ambiguity instead of relying on it.
if [ "${XFORGE_SKIP_GLIBC:-0}" != "1" ]; then
    if command -v sqlite3 >/dev/null 2>&1; then
        indexed="$(sqlite3 "$OUT_ROOTFS/meta.db" \
            "SELECT COUNT(*) FROM paths WHERE CAST(path AS TEXT) LIKE '%aarch64-linux-gnu%';" \
            2>/dev/null || echo 0)"
        total="$(sqlite3 "$OUT_ROOTFS/meta.db" \
            "SELECT COUNT(*) FROM paths;" 2>/dev/null || echo 0)"
        [ "${indexed:-0}" -gt 0 ] || die \
            "the glibc layer is not indexed in meta.db ($indexed of ${total:-0} paths)
       — the guest would not see it. It must be installed before the fakefs
       conversion, not copied in afterwards."
        note "glibc paths indexed in meta.db: $indexed of $total"
    else
        note "sqlite3 not available — skipping the glibc indexing check"
    fi
fi

# ---------------------------------------------------------------------------
# 8. Pack
# ---------------------------------------------------------------------------
log "Packing $ZIP_NAME"
ZIP_PATH="$OUT_DIR/$ZIP_NAME"
rm -f "$ZIP_PATH"

# Run from the work dir so the archive contains `alpine-rootfs/...` rather than
# absolute paths — the app unzips it straight into Documents.
#
# The SQLite sidecar files are excluded on purpose: `meta.db-wal`/`-shm` are
# transient and are not part of the root. Shipping them would be harmless at
# best and a corrupt-looking database at worst.
(
    cd "$WORK"
    zip -qr "$ZIP_PATH" "$ROOTFS_NAME" -x "*.db-shm" -x "*.db-wal"
)

[ -f "$ZIP_PATH" ] || die "the ZIP was not produced"
# Read the listing once: `unzip -Z1 … | grep -q` is not safe under `set -o
# pipefail` (grep exits at the first match, unzip dies of SIGPIPE, and the
# pipeline then reports failure for a check that passed).
unzip -Z1 "$ZIP_PATH" > "$WORK/zip-contents.txt"
grep -qE "^$ROOTFS_NAME/data/$" "$WORK/zip-contents.txt" \
    || die "the ZIP has no $ROOTFS_NAME/data/ entry"
grep -qE "^$ROOTFS_NAME/meta\.db$" "$WORK/zip-contents.txt" \
    || die "the ZIP has no $ROOTFS_NAME/meta.db entry"
! grep -qE '\.db-(wal|shm)$' "$WORK/zip-contents.txt" \
    || die "the ZIP contains SQLite WAL/SHM sidecars"

# Checksum, so a consumer can pin the exact root it expects.
( cd "$OUT_DIR" && sha256sum "$ZIP_NAME" > "$ZIP_NAME.sha256" )

log "Done"
note "rootfs: $ZIP_PATH"
note "size:   $(du -h "$ZIP_PATH" | cut -f1)"
note "sha256: $(cut -d' ' -f1 < "$ZIP_PATH.sha256")"
note "entries: $(wc -l < "$WORK/zip-contents.txt")"
echo
cat "$DATA/usr/local/share/xforge/rootfs-manifest.txt"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "rootfs=$ZIP_PATH"
        echo "rootfs_name=$ZIP_NAME"
        echo "rootfs_size=$(stat -c %s "$ZIP_PATH" 2>/dev/null || stat -f %z "$ZIP_PATH")"
        echo "rootfs_sha256=$(cut -d' ' -f1 < "$ZIP_PATH.sha256")"
    } >> "$GITHUB_OUTPUT"
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "### Alpine rootfs"
        echo
        echo '```'
        cat "$DATA/usr/local/share/xforge/rootfs-manifest.txt"
        echo '```'
        echo
        echo "\`$ZIP_NAME\` — $(du -h "$ZIP_PATH" | cut -f1)"
    } >> "$GITHUB_STEP_SUMMARY"
fi
