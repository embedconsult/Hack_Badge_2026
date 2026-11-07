# Findings: everything learned porting the badge to Crystal

This file collects what we found while porting the Supercon 2026 Billboard Badge to Crystal: the hardware, the panel, the toolchain, the network, the games and the BeagleBadge. The details stay in the linked notes; this is where to look first. As of commit cc22810 (2026-11-07).

## Hardware (Supercon 2026 badge, ESP32-S3, 8 MB flash, 8 MB PSRAM)

- **Panel power:** GPIO48 (EPD_PWR_ENABLE) drives a P-FET high-side switch, and **LOW = powered**. MicroPython never drives it, so the panel works only because the pin floats low. We drive it, and it must stay off at least 1.5 s between power-ups. ([EPD_NOTES](firmware/EPD_NOTES.md))
- **Panel:** E2969JS0B1, a 960×672 black/white/red panel with two CoGs, OTP driver "B". BUSY is low while busy. MSB is the leftmost pixel, and with the OTP register order **nothing is bit-reversed**; MicroPython's reversal only pairs with its own hard-coded registers.
- **Strapping pins:** GPIO3 (CS2) is a strapping pin. GPIO45 (MISO) is VDD_SPI strapping: leave it unconfigured.
- **Task stacks:** they must be 8 KB. At 4 KB, adding the RMT calls overflowed silently and killed the USB-Serial/JTAG console and esptool's auto-reset.
- **Knob SAOs:** the ChargedHex AS5600 SAOs put the analog output on SAO GPIO1 and a WS2812 on GPIO2. Knobs in SAO1 and SAO3 read on GPIO2 and GPIO7 (ADC1), with LEDs on GPIO42 and GPIO6. Reading the analog outputs avoids the two AS5600s colliding at I2C address 0x36.
- **Flash layout:** we use two OTA slots, with apps at **0x20000** (never 0x10000). NVS keeps MicroPython's offset, so old settings survive. ([partitions.csv](firmware/partitions.csv)). A full MicroPython backup is in `/work/backup/` (outside git).
- **Console:** opening the console through an RFC2217 bridge resets the chip. The raw socat bridge ([badge-bridge.sh](tools/badge-bridge.sh)) does not.

## E-paper waveforms (measured on the badge, camera-checked)

- **Slow red clean:** the OTP refresh takes **33 s**. Input frees the main loop, but the waveform can't be cut short: the next refresh waits for it to finish.
- **Upload:** both planes upload over DMA at 20 MHz in 66 ms.
- **Fast refreshes:**
  - On driver B, each fast pull takes a fixed ~1.16 s whatever the 0xB0 table asks.
  - yigitabi5444's 20-frame pull takes 580 ms.
  - The 20-frame *windows* make +336-row ghost copies on this panel, so we don't use them.
- **Ink commands:**
  - Writing both RAMs on every update turns `(0x11 << 1) | 0x10` into a per-pixel command: 1 or 3 = VDH for N frames, 2 = VDL, 0 = nothing. Sketch ink and diff updates use this.
  - The CoG swaps 0x10 and 0x11 after every pull.
- **Mirroring:** the session also needs DCTL (`0x01 otp[0x10]`), or the image is mirrored within each CoG half. That was the "strokes start far right" bug.
- **Pink ghosts:** erasing black with VDL leaves pink, because the red pigment rises. 3×19 frames of VDL erase cleanly. Erases are now VDL 19 plus 2 settle pulls, which ride on the next frames for free.
- **Red:** a fast refresh can't remove red, so a fast refresh after a red frame is promoted to slow.
- **Speeds now:**
  - A diff update takes about 0.65 s.
  - Opening an app takes 4.2–4.8 s. FAST_ENTRY (off by default) cuts it to 0.66–0.99 s.
- **Still open, with camera checks ready:** the faint grey trail in games, Sketch's first-stroke strength, and ghosts under FAST_ENTRY (`python3 crystal/tools/morning_checks.py trail|ink|fast`).

## Crystal on Xtensa ([toolchain/README](toolchain/README.md))

