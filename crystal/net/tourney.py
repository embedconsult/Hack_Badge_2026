"""Badge-link robot tournaments (PROTOCOL.md, message T): the Python side of
crystal/firmware/main/tourney_net.c, for sim_badge.py.

The badge with the lowest MAC among the robot badges organizes: it asks
everyone for their slot robots (Q -> E), fetches the sources it lacks
(S -> B chunks, robonet's cache), sends the plan (P -> A), and every badge
plays the whole tournament itself with the badge's engine
(`rb tourney <seed> <seeds> robot.cr ...`, src/robots/tourney.cr). Each sends
its tournament hash (R); the organizer compares and sends the standings (W).
"""
import os
import struct
import subprocess
import tempfile
import zlib

from robonet import CHUNK, RETRY_MS, ticks

ASK_TRIES = 50
HEAR_MS = 2500
FETCH_MS = 60000
PLAN_EVERY_MS = 1000
PLAN_FOR_MS = 60000
RESULT_MS = 900000
JOIN_MS = 120000
PUSH_MAX = 4
TN_MINE = 8
TN_ROBOTS = 48
TN_BADGES = 8
ENTRY = 6


def run_tourney(engine, seed, seeds, sources):
    """(hash, table bytes, text) of the whole tournament, with the badge engine."""
    with tempfile.TemporaryDirectory() as d:
        files = []
        for i, src in enumerate(sources):
            f = os.path.join(d, "r%d.cr" % i)
            with open(f, "wb") as fh:
                fh.write(src)
            files.append(f)
        out = subprocess.run([engine, "tourney", str(seed), str(seeds)] + files, capture_output=True, text=True,
                             timeout=600).stdout
    h, table = None, b""
    for line in out.splitlines():
        w = line.split()
        if w and w[0] == "hash":
            h = int(w[1])
        elif w and w[0] == "table":
            table = bytes.fromhex(w[1])
    return h, table, out


