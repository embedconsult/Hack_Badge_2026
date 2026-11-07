# 9.69"/9.70" PDi panel (E2969JS0B1, 960x672 BWR, two CoGs): driver notes

Sources compared:
- C++: `/work/EPD_Driver_GU_large/src/EPD_Driver.cpp` (PDi, Arduino), screen `eScreen_EPD_969 = 0x9608`
- Py-main: `lib/epd.py` (badge firmware, SoftSPI 8 MHz)
- Py-up: `upstream/claude_development:lib/epd.py` (hardware SPI 8 MHz, fast LUTs)

## Signals
| Signal | GPIO | Notes |
|---|---|---|
| CS1 (C++ `panelCS`, "master", left half) | 13 | active low |
| CS2 (C++ `panelCSS`, "slave", right half) | 3 | active low (GPIO3 is a strapping pin; only sampled at reset) |
| BUSY1 / BUSY2 | 12 / 8 | **low = busy, high = ready** (C++ waits `while (BUSY != HIGH)`) |
| DC | 10 | low = command index, high = data |
| RST | 11 | active low |
| SCK / MOSI | 21 / 47 | SPI mode 0, MSB first, 8 MHz in the C++ reference |
| MISO | 45 | not connected; GPIO45 is the VDD_SPI strapping pin, so leave it unconfigured |
| PWR_EN | 48 | declared in Python, never driven by anyone; panel works without it |

## Framing (one "send index data")
- Both CoGs: DC=0, CS1=CS2=0, write index, CS1=CS2=1, DC=1, CS1=CS2=0, write data bytes, CS1=CS2=1.
- One CoG (M or S): other CS=1, DC=0, CS=0, index, CS=1, DC=1, CS=0, data..., CS=1.
  CS is toggled between the index byte and the data, so CS must be a GPIO, not the SPI peripheral's CS.

## Global update (C++ `globalUpdate`) = reset, send images, COG init, DC/DC soft start, refresh, soft shutdown
1. **Reset** `_reset(200,20,200,200,5)`: wait 200 ms, RST=1, 20 ms, RST=0, 200 ms, RST=1, 200 ms, CS1=CS2=1, 5 ms.
2. **Send images** (both):
   - `0x13` DUW = `00 3B 00 00 9F 02` (x bytes 0..0x3B = 60 bytes, y 0..0x29F = 671)
   - `0x90` DRFW = `00 3B 00 A9`
   - Master: `0x12` RAM_RW `3B 00 14`; `0x10` black plane (40,320 B); `0x12` `3B 00 14`; `0x11` red plane (40,320 B)
   - Slave: same with the right-half planes.
   - Half-plane = 672 rows x 60 bytes; the badge frame buffer is 672 rows x 120 bytes, bytes 0..59 = left = master.
3. **COG_initial**:
   - both: `05 7D`, 200 ms, `05 00`, 10 ms, `D8 80` (MS_SYNC), `D6 00` (BVSS), `A7 10`, 100 ms, `A7 00`, 100 ms, `03 00 11` (OSC)
   - master: `44 00`, `45 80`, `A7 10`, 100 ms, `A7 00`, 100 ms, `44 06`, `45 82` (temp 0x82 = 25 C), `A7 10`, 100 ms, `A7 00`, 100 ms
   - slave: identical sequence
   - both `60 25` (TCON); master `61 01` (STV_DIR); both `02 00` (VCOM)
   - (commented out in C++: `C2 3F`, `01 00`)
4. **DC/DC soft start** (all to both CoGs; 2 ms after each step):
   - `51 50 01`
   - v=1..4: `09 1F`, `51 50 v`, `09 9F`
   - v=1..10: `09 1F`, `51 0A v`, `09 9F`
   - v=3..10: `09 7F`, `51 0A v`, `09 FF`
   - v=9..2: `09 7F`, `51 v 0A`, `09 FF`   (C++ keeps `Index51_data[3]` = 10 from the previous loop)
   - `09 FF`, 10 ms
5. **Refresh**: wait BUSY high, `15 3C` (both), 5 ms.
6. **DC/DC soft shutdown**: wait BUSY high, `09 7F`, `05 7D`, `09 00`, 200 ms, wait BUSY high, DC=0, CS1=0, RST=0, CS1=1.

`COG_powerOff` (not called by globalUpdate): `09 7F 7D 00`, 200 ms, wait BUSY high, DC=0, CS=0, (writes LOW to the BUSY input), 150 ms, RST=0.

