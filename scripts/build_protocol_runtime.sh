#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_ROOT="$PWD"
TASK_PREFIX="${AT_CURL_PREFIX:-$TASK_ROOT/.build/protocol-runtime}"
TASK_BUILD="$TASK_ROOT/.build/protocol-source"
TASK_PATCH="$TASK_ROOT/scripts/patches/curl-8.22-ssh-passphrase.patch"
TASK_STAMP="curl-8.22.0-$(cat "$TASK_PATCH" "$TASK_ROOT/scripts/build_protocol_runtime.sh" | shasum -a 256 | cut -d ' ' -f 1)"
if test -f "$TASK_PREFIX/.aether-build" && test -f "$TASK_PREFIX/lib/libcurl.4.dylib" &&
   test "$(cat "$TASK_PREFIX/.aether-build")" = "$TASK_STAMP"; then
  exit 0
fi
test -d /opt/homebrew/opt/openssl@3
test -d /opt/homebrew/opt/libssh2
mkdir -p "$TASK_BUILD" "$TASK_PREFIX"
TASK_ARCHIVE="$TASK_BUILD/curl-8.22.0.tar.bz2"
if ! test -f "$TASK_ARCHIVE"; then
  curl --fail --location --retry 3 https://curl.se/download/curl-8.22.0.tar.bz2 -o "$TASK_ARCHIVE"
fi
echo "5d956a6a22b3c279f50c421ee5d3c9e9d660cb6f115dcf881b579e952130549c  $TASK_ARCHIVE" | shasum -a 256 -c -
# Re-extraction resets only this script's own source build after an interrupted run.
python3 "$TASK_ROOT/scripts/clean_generated.py" runtime
tar -xf "$TASK_ARCHIVE" -C "$TASK_BUILD"
cd "$TASK_BUILD/curl-8.22.0"
patch --batch --forward -p1 < "$TASK_PATCH"
CFLAGS="-O2 -mmacosx-version-min=26.0" LDFLAGS="-mmacosx-version-min=26.0" \
./configure --prefix="$TASK_PREFIX" --with-openssl=/opt/homebrew/opt/openssl@3 \
  --with-libssh2=/opt/homebrew/opt/libssh2 --enable-shared --disable-static \
  --disable-docs --without-libpsl --without-brotli --without-zstd \
  --without-nghttp2 --without-ngtcp2 --without-nghttp3 --without-librtmp \
  --without-libidn2 --without-libssh --without-gssapi --without-ldap \
  --disable-ldap --disable-ldaps --with-ca-bundle=/opt/homebrew/etc/ca-certificates/cert.pem \
  > "$TASK_BUILD/configure.log" 2>&1
make -j "$(sysctl -n hw.ncpu)" > "$TASK_BUILD/make.log" 2>&1
make install > "$TASK_BUILD/install.log" 2>&1
cp COPYING "$TASK_PREFIX/curl-LICENSE.txt"
printf '%s\n' "$TASK_STAMP" > "$TASK_PREFIX/.aether-build"
"$TASK_PREFIX/bin/curl" --version
cd "$TASK_ROOT"
python3 scripts/clean_generated.py runtime
