# App registry: every screen of the badge is an app module that includes
# the `App` marker. The home screen (src/apps/home.cr) shows them all as an
# icon grid; Menu +/- step through them inside an app, Menu + and Menu -
# pressed together go home from anywhere (knob task, src/main.cr).
#
# Layout and the "top bar with button labels" idea follow yigitabi5444's
# badge os (github.com/yigitabi5444/supercon26-badge-os, main/main.c); this
# is our own Crystal implementation.
#
# ---- Writing an app -----------------------------------------------------
# Drop a file into src/apps/ (main.cr requires "./apps/*"):
#
#   module FooApp
#     include App
#     ORDER = 300        # grid position, unique (built-ins 0..7, then 100+)
#     NAME  = "FOO"      # <= 9 characters: icon label, shell `mode foo`
#     # optional:
#     COLOR     = 0x00C0FF_u32 # LED colour (RGB) while selected / running
#     OWNS_MENU = true         # Menu +/- reach tick() as BTN_PLUS/BTN_MINUS
#                              # presses instead of switching apps
#
#     def self.icon(x : Int32, y : Int32) : Nil   # optional; Apps::ICON
#       Gfx.tile(x, y)                            # square at (x, y) in
#       Gfx.box(x + 40, y + 40, 80, 80, false)    # EPD.black (default:
#     end                                         # the first letter)
#
#     def self.enter : Nil          # required: draw the first frame, then
#       EPD.fill(EPD::WHITE)        # Apps.show_clean (full clean refresh)
#       TopBar.draw(NAME, "", "", "A: GO", "B: STOP")
#       Apps.show_clean
#     end
#
#     def self.tick(now : Int32, inp : LibGames::Input) : Nil # optional
#       # every main loop pass (input wakes it; else ~every 20 ms).
#       # Games.pressed?(inp, Games::BTN_B) ... redraw, then Apps.show
#       # (differential update: only changed pixels, ~0.65 s).
#     end
#
#     def self.leave : Nil          # optional: free radio / buffers
#     end
#   end
#
# Rules: only the main task touches the panel (enter / tick / leave run on
# it). Long work belongs on your own FreeRTOS task (C side). Check
# `Apps.leaving?` in long loops and return early: the user wants out.
# User A arrives as a press on RELEASE (the hold is the colour refresh on
# the built-in screens); B, knobs and owned Menu buttons arrive at once.
# Never use rows-only windows (EPD_NOTES.md); red only via EPD.refresh(false)
# (~33 s slow waveform).

module App
end

SCR_HOME = 255 # Shared.target / Shared.screen value of the home screen

