#!/usr/bin/env bash
#
# test-verify-toolchain.sh — check that verify-rootfs.sh holds a root to what its
# manifest claims about the build toolchain.
#
# This is the half of the rootfs verification that a *packed* root gets: a fakefs
# ZIP cannot be chrooted, so "the console starts" is checked on the tree during
# the build and "the toolchain is really in here" is checked structurally, on the
# artifact. The structural half is easy to get wrong in a way that passes
# everything — a check that looks for the wrong path, or that trusts the manifest
# instead of the root.
#
# So each case below builds a root that is complete EXCEPT for one thing, and
# asserts that verify-rootfs.sh fails, naming that thing.
#
# Usage: Tools/test-verify-toolchain.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# Overridable so this can be pointed at a copy of the checker; the default is the
# one that ships.
VERIFY="${XFORGE_VERIFY:-$HERE/../EmbeddedLinux/verify-rootfs.sh}"
[ -f "$VERIFY" ] || { echo "cannot find $VERIFY" >&2; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

note() { printf '  %s\n' "$*"; }
ok()   { pass=$((pass + 1)); }
bad()  { fail=$((fail + 1)); printf 'FAIL: %s\n' "$*" >&2; }

# A root with everything the console checks want, so the toolchain checks are the
# only thing under test.
make_root() {
    local root="$1"
    mkdir -p "$root/bin" "$root/sbin" "$root/etc/init.d" "$root/root" \
             "$root/usr/share/terminfo/x" "$root/usr/local/share/xforge"
    printf '#!/bin/sh\n' > "$root/bin/busybox"
    chmod +x "$root/bin/busybox"
    printf '#!/bin/sh\n' > "$root/sbin/init"
    chmod +x "$root/sbin/init"
    ln -sf /bin/busybox "$root/bin/sh"
    cp "$HERE/../EmbeddedLinux/xforge-login" "$root/sbin/xforge-login"
    chmod +x "$root/sbin/xforge-login"
    printf '::sysinit:/etc/init.d/rcS\ntty1::respawn:/sbin/xforge-login root\n' > "$root/etc/inittab"
    printf '#!/bin/sh\nexit 0\n' > "$root/etc/init.d/rcS"
    printf 'root:x:0:0:root:/root:/bin/sh\n' > "$root/etc/passwd"
    printf 'root:x:0:0:root:/root:/bin/sh\n' > "$root/etc/shadow"
    printf 'export TERM=xterm-256color\nexport PATH=/bin\n' > "$root/etc/profile"
    mkdir -p "$root/etc/apk"
    printf 'https://example.invalid/main\n' > "$root/etc/apk/repositories"
    : > "$root/usr/share/terminfo/x/xterm-256color"
    printf '#!/bin/sh\n' > "$root/root/install-toolchain.sh"
    cat > "$root/usr/local/share/xforge/rootfs-manifest.txt" <<'EOF'
base:      alpine-minirootfs-3.21.0-aarch64.tar.gz
rootfs:    3.21.0
engine:    ish-arm64
format:    fakefs-zip
shell:     /bin/sh
console:   /sbin/xforge-login root (tty1, respawned by init)
toolchain: not provisioned (the guest installs it on demand)
stamp:     rootfs-v5
EOF
}

# Add a complete, working toolchain to a root.
add_toolchain() {
    local root="$1"
    mkdir -p "$root/usr/local/bin" "$root/opt/xtool/usr/bin" \
             "$root/usr/local/share/xforge" \
             "$root/root/.local/share/swiftly/toolchains/6.2-RELEASE/usr/bin" \
             "$root/root/.local/share/swiftly/toolchains/6.2-RELEASE/usr/lib/swift/linux/aarch64" \
             "$root/root/.swiftpm/swift-sdks/darwin.artifactbundle"
    for tool in xtool swift swiftc swiftly; do
        printf '#!/bin/sh\n' > "$root/usr/local/bin/$tool"
        chmod +x "$root/usr/local/bin/$tool"
    done
    printf 'XFORGE_GLIBC_LD=/opt/glibc/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1\n' \
        > "$root/usr/local/share/xforge/glibc.env"
    printf '#!/bin/sh\n' > "$root/opt/xtool/usr/bin/xtool"
    chmod +x "$root/opt/xtool/usr/bin/xtool"
    : > "$root/root/.local/share/swiftly/toolchains/6.2-RELEASE/usr/bin/swift-frontend"
    : > "$root/root/.local/share/swiftly/toolchains/6.2-RELEASE/usr/lib/swift/linux/aarch64/Swift.swiftmodule"
    : > "$root/root/.local/share/swiftly/toolchains/6.2-RELEASE/usr/lib/swift/linux/libswiftCore.so"
    printf '{"name": "darwin"}\n' > "$root/root/.swiftpm/swift-sdks/darwin.artifactbundle/info.json"
    cat > "$root/usr/local/share/xforge/darwin-sdk.txt" <<'EOF'
tag:      darwin-sdk-7
asset:    darwin.artifactbundle.zip
sha256:   0000000000000000000000000000000000000000000000000000000000000000
path:     /root/.swiftpm/swift-sdks/darwin.artifactbundle
EOF
    cat > "$root/usr/local/share/xforge/rootfs-manifest.txt" <<'EOF'
base:      alpine-minirootfs-3.21.0-aarch64.tar.gz
rootfs:    3.21.0
engine:    ish-arm64
format:    fakefs-zip
shell:     /bin/sh
console:   /sbin/xforge-login root (tty1, respawned by init)
toolchain: xtool, swiftly, swift
darwin-sdk: darwin-sdk-7 (darwin.artifactbundle.zip)
sdk-sha256: 0000000000000000000000000000000000000000000000000000000000000000
darwin-sdk-path: /root/.swiftpm/swift-sdks/darwin.artifactbundle
stamp:     rootfs-v5
EOF
}

# run_verify <root> — with the console check skipped: this is about the files, and
# running the console needs the *root's own* shell, which a synthetic root has not
# got.
run_verify() {
    XFORGE_VERIFY_SKIP_CONSOLE=1 bash "$VERIFY" "$1" > "$WORK/out.txt" 2>&1
}

check_passes() {
    local name="$1" root="$2"
    if run_verify "$root"; then ok; note "$name: passes"; else
        bad "$name should have passed"; sed 's/^/    /' "$WORK/out.txt" | tail -5
    fi
}

check_fails() {
    local name="$1" root="$2" expect="$3"
    if run_verify "$root"; then
        bad "$name should have failed"
    elif grep -q "$expect" "$WORK/out.txt"; then
        ok; note "$name: fails, naming '$expect'"
    else
        bad "$name failed without naming '$expect'"; sed 's/^/    /' "$WORK/out.txt" | tail -5
    fi
}

printf '\n==> A root with no toolchain claim\n'
make_root "$WORK/plain"
check_passes "plain root" "$WORK/plain"

printf '\n==> A root that claims a toolchain and has one\n'
make_root "$WORK/full"
add_toolchain "$WORK/full"
check_passes "provisioned root" "$WORK/full"

printf '\n==> A root that claims a toolchain and does not have one\n'
make_root "$WORK/liar"
sed -i 's|^toolchain:.*|toolchain: xtool, swiftly, swift|' \
    "$WORK/liar/usr/local/share/xforge/rootfs-manifest.txt"
check_fails "manifest without tools" "$WORK/liar" 'usr/local/bin/xtool is missing'

printf '\n==> The Swift toolchain, one piece at a time\n'
for piece in \
    'usr/local/bin/xtool' \
    'usr/local/bin/swift' \
    'usr/local/bin/swiftc' \
    'usr/local/bin/swiftly' \
    'opt/xtool/usr/bin/xtool' \
    'usr/local/share/xforge/glibc.env' ; do
    rm -rf "$WORK/missing"
    cp -a "$WORK/full" "$WORK/missing"
    rm -rf "$WORK/missing/$piece"
    check_fails "no $piece" "$WORK/missing" '/'"$piece"' is missing'
done

rm -rf "$WORK/nofrontend"
cp -a "$WORK/full" "$WORK/nofrontend"
rm -f "$WORK/nofrontend/root/.local/share/swiftly/toolchains/6.2-RELEASE/usr/bin/swift-frontend"
check_fails "no swift-frontend" "$WORK/nofrontend" 'no Swift toolchain under'

rm -rf "$WORK/nostdlib"
cp -a "$WORK/full" "$WORK/nostdlib"
rm -f "$WORK/nostdlib/root/.local/share/swiftly/toolchains/6.2-RELEASE/usr/lib/swift/linux/aarch64/Swift.swiftmodule"
check_fails "no stdlib interface" "$WORK/nostdlib" 'no Linux stdlib interface'

rm -rf "$WORK/nostdlibso"
cp -a "$WORK/full" "$WORK/nostdlibso"
rm -f "$WORK/nostdlibso/root/.local/share/swiftly/toolchains/6.2-RELEASE/usr/lib/swift/linux/libswiftCore.so"
check_fails "no stdlib library" "$WORK/nostdlibso" 'no Linux stdlib under'

rm -rf "$WORK/nosdkpath"
cp -a "$WORK/full" "$WORK/nosdkpath"
sed -i '/^path:/d' "$WORK/nosdkpath/usr/local/share/xforge/darwin-sdk.txt"
check_fails "SDK record without a path" "$WORK/nosdkpath" 'does not name where the SDK went'

rm -rf "$WORK/nosdk"
cp -a "$WORK/full" "$WORK/nosdk"
rm -rf "$WORK/nosdk/root/.swiftpm/swift-sdks/darwin.artifactbundle"
check_fails "SDK missing" "$WORK/nosdk" 'which is not in this root'

printf '\n==> A root with xtool but no Darwin SDK is fine (XFORGE_PROVISION_SDK=0)\n'
rm -rf "$WORK/nosdkclaim"
cp -a "$WORK/full" "$WORK/nosdkclaim"
rm -rf "$WORK/nosdkclaim/usr/local/share/xforge/darwin-sdk.txt" \
       "$WORK/nosdkclaim/root/.swiftpm"
sed -i -e '/^darwin-sdk:/d' -e '/^sdk-sha256:/d' -e '/^darwin-sdk-path:/d' \
    "$WORK/nosdkclaim/usr/local/share/xforge/rootfs-manifest.txt"
check_passes "toolchain without the SDK" "$WORK/nosdkclaim"

printf '\n%s checks passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
