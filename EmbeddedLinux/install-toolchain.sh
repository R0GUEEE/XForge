#!/bin/sh
#
# install-toolchain.sh — provision the XForge embedded Linux (inside the guest).
#
# Runs *in the guest* (Alpine aarch64 / musl), so the same script works from
# XForge's Terminal and from the Toolchain screen, which drives the steps one at
# a time to show progress:
#
#     sh /root/install-toolchain.sh            # every step
#     sh /root/install-toolchain.sh deps       # one step
#
# Steps: deps | glibc | xtool | swiftly | swift | verify
#
# Every step is idempotent: re-running it is a no-op once it has succeeded.
#
# The tools are glibc binaries (xtool is a Swift program built on Ubuntu; the
# toolchains swiftly installs are Ubuntu builds too) and this guest is musl, so
# a real glibc runtime is the first thing to install — `gcompat` is not enough.
# `test-glibc` below exercises it.
#
set -eu

ARCH="$(uname -m)"
# Ubuntu names the same machine two different ways and both are needed: its
# archive and pool use "arm64"/"amd64", while the directory the libraries land in
# is the GNU triple, "aarch64-linux-gnu".
case "$ARCH" in
    aarch64) UBUNTU_ARCH=arm64 ;;
    x86_64)  UBUNTU_ARCH=amd64 ;;
    *)       UBUNTU_ARCH="$ARCH" ;;
esac
MULTIARCH="$ARCH-linux-gnu"
GLIBC_ROOT=/opt/glibc
GLIBC_LIB="$GLIBC_ROOT/usr/lib/$MULTIARCH"
GLIBC_LD="$GLIBC_LIB/ld-linux-aarch64.so.1"
SHARE=/usr/local/share/xforge
SWIFTLY_HOME_DIR="${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}"
export SWIFTLY_HOME_DIR

# Ubuntu release whose glibc the Swift toolchains are built against.
UBUNTU_SUITE="${XFORGE_UBUNTU_SUITE:-noble}"

log() { echo "==> $*"; }

# ---------------------------------------------------------------------------
# glibc compatibility layer
# ---------------------------------------------------------------------------
#
# Binaries built on Ubuntu need Ubuntu's glibc. Rather than compiling one (an
# hour in the emulator), take the runtime out of the distribution's own packages
# and run them through *its* loader:
#
#     $GLIBC_LD --library-path $GLIBC_LIB:<tool's own libs> <tool>
#
# The loaders mount the necessary packages under $GLIBC_ROOT. The package list
# is what a Swift/xtool binary actually needs beyond libc itself: the toolchains
# link against libxml2, curl, krb5, ldap and ICU (Foundation), which the Ubuntu
# AppImage does not bundle.

glibc_packages() {
    cat <<'EOF'
libc6
libgcc-s1
libstdc++6
zlib1g
libcom-err2
libkeyutils1
libkrb5-3
libk5crypto3
libkrb5support0
libgssapi-krb5-2
libsasl2-2
libldap2
liblber2
libgnutls30
libp11-kit0
libtasn1-6
libunistring5
libidn2-0
libffi8
libbrotli1
libicu74
libxml2
libpng16-16
libselinux1
libpcre2-8-0
libacl1
libattr1
libgmp10
libnettle8t64
libhogweed6t64
EOF
}

# Resolve package names to pool URLs with the distribution's own indexes, so the
# script does not carry pinned filenames that go stale.
glibc_package_url() {
    for index in /tmp/xforge-glibc/Packages*; do
        [ -f "$index" ] || continue
        url="$(awk -v want="$1" '
            /^Package: /   { pkg = $2 }
            /^Filename: /  { if (pkg == want) { print "http://ports.ubuntu.com/ubuntu-ports/" $2; exit } }
        ' "$index")"
        [ -n "$url" ] && { echo "$url"; return 0; }
    done
    return 1
}

glibc_fetch_indexes() {
    for component in main universe; do
        target="/tmp/xforge-glibc/Packages-$component"
        [ -s "$target" ] && continue
        url="http://ports.ubuntu.com/ubuntu-ports/dists/$UBUNTU_SUITE/$component/binary-$UBUNTU_ARCH/Packages.gz"
        if curl -fL --retry 3 -o "$target.gz" "$url" 2>/dev/null; then
            gzip -dc "$target.gz" > "$target"
        fi
    done
}

