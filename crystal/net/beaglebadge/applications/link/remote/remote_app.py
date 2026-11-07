"""Remote: control a Supercon badge (Crystal firmware) from the BeagleBadge.

Pick a badge, then: switch its screen, tap its buttons, start its colour
render, send nametag text, or draw on its Sketch with the joystick. Commands
are the badge's own shell words, sent as badge link `C` packets
(crystal/net/PROTOCOL.md); its reply shows at the bottom.
"""

import lvgl as lv
import sys
if "core" not in sys.path:
    sys.path.append("core")
from core import app
import time
import _badgenet as bn
import _linkui as ui

ACTIONS = [
    ("Nametag", "mode nametag"),
    ("Portrait", "mode portrait"),
    ("Sketch: draw with joystick", None),
    ("Send nametag text", None),
    ("Colour render (hold A)", "hold a"),
    ("Press A", "press a"),
    ("Press B", "press b"),
    ("Next screen (Menu +)", "press plus"),
    ("Previous screen (Menu -)", "press minus"),
    ("Life", "mode life"),
    ("Snake", "mode snake"),
    ("Pong screen", "mode pong"),
    ("Link screen", "mode link"),
    ("Clean the panel", "clean"),
]
STATUS = {0: "ok", 1: "refused", 2: "busy", 3: "bad syntax"}
CHARS = " ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!?-.|"
# Sketch canvas on the Supercon badge (src/games/sketch.cr), pen area
SK_X0, SK_X1, SK_Y0, SK_Y1 = 140, 818, 145, 474
STROKE_MS = 900  # one stroke per panel refresh, roughly


