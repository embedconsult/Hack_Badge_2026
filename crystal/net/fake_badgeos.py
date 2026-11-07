#!/usr/bin/env python3
"""Impersonate a badge os badge over ESP-NOW from the BeagleBadge (frames
injected through a monitor vif, see espnow_nl80211.py), to test a Crystal
badge's badge os interop without badge os hardware.

    fake_badgeos.py [seconds] [--pong]

- Injects badge os v0.7 ranging beacons ("BOSR", one shared range, a name).
- Listens on UDP 4626 for what the Crystal bridge makes of them: a kind-3
  announce on our behalf and `E` tunnel frames.
- --pong: sends the Crystal badge `pong seek` (as if User A was pressed on its
  PONG screen) and plays badge os Pong against it over ESP-NOW only, as host
  (lower MAC), blind: the CC33xx cannot receive ESP-NOW, so the game state is
  sent without hearing the guest; the Crystal badge's announce flag shows
  whether it paired.

The CC33xx only transmits frames whose source address is its own, so the
fake badge os badge has the BeagleBadge's wlan0 MAC (spoofed MACs are dropped).
"""
import os
import socket
import struct
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
for d in (HERE, "/opt/badge_launcher/tools"):
    if os.path.exists(os.path.join(d, "espnow_nl80211.py")):
        sys.path.insert(0, d)
for d in (os.path.join(HERE, "beaglebadge", "applications", "link"), "/opt/badge_launcher/applications/link"):
    if os.path.exists(os.path.join(d, "_badgenet.py")):
        sys.path.insert(0, d)
import espnow_nl80211 as en  # noqa: E402
import _badgenet as bn  # noqa: E402

secs = 15.0
do_pong = "--pong" in sys.argv
for a in sys.argv[1:]:
    if a[0].isdigit():
        secs = float(a)

ME = en.mac_of("wlan0")
os.system("iw phy phy0 interface add mon0 type monitor 2>/dev/null; ip link set mon0 up")
tx = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
tx.bind(("mon0", 0))
RT = struct.pack("<BBHI", 0, 0, 8, 0)


def inject(payload):
    tx.send(RT + en.espnow_frame(ME, payload))


u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
u.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
u.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
u.bind(("", bn.PORT))
u.settimeout(0.01)

name = b"fake-os"
bosr = b"BOSR" + bytes.fromhex("f412fa0000bc") + b"\x01" + bytes.fromhex("f412fa0000cc") + struct.pack("<h", 250)
bosr += name + b"\x00" * (12 - len(name))

crystal = None  # (mac, addr)
bridged = {}
tunnel = {}
paired_seen = 0
pong = bn.Pong(ME, lambda pkt, to: inject(pkt))
t_seek = None
next_bosr = 0
end = time.time() + secs
while time.time() < end:
    now = int(time.monotonic() * 1000)
    if time.time() >= next_bosr:
        inject(bosr)
        next_bosr = time.time() + 1
    try:
        d, addr = u.recvfrom(600)
    except socket.timeout:
        d = None
    if d and d[:3] == b"BLK" and d[3] == 1:
        t, src = chr(d[4]), d[6:12]
        if t == "H" and d[12] == bn.K_CRYSTAL:
            crystal = (src, addr)
            if d[15] & 1:
                paired_seen += 1
        elif t == "H" and d[12] == bn.K_BADGEOS:
            bridged[src.hex()] = d[22:34].rstrip(b"\x00").decode()
        elif t == "E":
            k = d[19:23].decode(errors="replace")
            tunnel[k] = tunnel.get(k, 0) + 1
    if do_pong and crystal and t_seek is None:
        u.sendto(b"BLK" + bytes((1, ord("C"), 1)) + ME + b"pong seek", crystal[1])
        t_seek = now
        pong.state, pong.press, pong.peer = bn.L_SEEK, now, crystal[0]  # we "chose" it already
        print("sent pong seek to", bn.mac_str(crystal[0]))
    if do_pong and t_seek is not None:
        if pong.state == bn.L_SEEK and now - t_seek > 800:
            pong.pair_now(crystal[0], now)  # blind: assume the mutual choice happened
        pong.last_rx = now  # we cannot hear it; keep playing
        pong.my_dy = max(-3, min(3, pong.g[1] - pong.g[4] - 48))
        pong.tick(now)

os.system("iw dev mon0 del")
print("crystal:", bn.mac_str(crystal[0]) if crystal else None)
print("bridged announces for us:", bridged)
print("tunnel frames back over UDP:", tunnel)
if do_pong:
    print("crystal announces with the in-game flag:", paired_seen, " our score/state:", pong.g[6:8], pong.state)
