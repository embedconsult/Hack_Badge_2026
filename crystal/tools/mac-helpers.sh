#!/bin/bash
# Run on the Mac, from the root of this repository, alongside badge-bridge.sh:
#
#   crystal/tools/mac-helpers.sh [/dev/cu.usbmodemXXXX]   (BeagleBadge serial)
#
# 1. Serial bridge for a second board (e.g. a BeagleBadge) on TCP port 4001,
#    raw socat like badge-bridge.sh, so the container can use it at
#    host.docker.internal:4001.
# 2. Camera on request: when the container creates crystal/flash-request/snap,
#    one still is taken with the Mac's camera into crystal/flash-request/snap.jpg
#    (ffmpeg via AVFoundation; the first run asks macOS for camera permission
#    for the terminal app). The request file may contain a camera index (default 0).
set -u
cd "$(dirname "$0")/../.." || exit 1
DEV=${1:-}
REQ=crystal/flash-request
mkdir -p "$REQ"

pid=""
if [ -n "$DEV" ]; then
  socat -d TCP-LISTEN:4001,reuseaddr,fork "FILE:$DEV,raw,echo=0,nonblock,b115200" >"$REQ/beagle.log" 2>&1 &
  pid=$!
  echo "serial bridge for $DEV on :4001 (pid $pid)"
fi
trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null; exit 0' INT TERM

# MacPorts installs to /opt/local/bin and may name it ffmpeg7 or ffmpeg6.
export PATH="$PATH:/opt/local/bin:/opt/homebrew/bin:/usr/local/bin"
FFMPEG=""
for f in ffmpeg ffmpeg8 ffmpeg7 ffmpeg6; do command -v "$f" >/dev/null && { FFMPEG=$(command -v "$f"); break; }; done
IMAGESNAP=$(command -v imagesnap || true)
if [ -n "$FFMPEG" ]; then echo "camera: using $FFMPEG"
elif [ -n "$IMAGESNAP" ]; then echo "camera: using $IMAGESNAP"
else echo "note: no camera tool found (MacPorts: sudo port install imagesnap; Homebrew: brew install imagesnap)"; fi
echo "camera: waiting for $REQ/snap (cameras: ffmpeg -f avfoundation -list_devices true -i \"\")"
while true; do
  if [ -f "$REQ/snap" ]; then
    cam=$(tr -dc '0-9' <"$REQ/snap"); cam=${cam:-0}
    rm -f "$REQ/snap" "$REQ/snap.jpg"
    if [ -n "$FFMPEG" ]; then
      "$FFMPEG" -loglevel error -f avfoundation -framerate 30 -video_size 1280x720 -i "$cam" \
        -frames:v 1 -y "$REQ/snap.tmp.jpg" 2>"$REQ/snap.log" && mv "$REQ/snap.tmp.jpg" "$REQ/snap.jpg"
    else
      # imagesnap: -w warm-up seconds so exposure settles; camera index ignored
      "${IMAGESNAP:-imagesnap}" -q -w 1.5 "$REQ/snap.tmp.jpg" 2>"$REQ/snap.log" && mv "$REQ/snap.tmp.jpg" "$REQ/snap.jpg"
    fi
    echo "snap: $(date +%T) camera $cam -> $([ -f "$REQ/snap.jpg" ] && echo ok || echo failed)"
  fi
  if [ -n "$DEV" ] && ! kill -0 "$pid" 2>/dev/null && [ -e "$DEV" ]; then
    socat -d TCP-LISTEN:4001,reuseaddr,fork "FILE:$DEV,raw,echo=0,nonblock,b115200" >"$REQ/beagle.log" 2>&1 &
    pid=$!
  fi
  sleep 0.5
done
