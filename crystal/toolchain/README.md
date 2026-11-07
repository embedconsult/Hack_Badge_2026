# Crystal → Xtensa (ESP32-S3) toolchain

Stock Crystal can't target Xtensa: `Codegen::Target` rejects the arch, and
upstream LLVM builds don't include the Xtensa backend. This directory has a
small patch to Crystal 1.19.1 (the first release that supports LLVM 22) and the
scripts that build it against Espressif's LLVM.

| File | Purpose |
|---|---|
| `crystal-1.19.1-xtensa.patch` | 3 commits (`git am`): xtensa target + Xtensa C ABI; glibc `pthread_getattr_np` fallback when there's no `/proc`; static reloc model for bare-metal `*-elf` triples |
| `crystal-xtensa.sh` | Runs the patched compiler from the Alpine host via the rootfs's glibc loader |
| `make-gcc-shims.sh` | Writes `/proc`-free `xtensa-esp32s3-elf-*` shims into the rootfs |

The firmware build is `../firmware/build.sh` (see "Build the firmware" below).

## Layout (all under the Debian rootfs, `ROOTFS=/opt/debian`)

| Path in rootfs | What |
|---|---|
| `/opt/esp/esp-idf` | ESP-IDF v5.4.2; tools in `/root/.espressif` |
| `/opt/esp/shims` | from `make-gcc-shims.sh` |
| `/opt/esp-clang` | Espressif LLVM `esp-22.1.4_20260825` (clang + `libs-clang` packages, aarch64-linux-gnu) |
| `/opt/crystal-xtensa/bin/crystal` | patched compiler (glibc, links `libLLVM-22.so`) |
| `/opt/crystal-xtensa/src` | Crystal 1.19.1 stdlib (+ patch) |

### Why the rootfs, and the /proc gotchas
The host is Alpine (musl). Espressif's LLVM and ESP-IDF tools are glibc-only,
and gcompat isn't enough (`__snprintf_chk: symbol not found`). The Debian 12
arm64 rootfs runs them via `chroot`. The container can't mount `/proc` in the
chroot or bind-mount the repo, and proot doesn't help: Debian's proot 5.1
segfaults and Alpine has no proot package. So:
- Espressif's `xtensa-esp32s3-elf-*` wrappers panic ("no /proc/self/exe available").
  `make-gcc-shims.sh` replaces them with shell scripts. They set `XTENSA_GNU_CONFIG`
  and `-mdynconfig=xtensa_esp32s3.so` and run `xtensa-esp-elf-*`.
- The IDF component manager uses psutil, which needs `/proc`, so
  `build.sh` sets `IDF_COMPONENT_MANAGER=0`. Managed components won't work yet.
- The Crystal runtime calls `pthread_getattr_np` for the main thread, which reads
  `/proc/self/maps` (fixed by patch commit 2). `$ORIGIN` expansion of the library path needs
  `/proc/self/exe`, so always set `CRYSTAL_LIBRARY_PATH`.
- Build the compiler with `sequential_codegen=1`. The `-Dpreview_mt` build hangs without `/proc`.

## Rebuild the compiler
Host Crystal 1.16.3 (Alpine) cross-compiles the patched 1.19.1 source to an
aarch64-linux-gnu object, then it's linked in the rootfs:

```sh
ESP=<extracted clang-esp-22.1.4_20260825-aarch64-linux-gnu>/esp-clang
git clone --depth 1 -b 1.19.1 https://github.com/crystal-lang/crystal.git && cd crystal
git am /path/to/crystal/toolchain/crystal-1.19.1-xtensa.patch
apk add make
# llvm-config can't list libs (no static libs shipped), hence LLVM_LDFLAGS:
env LLVM_TARGETS="Xtensa RISCV" LLVM_LDFLAGS="-L/opt/esp-clang/lib -lLLVM-22" \
  make crystal target=aarch64-unknown-linux-gnu sequential_codegen=1 \
       LLVM_CONFIG=$ESP/bin/llvm-config O=$PWD/.build          # ~30 s, 60 MB crystal.o
cp .build/crystal.o /opt/debian/tmp/
chroot /opt/debian apt-get install -y libgc-dev libpcre2-dev   # once
chroot /opt/debian cc /tmp/crystal.o -o /opt/crystal-xtensa/bin/crystal -rdynamic \
  -L/opt/esp-clang/lib -Wl,-rpath,/opt/esp-clang/lib \
  -lLLVM-22 -lstdc++ -lpcre2-8 -lm -lgc -lpthread -ldl          # 40 MB binary
rm -rf /opt/debian/opt/crystal-xtensa/src && cp -a src /opt/debian/opt/crystal-xtensa/src
```
Espressif LLVM: `gh release download esp-22.1.4_20260825 -R espressif/llvm-project -p 'clang-esp-*-aarch64-linux-gnu.tar.xz' -p 'libs-clang-esp-*-aarch64-linux-gnu.tar.xz'`.
Extract both, then copy `esp-clang/` plus the `libLLVM*` files from libs into `/opt/debian/opt/esp-clang`.

