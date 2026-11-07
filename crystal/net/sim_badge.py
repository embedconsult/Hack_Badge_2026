#!/usr/bin/env python3
"""Pretend to be a Crystal Supercon badge (and one bridged badge os badge) on
the badge link protocol, for testing the BeagleBadge apps without the ESP32.

    python3 sim_badge.py [seconds] [--port 4627]

Binds its own port (default 4627, so it can run next to a launcher app on
the same BeagleBadge; peers reply to the source address), announces to the
broadcast port 4626, accepts remote commands (prints them), and plays Pong
with a simple AI paddle when it gets a `pong` command.
"""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
for d in (os.path.join(HERE, "beaglebadge", "applications", "link"), "/opt/badge_launcher/applications/link"):
    if os.path.exists(os.path.join(d, "_badgenet.py")):
        sys.path.insert(0, d)
        break
import _badgenet as bn  # noqa: E402

secs = 120.0
port = 4627
args = sys.argv[1:]
while args:
    a = args.pop(0)
    if a == "--port":
        port = int(args.pop(0))
    else:
        secs = float(a)

ME = bytes.fromhex("f412fa000001")      # fake Crystal badge
OS_MAC = bytes.fromhex("f412fa0000aa")  # fake badge os badge behind it
link = bn.Link(name="SimCrystal", kind=bn.K_CRYSTAL,
               caps=bn.CAP_REMOTE | bn.CAP_PONG | bn.CAP_BRIDGE | bn.CAP_SKETCH,
               mac=ME, port=port)
state = {"screen": 0, "name": "Jason|Kridner"}
link.screen = 0
pong_peer = {"addr": None}


def send_pong(pkt, to):
    p = link.peers.get(to)
    addr = p.addr if p else pong_peer["addr"]
    link.send(addr, "P", pkt)


pong = bn.Pong(ME, send_pong)


def on_command(src, line, addr):
    print("sim: command from %s: %r" % (bn.mac_str(src), line), flush=True)
    w = line.split()
    if not w:
        return 3
    if w[0] == "mode" and len(w) > 1 and w[1] in bn.SCREENS:
        state["screen"] = bn.SCREENS.index(w[1])
    elif w[0] == "text":
        state["name"] = line[5:]
        state["screen"] = 0
    elif w[0] == "pong":
        pong_peer["addr"] = addr
        pong.pair_now(src, bn.ticks())
        state["screen"] = 7
        print("sim: pong paired, host =", pong.host, flush=True)
    elif w[0] not in ("press", "hold", "colour", "knob", "stroke", "status", "clean"):
        return 1
    link.screen = state["screen"]
    return 0


def on_pong(src, pkt, via):
    if via is None:
        pong.rx(src, pkt, bn.ticks())


link.on_command = on_command
link.on_pong = on_pong

end = time.time() + secs
last_os = 0
while time.time() < end:
    now = bn.ticks()
    # we run on the BeagleBadge itself: "hear" its wlan0 MAC
    link.heard_list = [(bn.my_mac(), -52 - (now // 3000) % 12, -1)]
    link.flags = 1 if pong.state == bn.L_PAIRED else 0
    link.poll()
    # AI paddle: follow the ball
    me = 0 if pong.host else 1
    target = pong.g[1] - bn.PADH // 2 + bn.BALL // 2
    d = target - pong.g[4 + me]
    pong.my_dy = max(-bn.PAD_V + 1, min(bn.PAD_V - 1, d))
    pong.tick(now)
    if now - last_os > 1000:  # bridged badge os announce, as net.c sends it
        last_os = now
        name = b"yigit"
        body = bytes((bn.K_BADGEOS, bn.CAP_PONG, 255, 0)) + ME + name + b"\x00" * (12 - len(name))
        body += bytes((1,)) + ME + bytes(((-61) & 0xFF, 0xFF, 0xFF))
        link.sock.sendto(b"BLK" + bytes((1, ord("H"), 0)) + OS_MAC + body, link.bcast)
    time.sleep(0.01)
print("sim: done, rx", link.rx_count, "pong state", pong.state, "score", pong.g[6:8])
