#!/bin/sh
# Generate /proc-free replacements for Espressif's xtensa-esp32s3-elf-* wrappers
# (they're Rust binaries that read /proc/self/exe, and the chroot has no /proc).
# Each shim sets XTENSA_GNU_CONFIG to the chip's dynconfig .so and execs the
# generic xtensa-esp-elf-* tool, adding -mdynconfig for the compiler drivers.
# Run on the host; writes $ROOTFS/opt/esp/shims.
set -eu
ROOTFS=${ROOTFS:-/opt/debian}
CHIP=${CHIP:-esp32s3}
TC=$(cd "$ROOTFS" && ls -d root/.espressif/tools/xtensa-esp-elf/*/xtensa-esp-elf | tail -1)
OUT=$ROOTFS/opt/esp/shims
mkdir -p "$OUT"
for f in "$ROOTFS/$TC"/bin/xtensa-$CHIP-elf-*; do
  n=$(basename "$f"); tool=${n#xtensa-$CHIP-elf-}
  case $tool in gcc|g++|c++|cc|cpp|gcc-[0-9]*) extra="-mdynconfig=xtensa_$CHIP.so" ;; *) extra= ;; esac
  cat > "$OUT/$n" <<SH
#!/bin/sh
export XTENSA_GNU_CONFIG=/$TC/lib/xtensa_$CHIP.so
exec /$TC/bin/xtensa-esp-elf-$tool $extra "\$@"
SH
  chmod +x "$OUT/$n"
done
echo "wrote $(ls "$OUT" | wc -l) shims to $OUT"
