#!/bin/sh
set -eu

# Build zsign inside the embedded Alpine guest on first use. The upstream project
# is a C++ command-line signer (MIT), so it belongs in Linux where it can run,
# not as an iOS subprocess/framework. The marker makes this idempotent.
MARK=/usr/local/share/xforge/zsign-installed
BIN=/usr/local/bin/zsign
if [ -x "$BIN" ] && [ -f "$MARK" ]; then
    exit 0
fi
apk add --no-cache git make g++ pkgconf openssl-dev >/tmp/xforge-zsign-apk.log 2>&1
rm -rf /tmp/zsign-src
mkdir -p /tmp/zsign-src
cd /tmp/zsign-src
curl -fL --retry 3 https://github.com/zhlynn/zsign/archive/refs/heads/master.tar.gz -o zsign.tar.gz
tar -xzf zsign.tar.gz --strip-components=1
make -C build/linux clean all
install -m 0755 bin/zsign "$BIN"
mkdir -p "$(dirname "$MARK")"
printf 'source=https://github.com/zhlynn/zsign\ninstalled-at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARK"
rm -rf /tmp/zsign-src
zsign -v
