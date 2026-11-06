# Native Crystal firmware for the Hackaday Supercon 2026 Billboard Badge.
#
# Code under `src/badge/` must stay usable on the ESP32-S3 with a minimal
# runtime: no IO, File, Channel, spawn, Regex or Time-based APIs, and no
# heap allocation in per-pixel or per-sample loops. Hardware access goes
# through `Badge::HAL`, which has a host mock so specs run on Linux.
module Badge
  VERSION = "0.1.0"
end

require "./badge/*"
