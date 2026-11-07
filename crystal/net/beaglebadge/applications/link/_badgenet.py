"""Badge link protocol v1 (crystal/net/PROTOCOL.md) for the badge-launcher.

UDP port 4626 on the shared Wi-Fi: announces (H), remote commands (C/R),
badge os Pong packets (P) and the ESP-NOW tunnel (E) through a Crystal
Supercon badge. Runs on MicroPython (unix port) and on CPython.

The leading underscore keeps the app loader from treating this file as an
app; the Link apps import it (their category folder is on sys.path).
"""

import socket
import struct
import time

try:
    ticks = time.ticks_ms
    tdiff = time.ticks_diff
except AttributeError:  # CPython
    def ticks():
        return int(time.monotonic() * 1000)

    def tdiff(a, b):
        return a - b

PORT = 4626
K_BEAGLE, K_CRYSTAL, K_BADGEOS = 1, 2, 3
KIND_NAME = {1: "BeagleBadge", 2: "Supercon", 3: "badge os"}
CAP_REMOTE, CAP_PONG, CAP_BRIDGE, CAP_SKETCH, CAP_ROBOTS = 1, 2, 4, 8, 16
SCREENS = ["nametag", "portrait", "sketch", "life", "snake", "diag", "link", "pong"]
BCAST6 = b"\xff" * 6
ZERO6 = b"\x00" * 6
STALE_MS = 15000

# RSSI -> metres: log-distance model (PROTOCOL.md section 4)
RSSI_1M = -45
PATH_N = 2.5


def mac_str(m):
    return ":".join("%02x" % b for b in m)


def short_id(m):
    return "%02X%02X" % (m[4], m[5])


def distance_m(rssi):
    if rssi is None or rssi >= 0 or rssi < -110:
        return None
    return 10 ** ((RSSI_1M - rssi) / (10 * PATH_N))


def bucket(d):
    if d is None:
        return "?"
    if d < 1:
        return "here"
    if d < 3:
        return "near"
    if d < 8:
        return "room"
    return "far"


def my_mac(ifname="wlan0"):
    try:
        with open("/sys/class/net/%s/address" % ifname) as f:
            return bytes(int(x, 16) for x in f.read().strip().split(":"))
    except Exception:
        return b"\x02\x00\x00\x00\x00\x01"


def addr_ip(addr):
    """IP text of a recvfrom address (MicroPython: raw sockaddr bytes)."""
    if isinstance(addr, tuple):
        return addr[0]
    try:
        return "%d.%d.%d.%d" % (addr[4], addr[5], addr[6], addr[7])
    except Exception:
        return "?"


def _sockaddr(ip, port):
    return socket.getaddrinfo(ip, port)[0][-1]


class Peer:
    def __init__(self, mac):
        self.mac = mac
        self.kind = 0
        self.caps = 0
        self.screen = 255
        self.flags = 0
        self.via = ZERO6
        self.name = ""
        self.addr = None      # where its packets came from (None: bridged)
        self.heard = {}       # mac -> (rssi, cm): what it measured
        self.seen = 0

    def rssi_of(self, mac):
        e = self.heard.get(mac)
        return None if e is None or e[0] == 127 else e[0]

    def label(self):
        return self.name or short_id(self.mac)


