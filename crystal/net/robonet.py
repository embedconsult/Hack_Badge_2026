"""Badge-to-badge robot battles on the badge link (PROTOCOL.md, messages
B K G J Z): the Python side of crystal/firmware/main/robonet.c, for
sim_badge.py (and so for a BeagleBadge facing a real Supercon badge).

Both badges run the same battle themselves. The battle engine here is the
badge's own (crystal/firmware/test/robots/empty_prelude.cr built with
--prelude=empty, the `rb` binary): `rb <seed> <limit> robot.cr ...` prints
"cycles C winner W hash H" and a line per robot with its damage. Without an
engine the simulator still answers challenges and transfers robots, but has
no result to compare.
"""
import os
import struct
import subprocess
import tempfile
import time
import zlib

CHUNK = 512
SRC_MAX = 8160
RETRY_MS = 400
TRIES = 50  # 20 s: a badge may be busy redrawing its e-paper


def ticks():
    return int(time.monotonic() * 1000)


def run_engine(engine, seed, limit, sources):
    """Simulate with the badge engine; (cycles, winner, [damage], hash)."""
    with tempfile.TemporaryDirectory() as d:
        files = []
        for i, src in enumerate(sources):
            f = os.path.join(d, "r%d.cr" % i)
            with open(f, "wb") as fh:
                fh.write(src)
            files.append(f)
        out = subprocess.run([engine, str(seed), str(limit)] + files, capture_output=True, text=True,
                             timeout=120).stdout
    cycles = winner = h = None
    dmg = []
    for line in out.splitlines():
        w = line.split()
        if w and w[0] == "cycles":
            cycles, winner, h = int(w[1]), int(w[3]), int(w[5])
        elif w and w[0] == "robot":
            dmg.append(int(w[3]))
    return cycles, winner, dmg, h


