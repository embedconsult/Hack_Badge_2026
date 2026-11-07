#!/bin/sh
# Host tests for the content apps' C logic (Hackaday/News reader, Weather,
# Radar): parsing, layout, distance model and screens rendered to PNG
# (test/apps/out/). cJSON comes from the ESP-IDF tree.
set -eu
cd "$(dirname "$0")"
IDF=${IDF_PATH:-/opt/debian/opt/esp/esp-idf}
CJ=$IDF/components/json/cJSON
M=../../main
mkdir -p out bin
CF="-O1 -g -Wall -Wno-unused-function -I$M -I$CJ -lm"
gcc -o bin/test_feed test_feed.c $M/feed.c $M/apps_gfx.c $M/stb_image_impl.c $CF
[ -f test_weather.c ] && gcc -o bin/test_weather test_weather.c $M/weather.c $M/apps_gfx.c $CJ/cJSON.c $CF
[ -f test_radar.c ] && gcc -o bin/test_radar test_radar.c $M/radar.c $M/apps_gfx.c $CF
ok=0
for t in bin/test_*; do ./$t || ok=1; done
# PBM -> PNG for viewing
python3 -I -c "
import glob
from PIL import Image
for f in glob.glob('out/*.pbm'): Image.open(f).save(f[:-4] + '.png')
" 2>/dev/null || true
exit $ok
