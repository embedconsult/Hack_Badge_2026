#!/usr/bin/env python3
"""Pretend to be a Crystal Supercon badge (and one bridged badge os badge) on
the badge link protocol, for testing the BeagleBadge apps without the ESP32.

    python3 sim_badge.py [seconds] [--port 4627] [--link-port 4626] [--name SimCrystal]
                         [--bcast host:port] [--engine path/to/rb]
                         [--challenge BADGE robot.cr robot.cr [...]] [--seed N]
                         [--mac HEX12] [--mine robot.cr ...] [--builtins robot.cr ...]
                         [--tourney PEERS] [--seeds K]

Binds its own port (default 4627, so it can run next to a launcher app on
the same BeagleBadge; peers reply to the source address), and also listens on
the link port 4626 (shared with the launcher apps) for the badges' broadcast
announces. It announces to the link port's broadcast address (or --bcast),
accepts remote commands (prints them), and plays Pong with a simple AI paddle
when it gets a `pong` command.

Robot battles (robonet.py; PROTOCOL.md B K G J Z): it answers challenges
(a badge's `robot challenge <its name> ...`), receiving the robots it lacks,
and with --challenge it challenges the badge whose name starts with BADGE
(or whose MAC ends with those hex digits) to a battle of the robot files.
With --engine (the badge's own engine built for this machine:
crystal/firmware/test/robonet/run.sh builds it as test/robonet/bin/rb) it
simulates the battle too and compares its result with the badge's; it
exits 0 on the same result, 3 on a different one, 4 on a failure.

Tournaments (tourney.py; PROTOCOL.md T): --mine files are its slot robots
(it brings them when a tournament asks), --builtins the built-ins it adds
when it organizes; --tourney PEERS starts one once PEERS robot badges are
heard (the lowest MAC organizes: this sim, or it asks the lowest badge).
--bcast may be given several times (announces to each: several simulators
and host badges on one PC). With --mine or --tourney it exits like a
challenge once the standings are in (0 every badge agreed).
"""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
# The repo's _badgenet first (or one copied next to this file): an installed
# launcher's copy may be older than the robot battle hooks.
for d in (os.path.join(HERE, "beaglebadge", "applications", "link"), HERE, "/opt/badge_launcher/applications/link"):
    if os.path.exists(os.path.join(d, "_badgenet.py")):
        sys.path.insert(0, d)
        break
import _badgenet as bn  # noqa: E402
sys.path.insert(0, HERE)
import robonet  # noqa: E402
import tourney  # noqa: E402

_probe = bn.Link(port=0)
_ok = hasattr(_probe, "on_packet") and hasattr(bn, "CAP_ROBOTS")
_probe.close()
if not _ok:
    sys.exit("sim: %s is too old for robot battles (no on_packet / CAP_ROBOTS); copy the repo's "
             "crystal/net/beaglebadge/applications/link/_badgenet.py next to sim_badge.py" % bn.__file__)
print("sim: using", bn.__file__, flush=True)

secs = 120.0
port = 4627
link_port = bn.PORT
name = "SimCrystal"
bcasts = []
mac = None
mine = []
builtins = []
tourney_at = None
seeds = 2
engine = None
challenge = None   # (badge, [files])
seed = None
args = sys.argv[1:]
while args:
    a = args.pop(0)
    if a == "--port":
        port = int(args.pop(0))
    elif a == "--link-port":
        link_port = int(args.pop(0))
    elif a == "--name":
        name = args.pop(0)
    elif a == "--bcast":
        h, pp = args.pop(0).rsplit(":", 1)
        bcasts.append((h, int(pp)))
    elif a == "--mac":
        mac = bytes.fromhex(args.pop(0))
    elif a in ("--mine", "--builtins"):
        lst = mine if a == "--mine" else builtins
        while args and not args[0].startswith("--"):
            lst.append(open(args.pop(0), "rb").read())
    elif a == "--tourney":
        tourney_at = int(args.pop(0))
    elif a == "--seeds":
        seeds = int(args.pop(0))
    elif a == "--engine":
        engine = args.pop(0)
    elif a == "--seed":
        seed = int(args.pop(0))
    elif a == "--challenge":
        badge = args.pop(0)
        files = []
        while args and not args[0].startswith("--"):
            files.append(args.pop(0))
        challenge = (badge, files)
    else:
        secs = float(a)

ME = mac or bytes.fromhex("f412fa%06x" % (port & 0xFFFFFF))  # fake Crystal badge
OS_MAC = bytes.fromhex("f412fa0000aa")  # fake badge os badge behind it
link = bn.Link(name=name, kind=bn.K_CRYSTAL,
               caps=bn.CAP_REMOTE | bn.CAP_PONG | bn.CAP_BRIDGE | bn.CAP_SKETCH | bn.CAP_ROBOTS,
               mac=ME, port=port, bcast_port=link_port, listen_bcast=True)
if bcasts:
    link.bcast = bcasts[0]
    _hello = link.hello

    def hello_all():
        for b in bcasts:
            link.bcast = b
            _hello()
    link.hello = hello_all
robots = robonet.RoboNet(lambda addr, t, body: link.send(addr, t, body), engine=engine)


def robot_peers():
    return [(p.addr, p.mac, p.name) for p in link.live_peers((bn.K_CRYSTAL, bn.K_BEAGLE))
            if p.addr and p.caps & bn.CAP_ROBOTS]


tour = tourney.Tourney(robots, ME, name, mine=mine, builtins=builtins, engine=engine, peers=robot_peers)


def on_packet(t, src, body, addr):
    if t == "T":
        tour.rx(src, body, addr)
    else:
        robots.rx(src, t, body, addr)


link.on_packet = on_packet
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
    elif w[0] == "robot" and (len(w) == 1 or w[1] in ("list", "run")):
        pass
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
sources = [open(f, "rb").read() for f in challenge[1]] if challenge else []
challenged = False
started = False
in_tourney = tourney_at is not None or bool(mine)
while time.time() < end:
    robots.tick()
    tour.tick()
    if tourney_at is not None and not started and len(robot_peers()) >= tourney_at:
        print("sim: tournament start ->", tour.start(seed or 0, seeds), flush=True)
        started = True
    if in_tourney and tour.verdict:
        break
    if challenge and not challenged:
        for p in link.live_peers((bn.K_CRYSTAL, bn.K_BEAGLE)):
            if p.addr and p.caps & bn.CAP_ROBOTS and (
                    p.name.lower().startswith(challenge[0].lower()) or
                    bn.mac_str(p.mac).replace(":", "").endswith(challenge[0].lower())):
                robots.challenge(p.addr, p.mac, sources, seed or (int(time.time()) & 0x7FFFFFFF) | 1)
                challenged = True
                break
    if challenge and robots.verdict:
        break
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
print("sim: done, rx", link.rx_count, "pong state", pong.state, "score", pong.g[6:8],
      "robots", robots.verdict)
if in_tourney:
    for _ in range(150):  # linger: others may still want our result or the standings
        robots.tick()
        tour.tick()
        link.poll()
        time.sleep(0.01)
    sys.exit(0 if tour.verdict == "same" else 3 if tour.verdict == "different" else 4 if tour.verdict else 5)
if challenge:
    sys.exit(0 if robots.verdict == "same" else 3 if robots.verdict == "different" else 4)