class Link:
    """One socket, the peer table, and handlers. Call poll() often."""

    def __init__(self, name="Beagle", kind=K_BEAGLE, caps=0, mac=None, port=PORT, bcast_port=PORT, listen_bcast=False):
        self.me = mac or my_mac()
        self.name = name
        self.kind = kind
        self.caps = caps
        self.screen = 255
        self.flags = 0
        self.heard_list = []   # [(mac, rssi, cm)] for our announces
        self.peers = {}
        self.seq = 0
        self.on_pong = None    # f(src_mac, pkt_bytes, via_mac or None)
        self.on_reply = None   # f(src_mac, status, seq, text)
        self.on_command = None  # f(src_mac, line, addr) -> status (simulators)
        self.on_tunnel = None  # f(bridge_mac, src_mac, rssi, payload)
        self.on_packet = None  # f(type, src_mac, body, addr): other types (robot battles B K G J Z)
        self.next_hello = 0
        self.rx_count = 0
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        s.bind(_sockaddr("0.0.0.0", port))
        s.setblocking(False)
        self.sock = s
        self.bcast = _sockaddr("255.255.255.255", bcast_port)
        # listen_bcast: also hear the announces broadcast to bcast_port while
        # bound to another port (the badges broadcast to 4626; a simulator on
        # 4627 shares 4626 with the launcher's apps; SO_REUSEADDR on both
        # sockets gets every broadcast to each of them)
        self.socks = [s]
        if listen_bcast and bcast_port != port:
            r = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            r.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            r.bind(_sockaddr("0.0.0.0", bcast_port))
            r.setblocking(False)
            self.socks.append(r)

    def close(self):
        for s in self.socks:
            try:
                s.close()
            except Exception:
                pass

    # ---- send ----------------------------------------------------------
    def _hdr(self, t, src=None):
        self.seq = (self.seq + 1) & 0xFF
        return b"BLK" + bytes((1, ord(t), self.seq)) + (src or self.me)

    def send(self, addr, t, body=b""):
        try:
            self.sock.sendto(self._hdr(t) + body, addr or self.bcast)
        except Exception as e:
            print("badgenet: send failed:", e)
        return self.seq

    def hello(self):
        name = self.name.encode()[:12]
        b = bytes((self.kind, self.caps, self.screen, self.flags)) + ZERO6
        b += name + b"\x00" * (12 - len(name))
        hl = self.heard_list[:8]
        b += bytes((len(hl),))
        for mac, rssi, cm in hl:
            b += mac + struct.pack("<bh", rssi, cm)
        self.send(None, "H", b)

    def command(self, peer, line):
        """Remote command to a Crystal badge; returns the sequence number."""
        return self.send(peer.addr, "C", line.encode())

    def pong_send(self, peer, pkt):
        if peer is None:
            self.send(None, "P", pkt)
        else:
            self.send(peer.addr, "P", pkt)

    def tunnel(self, bridge, dst, payload):
        """ESP-NOW frame through a bridge (sent with the bridge's MAC)."""
        self.send(bridge.addr, "E", dst + b"\x00" + payload)

    # ---- receive -------------------------------------------------------
    def poll(self):
        now = ticks()
        if tdiff(now, self.next_hello) >= 0:
            self.hello()
            self.next_hello = now + 1000
        for s in self.socks:
            for _ in range(32):
                try:
                    data, addr = s.recvfrom(2048)
                except Exception:
                    break
                self._rx(data, addr, now)

    def _rx(self, d, addr, now):
        if len(d) < 12 or d[0:3] != b"BLK" or d[3] != 1:
            return
        t = chr(d[4])
        src = bytes(d[6:12])
        if src == self.me:
            return
        b = d[12:]
        self.rx_count += 1
        if t == "H" and len(b) >= 23:
            if b[0] == K_BADGEOS and bytes(b[4:10]) == self.me:
                return
            p = self.peers.get(src)
            if p is None:
                p = Peer(src)
                self.peers[src] = p
            if b[0] == K_BADGEOS and p.kind == K_BADGEOS and bytes(b[4:10]) != p.via and b[22] >= 1 \
                    and b[29] == 127 and p.rssi_of(p.via) is not None and tdiff(now, p.seen) < 5000:
                return  # a second bridge that cannot hear it: keep the one that measures it
            p.kind, p.caps, p.screen, p.flags = b[0], b[1], b[2], b[3]
            p.via = bytes(b[4:10])
            p.name = bytes(b[10:22]).split(b"\x00")[0].decode()
            p.addr = None if p.kind == K_BADGEOS else addr
            p.seen = now
            heard = {}
            n = b[22]
            for i in range(n):
                o = 23 + 9 * i
                if o + 9 > len(b):
                    break
                rssi, cm = struct.unpack("<bh", bytes(b[o + 6:o + 9]))
                heard[bytes(b[o:o + 6])] = (rssi, cm)
            p.heard = heard
        elif t == "R" and len(b) >= 2:
            if self.on_reply:
                self.on_reply(src, b[0], b[1], bytes(b[2:]).decode())
        elif t == "C":
            st = 1
            if self.on_command:
                st = self.on_command(src, bytes(b).decode(), addr)
            self.sock.sendto(self._hdr("R") + bytes((st, d[5])), addr)
        elif t == "P" and len(b) >= 25:
            p = self.peers.get(src)
            if p is not None:
                p.seen = now
                p.addr = addr
            if self.on_pong:
                self.on_pong(src, bytes(b[:25]), None)
        elif t == "E" and len(b) > 7:
            mac = bytes(b[0:6])
            rssi = struct.unpack("<b", bytes(b[6:7]))[0]
            payload = bytes(b[7:])
            if self.on_tunnel:
                self.on_tunnel(src, mac, rssi, payload)
            if payload[:4] == b"PONG" and self.on_pong and len(payload) >= 25:
                self.on_pong(mac, payload[:25], src)
        elif self.on_packet:
            p = self.peers.get(src)
            if p is not None:
                p.seen = now
            self.on_packet(t, src, bytes(b), addr)

    def live_peers(self, kinds=None):
        now = ticks()
        out = []
        for p in self.peers.values():
            if tdiff(now, p.seen) > STALE_MS:
                continue
            if kinds and p.kind not in kinds:
                continue
            out.append(p)
        return out

    def peer_distance(self, p):
        """(metres or None, rssi or None, how) for a peer, from my point of view."""
        if p.kind == K_BADGEOS:
            # measured at its bridge (bridged announce carries one entry: the bridge)
            e = p.heard.get(p.via)
            if e and e[1] >= 0:
                return e[1] / 100.0, e[0], "FTM via bridge"
            rssi = e[0] if e and e[0] != 127 else None
            return distance_m(rssi), rssi, "RSSI at bridge"
        rssi = p.rssi_of(self.me)
        e = p.heard.get(self.me)
        if e and e[1] >= 0:
            return e[1] / 100.0, rssi, "FTM"
        return distance_m(rssi), rssi, "RSSI"


