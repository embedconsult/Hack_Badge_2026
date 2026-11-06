# Badge firmware in Crystal

Work in progress: a port of the badge's MicroPython code (`../lib`, `../apps`)
to Crystal, targeting the ESP32-S3 natively, with LVGL through
[lvgl-crystal](https://github.com/embedconsult/lvgl-crystal).

Run the host specs:

```sh
cd crystal
crystal spec
```
