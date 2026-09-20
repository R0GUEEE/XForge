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
# Output sinks
#
# Never send a *guest process*'s output to /dev/null here. iSH-AOK's arm64
# engine has been observed to SIGKILL a forked guest program whose stdout/stderr
# points at /dev/null — `swift --version >/dev/null 2>&1` died where the same
# command without the redirect ran fine, and `apk info -e … >/dev/null` died
# intermittently. Pipes and real files are safe, and a shell *builtin*
# (`command -v x >/dev/null`) is not affected, so silence goes to a file.
# ---------------------------------------------------------------------------
SILENT="${TMPDIR:-/tmp}/xforge-silent.$$"
: > "$SILENT"

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

# The development halves are needed to *link*, not just to run: glibc's
# crt1.o/crti.o/crtn.o/libc.so and libc_nonshared.a come from libc6-dev, and
# GCC's crtbeginS.o/crtendS.o/libgcc.a from libgcc-<n>-dev. Without them a link
# dies with
#     /usr/bin/ld: cannot find crtbeginS.o / cannot find -lgcc
# which is what compiling a Swift program in this rootfs hit — `swift --version`
# was fine, because printing a version does not link anything.
#
# One name per line, NO comments: the caller reads this list with word splitting.
glibc_packages() {
    cat <<'EOF'
libc6
libc6-dev
libgcc-s1
libgcc-13-dev
libgcc-14-dev
libstdc++6
libstdc++-13-dev
libstdc++-14-dev
zlib1g
libcom-err2
libkeyutils1
libkrb5-3
libk5crypto3
libkrb5support0
libgssapi-krb5-2
libsasl2-2
libldap2
libgnutls30t64
libp11-kit0
libtasn1-6
libunistring5
libidn2-0
libffi8
libbrotli1
libicu74
libxml2
libpng16-16t64
libselinux1
libpcre2-8-0
libacl1
libattr1
libgmp10
libnettle8t64
libhogweed6t64
libcurl4t64
libnghttp2-14
libpsl5t64
libssh-4
librtmp1
libssl3t64
libzstd1
liblzma5
libgcrypt20
libgpg-error0
libuuid1
libblkid1
libcap2
libedit2
libpython3.12t64
libsqlite3-0
libncurses6
libncursesw6
libtinfo6
libz3-4
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
        if curl -fL --retry 3 -o "$target.gz" "$url" 2>>"$SILENT"; then
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

        missing_packages=""
        for pkg in $(glibc_packages); do
            url="$(glibc_package_url "$pkg" || true)"
            if [ -z "$url" ]; then
                # Not something to skip quietly. A name the suite does not have
                # means the layer will be missing a library, and that surfaces
                # much later as a symbol lookup error inside one of the tools:
                # `libgnutls30` became `libgnutls30t64` in noble, and the miss
                # only showed up as "swift-sdk: undefined symbol
                # nettle_rsa_oaep_sha512_decrypt, version HOGWEED_6" — while
                # `swift --version` kept working, so nothing looked wrong.
                echo "    $pkg: NOT FOUND in the $UBUNTU_SUITE indexes" >&2
                missing_packages="$missing_packages $pkg"
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
                # GCC's own directory: crtbeginS.o/crtendS.o/libgcc.a live under
                # usr/lib/gcc/<triple>/<version>/, which is where clang looks for
                # the GNU toolchain it links with.
                if [ -d "usr/lib/gcc/$MULTIARCH" ]; then
                    mkdir -p "$GLIBC_ROOT/usr/lib/gcc/$MULTIARCH"
                    cp -a "usr/lib/gcc/$MULTIARCH/." "$GLIBC_ROOT/usr/lib/gcc/$MULTIARCH/"
                fi
                if [ -e "usr/lib/ld-linux-$ARCH.so.1" ]; then
                    cp -a "usr/lib/ld-linux-$ARCH.so.1" "$GLIBC_ROOT/usr/lib/" 2>>"$SILENT" || true
                fi
                if [ -d usr/share/icu ]; then
                    mkdir -p "$GLIBC_ROOT/usr/share"
                    cp -a usr/share/icu "$GLIBC_ROOT/usr/share/" 2>>"$SILENT" || true
                fi
            )
            echo "    $pkg"
        done
        if [ -n "$missing_packages" ]; then
            echo "the glibc layer cannot be built — no such package:$missing_packages" >&2
            echo "fix glibc_packages() for Ubuntu $UBUNTU_SUITE ($UBUNTU_ARCH)" >&2
            exit 1
        fi

        # A name that resolved is not the same as a library that arrived: the
        # layer is only useful if the files a Swift or xtool binary loads are
        # actually present, so the files are what gets checked.
        glibc_have() {
            for candidate in "$GLIBC_LIB/$1"*; do
                [ -e "$candidate" ] && return 0
            done
            return 1
        }
        incomplete=""
        for lib in libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 libstdc++.so libstdc++.so.6 \
                   libgcc_s.so.1 libz.so.1 libzstd.so.1 liblzma.so.5 libxml2.so.2 libcurl.so.4 \
                   libssl.so.3 libcrypto.so.3 libgnutls.so.30 libhogweed.so.6 \
                   libnettle.so.8 libgmp.so.10 libicuuc.so.74 liblber.so.2 \
                   libldap.so.2 libpng16.so.16 libpsl.so.5 libz3.so.4 libsqlite3.so.0; do
            glibc_have "$lib" || incomplete="$incomplete $lib"
        done
        # Startup and compiler objects, which are files rather than shared
        # libraries: glibc's crt1.o/crti.o/crtn.o/libc.so land in the multiarch
        # directory, GCC's crtbeginS.o/crtendS.o/libgcc.a in its versioned one.
        for obj in crt1.o crti.o crtn.o libc_nonshared.a; do
            glibc_have "$obj" || incomplete="$incomplete $obj"
        done
        for obj in crtbeginS.o crtendS.o libgcc.a; do
            found=""
            for candidate in "$GLIBC_ROOT/usr/lib/gcc/$MULTIARCH"/*/"$obj"; do
                [ -e "$candidate" ] && found=1
            done
            [ -n "$found" ] || incomplete="$incomplete $obj"
        done
        if [ -n "$incomplete" ]; then
            echo "the glibc layer is incomplete — nothing provides:$incomplete" >&2
            echo "a package in glibc_packages() was renamed in $UBUNTU_SUITE; the" >&2
            echo "names above are what the Swift/xtool binaries load and link against." >&2
            exit 1
        fi
        log "glibc at $GLIBC_LD"
    fi

    mkdir -p "$GLIBC_ROOT/usr/lib" "$SHARE"
    # A compiler finds its GNU toolchain by path, not through a search path:
    # clang looks in /usr/lib/gcc/<triple>/<version>, so the extracted copy has
    # to be visible there (the same trick the multiarch directory below uses).
    if [ -d "$GLIBC_ROOT/usr/lib/gcc/$MULTIARCH" ]; then
        mkdir -p /usr/lib/gcc
        ln -sfn "$GLIBC_ROOT/usr/lib/gcc/$MULTIARCH" "/usr/lib/gcc/$MULTIARCH"
    fi
    if [ ! -e "$GLIBC_ROOT/usr/lib/ld-linux-$ARCH.so.1" ]; then
        ln -sf "$GLIBC_LD" "$GLIBC_ROOT/usr/lib/ld-linux-$ARCH.so.1"
    fi

    # Wire this glibc in as the system's glibc, not just a directory to point a
    # wrapper at. Running a tool through the loader only covers the *first*
    # process: Swift's driver execs swift-frontend and swift-build as children,
    # and a child starts from its own ELF interpreter. With gcompat's stub
    # loader at /lib/ld-linux-<arch>.so.1 those children went back to musl and
    # died on glibc symbols (__isoc23_strtol, mallinfo2, pthread_cond_clockwait)
    # and on libraries musl does not have (libncurses.so.6, libuuid.so.1).
    #
    # Alpine's own programs are unaffected: they use /lib/ld-musl-<arch>.so.1
    # and libc.musl-<arch>.so.1, never these names.
    rm -f "/lib/ld-linux-$ARCH.so.1"
    ln -s "$GLIBC_LD" "/lib/ld-linux-$ARCH.so.1"
    ln -sfn "$GLIBC_LIB" "/usr/lib/$MULTIARCH"
    ln -sfn "$GLIBC_LIB" "/lib/$MULTIARCH"
    for lib in libc.so.6 libm.so.6 libpthread.so.0 librt.so.1 libdl.so.2 \
               libresolv.so.2 libutil.so.1 libcrypt.so.1; do
        if [ -e "$GLIBC_LIB/$lib" ]; then
            rm -f "/lib/$lib"
            ln -s "$GLIBC_LIB/$lib" "/lib/$lib"
        fi
    done

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
    # These are the Alpine-side prerequisites for importing projects, resolving
    # SwiftPM packages, extracting the Darwin SDK and compiling C/C++ package
    # dependencies. Keep this list in the rootfs: XForge's host is only a UI and
    # file-transfer bridge, never the build environment.
    packages="
        bash curl wget tar xz zip unzip git ca-certificates
        gcompat libc6-compat zlib-static openssl
        binutils zstd file gnupg tzdata
        build-base clang lld cmake ninja pkgconf
        linux-headers musl-dev openssl-dev libxml2-dev icu-dev
        python3 perl sqlite-dev
    "

    missing=""
    for package in $packages; do
        apk info -e "$package" >"$SILENT" 2>&1 || missing="$missing $package"
    done

    if [ -n "$missing" ]; then
        log "Installing missing Alpine build dependencies:$missing"
        apk add --no-cache $missing
    else
        log "Alpine build dependencies already installed"
    fi
}

xtool_wrapper() {
    cat > /usr/local/bin/xtool <<'EOF'
#!/bin/sh
# xtool is an Ubuntu glibc binary; run it through the glibc loader installed by
# install-toolchain.sh, with the libraries it ships alongside it.
. /usr/local/share/xforge/glibc.env
# The AppImage's own libraries come first: Ubuntu's libcurl (which Swift needs)
# is newer than the nghttp2 the AppImage bundles, and mixing them the other way
# round gives "undefined symbol: nghttp2_option_set_no_rfc9113_...".
exec "$XFORGE_GLIBC_LD" --library-path "/opt/xtool/usr/lib:$XFORGE_GLIBC_LIB" \
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
        ( cd /opt && rm -rf squashfs-root && /tmp/xtool.AppImage --appimage-extract >"$SILENT" 2>&1 )
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
# rather than on any PATH a `sh -c` command would search. The toolchain is looked
# up directly first: swiftly's own shims only work in a shell that has sourced its
# environment file, which is exactly what XForge's command runner is not.
swift_wrapper() {
    name="$1"
    # The linker's own search path is the guest's (musl) one, where Alpine's
    # libstdc++ — which carries no symbol versions — shadows Ubuntu's, and
    # linking anything against libswiftCore fails with
    #   undefined reference to \`std::__throw_logic_error(char const*)@GLIBCXX_3.4'
    # So the layer's directories go on the link line explicitly, ahead of
    # anything the driver adds. (-L only reorders the search; it changes no
    # runtime path, so Alpine's own binaries are untouched.)
    link_dirs="-Xlinker -L$GLIBC_LIB -Xlinker -L$GLIBC_ROOT/usr/lib/gcc/$MULTIARCH"
    for version_dir in "$GLIBC_ROOT"/usr/lib/gcc/$MULTIARCH/*/; do
        [ -d "$version_dir" ] && link_dirs="$link_dirs -Xlinker -L${version_dir%/}"
    done

    cat > "/usr/local/bin/$name" <<EOF