class Tourney:
    """One badge's tournament side. rn: robonet.RoboNet (cache, send)."""

    def __init__(self, rn, me, name, mine=(), builtins=(), engine=None, peers=None, on_status=None):
        self.rn = rn
        self.me = me
        self.name = name
        self.mine = [bytes(s) for s in mine]
        self.builtins = [bytes(s) for s in builtins]
        self.engine = engine
        self.peers = peers or (lambda: [])  # -> [(addr, mac, name)] live robot peers
        self.on_status = on_status or (lambda t: print("tourney:", t, flush=True))
        self.t = None
        self.verdict = None   # "same" / "different" / "failed: ..."
        self.standings = None  # (hash, table) from W
        self.pending = None    # asked to organize: (at, seed, seeds, asker)

    # ---- helpers -------------------------------------------------------
    def send(self, addr, sub, tid, body=b""):
        self.rn.send(addr, "T", sub.encode() + struct.pack("<I", tid) + body)

    def have(self, crc, n):
        return (crc, n) in self.rn.cache

    def got(self, crc, n):
        if self.have(crc, n):
            return 0xFFFFFFFF
        parts = self.rn.partial.get((crc, n), {})
        m = 0
        for off in parts:
            if off // CHUNK < 32:
                m |= 1 << (off // CHUNK)
        return m

    def key(self, s):
        return zlib.crc32(s) & 0xFFFFFFFF, len(s)

    def add(self, s):
        k = self.key(s)
        self.rn.cache[k] = s
        return k

    def push(self, addr, crc, n, got):
        s = self.rn.cache.get((crc, n))
        if s is None:
            return
        sent = 0
        for k, off in enumerate(range(0, n, CHUNK)):
            if sent >= PUSH_MAX:
                break
            if k < 32 and got & (1 << k):
                continue
            self.rn.send(addr, "B", struct.pack("<IHH", crc, n, off) + s[off:off + CHUNK])
            sent += 1

    def missing(self):
        return [r for r in self.t["robots"] if not self.have(r[0], r[1])]

    def request_missing(self, addr, owner=None):
        t = self.t
        for crc, n, o in t["robots"]:
            if (owner is None or o == owner) and not self.have(crc, n):
                self.send(addr, "S", t["tid"], struct.pack("<IHI", crc, n, self.got(crc, n)))

    def busy(self):
        return self.t is not None and self.t["st"] not in ("done", "failed")

    def _fail(self, why):
        self.t["st"] = "failed"
        self.verdict = "failed: " + why
        self.on_status(self.verdict)

    # ---- start ---------------------------------------------------------
    def start(self, seed, seeds=2):
        if self.busy():
            return -1
        peers = self.peers()
        if not peers:
            return -2
        lo = min(peers, key=lambda p: p[1])
        if self.me < lo[1]:
            self.organize(seed, seeds)
        else:
            self.t = {"role": "ask", "st": "ask", "org": lo, "seed": seed, "seeds": seeds, "next": 0, "tries": 0,
                      "tid": 0}
            self.on_status("asking %s to organize" % lo[2])
        return 0

    def name_of(self, mac):
        return next((n for a, m, n in self.peers() if m == mac), "badge")

    def organize(self, seed, seeds, asker=None):
        now = ticks()
        seed = (seed & 0x7FFFFFFF) if seed else ((now * 2654435761) & 0x7FFFFFFF) | 1
        tid = ((seed * 2246822519) ^ now ^ struct.unpack("<I", self.me[2:6])[0]) & 0xFFFFFFFF or 1
        badges = [{"addr": None, "mac": self.me, "name": self.name, "e": True, "mine": [self.add(s) for s in self.mine],
                   "gone": False, "ack": False, "res": False, "hash": None, "tries": 0, "next": 0}]
        peers = self.peers()
        if asker and all(p[1] != asker[1] for p in peers):
            peers.append(asker)  # it asked: in even if not heard yet
        for addr, mac, name in sorted(peers, key=lambda p: p[1])[:TN_BADGES - 1]:
            badges.append({"addr": addr, "mac": mac, "name": name, "e": False, "mine": [], "gone": False,
                           "ack": False, "res": False, "hash": None, "tries": 0, "next": 0})
        self.t = {"role": "org", "st": "collect", "tid": tid, "seed": seed, "seeds": max(1, min(4, seeds)),
                  "badges": badges, "robots": [], "mine_done": False, "w": None, "w_sent": 0, "next": 0}
        self.verdict = None
        self.standings = None
        self.on_status("organizing %08x with %d other badges, seed %d" % (tid, len(badges) - 1, seed))

    def _make_plan(self):
        t = self.t
        robots = []
        for k, b in enumerate(t["badges"]):
            for crc, n in b["mine"]:
                if len(robots) < TN_ROBOTS and n > 0 and all((crc, n) != r[:2] for r in robots):
                    robots.append((crc, n, k))
        for s in self.builtins:
            crc, n = self.add(s)
            if len(robots) < TN_ROBOTS and all((crc, n) != r[:2] for r in robots):
                robots.append((crc, n, 255))
        t["robots"] = robots
        t["st"] = "fetch"
        t["deadline"] = ticks() + FETCH_MS

    def _plan_body(self):
        t = self.t
        b = struct.pack("<IBBB", t["seed"], t["seeds"], len(t["badges"]), len(t["robots"]))
        for x in t["badges"]:
            b += x["mac"] + x["name"].encode()[:12].ljust(12, b"\0")
        for crc, n, o in t["robots"]:
            b += struct.pack("<IHB", crc, n, o)
        return b

    def _play(self):
        """Every badge plays the whole tournament itself."""
        t = self.t
        t["st"] = "plan" if t["role"] == "org" else "result"
        t["start"] = ticks()
        if not self.engine:
            self.on_status("no engine: not playing")
            return
        h, table, out = run_tourney(self.engine, t["seed"], t["seeds"], [self.rn.cache[r[:2]] for r in t["robots"]])
        t["hash"], t["table"] = h, table
        t["mine_done"] = True
        t["next"] = 0
        self.on_status("my result: %d robots, hash %u" % (len(t["robots"]), h))
        for line in out.splitlines():
            if line.startswith(("rank ", "final ", "champion ")):
                print("tourney:", line, flush=True)

    def _finish_org(self):
        t = self.t
        w = struct.pack("<IB", t["hash"] or 0, len(t["badges"]))
        for k, b in enumerate(t["badges"]):
            w += bytes((1 if k == 0 else 2 if not b["res"] else 1 if b["hash"] == t["hash"] else 0,))
        w += struct.pack("<H", len(t["table"])) + t["table"]
        t["w"] = w
        t["st"] = "done"
        self.standings = (t["hash"], t["table"])
        agree = [b["name"] for k, b in enumerate(t["badges"]) if w[5 + k] == 1]
        diff = [b["name"] for k, b in enumerate(t["badges"]) if w[5 + k] == 0]
        self.verdict = "different" if diff else "same"
        self.on_status("VERDICT: %s result (agree: %s; different: %s)" % (self.verdict.upper(), agree, diff))
        for b in t["badges"][1:]:
            if not b["gone"]:
                self.send(b["addr"], "W", t["tid"], w)

    # ---- receive -------------------------------------------------------
    def rx(self, src, b, addr):
        if len(b) < 5:
            return
        sub = chr(b[0])
        tid = struct.unpack("<I", b[1:5])[0]
        d = b[5:]
        t = self.t
        if sub == "S":
            if len(d) >= 10:
                crc, n, got = struct.unpack("<IHI", d[:10])
                self.push(addr, crc, n, got)
            return
        if sub == "O":
            if not self.busy() and not self.pending and len(d) >= 5:
                seed, seeds = struct.unpack("<IB", d[:5])  # in a moment: hear every badge's announce first
                self.pending = (ticks() + HEAR_MS, seed, seeds, (addr, src, self.name_of(src)))
            return
        if sub == "Q" and (not self.busy() or t["role"] == "ask") and not (t and t["role"] == "part" and t["tid"] == tid):
            mine = [self.add(s) for s in self.mine][:TN_MINE]
            self.t = {"role": "part", "st": "joined", "tid": tid, "org": (addr, src), "mine": mine,
                      "deadline": ticks() + JOIN_MS, "mine_done": False, "next": 0}
            self.verdict = None
            self.standings = None
            self.on_status("joined tournament %08x with %d robots" % (tid, len(mine)))
            self._send_e()
            return
        if not t or tid != t.get("tid"):
            return
        if t["role"] == "org":
            self._org_rx(src, sub, d, addr)
        elif t["role"] == "part" and src == t["org"][1]:
            t["org"] = (addr, src)
            self._part_rx(sub, d)

    def _send_e(self):
        t = self.t
        b = bytes((len(t["mine"]),)) + b"".join(struct.pack("<IH", c, n) for c, n in t["mine"])
        self.send(t["org"][0], "E", t["tid"], b)

    def _send_a(self):
        t = self.t
        self.send(t["org"][0], "A", t["tid"], bytes((len(self.missing()),)))

    def _org_rx(self, src, sub, d, addr):
        t = self.t
        b = next((x for x in t["badges"][1:] if x["mac"] == src), None)
        if b is None:
            return
        b["addr"] = addr
        if sub == "E" and t["st"] == "collect" and not b["e"] and d:
            m = d[0]
            if m > TN_MINE or len(d) < 1 + 6 * m:
                return
            b["e"] = True
            b["mine"] = [struct.unpack("<IH", d[1 + 6 * i:7 + 6 * i]) for i in range(m)]
            self.on_status("%s brings %d robots" % (b["name"], m))
        elif sub == "A" and d and d[0] == 0:
            b["ack"] = True
        elif sub == "R" and t["st"] in ("plan", "done") and len(d) >= 4:
            if not b["res"]:
                b["res"] = b["ack"] = True
                b["hash"] = struct.unpack("<I", d[:4])[0]
                self.on_status("%s's result: hash %u" % (b["name"], b["hash"]))
            if t["st"] == "done":
                self.send(addr, "W", t["tid"], t["w"])

    def _part_rx(self, sub, d):
        t = self.t
        if sub == "Q":
            if t["st"] == "joined":
                self._send_e()
        elif sub == "P" and len(d) >= 7:
            if t["st"] != "joined":
                self._send_a()
                return
            seed, seeds, nb, n = struct.unpack("<IBBB", d[:7])
            if len(d) < 7 + 18 * nb + 7 * n:
                return
            t["seed"], t["seeds"] = seed, seeds
            t["badges"] = [{"mac": d[7 + 18 * k:13 + 18 * k],
                            "name": d[13 + 18 * k:25 + 18 * k].split(b"\0")[0].decode()} for k in range(nb)]
            o = 7 + 18 * nb
            t["robots"] = [struct.unpack("<IHB", d[o + 7 * i:o + 7 * i + 7]) for i in range(n)]
            t["st"] = "get"
            t["deadline"] = ticks() + FETCH_MS
            self.on_status("plan: %d robots from %d badges, seed %d" % (n, nb, seed))
            if not self.missing():
                self._send_a()
                self._play()
            else:
                self._send_a()
        elif sub == "W" and t["st"] in ("result", "get") and len(d) >= 5:
            h, nb = struct.unpack("<IB", d[:5])
            tl = struct.unpack("<H", d[5 + nb:7 + nb])[0]
            table = d[7 + nb:7 + nb + tl]
            agree = [d[5 + k] for k in range(nb)]
            me = next((k for k, x in enumerate(t["badges"]) if x["mac"] == self.me), -1)
            if me >= 0:
                agree[me] = 1 if t.get("hash") == h else 0 if t["mine_done"] else 2
            self.standings = (h, table)
            t["st"] = "done"
            diff = [t["badges"][k]["name"] for k in range(nb) if agree[k] == 0]
            self.verdict = "different" if diff else "same"
            self.on_status("VERDICT: %s result (standings from the organizer; different: %s)" % (
                self.verdict.upper(), diff))

    # ---- tick ----------------------------------------------------------
    def tick(self):
        now = ticks()
        if self.pending and now >= self.pending[0]:
            _, seed, seeds, asker = self.pending
            self.pending = None
            if not self.busy():
                self.organize(seed, seeds, asker=asker)
        t = self.t
        if not t:
            return
        if t["role"] == "ask" and t["st"] == "ask" and now >= t["next"]:
            t["tries"] += 1
            if t["tries"] > ASK_TRIES:
                return self._fail("%s did not organize" % t["org"][2])
            self.send(t["org"][0], "O", 0, struct.pack("<IB", t["seed"], t["seeds"]))
            t["next"] = now + RETRY_MS
        elif t["role"] == "org":
            self._org_tick(now)
        elif t["role"] == "part":
            if t["st"] in ("joined", "get") and now >= t["deadline"]:
                return self._fail("sent no plan" if t["st"] == "joined" else "robots did not arrive")
            if t["st"] == "get" and now >= t["next"]:
                if not self.missing():
                    self._send_a()
                    self._play()
                    return
                self.request_missing(t["org"][0])
                t["next"] = now + RETRY_MS
            elif t["st"] == "result" and t["mine_done"] and now >= t["next"]:
                self.send(t["org"][0], "R", t["tid"], struct.pack("<I", t["hash"] or 0))
                t["next"] = now + PLAN_EVERY_MS

    def _org_tick(self, now):
        t = self.t
        if t["st"] == "collect":
            waiting = False
            for b in t["badges"][1:]:
                if b["e"] or b["gone"]:
                    continue
                waiting = True
                if now < b["next"]:
                    continue
                b["tries"] += 1
                if b["tries"] > ASK_TRIES:
                    b["gone"] = True
                    self.on_status("%s did not answer, left out" % b["name"])
                    continue
                self.send(b["addr"], "Q", t["tid"])
                b["next"] = now + RETRY_MS
            if not waiting:
                self._make_plan()
        elif t["st"] == "fetch":
            if now >= t["deadline"]:
                t["robots"] = [r for r in t["robots"] if self.have(r[0], r[1])]
            if not self.missing():
                if len(t["robots"]) < 2:
                    return self._fail("too few robots")
                for b in t["badges"][1:]:
                    b["next"] = 0
                self._play()
                return
            if now >= t["next"]:
                for k, b in enumerate(t["badges"]):
                    if k and not b["gone"]:
                        self.request_missing(b["addr"], k)
                t["next"] = now + RETRY_MS
        elif t["st"] == "plan":
            for b in t["badges"][1:]:
                if b["gone"] or b["ack"] or b["res"] or now < b["next"]:
                    continue
                if now > t["start"] + PLAN_FOR_MS:
                    b["gone"] = True
                    continue
                self.send(b["addr"], "P", t["tid"], self._plan_body())
                b["next"] = now + PLAN_EVERY_MS
            if t["mine_done"] and all(b["gone"] or b["res"] for b in t["badges"][1:]) or \
                    (t["mine_done"] and now > t["start"] + RESULT_MS):
                self._finish_org()
        elif t["st"] == "done" and t["w_sent"] < 3 and now >= t["next"]:
            for b in t["badges"][1:]:
                if not b["gone"] and b["res"]:
                    self.send(b["addr"], "W", t["tid"], t["w"])
            t["w_sent"] += 1
            t["next"] = now + PLAN_EVERY_MS
