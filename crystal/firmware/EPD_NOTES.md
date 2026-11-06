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