- **Patched compiler:** Crystal 1.19.1, the first release with LLVM 22, needs 3 small patches: the Xtensa target and C ABI, a `pthread_getattr_np` fallback for when there is no /proc, and static relocations for `*-elf`. It is built against Espressif LLVM esp-22.1.4.
- **No standard library:** only `--prelude=empty` works. That means no stdlib, GC or exceptions; the firmware uses C shims in `firmware/main/*.c`.
- **Host:** the host is Alpine (musl), while Espressif's tools need glibc. They run in a Debian chroot without /proc. That needed shell shims for the gcc wrappers, `IDF_COMPONENT_MANAGER=0` and a sequential codegen build.
- **L32R reach:** Xtensa `L32R` reaches only 256 KiB backwards. At -O3 the single `.literal` pool fell out of reach. **The fix is `CRYSTAL_SPLIT`** (now the default, with -O3): each function gets its own `.text.<name>` section, so its literals go to `.literal.<name>`. Now only the largest function (54 KiB) must fit. An A/B test on the badge showed no regressions.
- **Inflate memory:** its 32 KiB window falls back to PSRAM. After ROBOTS plus Wi-Fi, internal RAM is too fragmented, and Sketch's frame failed to decode.

## Network ([net/PROTOCOL](net/PROTOCOL.md))

- **Link protocol:** UDP port 4626, broadcast announces, unicast commands. The robot battle messages are G/J/B/K/Z, and tournaments use T. Caps bit 16 means the badge plays robots.
- **BeagleBadge Wi-Fi:** a TI CC33xx chip. It can *send* ESP-NOW via monitor-mode injection (24 of 25 frames arrived), but can't *receive* it, because the chip's firmware filters it. So the Supercon badge bridges ESP-NOW to UDP.
- **badge os:** it is fixed on channel 1, while a phone hotspot picks 1, 6 or 11. `net ap on` makes the badge a channel-1 access point (`BADGE-LINK-xxxx`, 192.168.4.1) that everyone joins. There is no internet or OTA in that mode.
- **Settings pages:** sending each page whole with `Content-Length` fixed `/robots` cutting off with 8 slots.
- **Autojoin:** a badge joins a link tournament only while on Home or ROBOTS, or after 60 s idle. An `O` message used to bypass this; that is fixed.
- **TLS:** a TLS handshake on the badge is slow, so plain `http://` on the local network is what keeps snake bots inside the 500 ms deadline.

## Bot competitions

- **SNAKES** ([net/snakes/README](net/snakes/README.md)):
  - Bots use the Battlesnake HTTP/JSON API, so they can be written in any language.
  - The badge is the referee, with 500 ms for all bots together. A bot that misses gets a safe automatic move, shown as MISSED (AUTO).
  - A turn takes about 0.7 s because of the e-paper.
  - The Elo league is kept in NVS.
- **ROBOTS:**
  - A port of crystal-robots (GPL-2.0), with a hand-written lexer and parser that keep upstream's multipass rules.
  - It matches upstream `run_stepwise` at every motion update (`firmware/test/robots/`).
  - A battle takes 0.1–0.4 s on the badge. One badge ran 55 tournament battles in 31 s.
  - Battles are deterministic, so two badges simulate the same battle and cross-check the result. A link tournament with the BeagleBadge ran 18 robots and 91 battles in 127 s, ending "all 2 badges got the same result" (photographed 2026-11-07).

## BeagleBadge

- **Console:** its serial console needs the RFC2217 bridge (`BRIDGE=rfc2217 badge-bridge.sh … 4001`), because the raw socat bridge doesn't configure its USB-serial chip. Run commands with [tools/bb.py](tools/bb.py), which needs pyserial.
- **Hotspot:** it doesn't reconnect to a hotspot that slept; `nmcli con up jdkphone83` brings it back.
- **Simulator:** `sim_badge.py` must use the repo's `_badgenet.py`; the launcher's installed copy was older. `install_beagle.sh` (BRANCH=crystal) updated the launcher apps on 2026-11-07.

## Bugs in the MicroPython firmware (for upstream)

- `epd.draw_image` turns white red, because the red test is `color[0] > 127`.
- The LED menu raises `IndexError` past 48 apps, because `MENU_BACKGROUND_COLORS` has only 6 entries.
- `lib/sao.py` doesn't import on MicroPython 1.24.1, so Sketch silently skips the SAO bus. This is fixed in PR #1.
- GPIO48 is never driven, and `cog_poweroff()` is never called (see Hardware).

## Undecided / untested

- **Not yet tested:**
  - QR codes and the Settings page on a real phone;
  - USBFLASH with a second badge;
  - a physical Menu+ and Menu− press.
- **Decisions open:**
  - the licence: the robot engine is GPL-2.0, and the repo has no LICENSE file;
  - an OTA release: none published yet;
  - the defaults for FAST_ENTRY, the diffe draw and inkf.
