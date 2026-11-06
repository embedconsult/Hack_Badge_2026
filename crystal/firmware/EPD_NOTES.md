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
