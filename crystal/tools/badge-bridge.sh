#!/bin/bash
# Run on the Mac (or whichever machine the badge is plugged into), from the
# root of this repository:
#
#   crystal/tools/badge-bridge.sh [/dev/cu.usbmodem101]
#
# Keeps a raw TCP bridge (socat) to the badge console on port 4000. Unlike an
# RFC2217 server it never touches DTR/RTS, so connecting does not reset the
# ESP32-S3; socat reopens the USB port per connection, so it survives the
# badge re-enumerating. Set BRIDGE=rfc2217 for the old esp_rfc2217_server. When the
# container writes crystal/flash-request/request (lines of "OFFSET FILE", with FILE
# relative to the repository root), it stops the bridge, flashes natively with
# esptool (which can reset the ESP32-S3's USB-Serial/JTAG into download mode
# by itself), writes the log to crystal/flash-request/result, and restarts the bridge.
set -u
cd "$(dirname "$0")/../.." || exit 1
PORT_DEV=${1:-/dev/cu.usbmodem101}
REQ=crystal/flash-request
mkdir -p "$REQ"
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
ESPTOOL="python3 -m esptool"
BRIDGE=${BRIDGE:-socat}
SERVER=$(command -v esp_rfc2217_server.py || echo "$HOME/Library/Python/3.9/bin/esp_rfc2217_server.py")

server_pid=""
start_server() {
  [ -e "$PORT_DEV" ] || return
  if [ "$BRIDGE" = socat ]; then
    socat -d TCP-LISTEN:4000,reuseaddr,fork "FILE:$PORT_DEV,raw,echo=0,nonblock" >"$REQ/server.log" 2>&1 &
  else
    python3 "$SERVER" -p 4000 "$PORT_DEV" >"$REQ/server.log" 2>&1 &
  fi
  server_pid=$!
  echo "$BRIDGE bridge up on :4000 ($PORT_DEV), pid $server_pid"
}
stop_server() {
  if [ -n "$server_pid" ]; then
    pkill -P "$server_pid" 2>/dev/null   # socat children holding the port
    kill "$server_pid" 2>/dev/null && wait "$server_pid" 2>/dev/null
  fi
  server_pid=""
}
trap 'stop_server; exit 0' INT TERM

start_server
while true; do
  if [ -f "$REQ/request" ]; then
    mv "$REQ/request" "$REQ/request.running"
    stop_server
    args=()
    while read -r off file; do
      [ -n "$off" ] && args+=("$off" "$file")
    done <"$REQ/request.running"
    echo "flashing: ${args[*]}"
    $ESPTOOL --chip esp32s3 -p "$PORT_DEV" -b 921600 --before default_reset --after hard_reset \
      write_flash --flash_mode dio --flash_freq 80m --flash_size 8MB "${args[@]}" \
      >"$REQ/result.tmp" 2>&1
    echo "exit $?" >>"$REQ/result.tmp"
    mv "$REQ/result.tmp" "$REQ/result"
    rm -f "$REQ/request.running"
    tail -2 "$REQ/result"
    sleep 2
  fi
  # Restart the bridge if it died, or if it lost the USB port when the badge
  # reset and re-enumerated (the server keeps a dead handle and logs
  # "Device not configured" on every connection instead of exiting).
  if [ "$BRIDGE" != socat ] && [ -n "$server_pid" ] && grep -q "Device not configured" "$REQ/server.log" 2>/dev/null; then
    echo "badge port went away; restarting bridge"
    stop_server
  fi
  if [ -z "$server_pid" ] || ! kill -0 "$server_pid" 2>/dev/null; then
    server_pid=""
    sleep 1
    start_server
  fi
  sleep 1
done
