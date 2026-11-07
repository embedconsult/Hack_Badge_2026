#!/usr/bin/env python3
"""Run a shell command on the BeagleBadge's serial console (RFC2217 bridge on :4001).

    bb.py [SECONDS] COMMAND...

The Mac side is: BRIDGE=rfc2217 crystal/tools/badge-bridge.sh /dev/cu.usbserial-XXXX 4001
(the raw socat bridge doesn't configure this board's USB-serial chip).
Never toggles DTR/RTS. Strips terminal escape codes from the output.
"""
import re, serial, sys, time

secs = 4.0
args = sys.argv[1:]
if args and re.fullmatch(r"\d+(\.\d+)?", args[0]):
    secs = float(args.pop(0))
s = serial.serial_for_url("rfc2217://host.docker.internal:4001?ign_set_control",
                          115200, timeout=0.3, do_not_open=True)
s.dtr = False
s.rts = False
s.open()
try:
    s.write((" ".join(args) + "\r").encode())
    buf = b""
    end = time.time() + secs
    while time.time() < end:
        buf += s.read(4096)
finally:
    s.close()
print(re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", buf.decode(errors="replace")))