class RoboNet:
    """One badge's side. send(addr, type, body); on_status(text)."""

    def __init__(self, send, engine=None, on_status=None):
        self.send = send
        self.engine = engine
        self.on_status = on_status or (lambda t: print("robonet:", t, flush=True))
        self.cache = {}       # (crc, len) -> bytes, complete sources
        self.partial = {}     # (crc, len) -> {offset: bytes}
        self.m = None         # the current match
        self.verdict = None   # "same" / "different" / "failed: ..."

    # ---- challenger --------------------------------------------------
    def challenge(self, addr, mac, sources, seed, limit=500000):
        robots = [(zlib.crc32(s) & 0xFFFFFFFF, len(s), s) for s in sources]
        for crc, n, s in robots:
            self.cache[(crc, n)] = s
        mid = (zlib.crc32(b"".join(sources) + struct.pack("<II", seed, ticks() & 0xFFFFFFFF)) or 1)
        self.m = {"id": mid, "init": True, "addr": addr, "mac": mac, "seed": seed, "limit": limit,
                  "robots": robots, "state": "ask", "next": ticks() + RETRY_MS, "tries": 0, "send": [],
                  "mine": None, "theirs": None}
        self.verdict = None
        self._send_g()
        self.on_status("challenging, match %08x, seed %d" % (mid, seed))

    def _send_g(self):
        m = self.m
        b = struct.pack("<IIIB", m["id"], m["seed"], m["limit"], len(m["robots"]))
        for crc, n, _ in m["robots"]:
            b += struct.pack("<IH", crc, n)
        self.send(m["addr"], "G", b)

    def _send_b(self):
        m = self.m
        k, off = m["send"][0]
        crc, n, s = m["robots"][k]
        self.send(m["addr"], "B", struct.pack("<IHH", crc, n, off) + s[off:off + CHUNK])

    # ---- both ----------------------------------------------------------
    def rx(self, src_mac, t, b, addr):
        m = self.m
        if t == "B" and len(b) >= 8:
            crc, n, off = struct.unpack("<IHH", b[:8])
            data = bytes(b[8:])
            ok = 0 < n <= SRC_MAX and off % CHUNK == 0 and off < n and len(data) == min(CHUNK, n - off)
            if ok and (crc, n) not in self.cache:
                parts = self.partial.setdefault((crc, n), {})
                parts[off] = data
                if sum(len(v) for v in parts.values()) == n:
                    s = b"".join(parts[o] for o in sorted(parts))
                    del self.partial[(crc, n)]
                    if zlib.crc32(s) & 0xFFFFFFFF == crc:
                        self.cache[(crc, n)] = s
            self.send(addr, "K", struct.pack("<IHB", crc, off, 0 if ok else 1))
        elif t == "G" and len(b) >= 13:
            mid, seed, limit, cnt = struct.unpack("<IIIB", b[:13])
            robots = [struct.unpack("<IH", b[13 + 6 * k:19 + 6 * k]) for k in range(cnt)]
            if m and m["id"] == mid and not m["init"]:
                self.send(addr, "J", struct.pack("<IBB", mid, 0, 0))
                return
            if m and (m["state"] in ("ask", "send", "run") or (m["state"] == "done" and m["theirs"] is None)):
                self.send(addr, "J", struct.pack("<IBB", mid, 2, 0))
                return
            mask = 0
            for k, key in enumerate(robots):
                if key not in self.cache:
                    mask |= 1 << k
            if mask:
                self.send(addr, "J", struct.pack("<IBB", mid, 1, mask))
                self.on_status("asked for robots (mask %x)" % mask)
                return
            self.m = {"id": mid, "init": False, "addr": addr, "mac": src_mac, "seed": seed, "limit": limit,
                      "robots": [(c, n, self.cache[(c, n)]) for c, n in robots], "state": "run",
                      "mine": None, "theirs": None, "next": 0}
            self.verdict = None
            self.send(addr, "J", struct.pack("<IBB", mid, 0, 0))
            self.on_status("accepted match %08x, seed %d" % (mid, seed))
            self._play()
        elif m is None or src_mac != m["mac"]:
            return
        elif t == "J" and len(b) >= 6 and m["init"] and m["state"] == "ask":
            mid, st, mask = struct.unpack("<IBB", b[:6])
            if mid != m["id"]:
                return
            if st == 0:
                m["state"] = "run"
                self.on_status("peer accepted")
                self._play()
            elif st == 1:
                m["send"] = [(k, off) for k in range(len(m["robots"])) if mask & (1 << k)
                             for off in range(0, m["robots"][k][1], CHUNK)]
                m["state"] = "send"
                m["tries"] = 0
                m["next"] = ticks() + RETRY_MS
                self.on_status("sending %d chunks" % len(m["send"]))
                self._send_b()
            else:
                self._fail("peer is busy")
        elif t == "K" and len(b) >= 7 and m["state"] == "send":
            crc, off, st = struct.unpack("<IHB", b[:7])
            k, o = m["send"][0]
            if crc == m["robots"][k][0] and off == o:
                if st:
                    return self._fail("peer refused a robot")
                m["send"].pop(0)
                m["tries"] = 0
                m["next"] = ticks() + RETRY_MS
                if m["send"]:
                    self._send_b()
                else:
                    m["state"] = "ask"
                    self._send_g()
        elif t == "Z" and len(b) >= 10:
            mid, cyc, win, cnt = struct.unpack("<IIbB", b[:10])
            if mid != m["id"] or len(b) < 14 + cnt:
                return
            first = m["theirs"] is None
            m["theirs"] = (cyc, win, list(b[10:10 + cnt]), struct.unpack("<I", b[10 + cnt:14 + cnt])[0])
            self.on_status("peer result: cycles %d winner %d damage %s hash %08x" % (
                cyc, win, m["theirs"][2], m["theirs"][3]))
            has_mine = len(b) >= 15 + cnt and b[14 + cnt]
            if m["mine"] is not None:
                if not has_mine:
                    self._send_z()  # the peer still lacks ours (or lost it)
                if first:
                    self._judge()

    def _play(self):
        m = self.m
        if not self.engine:
            self.on_status("no engine (--engine): not simulating, no result to compare")
            return
        r = run_engine(self.engine, m["seed"], m["limit"], [s for _, _, s in m["robots"]])
        m["mine"] = (r[0], r[1], [min(255, d) for d in r[2]], r[3])
        m["state"] = "done"
        m["next"] = ticks() + 1000
        self.on_status("my result: cycles %d winner %d damage %s hash %08x" % (
            r[0], r[1], m["mine"][2], r[3]))
        self._send_z()
        if m["theirs"] is not None:
            self._judge()

    def _send_z(self):
        m = self.m
        cyc, win, dmg, h = m["mine"]
        self.send(m["addr"], "Z", struct.pack("<IIbB", m["id"], cyc, win, len(dmg)) + bytes(dmg) +
                  struct.pack("<IB", h, 1 if m["theirs"] is not None else 0))

    def _judge(self):
        m = self.m
        same = m["mine"] == m["theirs"]
        m["state"] = "over"
        self.verdict = "same" if same else "different"
        self.on_status("VERDICT: %s result" % self.verdict.upper())

    def _fail(self, why):
        self.m["state"] = "failed"
        self.verdict = "failed: " + why
        self.on_status(self.verdict)

    def tick(self):
        m = self.m
        if not m:
            return
        now = ticks()
        if m["state"] in ("ask", "send") and now >= m["next"]:
            m["tries"] += 1
            if m["tries"] > TRIES:
                return self._fail("peer did not answer")
            if m["state"] == "ask":
                self._send_g()
            else:
                self._send_b()
            m["next"] = now + RETRY_MS
        elif m["state"] == "done" and m["theirs"] is None and now >= m["next"]:
            self._send_z()
            m["next"] = now + 1000
