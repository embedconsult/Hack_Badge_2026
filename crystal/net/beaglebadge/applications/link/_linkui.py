"""Small LVGL helpers shared by the Link apps (badge-launcher look and feel:
white screen, black text, 1 px black borders, inverted focus row)."""

import lvgl as lv
import time

UP = (lv.KEY.UP, lv.KEY.PREV, 11)
DOWN = (lv.KEY.DOWN, lv.KEY.NEXT, 9)
LEFT = (lv.KEY.LEFT, 20)
RIGHT = (lv.KEY.RIGHT, 19)
ENTER = (lv.KEY.ENTER, 10, 13)
ESC = (lv.KEY.ESC, 27, lv.KEY.BACKSPACE, 8)


def font(size):
    try:
        return getattr(lv, "font_montserrat_%d" % size)
    except AttributeError:
        return None


def make_screen():
    scr = lv.obj()
    scr.set_style_bg_color(lv.color_white(), 0)
    scr.set_style_bg_opa(lv.OPA.COVER, 0)
    scr.set_style_pad_all(0, 0)
    scr.set_style_border_width(0, 0)
    scr.remove_flag(lv.obj.FLAG.SCROLLABLE)
    lv.screen_load(scr)
    import input
    if input.driver and input.driver.group:
        input.driver.group.remove_all_objs()
        scr.add_flag(lv.obj.FLAG.CLICKABLE)
        input.driver.group.add_obj(scr)
        lv.group_focus_obj(scr)
        input.driver.group.set_editing(True)
    return scr


def label(parent, text, x, y, size=14, w=None):
    l = lv.label(parent)
    l.set_text(text)
    l.set_style_text_color(lv.color_black(), 0)
    f = font(size)
    if f:
        l.set_style_text_font(f, 0)
    if w:
        l.set_width(w)
        for name in ("LONG_MODE", "LONG"):
            enum = getattr(lv.label, name, None)
            if enum is not None and hasattr(enum, "CLIP"):
                l.set_long_mode(enum.CLIP)
                break
    l.set_pos(x, y)
    return l


def box(parent, x, y, w, h, filled=True, border=0):
    o = lv.obj(parent)
    o.set_size(w, h)
    o.set_pos(x, y)
    o.set_style_radius(0, 0)
    o.set_style_pad_all(0, 0)
    o.set_style_bg_color(lv.color_black() if filled else lv.color_white(), 0)
    o.set_style_bg_opa(lv.OPA.COVER, 0)
    o.set_style_border_width(border, 0)
    o.set_style_border_color(lv.color_black(), 0)
    o.remove_flag(lv.obj.FLAG.SCROLLABLE)
    return o


def title_bar(parent, title, hint):
    label(parent, title, 8, 4, 24)
    h = label(parent, hint, 8, 34, 14)
    rule = box(parent, 0, 54, 400, 2)
    return h


class Keys:
    """Edges with auto-repeat from the launcher's input driver (or LVGL KEY events)."""

    def __init__(self):
        self.prev = False
        self.next_rep = 0
        self.ev_key = 0

    def on_event(self, e):  # SDL / LVGL keyboard path
        self.ev_key = e.get_key()

    def poll(self):
        """Returns (key pressed now or repeating, key held or None)."""
        import input
        now = time.ticks_ms()
        if self.ev_key:
            k = self.ev_key
            self.ev_key = 0
            return k, None
        d = input.driver
        if not d:
            return None, None
        pressed = d.state == lv.INDEV_STATE.PRESSED
        key = d.last_key
        ev = None
        if pressed and not self.prev:
            ev = key
            self.next_rep = time.ticks_add(now, 450)
        elif pressed and time.ticks_diff(now, self.next_rep) >= 0:
            ev = key
            self.next_rep = time.ticks_add(now, 120)
        self.prev = pressed
        return ev, (key if pressed else None)


class RowList:
    """Up to `rows` text rows with an inverted focus row; scrolls with the focus."""

    def __init__(self, parent, x, y, w, row_h=30, rows=7, size=16):
        self.items = []
        self.sel = 0
        self.top = 0
        self.rows = rows
        self.objs = []
        self.shown = None
        for i in range(rows):
            b = box(parent, x, y + i * row_h, w, row_h - 2, filled=False)
            l = label(b, "", 6, (row_h - 2 - size) // 2 - 2, size, w - 12)
            self.objs.append((b, l))

    def set_items(self, items):
        self.items = items
        if self.sel >= len(items):
            self.sel = max(0, len(items) - 1)
        self.render()

    def move(self, d):
        if self.items:
            self.sel = (self.sel + d) % len(self.items)
            self.render()

    def render(self):
        if self.sel < self.top:
            self.top = self.sel
        if self.sel >= self.top + self.rows:
            self.top = self.sel - self.rows + 1
        state = (tuple(self.items[self.top:self.top + self.rows]), self.sel - self.top)
        if state == self.shown:
            return  # e-paper: touch nothing that did not change
        self.shown = state
        for i, (b, l) in enumerate(self.objs):
            k = self.top + i
            focus = k == self.sel and k < len(self.items)
            b.set_style_bg_color(lv.color_black() if focus else lv.color_white(), 0)
            b.set_style_border_width(1 if k < len(self.items) else 0, 0)
            l.set_style_text_color(lv.color_white() if focus else lv.color_black(), 0)
            l.set_text(self.items[k] if k < len(self.items) else "")
