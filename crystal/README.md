# Badge firmware in Crystal

Work in progress: a port of the badge's MicroPython code (`../lib`, `../apps`)
to Crystal, targeting the ESP32-S3 natively, with LVGL through
[lvgl-crystal](https://github.com/embedconsult/lvgl-crystal).

Guarded goals (read before changing Sketch): [GOALS.md](GOALS.md). What we learned along the way (hardware, panel, toolchain, network): [FINDINGS.md](FINDINGS.md).

Run the host specs:

```sh
cd crystal
crystal spec
```

## Apps and the home screen
Every screen is an app module in `firmware/src/apps/` (`include App`, `ORDER`, `NAME`, hooks
`icon`/`enter`/`tick`/`leave`; the contract is at the top of `firmware/src/apps/app.cr`). The home
screen shows them as a 4 x 2 icon grid with a top bar that labels each button. Menu - and Menu +
(or the right knob) move the selection, and A or B opens the app. Menu + and Menu - pressed
together return home from any app. Settings opens a hotspot "Badge-XXXX" with a phone settings page.
Schedule shows the Supercon talks and workshops. The home grid, the top bar and the hotspot settings
page follow yigitabi5444's badge os (github.com/yigitabi5444/supercon26-badge-os). Host previews of
the screens: `firmware/test/render/render_apps.cr`.
