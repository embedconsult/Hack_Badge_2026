#!/bin/sh
# Compile only the Crystal object (src/main.cr) the way main/CMakeLists.txt
# does, inside the build rootfs, and print its section sizes. Xtensa L32R
# reaches literals at most 256 KiB back; with one .literal + one .text section
# (CRYSTAL_SPLIT=0) .text of crystal_app.o must stay well below that (the link
# fails with "dangerous relocation: l32r"). With CRYSTAL_SPLIT=1 each function
# has its own pool and only the largest function matters. For the reach in a
# real link run literal_reach.py on the map; crystal_grow.sh tests the limit.
#   [CRYSTAL_SPLIT=1] crystal/firmware/test/robots/crystal_size.sh [crystal flags, default --release]
set -eu
ROOTFS=${ROOTFS:-/opt/debian}
HERE=$(cd "$(dirname "$0")/../.." && pwd)
WORK=${WORK:-/build/crystal-size}
SPLIT=${CRYSTAL_SPLIT:-0}
[ $# -gt 0 ] || set -- --release
rm -rf "$ROOTFS$WORK"
mkdir -p "$ROOTFS$WORK"
cp -a "$HERE/src" "$HERE/main/crystal_sections.py" "$ROOTFS$WORK/"
EMIT=
[ "$SPLIT" = 1 ] && EMIT="--emit llvm-ir"
chroot "$ROOTFS" /usr/bin/env -i HOME=/root PATH=/usr/bin:/bin \
  CRYSTAL_PATH=/opt/crystal-xtensa/src CRYSTAL_LIBRARY_PATH=/opt/crystal-xtensa/lib \
  CRYSTAL_CACHE_DIR="$WORK/cache" \
  /opt/crystal-xtensa/bin/crystal build --prelude=empty --cross-compile \
  --target xtensa-esp-unknown-elf --mcpu esp32s3 "$@" --single-module $EMIT \
  -o "$WORK/crystal_app" "$WORK/src/main.cr" >/dev/null
if [ "$SPLIT" = 1 ]; then
  O=-O2
  case " $* " in *" --release "*|*" -O3 "*) O=-O3 ;; *" -O1 "*) O=-O1 ;; *" -O0 "*) O=-O0 ;; esac
  chroot "$ROOTFS" python3 "$WORK/crystal_sections.py" "$WORK/crystal_app.ll" "$WORK/crystal_app.split.ll"
  chroot "$ROOTFS" /opt/esp-clang/bin/llc -mtriple=xtensa-esp-unknown-elf -mcpu=esp32s3 \
    -relocation-model=static -global-isel=0 $O ${CRYSTAL_LLC_FLAGS:-} \
    -filetype=obj -o "$WORK/crystal_app.o" "$WORK/crystal_app.split.ll"
fi
chroot "$ROOTFS" /opt/esp/shims/xtensa-esp32s3-elf-size -A "$WORK/crystal_app.o" |
  awk '{k = $1} $1 ~ /^\.text/ {k = ".text"} $1 ~ /^\.literal/ {k = ".literal"}
       k ~ /^\.(text|literal|rodata|data|bss)$/ {s[k] += $2; n[k]++
         if (k == ".text" && $2 > m) {m = $2; mn = $1}}
       END {for (k in s) printf "%-10s %8d  (%d sections)\n", k, s[k], n[k]
            printf "largest text section %s %d\n", mn, m}'
