# Hack_Badge_2026 — native Crystal firmware (`crystal` branch)

Firmware for the **Hackaday Supercon 2026 "Billboard Badge"** (ESP32-S3 with a
9.7" 960×672 black/white/red e-paper), rewritten as native
[Crystal](https://crystal-lang.org) code running on the ESP32-S3 under ESP-IDF.

- `crystal/firmware/` — the ESP-IDF project: Crystal app (`src/*.cr`), e-paper
  driver, PNG decoder, apps (Nametag, Portrait, Sketch, Life, Snake, DIAG) and a
  USB-serial debug shell
- `crystal/toolchain/` — the patch and scripts that let Crystal compile for Xtensa
- `crystal/firmware/EPD_NOTES.md` — what we learned about driving the panel,
  including fast rows-only partial updates
- `crystal/tools/` — `badge-bridge.sh` (USB bridge + flasher) and `console.py`
- The original MicroPython firmware is still at the repo root (`main.py`, `lib/`, `apps/`)

## Credits

- **Geoff McIntyre ([FacioErgoSum](https://github.com/FacioErgoSum/Hack_Badge_2026))** —
  the badge firmware this fork started from, including the Etch-A-Sketch app,
  its frame art, the AS5600 knob work and the e-paper speed-ups that the Crystal
  Sketch is ported from.
- **[Hackaday](https://github.com/Hack-a-Day/2026-Billboard_Badge)** — the badge
  hardware, schematics, panel documentation and the `esp32s3-itc97` C++ driver our
  e-paper driver is ported from.
- **[yigitabi5444/supercon26-badge-os](https://github.com/yigitabi5444/supercon26-badge-os)** —
  on-badge measurements (fast session open, RAM write pointer, power errata)
  that made fast partial updates work.
- **Pervasive Displays** — the iTC panel and its reference drivers.
- Crystal port by **Jason Kridner ([BeagleBoard.org](https://www.beagleboard.org))**,
  developed with Claude Code.