## Where Python and C++ differ
- **BUSY**: C++ polls one `panelBusy` pin; both Pythons require BUSY1 *and* BUSY2 high.
- **Busy poll interval**: C++ and Py-main 100 ms; Py-up 10 ms. COG_powerOff in C++ spins without delay; Python 1 ms.
- **Bit order**: C++ sends bytes as given (its `reverse()` helper is unused). Python bit-reverses every byte unless
  `/data/hwconf` says `display_pn == b"84"` (default `B1` -> reversed). The badge buffer is MONO_HLSB (MSB = leftmost).
- **SPI**: C++ hardware SPI 8 MHz mode 0; Py-main SoftSPI "8 MHz" (much slower in practice); Py-up hardware SPI(1) 8 MHz, 4 KB chunks.
- **COG_powerOff**: C++ writes LOW to the BUSY pin (input; a no-op/bug); Python doesn't.
- **Py-up extras** (not in C++): optional fast waveform written to register `0xB0` after COG init (from
  `data/rendered_luts.py`; driver "B" = 400 bytes, driver "8" = 180 bytes), multiple `15 3C` refreshes per upload,
  pre-flash of solid black/white frames, periodic full refresh. Py-up's ~6 s update is this fast path, not the OTP waveform.
- Sequence bytes, delays and the soft-start ramp are otherwise identical across all three.

## The sequence actually used: Hackaday's esp32s3-itc97 driver (epd97.cpp)
`/work/2026-Billboard_Badge/firmware/esp32s3-itc97` is the primary reference (an ESP32-S3 driver for exactly this panel).
It differs from the PDi/Python sequence above in several ways:
- **Panel power**: GPIO48 = EPD_PWR_ENABLE drives the gate of Q2 (SK2301 P-FET; source +3V3, drain VCC_EPD), with no
  pull resistor. **LOW = panel powered.** Parked HIGH before the pin is made an output, then driven LOW 800 ms before the reset.
  MicroPython never drives it (it floats; the panel works by luck).
