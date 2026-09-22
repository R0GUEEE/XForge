set -eu

# Build zsign inside the embedded Alpine guest on first use. The upstream project
# is a C++ command-line signer (MIT), so it belongs in Linux where it can run,
# not as an iOS subprocess/framework. Pin the source revision so the installed
# signer is reproducible and cannot silently change as upstream master moves.
ZSIGN_COMMIT=614caa8d1ca949e260e5746144aa52d27a4b08d6
ZSIGN_SHA256=a373dc5ddbf81ba5c435a48c14b4a2857506c3dde02ec62e0136b6968797384b
MARK=/usr/local/share/xforge/zsign-installed
BIN=/usr/local/bin/zsign
if [ -x "$BIN" ] && [ -f "$MARK" ]; then
    exit 0
fi
apk add --no-cache curl tar git make g++ pkgconf python3 openssl-dev >/tmp/xforge-zsign-apk.log 2>&1
rm -rf /tmp/zsign-src
mkdir -p /tmp/zsign-src
cd /tmp/zsign-src
curl -fL --retry 3 "https://github.com/zhlynn/zsign/archive/$ZSIGN_COMMIT.tar.gz" -o zsign.tar.gz
printf '%s  %s\n' "$ZSIGN_SHA256" zsign.tar.gz | sha256sum -c -
tar -xzf zsign.tar.gz --strip-components=1
# Keep the PKCS#12 password out of zsign's argv/process listing. The upstream
# CLI accepts -p <password>; patch this pinned source with -Q <password-file>,
# which reads the secret into memory and trims its newline. The job deletes the
# file immediately after signing.
python3 /root/xforge/patch-zsign-password-file.py
make -C build/linux clean all
install -m 0755 bin/zsign "$BIN"
mkdir -p "$(dirname "$MARK")"
printf 'source=https://github.com/zhlynn/zsign\ncommit=%s\ninstalled-at=%s\n' \
    "$ZSIGN_COMMIT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARK"
rm -rf /tmp/zsign-src
zsign -v
