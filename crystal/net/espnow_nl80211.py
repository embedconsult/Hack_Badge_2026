#!/usr/bin/env python3
"""ESP-NOW from Linux without monitor mode: nl80211 action-frame registration
and transmission on a managed interface (PROTOCOL.md section 7, experiment 1).

    espnow_nl80211.py listen [seconds] [ifname]       print ESP-NOW frames received
    espnow_nl80211.py send <text> [ifname] [freq]     broadcast one ESP-NOW frame
    espnow_nl80211.py bosr <name> [ifname]            broadcast a badge os BOSR beacon
    espnow_nl80211.py inject <name> [count]           BOSR beacons injected through a monitor vif (mon0)

Results on the BeagleBadge (TI CC33xx, kernel 6.12), 2026-11-07:
  - listen: registration ok, but no ESP-NOW frame ever arrives (the firmware drops them; a mon0 sniffer
    sees only a few beacons and data frames too).
  - send/bosr: ENOTCONN from mac80211 (station mode refuses management frames outside its BSS).
  - inject: WORKS. `iw phy phy0 interface add mon0 type monitor` runs next to the associated wlan0, and
    frames written to mon0 with a radiotap header go out on wlan0's channel: a Crystal badge received 24
    of 25 BOSR beacons (RSSI -26 dBm at 20 cm) and listed the BeagleBadge as a badge os badge.

ESP-NOW = 802.11 action frame, category 127 (vendor), OUI 18:fe:34, 4 random
bytes, then a vendor element dd <len> 18:fe:34 04 01 <payload>. Pure stdlib,
needs root (CAP_NET_ADMIN). Frames go out on the interface's current channel
unless freq (MHz) is given (off-channel TX, if the driver allows).
"""
import os
import socket
import struct
import sys
import time

NETLINK_GENERIC = 16
GENL_ID_CTRL = 0x10
CTRL_CMD_GETFAMILY = 3
CTRL_ATTR_FAMILY_ID = 1
CTRL_ATTR_FAMILY_NAME = 2
NLM_F_REQUEST, NLM_F_ACK = 1, 4
NLMSG_ERROR = 2

CMD_REGISTER_FRAME = 58
CMD_FRAME = 59
A_IFINDEX = 3
A_WIPHY_FREQ = 38
A_FRAME = 51
A_FRAME_MATCH = 91
A_FRAME_TYPE = 101
A_OFFCHANNEL_TX_OK = 108
A_DONT_WAIT_FOR_ACK = 142
A_RX_SIGNAL_DBM = 151

OUI = b"\x18\xfe\x34"


def attr(t, data):
    n = 4 + len(data)
    return struct.pack("=HH", n, t) + data + b"\x00" * ((4 - n % 4) % 4)


def parse_attrs(b):
    out = {}
    i = 0
    while i + 4 <= len(b):
        n, t = struct.unpack_from("=HH", b, i)
        if n < 4:
            break
        out[t & 0x3FFF] = b[i + 4:i + n]
        i += (n + 3) & ~3
    return out


class Genl:
    def __init__(self):
        self.s = socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, NETLINK_GENERIC)
        self.s.bind((0, 0))
        self.seq = 1
        self.fam = self.family("nl80211")

    def msg(self, fam, cmd, attrs, flags=NLM_F_REQUEST | NLM_F_ACK):
        self.seq += 1
        body = struct.pack("=BBH", cmd, 1, 0) + b"".join(attrs)
        hdr = struct.pack("=IHHII", 16 + len(body), fam, flags, self.seq, 0)
        self.s.send(hdr + body)
        return self.seq

    def recv(self):
        data = self.s.recv(65536)
        msgs = []
        i = 0
        while i + 16 <= len(data):
            n, t, f, seq, pid = struct.unpack_from("=IHHII", data, i)
            msgs.append((t, seq, data[i + 16:i + n]))
            i += (n + 3) & ~3
        return msgs

    def ack(self, seq):
        while True:
            for t, s, b in self.recv():
                if t == NLMSG_ERROR and s == seq:
                    return struct.unpack_from("=i", b)[0]

    def family(self, name):
        seq = self.msg(GENL_ID_CTRL, CTRL_CMD_GETFAMILY, [attr(CTRL_ATTR_FAMILY_NAME, name.encode() + b"\x00")],
                       NLM_F_REQUEST)
        for t, s, b in self.recv():
            if t == GENL_ID_CTRL:
                a = parse_attrs(b[4:])
                return struct.unpack("=H", a[CTRL_ATTR_FAMILY_ID][:2])[0]
        raise OSError("no nl80211")


def ifindex(name):
    return socket.if_nametoindex(name)