module Apps
  ICON = 160 # icon square, px

  # Number of registered apps (home not counted).
  def self.count : Int32
    {{ App.includers.size }}
  end

  # Checks at compile time that the built-ins keep their SCR_* numbers.
  macro check_builtins
    {% for m, i in App.includers.sort_by { |m| m.constant("ORDER") } %}
      {% if m.has_constant?("BUILTIN") && m.constant("ORDER") != i %}
        {% raise "app #{m}: built-in ORDER #{m.constant("ORDER")} must equal its index #{i}" %}
      {% end %}
    {% end %}
  end

  def self.name(id : Int32) : String
    check_builtins
    {% for m, i in App.includers.sort_by { |m| m.constant("ORDER") } %}
      return {{m}}::NAME if id == {{i}}
    {% end %}
    id == SCR_HOME ? "HOME" : "?"
  end

  # Built-in screens: main.cr draws and runs them itself.
  def self.builtin?(id : Int32) : Bool
    {% for m, i in App.includers.sort_by { |m| m.constant("ORDER") } %}
      {% if m.has_constant?("BUILTIN") %} return true if id == {{i}} {% end %}
    {% end %}
    false
  end

  def self.owns_menu?(id : Int32) : Bool
    return true if id == SCR_HOME
    {% for m, i in App.includers.sort_by { |m| m.constant("ORDER") } %}
      {% if m.has_constant?("OWNS_MENU") %} return {{m}}::OWNS_MENU if id == {{i}} {% end %}
    {% end %}
    false
  end

  # LED colour 0xRRGGBB.
  def self.rgb(id : Int32) : UInt32
    {% for m, i in App.includers.sort_by { |m| m.constant("ORDER") } %}
      {% if m.has_constant?("COLOR") %} return {{m}}::COLOR.to_u32! if id == {{i}} {% end %}
    {% end %}
    k = id & 7
    k == 0 ? 0xFF6000_u32 : (k == 1 ? 0x60FF00_u32 : (k == 2 ? 0x00FFA0_u32 : (k == 3 ? 0x0080FF_u32 :
      (k == 4 ? 0xA000FF_u32 : (k == 5 ? 0xFF0080_u32 : (k == 6 ? 0xFFFF00_u32 : 0x00FFFF_u32))))))
  end

  def self.icon(id : Int32, x : Int32, y : Int32) : Nil
    {% for m, i in App.includers.sort_by { |m| m.constant("ORDER") } %}
      {% if m.class.has_method?(:icon) %}
        if id == {{i}}
          {{m}}.icon(x, y)
          return
        end
      {% end %}
    {% end %}
    Gfx.letter_icon(x, y, name(id))
  end

  def self.enter(id : Int32) : Nil
    @@leaving = false
    {% for m, i in App.includers.sort_by { |m| m.constant("ORDER") } %}
      {% unless m.has_constant?("BUILTIN") %}
        if id == {{i}}
          {{m}}.enter
          return
        end
      {% end %}
    {% end %}
  end

  def self.tick(id : Int32, now : Int32, inp : LibGames::Input) : Nil
    {% for m, i in App.includers.sort_by { |m| m.constant("ORDER") } %}
      {% if !m.has_constant?("BUILTIN") && m.class.has_method?(:tick) %}
        if id == {{i}}
          {{m}}.tick(now, inp)
          return
        end
      {% end %}
    {% end %}
  end

  def self.leave(id : Int32) : Nil
    {% for m, i in App.includers.sort_by { |m| m.constant("ORDER") } %}
      {% if m.class.has_method?(:leave) %}
        if id == {{i}}
          {{m}}.leave
          return
        end
      {% end %}
    {% end %}
  end

  # App id whose NAME matches buf[0, n] (ASCII, case-insensitive), or -1.
  def self.find(buf : UInt8*, n : Int32) : Int32
    return SCR_HOME if Gfx.same_word?(buf, n, "HOME")
    i = 0
    c = count
    while i < c
      return i if Gfx.same_word?(buf, n, name(i))
      i = i &+ 1
    end
    -1
  end

  # True once the user asked to leave the running app (Menu, home combo,
  # shell): long loops in enter/tick should return.
  def self.leaving? : Bool
    Shared.target != Shared.screen
  end

  def self.go_home : Nil
    Shared.target = SCR_HOME
  end

  # Full clean refresh (3 pulls, shaking base LUT): scene changes, ~3.5 s.
  # FAST_ENTRY (shell `flag FAST_ENTRY 1`, off by default until checked on
  # camera): entering an app or Home from another app or Home is one diff
  # update (~0.65 s, erases settled by EPD's settle pulls) instead of the
  # 3-pull clean (~4.5 s). A real clean still runs when red was on the panel,
  # when the previous screen isn't a registry app / Home (Sketch ink, colour
  # images: the diff baseline would be stale), after FAST_MAX fast entries
  # in a row, or when the app passes force = true.
  FAST_MAX = 8
  @@fast_entry = false
  @@entering = false
  @@entry_ok = false
  @@fast_n = 0

  def self.fast_entry? : Bool
    @@fast_entry
  end

  def self.fast_entry=(v : Bool) : Nil
    @@fast_entry = v
  end

  # enter_screen: around the app's enter (prev_ok = the previous screen
  # was a registry app or Home and no red is involved).
  def self.begin_entry(prev_ok : Bool) : Nil
    @@entering = true
    @@entry_ok = prev_ok
  end

  def self.end_entry : Nil
    @@entering = false
  end

  def self.show_clean(force : Bool = false) : Nil
    if @@entering && @@fast_entry && @@entry_ok && !force && @@fast_n < FAST_MAX && EPD.diff_shown_valid?
      @@fast_n = @@fast_n &+ 1
      t0 = millis
      show
      log2("apps: fast entry ms / fast entries in a row", millis &- t0, @@fast_n)
      return
    end
    @@fast_n = 0
    Shared.rendering = true
    fast_bw(3, EPD::LUT_BASE)
    # Open the diff session now (~0.6-3.6 s) so the first Apps.show after a
    # clean is one ~0.65 s pull, not a session open plus the pull.
    EPD.diff_prepare
    Shared.rendering = false
  end

  # Differential update (whole panel, only changed pixels driven, ~0.65 s):
  # menus, cursors, counters. Do a show_clean now and then (every ~20
  # updates or on page changes with lots of erased ink) against ghosts.
  def self.show : Nil
    Shared.rendering = true
    EPD.fast_pulls = 1
    EPD.refresh_diff
    Shared.rendering = false
  end