step_glibc() {
    if [ -x "$GLIBC_LD" ] && [ -f "$GLIBC_LIB/libc.so.6" ]; then
        log "glibc runtime already present at $GLIBC_ROOT"
    else
        log "Installing the glibc runtime (Ubuntu $UBUNTU_SUITE, $UBUNTU_ARCH)"
        mkdir -p "$GLIBC_LIB" "$GLIBC_ROOT/usr/lib" /tmp/xforge-glibc
        glibc_fetch_indexes

        for pkg in $(glibc_packages); do
            url="$(glibc_package_url "$pkg" || true)"
            if [ -z "$url" ]; then
                echo "    $pkg: not found in the $UBUNTU_SUITE indexes"
                continue
            fi
            deb="/tmp/xforge-glibc/$pkg.deb"
            [ -s "$deb" ] || curl -fL --retry 3 -o "$deb" "$url"
            (
                cd /tmp/xforge-glibc
                rm -rf unpack && mkdir unpack && cd unpack
                ar x "$deb"
                # Ubuntu ships the payload as zstd; older packages use xz/gz.
                if [ -f data.tar.zst ]; then
                    zstd -d -c data.tar.zst | tar -xf -
                elif [ -f data.tar.xz ]; then
                    tar -xJf data.tar.xz
                else
                    tar -xzf data.tar.gz
                fi
                # Merged-/usr layout: the libraries live under usr/lib/<arch>/.
                if [ -d "usr/lib/$MULTIARCH" ]; then
                    cp -a "usr/lib/$MULTIARCH/." "$GLIBC_LIB/"
                fi
                if [ -e "usr/lib/ld-linux-$ARCH.so.1" ]; then
                    cp -a "usr/lib/ld-linux-$ARCH.so.1" "$GLIBC_ROOT/usr/lib/" 2>/dev/null || true
                fi
                if [ -d usr/share/icu ]; then
                    mkdir -p "$GLIBC_ROOT/usr/share"
                    cp -a usr/share/icu "$GLIBC_ROOT/usr/share/" 2>/dev/null || true
                fi
            )
            echo "    $pkg"
        done
        log "glibc at $GLIBC_LD"
    fi

    mkdir -p "$GLIBC_ROOT/usr/lib" "$SHARE"
    if [ ! -e "$GLIBC_ROOT/usr/lib/ld-linux-$ARCH.so.1" ]; then
        ln -sf "$GLIBC_LD" "$GLIBC_ROOT/usr/lib/ld-linux-$ARCH.so.1"
    fi

    cat > "$SHARE/glibc.env" <<EOF
# Sourced by the wrappers in /usr/local/bin. Each tool's wrapper appends the
# libraries it ships with to XFORGE_GLIBC_LIB.
XFORGE_GLIBC_ROOT=$GLIBC_ROOT
XFORGE_GLIBC_LIB=$GLIBC_LIB
XFORGE_GLIBC_LD=$GLIBC_LD
EOF
    log "glibc layer ready"
}

step_deps() {
    log "Refreshing Alpine package indexes"
    apk update

    # Install one package at a time. Besides making failures attributable, this
    # produces steady output for XForge's live installer log instead of one
    # opaque apk transaction that can look stuck at 0%.
    packages="
bash
curl
wget
tar
xz
zip
unzip
git
ca-certificates
gcompat
libc6-compat
zlib-static
openssl
binutils
zstd
file
gnupg
"
    total="$(printf '%s\n' "$packages" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
    current=0
    printf '%s\n' "$packages" | while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        current=$((current + 1))
        log "Installing base package $current/$total: $pkg"
        apk add --no-cache "$pkg"
    done

    update-ca-certificates >/dev/null 2>&1 || true
    log "base packages installed"
}

xtool_wrapper() {
    cat > /usr/local/bin/xtool <<'EOF'
#!/bin/sh
# xtool is an Ubuntu glibc binary; run it through the glibc loader installed by
# install-toolchain.sh, with the libraries it ships alongside it.
. /usr/local/share/xforge/glibc.env
exec "$XFORGE_GLIBC_LD" --library-path "$XFORGE_GLIBC_LIB:/opt/xtool/usr/lib" \
    /opt/xtool/usr/bin/xtool "$@"
EOF
    chmod +x /usr/local/bin/xtool
}

step_xtool() {
    log "Installing xtool ($ARCH)"
    if [ -x /opt/xtool/usr/bin/xtool ]; then
        log "xtool already unpacked at /opt/xtool"
    else
        # Exactly the release asset xtool documents, unpacked once instead of
        # every run (APPIMAGE_EXTRACT_AND_RUN extracts ~50 MB per invocation).
        curl -fL --retry 3 \
            "https://github.com/xtool-org/xtool/releases/latest/download/xtool-$ARCH.AppImage" \
            -o /tmp/xtool.AppImage
        chmod +x /tmp/xtool.AppImage
        ( cd /opt && rm -rf squashfs-root && /tmp/xtool.AppImage --appimage-extract >/dev/null )
        rm -rf /opt/xtool && mv /opt/squashfs-root /opt/xtool
        rm -f /tmp/xtool.AppImage
    fi
    xtool_wrapper
    log "xtool installed at /usr/local/bin/xtool (unpacked in /opt/xtool)"
}

step_swiftly() {
    log "Installing swiftly (the Swift installer)"
    if [ -x /usr/local/bin/swiftly ]; then
        log "swiftly already present"
        return 0
    fi
    cd /tmp
    curl -fL --retry 3 -O "https://download.swift.org/swiftly/linux/swiftly-$ARCH.tar.gz"
    tar zxf "swiftly-$ARCH.tar.gz"
    rm -f "swiftly-$ARCH.tar.gz"
    # --assume-yes/--quiet-shell-followup: there is no terminal to answer its
    # prompts from, and its profile edits are pointless (XForge runs
    # non-interactive /bin/sh -c).
    ./swiftly init --assume-yes --quiet-shell-followup --skip-install --platform "ubuntu24.04"
    rm -f ./swiftly
    ln -sf "$SWIFTLY_HOME_DIR/bin/swiftly" /usr/local/bin/swiftly
    log "swiftly installed at /usr/local/bin/swiftly"
}