def mac_of(name):
    with open("/sys/class/net/%s/address" % name) as f:
        return bytes(int(x, 16) for x in f.read().strip().split(":"))


def espnow_frame(src, payload, dst=b"\xff" * 6, bssid=b"\xff" * 6):
    hdr = b"\xd0\x00" + b"\x00\x00" + dst + src + bssid + b"\x00\x00"
    body = b"\x7f" + OUI + os.urandom(4)
    body += b"\xdd" + bytes((5 + len(payload),)) + OUI + b"\x04\x01" + payload
    return hdr + body


def parse_espnow(frame):
    """(src mac, payload) or None"""
    if len(frame) < 24 + 8 + 7 or frame[0] != 0xD0:
        return None
    b = frame[24:]
    if b[0] != 0x7F or b[1:4] != OUI or b[8] != 0xDD or b[10:13] != OUI or b[13] != 4:
        return None
    n = b[9] - 5
    return frame[10:16], b[15:15 + n]


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return
    g = Genl()
    if args[0] == "listen":
        secs = float(args[1]) if len(args) > 1 else 10
        ifn = args[2] if len(args) > 2 else "wlan0"
        seq = g.msg(g.fam, CMD_REGISTER_FRAME, [attr(A_IFINDEX, struct.pack("=I", ifindex(ifn))),
                                                attr(A_FRAME_TYPE, struct.pack("=H", 0x00D0)),
                                                attr(A_FRAME_MATCH, b"\x7f" + OUI)])
        e = g.ack(seq)
        print("register action frames 7f 18fe34 on %s: %s" % (ifn, "ok" if e == 0 else os.strerror(-e)))
        if e:
            return
        g.s.settimeout(0.5)
        end = time.time() + secs
        n = 0
        while time.time() < end:
            try:
                msgs = g.recv()
            except socket.timeout:
                continue
            for t, s, b in msgs:
                if t != g.fam or b[0] != CMD_FRAME:
                    continue
                a = parse_attrs(b[4:])
                fr = a.get(A_FRAME, b"")
                sig = struct.unpack("=i", a[A_RX_SIGNAL_DBM][:4])[0] if A_RX_SIGNAL_DBM in a else None
                freq = struct.unpack("=I", a[A_WIPHY_FREQ][:4])[0] if A_WIPHY_FREQ in a else None
                p = parse_espnow(fr)
                n += 1
                if p:
                    print("esp-now from %s %s dBm %s MHz: %r" % (p[0].hex(":"), sig, freq, p[1][:40]))
                else:
                    print("action frame %d bytes, %s dBm" % (len(fr), sig))
        print("frames:", n)
    elif args[0] == "inject":
        name = args[1].encode()[:12]
        count = int(args[2]) if len(args) > 2 else 5
        if not os.path.exists("/sys/class/net/mon0"):
            os.system("iw phy phy0 interface add mon0 type monitor && ip link set mon0 up")
        mac = mac_of("wlan0")
        payload = b"BOSR" + mac + b"\x00" + name + b"\x00" * (12 - len(name))
        s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
        s.bind(("mon0", 0))
        radiotap = struct.pack("<BBHI", 0, 0, 8, 0)
        for _ in range(count):
            s.send(radiotap + espnow_frame(mac, payload))
            time.sleep(1)
        print("injected %d BOSR beacons as %r" % (count, name))
    elif args[0] in ("send", "bosr"):
        ifn = args[2] if len(args) > 2 else "wlan0"
        if args[0] == "send":
            payload = args[1].encode()
        else:
            name = args[1].encode()[:12]
            payload = b"BOSR" + mac_of(ifn) + b"\x00" + name + b"\x00" * (12 - len(name))
        # mac80211 refuses (ENOTCONN) management frames whose BSSID is not the associated AP's while
        # a station is connected: BSSID=<ap mac> in the environment uses the AP's (ESP-NOW receivers ignore it)
        bss = bytes(int(x, 16) for x in os.environ["BSSID"].split(":")) if os.environ.get("BSSID") else b"\xff" * 6
        at = [attr(A_IFINDEX, struct.pack("=I", ifindex(ifn))), attr(A_FRAME, espnow_frame(mac_of(ifn), payload, bssid=bss)),
              attr(A_DONT_WAIT_FOR_ACK, b"")]
        if len(args) > 3:
            at += [attr(A_WIPHY_FREQ, struct.pack("=I", int(args[3]))), attr(A_OFFCHANNEL_TX_OK, b"")]
        e = g.ack(g.msg(g.fam, CMD_FRAME, at))
        print("tx esp-now %d bytes on %s: %s" % (len(payload), ifn, "ok" if e == 0 else os.strerror(-e)))


if __name__ == "__main__":
    main()
