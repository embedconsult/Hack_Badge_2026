#!/bin/sh
# Run the xtensa-patched Crystal compiler installed in the Debian rootfs.
#
# The compiler is glibc-linked (Espressif's libLLVM-22.so is glibc-only), so on
# the Alpine/musl host it runs through the rootfs's dynamic loader, which keeps
# the host's real /proc. Inside the rootfs (chroot) call
# /opt/crystal-xtensa/bin/crystal directly with CRYSTAL_PATH and CRYSTAL_LIBRARY_PATH set.
#
#   crystal-xtensa.sh build --prelude=empty --cross-compile \
#     --target xtensa-esp-unknown-elf --mcpu esp32s3 --release -o out src.cr
ROOTFS=${ROOTFS:-/opt/debian}
C=$ROOTFS/opt/crystal-xtensa
export CRYSTAL_PATH=${CRYSTAL_PATH:-$C/src}
export CRYSTAL_LIBRARY_PATH=${CRYSTAL_LIBRARY_PATH:-$C/lib}
exec "$ROOTFS/lib/ld-linux-aarch64.so.1" \
  --library-path "$ROOTFS/lib/aarch64-linux-gnu:$ROOTFS/usr/lib/aarch64-linux-gnu:$ROOTFS/opt/esp-clang/lib" \
  "$C/bin/crystal" "$@"