# swift and swiftc are glibc binaries too, and they live under the swiftly home
# rather than on any PATH a `sh -c` command would search: these wrappers put
# them there.
swift_wrapper() {
    name="$1"
    cat > "/usr/local/bin/$name" <<EOF
#!/bin/sh
. /usr/local/share/xforge/glibc.env
. "\${SWIFTLY_HOME_DIR:-/root/.local/share/swiftly}/env.sh" >/dev/null 2>&1 || true
for dir in \${PATH}; do
    case "\$dir" in /usr/local/bin) continue;; esac
    if [ -x "\$dir/$name" ]; then
        exec "\$XFORGE_GLIBC_LD" --library-path "\$XFORGE_GLIBC_LIB" "\$dir/$name" "\$@"
    fi
done
echo "xforge: $name is not installed yet (run: swiftly install latest --use)" >&2
exit 127
EOF
    chmod +x "/usr/local/bin/$name"
}

step_swift() {
    log "Installing the Swift toolchain"
    [ -e "$SHARE/glibc.env" ] || { echo "run the glibc step first" >&2; exit 1; }
    . "$SHARE/glibc.env"

    # The wrappers go in first, so `swift --version` always answers something
    # useful — a version, or exactly why there is none yet.
    swift_wrapper swift
    swift_wrapper swiftc

    . "$SWIFTLY_HOME_DIR/env.sh"
    # `swiftly list` exits 0 and prints a separator even with nothing installed,
    # so ask the directory that actually holds toolchains.
    if [ -n "$(ls -A "$SWIFTLY_HOME_DIR/toolchains" 2>/dev/null)" ]; then
        log "a toolchain is already installed: $(ls "$SWIFTLY_HOME_DIR/toolchains" | tail -1)"
        return 0
    fi

    # swiftly verifies the download's signature with gpg, and refuses without it
    # ("gpg is not installed ... To skip signature verification, specify
    # --no-verify"). Try to verify; fall back to skipping it, loudly.
    if command -v gpg >/dev/null 2>&1; then
        if ! swiftly install latest --use --assume-yes; then
            echo "    signature verification failed; retrying without it"
            swiftly install latest --use --assume-yes --no-verify
        fi
    else
        echo "    gpg is not installed in the guest: skipping signature verification"
        swiftly install latest --use --assume-yes --no-verify
    fi

    # `swiftly init --skip-install` leaves it unlinked; make it manage the
    # toolchain we just installed.
    swiftly link >/dev/null 2>&1 || true
    log "swift wrapper installed at /usr/local/bin/swift"
}

# Report what actually runs, and do not pretend. Each tool is checked through
# the same path a user's command would take.
step_verify() {
    log "Verifying the tools"
    failed=0
    for tool in xtool swift swiftly; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "    $tool: not installed"
            printf 'XFORGE-VERIFY\t%s\tmissing\tnot installed\n' "$tool"
            failed=1
            continue
        fi
        # The exit status decides, not the output: a wrapper that reports "not
        # installed" prints a line and exits 127, and counting that as success is
        # how "installed" and "works" got confused the first time.
        version_file="/tmp/xforge-version.$$"
        if timeout 120 "$tool" --version >"$version_file" 2>&1; then
            out="$(head -1 "$version_file")"
            if [ -n "$out" ]; then
                echo "    $tool: ok — $out"
                printf 'XFORGE-VERIFY\t%s\tok\t%s\n' "$tool" "$out"
            else
                echo "    $tool: INSTALLED BUT SILENT (no version output)"
                printf 'XFORGE-VERIFY\t%s\tbroken\tinstalled, but it prints nothing\n' "$tool"
                failed=1
            fi
        else
            out="$(head -1 "$version_file")"
            echo "    $tool: INSTALLED BUT NOT RUNNING — ${out:-no output}"
            printf 'XFORGE-VERIFY\t%s\tbroken\t%s\n' "$tool" "${out:-no output}"
            failed=1
        fi
        rm -f "$version_file"
    done
    if [ "$failed" -eq 0 ]; then
        log "All tools are ready."
    else
        log "Finished. Tools marked 'not running' are installed in the rootfs but"
        log "the guest's emulation faults on them — see the Engine log."
    fi
    return 0
}

case "${1:-all}" in
    deps)    step_deps ;;
    glibc)   step_glibc ;;
    xtool)   step_xtool ;;
    swiftly) step_swiftly ;;
    swift)   step_swift ;;
    verify)  step_verify ;;
    all)
        step_deps
        step_glibc
        step_xtool
        step_swiftly
        step_swift
        step_verify
        ;;
    *)
        echo "usage: $0 [deps|glibc|xtool|swiftly|swift|verify|all]" >&2
        exit 2
        ;;
esac
