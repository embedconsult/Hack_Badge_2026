#!/usr/bin/env python3
"""Talk to the badge console through the bridge on the Mac (raw TCP, port 4000).

    console.py [SECONDS] [HOST:PORT] [COMMAND...]

Prints everything the badge sends for SECONDS (default 10). Any COMMAND words
are sent first as one line (for the firmware shell). Raw TCP never touches
DTR/RTS, so connecting does not reset the badge.
"""
import socket, sys, time

secs = float(sys.argv[1]) if len(sys.argv) > 1 else 10
host, _, port = (sys.argv[2] if len(sys.argv) > 2 else "host.docker.internal:4000").rpartition(":")
cmd = " ".join(sys.argv[3:])
s = socket.create_connection((host, int(port)), timeout=5)
s.settimeout(0.3)
try:
    if cmd:
        s.sendall((cmd + "\r\n").encode())
    end = time.time() + secs
    while time.time() < end:
        try:
            data = s.recv(4096)
        except socket.timeout:
            continue
        if not data:
            break
        sys.stdout.write(data.decode(errors="replace"))
        sys.stdout.flush()
finally:
    s.close()
