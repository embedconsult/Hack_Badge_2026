"""Link Pong: two-badge Pong, BeagleBadge against a Supercon badge.

badge os's game (yigitabi5444/supercon26-badge-os main/app_pong.c) with the
same packets and rules, so each badge draws its own view: here the court is
scaled to 400 x 260 and your paddle is on the left. Opponents:
  - a Supercon badge with our Crystal firmware: paired at once (`pong` command);
    it plays with its left knob or A/B;
  - a badge os badge, through a Crystal badge's ESP-NOW bridge: press SELECT
    here and any button there at the same moment (badge os pairing);
  - "anyone pressing now": a broadcast pairing over Wi-Fi.
UP/DOWN (held) move your paddle. BACK leaves the game.
"""

import lvgl as lv
import sys
if "core" not in sys.path:
    sys.path.append("core")
from core import app
import time
import _badgenet as bn
import _linkui as ui

SX = 400 / bn.W     # badge os px -> BeagleBadge px
TOP = 40            # court y offset here
CH_PX = int(bn.CH * SX)


class NetPongApp(app.App):
    def __init__(self):
        super().__init__("Link Pong")
        self.screen = None
        self.timer = None
        self.link = None
        self.pong = None

    def enter(self, on_exit=None):
        self.on_exit_cb = on_exit
        self.screen = ui.make_screen()
        self.keys = ui.Keys()
        self.screen.add_event_cb(self.keys.on_event, lv.EVENT.KEY, None)
        self.pane = None
        self.mode = "pick"
        self.opp = None
        self.bridge = None
        try:
            self.link = bn.Link(name="Beagle " + bn.short_id(bn.my_mac()), caps=bn.CAP_PONG)
            self.link.on_pong = self.on_pong
        except Exception as e:
            ui.label(self.screen, "network error: %s" % e, 8, 100, 16)
        self.show_pick()
        self.last = 0
        self.timer = lv.timer_create(self.loop, 30, None)

    # ---- pick ------------------------------------------------------------
    def clear(self):
        if self.pane:
            self.pane.delete()
        self.pane = ui.box(self.screen, 0, 0, 400, 300, filled=False)
        return self.pane

    def show_pick(self):
        self.mode = "pick"
        p = self.clear()
        self.hint = ui.title_bar(p, "Link Pong", "pick an opponent  SELECT  BACK")
        self.list = ui.RowList(p, 4, 60, 392, row_h=34, rows=6, size=16)
        self.choices = []
        self.refresh_pick()

    def refresh_pick(self):
        if not self.link:
            return
        ch = []
        for q in self.link.live_peers((bn.K_CRYSTAL,)):
            if q.caps & bn.CAP_PONG:
                ch.append(("%s (Supercon)%s" % (q.label()[:14], "  busy" if q.flags & 1 else ""), "direct", q))
        for q in self.link.live_peers((bn.K_BADGEOS,)):
            br = self.link.peers.get(q.via)
            if br and br.addr:
                ch.append(("%s (badge os, via %s)" % (q.label()[:10], br.label()[:8]), "bridge", q))
        ch.append(("anyone pressing now (Wi-Fi)", "seek", None))
        self.choices = ch
        self.list.set_items([c[0] for c in ch])

    # ---- game screen -------------------------------------------------------
    def show_game(self):
        self.mode = "game"
        p = self.clear()
        self.top = ui.label(p, "", 6, 6, 16, 300)
        self.score = ui.label(p, "", 310, 4, 24, 86)
        ui.box(p, 0, TOP - 2, 400, 2)
        for y in range(TOP, 300, 20):
            ui.box(p, 199, y + 5, 2, 10)
        self.goal = ui.box(p, 0, TOP, 3, CH_PX)
        pw, ph = max(4, int(bn.PADW * SX)), int(bn.PADH * SX)
        self.pad_l = ui.box(p, int(bn.PADX * SX), TOP, pw, ph)
        self.pad_r = ui.box(p, 400 - int(bn.PADX * SX) - pw, TOP, pw, ph, filled=False, border=2)
        b = max(6, int(bn.BALL * SX))
        self.ball = ui.box(p, 195, TOP + 100, b, b)
        self.shown = None
        self.frames = 0
        self.t0 = time.ticks_ms()

    def start(self, kind, q):
        now = time.ticks_ms()
        if kind == "bridge":
            self.bridge = self.link.peers.get(q.via)
            me = self.bridge.mac  # tunnelled frames leave with the bridge's MAC
            send = lambda pkt, to: self.link.tunnel(self.bridge, to, pkt)
        else:
            self.bridge = None
            me = self.link.me
            send = self.send_direct
        self.opp = q
        self.pong = bn.Pong(me, send)
        self.show_game()
        if kind == "direct":
            self.link.command(q, "pong")  # it pairs with us at once
            self.pong.pair_now(q.mac, now)
        else:
            self.pong.press_pair(now)

    def send_direct(self, pkt, to):
        if to == bn.BCAST6:
            self.link.pong_send(None, pkt)
        else:
            q = self.link.peers.get(to)
            if q and q.addr:
                self.link.pong_send(q, pkt)

    def on_pong(self, src, pkt, via):
        if not self.pong:
            return
        if self.bridge is not None:
            if via != self.bridge.mac:
                return
        elif via is not None:
            return
        self.pong.rx(src, pkt, time.ticks_ms())

    def render(self, now):
        pg = self.pong
        g = pg.g
        st = pg.state
        mirror = not pg.host
        if st == bn.L_PAIRED:
            msg = "playing: UP/DOWN"
        elif st == bn.L_SEEK:
            msg = "pairing... press there now"
        elif pg.failed_at is not None:
            msg = "no game: SELECT retries"
        else:
            msg = "SELECT: pair"
        me = 1 if mirror else 0
        top = "%s vs %s" % (msg, self.opp.label()[:10] if self.opp else "?")
        state = (top, g[6 + me], g[7 - me])
        if state != self.shown:
            self.shown = state
            self.top.set_text(top)
            self.score.set_text("%d : %d" % (g[6 + me], g[7 - me]))
        # positions, my paddle on the left
        y_me, y_op = g[4 + me], g[5 - me]
        self.pad_l.set_y(TOP + int(y_me * SX))
        self.pad_r.set_y(TOP + int(y_op * SX))
        bx = g[0] if not mirror else bn.W - bn.BALL - g[0]
        live = st == bn.L_PAIRED
        if live:
            self.ball.remove_flag(lv.obj.FLAG.HIDDEN)
            self.ball.set_pos(int(bx * SX), TOP + int(g[1] * SX))
        else:
            self.ball.add_flag(lv.obj.FLAG.HIDDEN)

    # ---- loop --------------------------------------------------------------
    def loop(self, t):
        if not self.screen:
            return
        now = time.ticks_ms()
        if self.link:
            self.link.poll()
        key, held = self.keys.poll()
        if key in ui.ESC:
            if self.mode == "game":
                if self.pong:
                    self.pong.stop()
                self.pong = None
                self.show_pick()
            else:
                self.exit()
                if self.on_exit_cb:
                    self.on_exit_cb()
            return
        if self.mode == "pick":
            if key in ui.UP:
                self.list.move(-1)
            elif key in ui.DOWN:
                self.list.move(1)
            elif key in ui.ENTER and self.choices:
                _, kind, q = self.choices[self.list.sel]
                self.start(kind, q)
            elif time.ticks_diff(now, self.last) > 2000:
                self.last = now
                self.refresh_pick()
            return
        pg = self.pong
        if key in ui.ENTER and pg.state != bn.L_PAIRED:
            if self.opp is not None and self.bridge is None:
                self.link.command(self.opp, "pong")
                pg.pair_now(self.opp.mac, now)
            else:
                pg.press_pair(now)
        pg.my_dy = -bn.PAD_V if held in ui.UP else (bn.PAD_V if held in ui.DOWN else 0)
        pg.tick(now)
        if time.ticks_diff(now, self.last) >= 60:
            self.last = now
            self.render(now)

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