#!/bin/sh
. /usr/local/share/xforge/glibc.env

# Linking has the same problem running does, one step earlier: the linker's own
# default paths are Alpine's, so \`-lstdc++\` resolves to the musl build — which
# carries no symbol versions at all — and linking anything against libswiftCore
# fails with
#   undefined reference to \`std::__throw_logic_error(char const*)@GLIBCXX_3.4'
# The driver turns LIBRARY_PATH into -L flags ahead of its defaults, so the
# glibc layer's copies win. (It also puts glibc's libc.so first, which is what
# makes the produced binary use the glibc loader — the same one this rootfs
# already points /lib/ld-linux-aarch64.so.1 at.)
export LIBRARY_PATH="\${XFORGE_GLIBC_LIB}\${LIBRARY_PATH:+:\$LIBRARY_PATH}"

home="\${SWIFTLY_HOME_DIR:-/root/.local/share/swiftly}"

for candidate in "\$home"/toolchains/*/usr/bin/$name "\$home"/bin/$name; do
    [ -x "\$candidate" ] || continue
    exec "\$candidate" $link_dirs "\$@"
done

. "\$home/env.sh" >/dev/null 2>&1 || true   # sourcing, not a forked program: the only safe /dev/null here
for dir in \${PATH}; do
    case "\$dir" in /usr/local/bin) continue;; esac
    if [ -x "\$dir/$name" ]; then
        exec "\$dir/$name" "\$@"
    fi
done

echo "xforge: $name is not installed yet (run: swiftly install latest --use)" >&2
echo "        looked in \$home/toolchains/*/usr/bin and \$home/bin" >&2
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
    if [ -n "$(ls -A "$SWIFTLY_HOME_DIR/toolchains" 2>>"$SILENT")" ]; then
        log "a toolchain is already installed: $(ls "$SWIFTLY_HOME_DIR/toolchains" | tail -1)"
        return 0
    fi

    # swiftly verifies the download's signature with gpg, and refuses without it
    # ("gpg is not installed ... To skip signature verification, specify
    # --no-verify"). Try to verify; fall back to skipping it, loudly.
    # swiftly exits non-zero for its Ubuntu "these dependencies should be
    # installed" advice even when the install worked, so the toolchain directory
    # is what decides whether to retry -- not the exit status.
    if command -v gpg >/dev/null 2>&1; then
        swiftly install latest --use --assume-yes || true
    else
        echo "    gpg is not installed in the guest: skipping signature verification"
        swiftly install latest --use --assume-yes --no-verify || true
    fi
    if [ -z "$(ls -A "$SWIFTLY_HOME_DIR/toolchains" 2>>"$SILENT")" ]; then
        echo "    no toolchain after the first attempt; retrying without signature verification"
        swiftly install latest --use --assume-yes --no-verify
    fi

    # `swiftly init --skip-install` leaves it unlinked; make it manage the
    # toolchain we just installed.
    swiftly link >"$SILENT" 2>&1 || true

    # Say what actually resolved. A guest whose swift cannot run is much easier to
    # diagnose from these four lines than from a wrapper's refusal.
    log "swift wrapper installed at /usr/local/bin/swift"
    echo "    toolchains: $(ls "$SWIFTLY_HOME_DIR/toolchains" 2>>"$SILENT" | tr '\n' ' ')"
    echo "    swiftly bin: $(ls "$SWIFTLY_HOME_DIR/bin" 2>>"$SILENT" | tr '\n' ' ')"
    if out="$(swift --version 2>&1)"; then
        echo "    swift --version: $(printf '%s' "$out" | head -1)"
    else
        echo "    swift --version FAILED: $(printf '%s' "$out" | head -3 | tr '\n' ' ')"
    fi
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
    # `swift sdk list` runs a *second* Swift binary — swift-sdk — with its own
    # library needs, and it is what installs the darwin SDK. It fails differently
    # from `swift --version` when the glibc layer is incomplete (a symbol lookup
    # error naming a library rather than the tool), so it is checked on its own.
    if command -v swift >/dev/null 2>&1; then
        sdk_probe="/tmp/xforge-sdk-probe.$$"
        if timeout 180 swift sdk list >"$sdk_probe" 2>&1; then
            line="$(head -1 "$sdk_probe" 2>>"$SILENT" || true)"
            echo "    swift-sdk: ok${line:+ — $line}"
            printf 'XFORGE-VERIFY\tswift-sdk\tok\t%s\n' "${line:-swift sdk list}"
        else
            line="$(head -1 "$sdk_probe" 2>>"$SILENT" || true)"
            last="$(tail -1 "$sdk_probe" 2>>"$SILENT" || true)"
            echo "    swift-sdk: INSTALLED BUT NOT RUNNING — ${last:-${line:-no output}}"
            echo "    what the probe said:"
            head -6 "$sdk_probe" 2>>"$SILENT" | sed 's/^/      /'
            # A load failure names a library but not why, so ask the loader which
            # libraries it picks and which it cannot find at all. "not found"
            # here means a package is missing from the glibc layer.
            if [ -f "$SHARE/glibc.env" ]; then
                . "$SHARE/glibc.env"
                sdk_bin="$(ls "$SWIFTLY_HOME_DIR"/toolchains/*/usr/bin/swift-sdk 2>>"$SILENT" | head -1 || true)"
                if [ -n "$sdk_bin" ]; then
                    echo "    loader resolution for $(basename "$sdk_bin"):"
                    "$XFORGE_GLIBC_LD" --list "$sdk_bin" 2>&1 | grep '=>' | sed 's/^/      /'
                fi
            fi
            printf 'XFORGE-VERIFY\tswift-sdk\tbroken\t%s\n' "${last:-${line:-no output}}"
            failed=1
        fi
        rm -f "$sdk_probe"
    fi

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
        # The build executor checks this stamp alongside the actual commands and
        # package database. Bump its suffix whenever the required rootfs setup
        # changes so existing guests are provisioned again exactly once.
        mkdir -p "$SHARE"
        touch "$SHARE/build-environment-v2"
        ;;
    *)
        echo "usage: $0 [deps|glibc|xtool|swiftly|swift|verify|all]" >&2
        exit 2
        ;;
esac