# ---- badge os Pong (main/link.h, app_pong.c), shared by app and simulator ----
W = 960
CH = 672 - 48
STEP_MS = 15
BALL_V, BALL_DY, PAD_V = 2, 3, 4
PAUSE_MS = 2500
BALL, PADW, PADH, PADX = 24, 16, 120, 24
WIN = 4
LINK_WINDOW, LINK_DECIDE, LINK_GIVEUP, LINK_TIMEOUT = 500, 600, 1500, 1000
LINK_PAIR_MS, LINK_GAME_MS = 50, 100
L_FREE, L_SEEK, L_PAIRED = 0, 1, 2
P_PAIR, P_GAME = 1, 2
PKT = "<4sBH6shhbbhhBB"


class Pong:
    """One side of a badge os Pong game. send(pkt_bytes, to_mac) is the transport."""

    def __init__(self, me, send, rand=None):
        self.me = me
        self.send = send
        self.state = L_FREE
        self.peer = ZERO6
        self.heard = {}
        self.host = False
        self.g = [0] * 8  # bx, by, dx, dy, py0, py1, s0, s1
        self.press = self.last_rx = self.next_tx = self.next_step = self.serve_at = 0
        self.sdx = BALL_V
        self.failed_at = None
        self.my_dy = 0  # paddle velocity input, px per step (-PAD_V..PAD_V)
        self._r = 12345
        self.rand = rand or self._rand

    def _rand(self):
        self._r = (self._r * 1103515245 + 12345) & 0x7FFFFFFF
        return self._r

    def reset_game(self, now):
        self.g = [(W - BALL) // 2, (CH - BALL) // 2, 0, 0, (CH - PADH) // 2, (CH - PADH) // 2, 0, 0]
        self.sdx = BALL_V if self.rand() & 1 else -BALL_V
        self.serve_at = now + PAUSE_MS
        self.next_step = now

    def pair_now(self, peer, now):
        self.peer = peer
        self.state = L_PAIRED
        self.last_rx = now
        self.host = self.me < peer
        self.reset_game(now)

    def press_pair(self, now):
        if self.state == L_PAIRED:
            return
        self.state = L_SEEK
        self.press = now
        self.peer = ZERO6

    def stop(self):
        self.state = L_FREE

    def rx(self, src, pkt, now):
        try:
            m, t, age, peer, bx, by, dx, dy, p0, p1, s0, s1 = struct.unpack(PKT, pkt)
        except Exception:
            return
        if m != b"PONG":
            return
        if t == P_PAIR and self.state != L_PAIRED:
            self.heard[src] = now - age
        mutual = src == self.peer and peer == self.me
        if self.state == L_SEEK and self.peer != ZERO6 and mutual:
            self.pair_now(src, now)
        if self.state == L_PAIRED and mutual:
            self.last_rx = now
            if t == P_GAME:
                if self.host:
                    self.g[5] = max(0, min(CH - PADH, p1))
                else:
                    mine = self.g[5]
                    self.g = [bx, by, dx, dy, p0, p1, s0, s1]
                    self.g[5] = mine

    def _fold(self, y):
        span = CH - BALL
        v = abs(y) % (2 * span)
        return 2 * span - v if v > span else v

    def _step(self, now):
        g = self.g
        if self.serve_at:
            if now < self.serve_at:
                return
            if g[6] == WIN or g[7] == WIN:
                g[6] = g[7] = 0
            r = self.rand()
            g[2] = self.sdx
            g[3] = (1 + (r // 2) % BALL_DY) * (1 if r & 1 else -1)
            self.serve_at = 0
        g[0] += g[2]
        g[1] += g[3]
        if g[1] < 0 or g[1] > CH - BALL:
            g[1] = self._fold(g[1])
            g[3] = -g[3]
        p = 1 if g[2] > 0 else 0
        face = W - PADX - PADW - BALL if p else PADX + PADW
        crossed = (g[0] >= face and g[0] - g[2] < face) if p else (g[0] <= face and g[0] - g[2] > face)
        off = g[1] + BALL // 2 - (g[4 + p] + PADH // 2)
        if crossed and abs(off) < (PADH + BALL) // 2:
            r = self.rand()
            g[0] = 2 * face - g[0]
            g[2] = -g[2]
            dy = int(off * BALL_DY / ((PADH + BALL) // 2)) + ((r >> 8) & 3) % 3 - 1
            dy = max(-BALL_DY, min(BALL_DY, dy))
            g[3] = dy if dy else (1 if (r >> 10) & 1 else -1)
        elif g[0] < -BALL or g[0] > W:
            g[7 - p] += 1  # score[!p]
            self.sdx = BALL_V if p else -BALL_V
            g[0], g[1], g[2], g[3] = (W - BALL) // 2, (CH - BALL) // 2, 0, 0
            self.serve_at = now + PAUSE_MS

    def tick(self, now):
        if self.state == L_SEEK and now - self.press >= LINK_GIVEUP:
            self.state = L_FREE
            self.failed_at = now
        if self.state == L_SEEK and now - self.press >= LINK_DECIDE and self.peer == ZERO6:
            cands = [m for m, t in self.heard.items() if abs(t - self.press) <= LINK_WINDOW]
            if len(cands) == 1:
                self.peer = cands[0]
            else:
                self.state = L_FREE
                self.failed_at = now
        if self.state == L_PAIRED and now - self.last_rx > LINK_TIMEOUT:
            self.state = L_FREE
            self.failed_at = now
        if self.state != L_PAIRED:
            self.next_step = now
        n = 0
        while self.state == L_PAIRED and now >= self.next_step and n < 40:
            me = 0 if self.host else 1
            self.g[4 + me] = max(0, min(CH - PADH, self.g[4 + me] + self.my_dy))
            if self.host:
                self._step(self.next_step)
            self.next_step += STEP_MS
            n += 1
        if n >= 40:
            self.next_step = now
        if self.state == L_FREE or now < self.next_tx:
            return
        g = self.g
        pkt = struct.pack(PKT, b"PONG", P_PAIR if self.state == L_SEEK else P_GAME,
                          (now - self.press) & 0xFFFF if self.state == L_SEEK else 0, self.peer,
                          g[0], g[1], g[2], g[3], g[4], g[5], g[6], g[7])
        self.send(pkt, BCAST6 if self.state == L_SEEK else self.peer)
        self.next_tx = now + (LINK_PAIR_MS if self.state == L_SEEK else LINK_GAME_MS)