- **Reset**: power on, 800 ms, RST=1, 50, RST=0, 100, RST=1, 400 ms. A second RST pulse (50/100/400) follows the OTP read.
- **OTP read** (bitbanged at ~50 kHz, MOSI turned around as input with pull-down, master CS only):
  driver B: `70 71 36` to both, then index `B9`; driver 8: `A1 00`, `A7 80`, `A3 00 40`, then `A8`. 1 dummy byte + 88 bytes.
  B is detected by `otp[0x16]==0x3B && otp[0x0D]==0x3B && otp[0x28]&0x80` and remapped into the driver-8 layout.
  **Our badge: E2969JS0B1 (driver B).** OTP TCON byte = 0x25 (same as the Python's hard-coded value).
- **Planes**: `01 otp[0x10]` (B only), DUW `13` = otp[0x16..0x1B], DRFW `90` = otp[0x0C..0x0F], RAM_RW `12` = otp[0x13..0x15],
  then `10` black and `11` red. **No bit reversal**: MSB = leftmost pixel. (The Python's reversal pairs with its own fixed registers.)
  epd97.cpp interleaves 60 bytes master / 60 bytes slave per line; we send each COG its whole half (same as PDi/Python) so DMA can do big chunks.
- **Update registers** (to both COGs): wait 660 ms; `05 7D` 200 ms; `05 00` 10 ms; [`C2 3F` driver 8]; `D8 otp[1D]`; `D6 otp[1E]`;
  `A7 10` 100; `A7 00` 100; [`03 00 otp[12]` driver 8]; `44 00`; `45 80`; `A7 10` 100; `A7 00` 100; `44 06`; `45 84` (B) / `86` (8);
  `A7 10` 100; `A7 00` 500 ms; `60 otp[0B]`; `61 otp[1C]` (both COGs); [`01 otp[10]` driver 8]; `02 otp[11]`.
- **Fast**: 400-byte (B) / 180-byte (8) table to `B0` after the registers, before the soft start.
- **DC/DC soft start** is driven by the 4 OTP ramp stages (8 bytes each at 0x20), not the hard-coded PDi ramp.
- **Refresh**: 100 ms, wait BUSY idle (10 s), `15 3C`, wait BUSY low (2 s), wait idle; epd97.cpp then watches 1 s for a second pass.
  Driver B fast = 3 pulls of `15 3C` (each ~1.16 s fixed). In a kept-open session later images only need planes + `15 3C`.
- **Stop**: `09 7F`, 20 ms, `05 7D`, `09 00`, 200 ms, DC=0, CS=0, 150 ms, RST=0, power off, 300 ms, CS=1, RST=1.
  Supply must stay off >= 1500 ms before the next power-up.
- Fast refresh cannot draw red: red is OR'ed into black, red plane sent as zeros. A fast refresh after a red frame is run slow.

## Measured on the badge (E2969JS0B1, SPI 20 MHz, planes in PSRAM)
| Step | Time |
|---|---|
| OTP probe (bitbanged, 50 kHz) | 1384 ms |
| Upload, both planes, both COGs (DMA, 4080-byte chunks) | 66 ms (164 ms at 8 MHz) |
| Slow (OTP waveform) refresh, panel busy | 33.0 s; ~36 s from upload start incl. registers + soft start |
| Fast, first image of a session | ~5.6 s upload-start to BUSY released (+2.4 s power-up/reset) |
| Fast, session kept open, 3 pulls | 3.55 s total (66 ms upload + 3 x 1.16 s) |
| Fast pull on driver B | fixed ~1.16 s whatever the 0xB0 table asks |
| PNG decode (1287-byte 960x672 palette PNG) | 155 ms |

Notes:
- epd97.cpp's 1 s "second pass" watch after each refresh never fired; it is kept only for slow refreshes.
- Game frames use a fast LUT without the shake group (`build_lutb(shake: false)`); the freed group
  drives paper (table 0) white once more. Unchanged pixels then do not visibly blink. A clean
  (shaking, 3-pull) refresh runs on mode entry and every 30 game frames.
- A fast refresh after a red frame is promoted to slow (fast cannot remove red).
- Task stacks must be 8 KB (main and knob task): at 4 KB / 3.5 KB adding the RMT calls overflowed
  silently and took down the USB-Serial/JTAG console and esptool's auto-reset.
- Opening the console through the RFC2217 bridge resets the chip.
- Fast LUT kinds (`EPD::LUT_*`): BASE (epd97/upstream, byte-identical to upstream lutb_base), NOSHAKE,
  BW (upstream "short black/white": table 2 idle after group 4), NOSHAKE_BW (game frames), KEEPRED and
  NOSHAKE_KEEPRED (tables 2 and 3 ground in every group: red pixels get no drive; used with raw planes so a
  red frame put up by a slow refresh survives fast updates, e.g. Sketch).
- Changing the LUT kind reopens the COG session (~5 s); keep one kind per run of frames.
- Partial window (`EPD.refresh_window`, from upstream PARTIAL_WINDOW): DUW 0x13 = [x0,x1,y0lo,y0hi,y1lo,y1hi]
  and DRFW 0x90 = [x0,x1,y0/4,y1/4] per COG (x in bytes of that half, rows 4-aligned), then RAM_RW and only
  the box's bytes. A COG with nothing to do gets a 1-unit window mid-screen. Setting DRFW alone shifts the image
  (upstream c2387f0). Not yet verified on our badge.
- Upstream da2826e: on driver B tables 0/1 split pixels in a checkerboard with the pixel value setting
  polarity, so an old/new differential via LUT edits alone is not possible; use the window instead.
- Slow refreshes can be aborted (`EPD.abortable=`, `request_abort` from the button poll): the BUSY wait
  returns, the COG is stopped and powered down.

## From yigitabi5444/supercon26-badge-os (main.c, panel_lab; read Nov 2026, credit to its author)
- 0xB0 group layout: `[levels a|b|c|d (2 bits each), TPa, TPb, SRab, TPc, TPd, SRcd, RP]`, 5 tables x 10 groups.
  Their shortest pull: every group `{lvl,1,1,0,1,1,1,1}` (phases a/b skipped with SRab 0, c and d 1 frame each)
  = 20 frames. A zero TP, RP 0 or SRab = SRcd = 0 hangs the CoG. Measured here: 580 ms full screen
  (vs 1159 ms for our 45/1/1 x3 tables), and rows-only windows of ~40 rows in 41-62 ms (vs 77 ms).
  **WFAST (20-frame) windows produce +336-row copies on this panel; not used** (Sketch photo on
  7dfbfae: a dark copy of the strokes ~336 rows lower, smudges, grey bands). Sketch ink stays on WIN_LUT
  (NOSHAKE_BW) rows-only windows. Kept as `EPD::LUT_WFAST` for DIAG B only (window ink only; table 1 = new pixel black gets VDH for N of the 20 frames,
  everything else GND, so ink never lightens). DIAG B "ink ladder" compares N = 19/12/8/5 with the old ink.
- The CoG swaps 0x10 and 0x11 after every pull. Their partial update keeps the previous frame in 0x11 and the
  new one in 0x10, table = (old << 1) | new: only changed pixels are driven (white->black VDH,
  black->white VDL), unchanged ones GND. They keep DRFW = whole panel ("a shorter y1 copies the top rows
  down") and write only the changed box through DUW + RAM_RW ([59 - x0, y0 lo, 0x14 | y0 >> 8], PDi byte
  order), so there are no window edges and no seams; every update is one 20-frame pull (~0.48 s).
  We keep rows-only windows (faster for small strokes) and write 0x11 = 0 in the window rows.
- Session open with PDi Wide_Large waits: 348 ms instead of ~2.4 s (we use the same quick open). 0xB0 is
  latched once per session ("rewriting it re-latches the slow one"): changing the table needs a new session.
  They restart the session every 60 pulls; we do every 20 images.
- Their 0x70 71 36 booster setting right after every reset matches errata 9.
- Their firmware uses an OTA partition table (otadata at 0xf000, ota_0 at 0x20000). Flashing it replaces
  our bootloader/partition table; restore the first 0x9000 bytes before flashing ours at 0x10000.

## Ink commands (UPD_INK, Sketch default) - Nov 2026 night session
- yigitabi's whole-panel session has no DCTL (0x01); with our OTP-order RAM writes (RAM_RW 00 00 10, bytes not
  reversed) the image then lands MIRRORED within each COG half (x 200 shows at 279). `diff_open` now sends
  `0x01 otp[0x10]` like write_planes. This was the "strokes start far right" bug in UPD_DIFF.
- Writing BOTH RAMs every update turns the table index (0x11 << 1) | 0x10 into a per-pixel command
  (DIAG B "ink command test", camera): 1 = VDH for INK_F1 frames, 3 = VDH for INK_F3 frames, 2 = VDL for
  INK_FE frames, 0 = nothing. VDH 2 frames per pass gives 5 visible steps from light grey to black over 5
  passes. VDL 19 frames on black leaves faint pink (red pigment comes up): don't use it to erase.
- Pull = 20 frames, 580 ms whole panel; 0x03 OSC (17..33) and 0x60 TCON (5..37) did not change it.
- Rows-only ink pulls (DUW rows + RAM_RW at the window start + DRFW rows) ran in 22-104 ms, but the strokes
  did not appear and the window edges left seam lines: off (flag INK_WIN). Pull time follows the DRFW rows
  (~0.85 ms/row + ~20 ms).

## Erase waveform: pink ghosts (wtest, Nov 2026)
- Black (put up by the fast base LUT) driven back to white with VDL for one 20-frame pull leaves PINK
  (camera, shell `wtest A B C`: three groups erased with three tables in one ink pull, after a slow
  `clean`). VDL 10 (the old DIFF_DRIVE) pink + grey; VDL 6 darker; VDL 19 lightest but still pink.
  VDH first, VDL/VDH shaking, or level 3 first: no better.
- More VDL time is what removes it: 2 pulls x 19 VDL faint, 3 pulls x 19 VDL clean. The red pigment
  is slower than the black and is still near the front after one pull.
- UPD_DIFF now: erase drive VDL 19 (diffe default) and every erased pixel gets table 2 in the next
  two pulls too, by writing RAM 0x11 = shown | settle (EPD settle_compose/settle_advance). Inside
  running apps (games) that rides on their next pulls for free (+50 ms upload for 0x11); when the
  app goes quiet for 400 ms the main loop runs the remaining settle pulls (EPD.diff_settle).
  Camera: Home selection frames and WEATHER's "UPDATING." no longer leave pink.
- Not balanced (3 x 19 VDL vs 10 VDH for writes); the clean refreshes rebalance from time to time.

## Sketch polish (Nov 2026 night, camera-verified)
- Knobs: a backlash filter (Sketch.follow, HYST 10 counts) replaces the deadband: no wobble when
  still, count-by-count motion; a jump > 700 counts between samples re-references (knob override,
  glitches). During every ink pull the EPD busy hook (epd_busy_hook) keeps polling the knobs, so the
  next pull draws the path the knobs took (circles stay round) instead of a chord.
- Pen cursor: four 3 px wide ticks 6..13 px from the pen, ink command 1 (one light pass) on never-
  inked pixels, removed with command 2 (VDL ink_fe = 2 frames). ink_fe must match ink_f1: with
  `inkf 4 3 2` the ticks are left behind as grey marks.
- Shake to erase (A): one ink session with a shake table (tables 1/2/3 = VDL 4/19/8 frames): pull 1
  lightens each inked pixel by a random strength, pull 2 strongly, then the usual 3-pull clean.
  2.3 s + 3.8 s. Keep power on between the shake and the clean (a cog_stop power-down cost 2.3 s).
- Red frame: after hold-A (or 60 s idle) the colour render stays; ink pulls never touch the red
  frame. Leaving it (or an OTA status screen) marks red residue; after 60 s idle the current screen
  is redrawn with one OTP refresh. Any input aborts the WAIT, but the OTP waveform still runs to its
  end and the next refresh waits for the rest (EPD.finish_aborted).
- PNG/Inflate: the 32 KiB inflate window falls back to PSRAM when internal RAM is fragmented
  (after ROBOTS + Wi-Fi the Etch frame failed to decode, E_MEMORY).
