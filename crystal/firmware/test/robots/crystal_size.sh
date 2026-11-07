#!/bin/sh
# Compile only the Crystal object (src/main.cr) the way main/CMakeLists.txt
# does, inside the build rootfs, and print its section sizes. Xtensa L32R
# reaches literals at most 256 KiB back, so .text of crystal_app.o must stay
# well below that (the link fails with "dangerous relocation: l32r").
#   crystal/firmware/test/robots/crystal_size.sh [extra crystal flags, default --release]
set -eu
ROOTFS=${ROOTFS:-/opt/debian}
HERE=$(cd "$(dirname "$0")/../.." && pwd)
WORK=${WORK:-/build/crystal-size}
[ $# -gt 0 ] || set -- --release
rm -rf "$ROOTFS$WORK"
mkdir -p "$ROOTFS$WORK"
cp -a "$HERE/src" "$ROOTFS$WORK/"
chroot "$ROOTFS" /usr/bin/env -i HOME=/root PATH=/usr/bin:/bin \
  CRYSTAL_PATH=/opt/crystal-xtensa/src CRYSTAL_LIBRARY_PATH=/opt/crystal-xtensa/lib \
  CRYSTAL_CACHE_DIR="$WORK/cache" \
  /opt/crystal-xtensa/bin/crystal build --prelude=empty --cross-compile \
  --target xtensa-esp-unknown-elf --mcpu esp32s3 "$@" -o "$WORK/crystal_app" "$WORK/src/main.cr" >/dev/null
chroot "$ROOTFS" /opt/esp/shims/xtensa-esp32s3-elf-size -A "$WORK/crystal_app.o" | grep -E '^\.(text|literal|rodata|data|bss) '