## Use
```sh
crystal-xtensa.sh build --prelude=empty --cross-compile \
  --target xtensa-esp-unknown-elf --mcpu esp32s3 --release -o out src.cr   # -> out.o
```
Crystal always emits a C `main` symbol. Localize it before linking
(`xtensa-esp32s3-elf-objcopy --localize-symbol=main out.o`).

## Build the firmware
```sh
crystal/firmware/build.sh          # = idf.py build merge-bin; outputs in crystal/firmware/build/
```

## Literal pools (`CRYSTAL_SPLIT`, `CRYSTAL_OPT`)
Xtensa `L32R` loads a 32-bit constant (a "literal") from at most 256 KiB
*before* the instruction. Crystal writes the whole program as one `.literal`
and one `.text` section, so once `.text` of `crystal_app.o` passes about
230 KiB the far end can't reach the pool and the link fails with
`dangerous relocation: l32r: literal target out of range`. With `--release`
(-O3) the code is 297 KiB, which is why the default build uses `-O2` (221 KiB;
89% of the reach is used already: `test/robots/literal_reach.py build/crystal_blink.map`).

`CRYSTAL_SPLIT=1` lifts the limit, without changing the compiler:
1. Crystal runs its optimisation pipeline as usual and `--emit llvm-ir` writes
   the optimised module (`crystal_app.ll`). (`--emit llvm-bc` doesn't work
   with `--cross-compile`: it copies a cache file that isn't written.)
2. `firmware/main/crystal_sections.py` gives every function an explicit
   `section ".text.<name>"`. The Xtensa backend then puts that function's
   pool in `.literal.<name>`. This is what `llc --function-sections` does,
   but with sanitised names: Crystal's names contain spaces
   (`*Menu::tick<Int32, Int32>:Nil`), and `idf.py size` can't parse a map file
   with spaces in input section names.
3. esp-clang's `llc` (the same LLVM 22 the compiler links) compiles it with
   the target machine Crystal would use (`-mcpu=esp32s3`, static relocs, no
   GlobalISel, -O3 codegen for `--release`, else -O2). The code is the same
   as Crystal's own object within a few bytes per function (7 of 631 symbols
   differ at -O3; the total is 1.2 KiB smaller).

The IDF linker script matches `.literal .literal.* .text .text.*` in one
statement, and the Xtensa linker keeps a file's literals at the front while
the reach fits. When it doesn't, the linker moves each pool in front of its own
function. So only one function (the largest is `crystal_app_main`, 54 KiB)
has to fit in 256 KiB, not the whole object. `--gc-sections` can now also drop unused
Crystal functions. Nothing goes to IRAM: the code stays in `.flash.text`, and
IRAM stays at 16383 of 16384 bytes. `CRYSTAL_LLC_FLAGS` passes extra `llc`
flags, e.g. `--mtext-section-literals` (pools inline in `.text.<name>`, behind a
jump at each function entry; not needed).

```sh
CRYSTAL_OPT=--release CRYSTAL_SPLIT=1 crystal/firmware/build.sh   # -O3, links
crystal/firmware/build.sh                                          # default: -O2, Crystal's own object
CRYSTAL_SPLIT=1 crystal/firmware/test/robots/crystal_size.sh       # object sizes only
crystal/firmware/test/robots/crystal_grow.sh   # full -O3 link with the code stub-grown (KIB=...)
```
`build.sh` passes the variables into the chroot via the generated
`main/crystal_flags.cmake`. A change re-runs cmake and the Crystal step.
The split is opt-in until it has been measured on the badge.

## Status / limits
Only `--prelude=empty` works so far: compiler primitives, `lib` bindings and
`fun`, with no stdlib, GC or exceptions. The Xtensa C ABI class
(`codegen/abi/xtensa.cr`) follows clang's rules: aggregates up to 24 bytes go
directly in a2..a7, larger ones byval; returns up to 16 bytes come back in a2..a5,
larger via sret. It has been checked against clang's IR for a 12-byte struct but
not exhaustively tested. The next pieces for a real runtime are an Xtensa
windowed-ABI fiber context switch, a GC (bdwgc port or arena), and abort-only
exceptions.
