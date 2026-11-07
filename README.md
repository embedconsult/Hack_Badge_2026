# Hack_Badge_2026 — native firmware for the Supercon 2026 badge

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
- `crystal/net/` — badge link: the Supercon badge talking to a BeagleBadge and to
  yigitabi5444's badge os badges over Wi-Fi/ESP-NOW ([PROTOCOL.md](crystal/net/PROTOCOL.md)),
  and the BeagleBadge launcher apps (below)
- The original MicroPython firmware is still at the repo root (`main.py`, `lib/`, `apps/`)

## BeagleBadge apps: Badge Finder, Remote, Link Pong

A **Link** category for the BeagleBadge's badge-launcher
(`crystal/net/beaglebadge/applications/link/`): find nearby Supercon badges with a distance
estimate, remote-control one (screens, buttons, nametag text, drawing on its Sketch), and play
Pong against it, each badge drawing its own view.

1. Supercon badge: set Wi-Fi in its USB shell (`wifi <ssid> <password>`), then turn network mode
   on: `net on`, or the LINK screen (Menu +/- to it) and User A. The LINK screen lists the badges
   it hears.
2. BeagleBadge: join the same Wi-Fi network (launcher Settings → WiFi), then as root:
   ```sh
   curl -fsSL https://raw.githubusercontent.com/embedconsult/Hack_Badge_2026/crystal/crystal/net/install_beagle.sh | BRANCH=crystal sh
   ```
   It copies the apps into `/opt/badge_launcher/applications/link/` (a previous copy is kept in
   `/root/link.orig`; nothing else in the launcher changes) and restarts `badge-launcher.service`.
   Without internet on the BeagleBadge, copy that folder over by hand and run
   `systemctl restart badge-launcher`.
3. Menu → **Link** → Badge Finder / Remote / Link Pong. UP/DOWN pick, SELECT, BACK.

Testing without a Supercon badge: `python3 crystal/net/sim_badge.py 300` on the BeagleBadge plays
a Crystal badge (plus one bridged badge os badge). `crystal/net/fake_badgeos.py` impersonates a
badge os badge over ESP-NOW (monitor-mode injection) to test a Supercon badge's bridge.

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