class RemoteApp(app.App):
    def __init__(self):
        super().__init__("Remote")
        self.screen = None
        self.timer = None
        self.link = None

    def enter(self, on_exit=None):
        self.on_exit_cb = on_exit
        self.screen = ui.make_screen()
        self.keys = ui.Keys()
        self.screen.add_event_cb(self.keys.on_event, lv.EVENT.KEY, None)
        self.hint = ui.title_bar(self.screen, "Remote", "")
        self.status = ui.label(self.screen, "", 8, 280, 14, 384)
        self.mode = "pick"
        self.target = None
        self.pane = None
        try:
            self.link = bn.Link(name="Beagle " + bn.short_id(bn.my_mac()))
            self.link.on_reply = self.on_reply
        except Exception as e:
            self.status.set_text("network error: %s" % e)
        self.show_pick()
        self.last = 0
        self.timer = lv.timer_create(self.loop, 50, None)

    # ---- panes -----------------------------------------------------------
    def new_pane(self):
        if self.pane:
            self.pane.delete()
        self.pane = ui.box(self.screen, 0, 56, 400, 222, filled=False)
        return self.pane

    def show_pick(self):
        self.mode = "pick"
        p = self.new_pane()
        self.list = ui.RowList(p, 4, 4, 392, row_h=34, rows=6, size=16)
        self.peers = []
        self.hint.set_text("pick a Supercon badge   SELECT  BACK")
        self.refresh_pick()

    def refresh_pick(self):
        if not self.link:
            return
        self.peers = [q for q in self.link.live_peers((bn.K_CRYSTAL,)) if q.caps & bn.CAP_REMOTE]
        scr = lambda q: bn.SCREENS[q.screen] if q.screen < len(bn.SCREENS) else "?"
        self.list.set_items(["%-14s %s  %s" % (q.label()[:14], bn.addr_ip(q.addr), scr(q)) for q in self.peers]
                            or ["no Supercon badge found yet", "(its LINK screen, A = net on)"])

    def show_actions(self):
        self.mode = "actions"
        p = self.new_pane()
        self.list = ui.RowList(p, 4, 4, 392, row_h=31, rows=7, size=16)
        self.list.set_items([a for a, _ in ACTIONS])
        self.hint.set_text("%s: SELECT sends   BACK" % self.target.label())

    def show_text(self):
        self.mode = "text"
        p = self.new_pane()
        self.text = list("Hello|Supercon")
        self.cur = 0
        ui.label(p, "UP/DOWN letter  LEFT/RIGHT move  SELECT send\n'|' starts the second line", 8, 6, 14, 384)
        self.t_lbl = ui.label(p, "", 8, 70, 24, 384)
        self.c_lbl = ui.label(p, "", 8, 110, 24, 384)
        self.render_text()
        self.hint.set_text("nametag text for %s" % self.target.label())

    def render_text(self):
        s = "".join(self.text)
        self.t_lbl.set_text(s)
        self.c_lbl.set_text(" " * self.cur + "^")

    def show_draw(self):
        self.mode = "draw"
        self.send("mode sketch")
        p = self.new_pane()
        # 678 x 329 badge px -> 339 x 165 here
        self.cv_x, self.cv_y = 30, 20
        ui.box(p, self.cv_x - 2, self.cv_y - 2, 343, 169, filled=False, border=2)
        self.pen = [(SK_X0 + SK_X1) // 2, (SK_Y0 + SK_Y1) // 2]
        self.sent = list(self.pen)
        self.pending = []  # corner points not sent yet
        self.dir = None
        self.cursor = ui.box(p, 0, 0, 6, 6)
        self.place_cursor()
        self.last_stroke = 0
        ui.label(p, "joystick draws  SELECT: colour  BACK: done", 8, 194, 14, 384)
        self.hint.set_text("drawing on %s" % self.target.label())

    def place_cursor(self):
        x = self.cv_x + (self.pen[0] - SK_X0) // 2
        y = self.cv_y + (self.pen[1] - SK_Y0) // 2
        self.cursor.set_pos(x - 3, y - 3)
        ui.box(self.pane, x - 1, y - 1, 2, 2)  # the trace stays on screen

    # ---- network -----------------------------------------------------------
    def send(self, line):
        if self.link and self.target:
            self.link.command(self.target, line)
            self.status.set_text("> " + line)

    def on_reply(self, src, st, seq, text):
        self.status.set_text("%s: %s %s" % (bn.short_id(src), STATUS.get(st, str(st)), text))

    # ---- loop --------------------------------------------------------------
    def draw_step(self, key, held, now):
        k = key  # edges and the driver's auto-repeat
        step = 12
        d = None
        if k in ui.UP:
            d = (0, -step)
        elif k in ui.DOWN:
            d = (0, step)
        elif k in ui.LEFT:
            d = (-step, 0)
        elif k in ui.RIGHT:
            d = (step, 0)
        if d:
            if self.dir is not None and d != self.dir:
                self.pending.append(tuple(self.pen))  # a corner: keep it
            self.dir = d
            self.pen[0] = max(SK_X0, min(SK_X1, self.pen[0] + d[0]))
            self.pen[1] = max(SK_Y0, min(SK_Y1, self.pen[1] + d[1]))
            self.place_cursor()
        if time.ticks_diff(now, self.last_stroke) >= STROKE_MS:
            nxt = self.pending.pop(0) if self.pending else tuple(self.pen)
            if list(nxt) != self.sent:
                self.send("stroke %d %d %d %d" % (self.sent[0], self.sent[1], nxt[0], nxt[1]))
                self.sent = list(nxt)
                self.last_stroke = now

    def loop(self, t):
        if not self.screen:
            return
        now = time.ticks_ms()
        if self.link:
            self.link.poll()
        key, held = self.keys.poll()
        m = self.mode
        if key in ui.ESC:
            if m == "pick":
                self.exit()
                if self.on_exit_cb:
                    self.on_exit_cb()
                return
            elif m == "actions":
                self.show_pick()
            else:
                self.show_actions()
            return
        if m == "pick":
            if key in ui.UP:
                self.list.move(-1)
            elif key in ui.DOWN:
                self.list.move(1)
            elif key in ui.ENTER and self.peers and self.list.sel < len(self.peers):
                self.target = self.peers[self.list.sel]
                self.show_actions()
            elif time.ticks_diff(now, self.last) > 2000:
                self.last = now
                self.refresh_pick()
        elif m == "actions":
            if key in ui.UP:
                self.list.move(-1)
            elif key in ui.DOWN:
                self.list.move(1)
            elif key in ui.ENTER:
                name, line = ACTIONS[self.list.sel]
                if name.startswith("Sketch"):
                    self.show_draw()
                elif name.startswith("Send nametag"):
                    self.show_text()
                else:
                    self.send(line)
        elif m == "text":
            if key in ui.UP or key in ui.DOWN:
                c = self.text[self.cur] if self.cur < len(self.text) else " "
                i = CHARS.find(c)
                i = (i + (1 if key in ui.UP else -1)) % len(CHARS)
                if self.cur >= len(self.text):
                    self.text.append(CHARS[i])
                else:
                    self.text[self.cur] = CHARS[i]
                self.render_text()
            elif key in ui.RIGHT:
                self.cur = min(len(self.text), self.cur + 1, 24)
                self.render_text()
            elif key in ui.LEFT:
                self.cur = max(0, self.cur - 1)
                self.render_text()
            elif key in ui.ENTER:
                s = "".join(self.text).strip()
                self.send("text " + s)
        elif m == "draw":
            if key in ui.ENTER:
                self.send("hold a")
            else:
                self.draw_step(key, held, now)

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
