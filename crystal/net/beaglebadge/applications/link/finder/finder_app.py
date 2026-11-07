"""Badge Finder: nearby Supercon badges and how far away they are.

Lists badges heard on the badge link protocol (crystal/net/PROTOCOL.md):
Supercon badges running our Crystal firmware (direct, over Wi-Fi) and badge os
badges (over ESP-NOW, through a Crystal badge acting as a bridge). Distance is
an RSSI estimate (FTM when a badge reports one): for a Crystal badge, the RSSI
it measured of this BeagleBadge's frames; for a badge os badge, its RSSI at the
bridge. UP/DOWN pick, SELECT: hot/cold view of one badge, BACK: exit.
"""

import lvgl as lv
import sys
if "core" not in sys.path:
    sys.path.append("core")
from core import app
import time
import _badgenet as bn
import _linkui as ui


ALPHA = 0.3  # RSSI EMA per refresh (~1.5 s): ~5 s to settle


def zone(d):
    if d is None:
        return "?"
    return "near" if d < 1.5 else ("medium" if d < 5 else "far")


def dist_text(d):
    if d is None:
        return "  ?  "
    return "%.1fm" % d if d < 10 else "%dm" % int(d)


class FinderApp(app.App):
    def __init__(self):
        super().__init__("Badge Finder")
        self.screen = None
        self.timer = None
        self.link = None

    def enter(self, on_exit=None):
        self.on_exit_cb = on_exit
        self.screen = ui.make_screen()
        self.keys = ui.Keys()
        self.screen.add_event_cb(self.keys.on_event, lv.EVENT.KEY, None)
        try:
            self.link = bn.Link(name="Beagle " + bn.short_id(bn.my_mac()))
        except Exception as e:
            self.link = None
            ui.label(self.screen, "Network error:\n%s\nIs Wi-Fi up?" % e, 10, 80, 16)
        self.hint = ui.title_bar(self.screen, "Badge Finder", "searching...  UDP 4626")
        self.list = ui.RowList(self.screen, 4, 60, 392, row_h=34, rows=7, size=16, cols=[0, 128, 162, 222, 330])
        self.detail = None
        self.focus_mac = None
        self.hist = {}  # mac -> [(t, d)] smoothed distances, last 8 s
        self.ema = {}   # mac -> smoothed RSSI
        self.last = {}  # mac -> (metres, rssi, how) of the last refresh
        self.up = ui.symbol("UP", "^")
        self.down = ui.symbol("DOWN", "v")
        self.last_draw = 0
        self.timer = lv.timer_create(self.loop, 50, None)

    def smooth(self, p):
        """(metres, smoothed RSSI, how): EMA over the badge's own max-over-4-s RSSI."""
        d, rssi, how = self.link.peer_distance(p)
        if how.startswith("FTM") or rssi is None:
            return d, rssi, how
        e = self.ema.get(p.mac)
        e = rssi if e is None else e + ALPHA * (rssi - e)
        self.ema[p.mac] = e
        return bn.distance_m(e), e, how

    def arrow(self, mac):
        h = self.hist.get(mac, [])
        if len(h) < 3:
            return ""
        old, new = h[0][1], h[-1][1]
        if new < old * 0.8:
            return self.up       # getting closer
        if new > old * 1.25:
            return self.down     # moving away
        return "-"

    def rows(self, now):
        peers = []
        for p in self.link.live_peers((bn.K_CRYSTAL, bn.K_BADGEOS)):
            d, rssi, how = self.smooth(p)
            self.last[p.mac] = (d, rssi, how)
            self.trend(p.mac, d, now)
            peers.append((d if d is not None else 999, p, d, rssi))
        peers.sort(key=lambda t: t[0])
        out = []
        for _, p, d, rssi in peers:
            kind = "SC" if p.kind == bn.K_CRYSTAL else "os"
            r = "%d" % rssi if rssi is not None else "--"
            out.append(((p.label()[:12], kind, dist_text(d), zone(d) + " " + self.arrow(p.mac), r), p))
        return out

    def open_detail(self, p):
        self.focus_mac = p.mac
        self.detail = ui.box(self.screen, 0, 56, 400, 244, filled=False)
        self.d_name = ui.label(self.detail, p.label(), 10, 6, 24)
        self.d_big = ui.label(self.detail, "", 10, 50, 48 if ui.font(48) else 24)
        self.d_info = ui.label(self.detail, "", 10, 140, 16, 380)
        self.d_bar = ui.box(self.detail, 10, 200, 4, 24)
        ui.box(self.detail, 10, 228, 380, 2)
        self.hint.set_text("BACK: list")

    def close_detail(self):
        if self.detail:
            self.detail.delete()
        self.detail = None
        self.focus_mac = None
        self.hint.set_text("UP/DOWN pick  SELECT focus  BACK exit")

    def trend_word(self, mac):
        a = self.arrow(mac)
        return {self.up: "getting closer", self.down: "moving away", "-": "steady"}.get(a, "")

    def trend(self, mac, d, now):
        h = self.hist.setdefault(mac, [])
        if d is not None:
            h.append((now, d))
        while h and time.ticks_diff(now, h[0][0]) > 8000:
            h.pop(0)

    def draw(self, now):
        items = self.rows(now)
        if self.detail:
            p = self.link.peers.get(self.focus_mac)
            if p is None:
                return
            d, rssi, how = self.last.get(p.mac, (None, None, "RSSI"))
            if rssi is not None:
                rssi = int(rssi)
            self.d_big.set_text("%s %s %s" % (dist_text(d), zone(d), self.arrow(p.mac)))
            via = ""
            if p.kind == bn.K_BADGEOS:
                br = self.link.peers.get(p.via)
                via = "  via %s" % (br.label() if br else bn.short_id(p.via))
            age = time.ticks_diff(now, p.seen) // 1000
            self.d_info.set_text("%s, %s%s\n%s  seen %ds ago  %s" % (
                bn.KIND_NAME.get(p.kind, "?"), how, via,
                ("%d dBm" % rssi) if rssi is not None else "no RSSI yet", age, self.trend_word(p.mac)))
            w = 4 if rssi is None else max(4, min(380, (rssi + 100) * 6))
            self.d_bar.set_width(w)
            return
        self.items = items
        self.list.set_items([t for t, _ in items] or ["no badges heard yet",
                                                      "(Supercon: LINK screen, A = net on)"])
        n = len(items)
        self.hint.set_text("%d badge%s  UP/DOWN SELECT BACK" % (n, "" if n == 1 else "s"))

    def loop(self, t):
        if not self.screen:
            return
        now = time.ticks_ms()
        if self.link:
            self.link.poll()
        key, held = self.keys.poll()
        if key in ui.ESC:
            if self.detail:
                self.close_detail()
                self.last_draw = 0
            else:
                self.exit()
                if self.on_exit_cb:
                    self.on_exit_cb()
                return
        elif key in ui.UP and not self.detail:
            self.list.move(-1)
        elif key in ui.DOWN and not self.detail:
            self.list.move(1)
        elif key in ui.ENTER and not self.detail and self.link:
            items = getattr(self, "items", [])
            if items and self.list.sel < len(items):
                self.open_detail(items[self.list.sel][1])
                self.last_draw = 0
        if self.link and time.ticks_diff(now, self.last_draw) > 1500:
            self.last_draw = now
            self.draw(now)

    def exit(self):
        if self.timer:
            self.timer.delete()
            self.timer = None
        if self.link:
            self.link.close()
            self.link = None
        if self.screen:
            self.screen.delete()
            self.screen = None