end

lib LibIDF
  fun cr_battery_pct : Int32 # main/apps.c: 0..100, -1 = on USB, -2 = unknown
  fun cr_tn_nearby : Int32   # main/net.c: a robot tournament nearby, not joined
end

# Drawing helpers into EPD.black (5x7 font, 6 px per char x scale).
module Gfx
  def self.box(x : Int32, y : Int32, w : Int32, h : Int32, black : Bool) : Nil
    EPD.fill_rect(x, y, w, h, black ? EPD::BLACK : EPD::WHITE)
  end

  # Outline t px thick (black or white).
  def self.frame(x : Int32, y : Int32, w : Int32, h : Int32, t : Int32, black : Bool = true) : Nil
    box(x, y, w, t, black)
    box(x, y &+ h &- t, w, t, black)
    box(x, y, t, h, black)
    box(x &+ w &- t, y, t, h, black)
  end

  def self.text(x : Int32, y : Int32, s : String, scale : Int32, black : Bool = true) : Int32
    draw_text(x, y, s, black ? EPD::BLACK : EPD::WHITE, scale)
    x &+ s.bytesize &* 6 &* scale
  end

  # Centred on cx.
  def self.text_c(cx : Int32, y : Int32, s : String, scale : Int32, black : Bool = true) : Nil
    draw_text(cx &- text_width(s, scale).unsafe_div(2), y, s, black ? EPD::BLACK : EPD::WHITE, scale)
  end

  def self.bytes(x : Int32, y : Int32, p : UInt8*, n : Int32, scale : Int32, black : Bool = true) : Int32
    draw_bytes(x, y, p, n, black ? EPD::BLACK : EPD::WHITE, scale)
  end

  # Filled disc (black or white).
  def self.disc(cx : Int32, cy : Int32, r : Int32, black : Bool) : Nil
    dy = 0 &- r
    while dy <= r
      dx = 0
      while (dx &+ 1) &* (dx &+ 1) &+ dy &* dy <= r &* r
        dx = dx &+ 1
      end
      box(cx &- dx, cy &+ dy, dx &* 2 &+ 1, 1, black)
      dy = dy &+ 1
    end
  end

  # Black Apps::ICON square with rounded corners (the icon base).
  def self.tile(x : Int32, y : Int32) : Nil
    s = Apps::ICON
    r = 24
    box(x, y, s, s, true)
    row = 0
    while row < r
      # corner cut: columns with (r-c)^2 + (r-row)^2 > r^2 become white
      c = 0
      while c < r && (r &- c) &* (r &- c) &+ (r &- row) &* (r &- row) > r &* r
        c = c &+ 1
      end
      if c > 0
        box(x, y &+ row, c, 1, false)
        box(x &+ s &- c, y &+ row, c, 1, false)
        box(x, y &+ s &- 1 &- row, c, 1, false)
        box(x &+ s &- c, y &+ s &- 1 &- row, c, 1, false)
      end
      row = row &+ 1
    end
  end

  # Default icon: the tile with the name's first letter in white.
  def self.letter_icon(x : Int32, y : Int32, name : String) : Nil
    tile(x, y)
    p = name.to_unsafe
    draw_bytes(x &+ (Apps::ICON &- 5 &* 14).unsafe_div(2), y &+ (Apps::ICON &- 7 &* 14).unsafe_div(2), p, 1, EPD::WHITE, 14)
  end

  def self.upper(c : UInt8) : UInt8
    c >= 0x61_u8 && c <= 0x7A_u8 ? c &- 0x20_u8 : c
  end

  def self.same_word?(buf : UInt8*, n : Int32, w : String) : Bool
    return false if n != w.bytesize
    p = w.to_unsafe
    i = 0
    while i < n
      return false if upper(buf[i]) != upper(p[i])
      i = i &+ 1
    end
    true
  end
