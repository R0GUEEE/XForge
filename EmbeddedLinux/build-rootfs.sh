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
#   3. convert the tarball into fakefs format — a `data/` tree + `meta.db`
#   4. configure the root in place (passwd, profile, motd, inittab, DNS, apk repos)
#   5. `zip -r` the result, excluding the SQLite WAL/SHM sidecars
#
# Why a ZIP of a fakefs and not a tarball the app imports at runtime: the
# conversion is the expensive part (thousands of files into SQLite), and doing it
# here means the app's first launch is a plain unzip — no multi-minute import on
# a phone. This is the same reason OpenMinis ships `alpine-rootfs.zip` and its
# app only calls unzip + mount_root.
#
# The root is deliberately SMALL: plain Alpine, no Swift toolchain, no glibc
# layer, no xtool. The guest installs tooling itself on demand
# (EmbeddedLinux/install-toolchain.sh, run inside the guest), which is what keeps
# this under a size that can be stored and fetched cheaply. Baking a toolchain in
# made the payload ~1.4 GB.
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

ROOTFS_NAME="alpine-rootfs"
ZIP_NAME="$ROOTFS_NAME.zip"

log()  { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\nerror: %s\n' "$*" >&2; exit 1; }

cleanup() {
    local status=$?
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

    # The step runs the guest's installer in a chroot, which needs mounts, and
    # aarch64 binaries have to execute. Say so plainly: otherwise this surfaces
    # as "mount: must be superuser to use mount" from somewhere in the middle of
    # a long install.
    [ "$(id -u)" -eq 0 ] || die "installing the glibc layer needs root (it chroots
       into the root being built and mounts /proc). Re-run with sudo, or set
       XFORGE_SKIP_GLIBC=1 to build a root without the layer."

    # Bind /proc and /dev: apk and the shell expect them, and the step's own
    # verification compiles a program.
    mount -t proc none "$DATA/proc"
    GLIBC_MOUNTS="$DATA/proc"
    trap 'for m in $GLIBC_MOUNTS; do umount -l "$m" 2>/dev/null || true; done' EXIT
    mount --rbind /dev "$DATA/dev" 2>/dev/null || true
    GLIBC_MOUNTS="$DATA/dev $GLIBC_MOUNTS"
    mount --rbind /sys "$DATA/sys" 2>/dev/null || true
    GLIBC_MOUNTS="$DATA/sys $GLIBC_MOUNTS"

    # DNS: name resolution happens inside the chroot, and the minirootfs ships no
    # nameservers at all.
    if [ -s /etc/resolv.conf ] && grep -q '^nameserver' /etc/resolv.conf; then
        grep '^nameserver' /etc/resolv.conf | sed -n '1,3p' > "$DATA/etc/resolv.conf"
    else
        printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$DATA/etc/resolv.conf"
    fi

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

    umount -l "$DATA/dev" 2>/dev/null || true
    umount -l "$DATA/sys" 2>/dev/null || true
    umount -l "$DATA/proc" 2>/dev/null || true

    # The layer's own prerequisite packages are no longer needed: they were
    # installed to run the step, not to run the guest.
    chroot "$DATA" /bin/sh -c "apk del --no-cache zstd binutils" >/dev/null 2>&1 || true

    note "glibc layer installed at /opt/glibc"
fi

# ---------------------------------------------------------------------------
# 5. Configure the root
#
# A bare Alpine minirootfs is not quite bootable as XForge's guest: it has no
# mount points, no DNS, no apk repositories, and root may not have a usable
# shell. These are the same adjustments the reference makes.
# ---------------------------------------------------------------------------
log "Configuring the root"

# The guest logs in as root with no password, and its shell must exist.
if [ -f "$DATA/etc/passwd" ]; then
    sed -i 's|^root:.*|root:x:0:0:root:/root:/bin/sh|' "$DATA/etc/passwd"
fi

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

cat > "$DATA/etc/motd" <<'EOF'

  XForge — Alpine Linux aarch64 on ish-arm64

  Swift and xtool are not installed yet. Install them in the guest with:
      sh /root/install-toolchain.sh all

EOF

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
    echo "built-at:  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "stamp:     rootfs-v1"
} > "$DATA/usr/local/share/xforge/rootfs-manifest.txt"

# ---------------------------------------------------------------------------
# 6. Convert to fakefs
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
"$FAKEFSIFY" "$STAGED_TAR" "$OUT_ROOTFS"
rm -f "$STAGED_TAR"

[ -d "$OUT_ROOTFS/data" ] || die "fakefsify produced no data/ directory"
[ -f "$OUT_ROOTFS/meta.db" ] || die "fakefsify produced no meta.db"
note "data: $(du -sh "$OUT_ROOTFS/data" | cut -f1)"
note "meta: $(du -h "$OUT_ROOTFS/meta.db" | cut -f1)"

# The glibc layer must be *indexed*, not merely present. This is the check that
# would have caught installing it after conversion: the files existed on disk and
# the guest could not see them at all.
if [ "${XFORGE_SKIP_GLIBC:-0}" != "1" ]; then
    if command -v sqlite3 >/dev/null 2>&1; then
        indexed="$(sqlite3 "$OUT_ROOTFS/meta.db" \
            "SELECT COUNT(*) FROM paths WHERE path LIKE '%aarch64-linux-gnu%';" 2>/dev/null || echo 0)"
        [ "${indexed:-0}" -gt 0 ] || die \
            "the glibc layer is not indexed in meta.db ($indexed paths) — the guest
       would not see it. It must be installed before the fakefs conversion."
        note "glibc paths indexed in meta.db: $indexed"
    fi
fi

# ---------------------------------------------------------------------------
# 7. Pack
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
