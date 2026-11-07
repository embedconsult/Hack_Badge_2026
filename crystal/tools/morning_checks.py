#!/usr/bin/env python3
"""Camera checks prepared overnight (Nov 2026): one flash, then

    python3 crystal/tools/morning_checks.py [trail|ink|fast|all]

Drives the badge over the console bridge (host.docker.internal:4000), takes
snapshots through crystal/flash-request/snap and saves them as
/tmp/morning-<name>.jpg. Nothing it sets is saved: a reboot restores the
defaults (diffe 19 0 10, inkf 2 2 2, FAST_ENTRY off).

trail  games' grey trail: ROCKS and ALIENS 40 s each with the diff
       white->black drive at 10 (default) and 6 frames (lighter black that
       may erase in one pull). Compare the faint copy one step behind.
ink    Sketch first-pass darkness: three strokes with inkf 2 2 2 (default),
       3 3 3 and 4 4 4 (the cursor erase fe must equal f1), each stroke then
       retraced once; the cursor parked off the line. Look for mid-grey first
       passes, darker retraces, and no cursor tick left behind.
fast   FAST_ENTRY: SCHEDULE -> Home -> SETTINGS -> Home -> BLOCKS -> Home
       with the flag on (one diff update per entry, logged "apps: fast entry
       ms"), snapping each; look for ghosts of the previous screen.
"""
import os, socket, sys, time

SNAP = "/work/Hack_Badge_2026/crystal/flash-request/snap"
JPG = SNAP + ".jpg"


_last_close = 0.0


def console(cmds):
    """cmds: list of strings; '@1.5' waits. Returns the console text."""
    # The Mac's socat bridge reopens the USB port per connection; one opened
    # less than ~2 s after the previous one closed often gets no data at all.
    # Keep 2 s between connections and check each with a "version" reply.
    global _last_close
    for attempt in range(6):
        time.sleep(max(0.0, _last_close + 2.0 - time.time()))
        s = socket.create_connection(("host.docker.internal", 4000), timeout=5)
        s.settimeout(0.05)
        s.sendall(b"version\r\n")
        got, e = b"", time.time() + 2.0
        while time.time() < e and b"badge " not in got:
            try:
                got += s.recv(4096)
            except socket.timeout:
                pass
        if b"badge " in got:
            break
        s.close()
        _last_close = time.time()
    else:
        raise SystemExit("console: no reply from the badge after 6 connections")
    out = []

    def rd(t):
        e = time.time() + t
        while time.time() < e:
            try:
                out.append(s.recv(4096).decode(errors="replace"))
            except socket.timeout:
                pass
    for c in cmds:
        if c.startswith("@"):
            rd(float(c[1:]))
        else:
            s.sendall((c + "\r\n").encode())
            rd(0.08)
    rd(0.5)
    s.close()
    _last_close = time.time()
    return "".join(out)


def snap(name):
    before = os.path.getmtime(JPG) if os.path.exists(JPG) else 0
    open(SNAP, "w").close()
    for _ in range(30):
        time.sleep(1)
        if os.path.exists(JPG) and os.path.getmtime(JPG) != before:
            break
    time.sleep(1)
    dst = "/tmp/morning-%s.jpg" % name
    if os.path.exists(JPG):
        os.system("cp %s %s" % (JPG, dst))
        print("snap", dst)
    else:
        print("snap FAILED", name)


def grep(text, *keys):
    for l in text.splitlines():
        if any(k in l for k in keys):
            print("  ", l.strip())


def trail():
    for d in (10, 6):
        for g in ("rocks", "aliens"):
            grep(console(["diffe 19 0 %d" % d, "@1", "mode %s" % g, "@40"]), "diffe")
            snap("trail-%s-draw%d" % (g, d))
            console(["mode home", "@8"])
    console(["diffe 19 0 10", "@1"])


def stroke(y_mv, l0, l1, back=True):
    cmds = ["knob r %d" % y_mv, "@0.3"]
    n = 40
    for i in range(n + 1):
        cmds += ["knob l %d" % (l0 + (l1 - l0) * i // n), "@0.05"]
    cmds.append("@1.5")
    if back:
        for i in range(n + 1):
            cmds += ["knob l %d" % (l1 - (l1 - l0) * i // n), "@0.05"]
        cmds.append("@1.5")
    cmds += ["knob r %d" % (y_mv + 120), "@2"]  # park the cursor off the line
    return cmds


def ink():
    console(["mode sketch", "@12", "press a", "@9"])
    for k, f in enumerate((2, 3, 4)):
        console(["inkf %d %d %d" % (f, f, f), "@1.5"])
        grep(console(stroke(900 + k * 500, 500, 2900) + ["knob off", "@1"]), "inkf", "ink upload")
    snap("ink-f2-f3-f4")
    console(["inkf 2 2 2", "@1"])


def fast():
    t = console(["flag FAST_ENTRY 1", "@1", "mode schedule", "@9"])
    snap("fast-0-schedule")
    for i, c in enumerate(("press menu", "mode settings", "press menu", "mode blocks", "press menu")):
        t += console([c, "@6"])
        snap("fast-%d-%s" % (i + 1, c.split()[-1]))
    grep(t, "fast entry", "entry ms")
    console(["flag FAST_ENTRY 0", "@1"])


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    for name, fn in (("trail", trail), ("ink", ink), ("fast", fast)):
        if what in (name, "all"):
            print("==", name)
            fn()