end

# Top bar, rows 0..TopBar::H-1 (badge os idea): what each button does now,
# printed beside it, with a tab at the panel edge pointing at the button.
# The buttons sit two in each top corner: Menu - (GPIO40, "previous") above
# User A on the left, Menu + (GPIO15, "next") above User B on the right.
# Centre: the app's title, then version and battery. "" = no label.
module TopBar
  H = 48

  @@pct = -2
  @@next = 0

  def self.battery : Int32
    now = millis
    if @@next == 0 || now &- @@next >= 0
      @@pct = LibIDF.cr_battery_pct
      @@next = now &+ 60_000
    end
    @@pct
  end

  def self.label(left : Bool, y : Int32, s : String) : Nil
    return if s.bytesize == 0
    if left
      Gfx.box(0, y, 6, 16, true)
      Gfx.text(14, y &+ 1, s, 2)
    else
      Gfx.box(EPD::WIDTH &- 6, y, 6, 16, true)
      Gfx.text(EPD::WIDTH &- 14 &- text_width(s, 2), y &+ 1, s, 2)
    end
  end

  def self.draw(title : String, minus : String, plus : String, a : String, b : String) : Nil
    Gfx.box(0, 0, EPD::WIDTH, H, false)
    label(true, 4, minus)
    label(false, 4, plus)
    label(true, 26, a)
    label(false, 26, b)
    Gfx.text_c(EPD::WIDTH.unsafe_div(2), 5, title, 2)
    # version + battery, centred on the second row
    v = LibIDF.cr_version
    n = 0
    while n < 24 && v[n] != 0_u8 && v[n] != 0x20_u8 # git describe only, no build time
      n = n &+ 1
    end
    pct = battery
    buf = Shared.label_buf
    k = 0
    if pct >= 0
      k = put_decimal(buf, pct)
      buf[k] = 0x25_u8 # '%'
      k = k &+ 1
    elsif pct == -1
      buf[0] = 0x55_u8; buf[1] = 0x53_u8; buf[2] = 0x42_u8 # "USB"
      k = 3
    end
    w = n &* 12 &+ (k > 0 ? 24 &+ 36 &+ k &* 12 : 0)
    x = (EPD::WIDTH &- w).unsafe_div(2)
    if LibIDF.cr_tn_nearby != 0 # instead of the version: a hint, nothing more (robot autojoin)
      x = Gfx.text(x, 27, "TOURNEY NEARBY", 2)
    else
      x = draw_bytes(x, 27, v, n, EPD::BLACK, 2)
    end
    if k > 0
      x = x &+ 24
      Gfx.frame(x, 27, 26, 14, 2)
      Gfx.box(x &+ 26, 31, 3, 6, true)
      fill = pct < 0 ? 18 : (18 &* pct).unsafe_div(100)
      Gfx.box(x &+ 4, 31, fill, 6, true)
      draw_bytes(x &+ 36, 27, buf, k, EPD::BLACK, 2)
    end
    Gfx.box(0, H &- 4, EPD::WIDTH, 2, true)
  end
end
