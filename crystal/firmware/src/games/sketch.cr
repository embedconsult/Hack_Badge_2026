# Sketch: port of upstream apps/sketch.py (claude_development 5665ab1), the
# knob-drawing toy. Left knob moves the pen left/right, right knob up/down
# (clockwise = right / up); the trace is drawn as you turn and the panel
# redraws shortly after the knobs stop. The pen stops at the edges of the
# Etch-a-Sketch screen.
#
#   User A - erase (blank frame, cleaning-flash refresh)
#   User B - two knobs: cleaning-flash refresh of the current drawing
#            one knob:  switch which axis the knob drives
#
# Knobs: upstream reads each AS5600's analog OUT (on SAO1/SAO3 GPIO1 = GPIO2 /
# GPIO7, auto-detected) and maps microvolts onto 0..4095 counts. Here the
# firmware passes calibrated mV (ideally an average of ADC_SAMPLES reads);
# our measured ranges map onto counts, then upstream's delta logic runs
# unchanged: wrap to -2048..2047, ignore |d| <= DEADBAND without advancing
# the reference (so slow turns still accumulate).
#
# Background: data/gallery/EtchASketch.png (960x670; embed
# main/EtchASketch.png). Upstream first paints rows 668..671 red because the
# image is 2 rows short: Sketch.prep_background does that. With a single knob
# upstream also prints status_text white-on-red at (STATUS_X, STATUS_Y) in
# MicroPython's 8x8 font at STATUS_SCALE.
#
# Firmware contract (per tick):
#   if Sketch.tick(now, inp)                  # true = refresh the panel
#     if Sketch.needs_background?
#       Sketch.prep_background(EPD.black, EPD.red)
#       PNG.draw(etch_png, ..., EPD.black, EPD.red, 0, 0, ...)
#       draw Sketch.status_text (if non-empty) white-on-red
#     Sketch.render(EPD.black, EPD.red)       # overlay trace
#     if Sketch.want_clean?  -> fast refresh with cleaning flash
#     elsif Sketch.dirty_box(pointerof(x0), pointerof(y0), pointerof(x1), pointerof(y1))
#                            -> partial B/W refresh of that window only
#   if Sketch.led_frame(now, panel_busy, leds8) -> write the 8 LEDs
#
# The trace lives in a private 1-bit canvas, so the planes can be rebuilt
# from the PNG at any time.

require "./common"

module Sketch
  LINE_W = 3 # trace thickness in pixels
  HALF   = 1 # LINE_W / 2
  # Largest all-white box in EtchASketch.png's screen is x 132..826,
  # y 121..524; keep the whole 3 px line inside it (inclusive bounds).
  X_MIN = 134 # 132 + HALF + 1
  Y_MIN = 123
  X_MAX = 824 # 826 - HALF - 1
  Y_MAX = 522
  # The pen stays clear of the version label at the top and the help strip
  # at the bottom of the white screen (main.cr draws both inside it).
  PEN_Y_MIN = Y_MIN + 20 # label rows Y_MIN .. Y_MIN + 17
  PEN_Y_MAX = Y_MAX - 46 # help strip rows Y_MAX - 42 .. Y_MAX - 5

  PX_PER_REV      =  240 # pen travel per full knob turn (0..1 knob range)
  DEADBAND        =   12 # counts (of 4096) of ADC noise to ignore
  ADC_SAMPLES     =    8 # readings the firmware should average per poll
  IDLE_REFRESH_MS =  700 # refresh this long after the knobs stop...
  MAX_WAIT_MS     = 4000 # ...or at most this long while still drawing
  INVERT_X        = false
  INVERT_Y        = false
  SWAP_KNOBS      = false # if the knobs come out backwards

  COUNTS = 4096

  # LEDs (8: 0-3 = X knob, 4-7 = Y knob), colors 0xRRGGBB as upstream's
  # led_bar COLORS (scale by its brightness, 24/255 by default).
  LED_TURN_HOLD_MS = 400 # keep the turning animation this long after a turn
  LED_WALL_MS      = 250 # red flash after hitting a wall
  LED_DOT_STEPS    =  16 # dot steps per knob revolution
  C_OFF            = 0x000000_u32
  C_RED            = 0xFF0000_u32
  C_GREEN          = 0x00FF00_u32
  C_YELLOW         = 0xFFA000_u32
  C_CYAN           = 0x00FFFF_u32
  C_MAGENTA        = 0xFF00FF_u32
  C_WHITE          = 0xFFC896_u32
  X_COLOR          = C_CYAN
  Y_COLOR          = C_MAGENTA
  WALL_COLOR       = C_RED

  # Upstream status line (only shown with a single knob)
  STATUS_X     = 200
  STATUS_Y     = 560
  STATUS_SCALE =   2
  FRAME_ROWS   = 670 # EtchASketch.png height; rows 668..671 pre-filled red

  # refresh_reason values
  R_NONE  = 0
  R_CLEAN = 1 # launch / erase / User B: cleaning flash, whole panel
  R_IDLE  = 2 # knobs idle IDLE_REFRESH_MS: partial window
  R_MAX   = 3 # still drawing, MAX_WAIT_MS since the first change: partial

  @@canvas = Pointer(UInt8).null
  @@knobs = 2        # 1 = single-knob mode (X knob only, B toggles axis)
  @@single_y = false # single-knob mode drives Y
  @@px = 479
  @@py = 322
  @@fx = 0 # sub-pixel remainders in px * COUNTS (exact for 240/4096)
  @@fy = 0
  @@last_x = -1 # last accepted counts, -1 = none yet
  @@last_y = -1
  @@dirty = false
  @@pending_clean = false
  @@want_clean = false
  @@needs_bg = true
  @@blink = 0
  # ink bounding box since the last refresh (inclusive; empty if bx0 > bx1)
  @@bx0 = 1
  @@by0 = 1
  @@bx1 = 0
  @@by1 = 0
  # box handed to the refresh tick just requested
  @@rx0 = 1
  @@ry0 = 1
  @@rx1 = 0
  @@ry1 = 0
  # LED animation
  @@phase_x = 0 # accumulated counts (LED step = 4096 / LED_DOT_STEPS)
  @@phase_y = 0
  @@turn_x = 0
  @@turn_y = 0
  @@wall_x = 0
  @@wall_y = 0
  @@turned_x = false
  @@turned_y = false
  @@walled_x = false
  @@walled_y = false
  @@led_valid = false
  @@led_last = Pointer(UInt32).null # 8 colors
  # timestamps (ms, the `now` passed to tick)
  @@last_move = 0
  @@first_change = 0
  @@refresh_at = 0
  @@reason = R_NONE

  def self.x : Int32
    @@px
  end

  def self.y : Int32
    @@py
  end

  def self.canvas : UInt8*
    @@canvas
  end

  def self.dirty? : Bool
    @@dirty
  end

  # The refresh just asked for should be a cleaning flash (valid after
  # tick/render; a launch via Menu sets it in render).
  def self.want_clean? : Bool
    @@want_clean
  end

  # The planes must be rebuilt (prep_background + EtchASketch.png) before
  # render.
  def self.needs_background? : Bool
    @@needs_bg
  end

  def self.single_knob? : Bool
    @@knobs == 1
  end

  def self.single_axis_y? : Bool
    @@single_y
  end

  # Timestamps for latency logging: last pen motion, first change since the
  # last refresh, and when tick last returned true (+ why, R_*).
  def self.last_motion_ms : Int32
    @@last_move
  end

  def self.first_change_ms : Int32
    @@first_change
  end

  def self.refresh_ms : Int32
    @@refresh_at
  end

  def self.refresh_reason : Int32
    @@reason
  end

  # White LED blinks owed (1 = now X, 2 = now Y); reading clears it.
  def self.blink_request : Int32
    b = @@blink
    @@blink = 0
    b
  end

  # Upstream's status line; "" when both knobs are in use.
  def self.status_text : String
    return "" if @@knobs == 2
    SWAP_KNOBS ? "1 knob (SAO3/GPIO7) - B switches X/Y" : "1 knob (SAO1/GPIO2) - B switches X/Y"
  end

  # knobs: 2 (default) or 1 (single-knob mode, as upstream with one knob).
  def self.init(knobs : Int32 = 2) : Bool
    if @@canvas.null?
      @@canvas = game_alloc(Games::PLANE)
      @@led_last = game_alloc(32).as(UInt32*)
      return false if @@canvas.null? || @@led_last.null?
    end
    @@knobs = knobs == 1 ? 1 : 2
    @@single_y = false
    @@fx = 0
    @@fy = 0
    @@phase_x = 0
    @@phase_y = 0
    @@turned_x = false
    @@turned_y = false
    @@walled_x = false
    @@walled_y = false
    resync
    true
  end

  # (Re)launch, as upstream's `launched`: blank frame + cleaning flash.
  # Also forgets the knob references so turns made elsewhere don't jump.
  def self.resync : Nil
    @@last_x = -1
    @@last_y = -1
    blank
  end

  # Empty frame with the pen dot; owes a cleaning-flash refresh. Public so
  # the firmware can wire other erase triggers (upstream: MPU6050 shake,
  # with 3 white blinks).
  def self.blank : Nil
    Games.zero(@@canvas, Games::PLANE)
    # Pen back to the centre of the drawable area, and the knob references
    # forgotten: the next reading of each knob becomes its new zero, so the
    # current knob angles map to the centre.
    @@px = (X_MIN &+ X_MAX).unsafe_div(2)
    @@py = (PEN_Y_MIN &+ PEN_Y_MAX).unsafe_div(2)
    @@fx = 0
    @@fy = 0
    @@last_x = -1
    @@last_y = -1
    pen_dot
    @@needs_bg = true
    @@pending_clean = true
    @@dirty = false
    @@led_valid = false
    box_reset
  end

  def self.pen_dot : Nil
    Games.fill_rect(@@canvas, @@px &- HALF, @@py &- HALF, LINE_W, LINE_W)
  end

  # Upstream _blank's background prep: white planes, rows 668..671 red
  # (the PNG is 2 rows short). Then decode EtchASketch.png on top.
  def self.prep_background(black : UInt8*, red : UInt8*) : Nil
    Games.clear(black, red)
    Games.fill_rect(red, 0, 668, Games::W, 4)
  end

  # ---- partial-update window ----------------------------------------------

  def self.box_reset : Nil
    @@bx0 = 1
    @@by0 = 1
    @@bx1 = 0
    @@by1 = 0
  end

  def self.box_add(x0 : Int32, y0 : Int32, x1 : Int32, y1 : Int32) : Nil
    if @@bx0 > @@bx1
      @@bx0 = x0
      @@by0 = y0
      @@bx1 = x1
      @@by1 = y1
      return
    end
    @@bx0 = x0 if x0 < @@bx0
    @@by0 = y0 if y0 < @@by0
    @@bx1 = x1 if x1 > @@bx1
    @@by1 = y1 if y1 > @@by1
  end

  # Inclusive pixel box of the ink added since the previous refresh, for the
  # refresh tick() just requested. false = no partial window (clean refresh
  # or nothing drawn).
  def self.dirty_box(x0 : Int32*, y0 : Int32*, x1 : Int32*, y1 : Int32*) : Bool
    return false if @@want_clean || @@rx0 > @@rx1
    x0.value = @@rx0
    y0.value = @@ry0
    x1.value = @@rx1
    y1.value = @@ry1
    true
  end

  # ---- knobs ----------------------------------------------------------------

  # Millivolts in [lo, hi] -> counts 0..4095.
  def self.counts(mv : Int32, lo : Int32, hi : Int32) : Int32
    c = Games.knob(mv, lo, hi)
    c > COUNTS &- 1 ? COUNTS &- 1 : c
  end

  # Upstream AnalogKnob.delta on counts; *last = -1 means no reading yet.
  def self.delta(a : Int32, last : Int32*) : Int32
    if last.value < 0
      last.value = a
      return 0
    end
    d = ((a &- last.value &+ 2048) & 4095) &- 2048
    return 0 if d >= 0 &- DEADBAND && d <= DEADBAND
    last.value = a
    d
  end

  # Line of width LINE_W: the 3x3 brush at every Bresenham point (the same
  # pixels as upstream's 9 offset lines). Grows the dirty box.
  def self.line(p : UInt8*, x0 : Int32, y0 : Int32, x1 : Int32, y1 : Int32) : Nil
    bx0 = x0 < x1 ? x0 : x1
    bx1 = x0 < x1 ? x1 : x0
    by0 = y0 < y1 ? y0 : y1
    by1 = y0 < y1 ? y1 : y0
    box_add(bx0 &- HALF, by0 &- HALF, bx1 &+ HALF, by1 &+ HALF)
    dx = x1 &- x0
    dx = 0 &- dx if dx < 0
    dy = y1 &- y0
    dy = 0 &- dy if dy < 0
    sx = x0 < x1 ? 1 : -1
    sy = y0 < y1 ? 1 : -1
    err = dx &- dy
    while true
      Games.fill_rect(p, x0 &- HALF, y0 &- HALF, LINE_W, LINE_W)
      break if x0 == x1 && y0 == y1
      e2 = err &* 2
      if e2 > 0 &- dy
        err = err &- dy
        x0 = x0 &+ sx
      end
      if e2 < dx
        err = err &+ dx
        y0 = y0 &+ sy
      end
    end
  end

  # Upstream _read_deltas + _poll_knobs, on counts (ax = X knob, ay = Y).
  def self.poll(now : Int32, ax : Int32, ay : Int32) : Nil
    cx = 0
    cy = 0
    if @@knobs == 2
      cx = delta(ax, pointerof(@@last_x))
      cy = delta(ay, pointerof(@@last_y))
    else
      d = delta(ax, pointerof(@@last_x))
      if @@single_y
        cy = d
      else
        cx = d
      end
    end
    cx = 0 &- cx if INVERT_X
    cy = 0 &- cy if INVERT_Y
    return if cx == 0 && cy == 0

    if cx != 0
      @@turn_x = now
      @@turned_x = true
      @@phase_x = @@phase_x &+ cx
    end
    if cy != 0
      @@turn_y = now
      @@turned_y = true
      @@phase_y = @@phase_y &+ cy
    end

    @@fx = @@fx &+ cx &* PX_PER_REV
    @@fy = @@fy &- cy &* PX_PER_REV # clockwise = up
    mx = @@fx.unsafe_div(COUNTS)    # truncates toward zero, like int()
    my = @@fy.unsafe_div(COUNTS)
    return if mx == 0 && my == 0
    @@fx = @@fx &- mx &* COUNTS
    @@fy = @@fy &- my &* COUNTS

    tx = @@px &+ mx
    ty = @@py &+ my
    nx = tx < X_MIN ? X_MIN : (tx > X_MAX ? X_MAX : tx)
    ny = ty < PEN_Y_MIN ? PEN_Y_MIN : (ty > PEN_Y_MAX ? PEN_Y_MAX : ty)
    if nx != tx
      @@wall_x = now
      @@walled_x = true
      @@fx = 0 # don't bank turns against the wall
    end
    if ny != ty
      @@wall_y = now
      @@walled_y = true
      @@fy = 0
    end
    return if nx == @@px && ny == @@py
    line(@@canvas, @@px, @@py, nx, ny)
    @@px = nx
    @@py = ny
    @@first_change = now unless @@dirty
    @@dirty = true
    @@last_move = now
  end

  # Tick on raw counts and button edges (test hook; tick() wraps it).
  def self.tick_counts(now : Int32, cl : Int32, cr : Int32, pressed : UInt32) : Bool
    clean = @@pending_clean
    if (pressed & Games::BTN_A) != 0_u32
      blank
      clean = true
    end
    if (pressed & Games::BTN_B) != 0_u32
      if @@knobs == 1
        @@single_y = !@@single_y
        @@blink = @@single_y ? 2 : 1
      else
        clean = true # display.clean(): re-flash the current drawing
      end
    end
    ax = SWAP_KNOBS ? cr : cl
    ay = SWAP_KNOBS ? cl : cr
    poll(now, ax, ay)

    if clean
      @@want_clean = true
      @@dirty = false
      @@refresh_at = now
      @@reason = R_CLEAN
      @@rx0 = 1
      @@rx1 = 0
      box_reset
      return true
    end
    @@want_clean = false
    return false unless @@dirty
    idle = now &- @@last_move >= IDLE_REFRESH_MS
    overdue = now &- @@first_change >= MAX_WAIT_MS
    return false unless idle || overdue
    @@dirty = false
    @@refresh_at = now
    @@reason = idle ? R_IDLE : R_MAX
    @@rx0 = @@bx0
    @@ry0 = @@by0
    @@rx1 = @@bx1
    @@ry1 = @@by1
    box_reset
    true
  end

  # true = refresh the panel now (want_clean? / dirty_box pick how).
  def self.tick(now : Int32, inp : LibGames::Input) : Bool
    tick_counts(now,
      counts(inp.left_mv, Games::LEFT_MV_LO, Games::LEFT_MV_HI),
      counts(inp.right_mv, Games::RIGHT_MV_LO, Games::RIGHT_MV_HI),
      inp.pressed)
  end

  # Overlay the trace (black, red cleared under it) onto planes that hold
  # the frame (see needs_background?).
  def self.render(black : UInt8*, red : UInt8*) : Nil
    c = @@canvas
    i = 0
    while i < Games::PLANE
      v = c[i]
      if v != 0_u8
        black[i] = black[i] | v
        red[i] = red[i] & (v ^ 0xFF_u8)
      end
      i = i &+ 1
    end
    @@needs_bg = false
    @@want_clean = true if @@pending_clean # e.g. entered via Menu
    @@pending_clean = false
  end

  # Fallback when the PNG isn't available: white screen, black outline
  # around the drawable area.
  def self.draw_plain_frame(black : UInt8*, red : UInt8*) : Nil
    Games.clear(black, red)
    Games.rect_outline(black, X_MIN &- 6, Y_MIN &- 6, X_MAX &- X_MIN &+ 13, Y_MAX &- Y_MIN &+ 13, 4)
  end

  # ---- LEDs (upstream _update_leds) ------------------------------------------

  # One knob's 4 LEDs into dst[0..3]; false = idle (no animation).
  def self.knob_leds(now : Int32, walled : Bool, wall : Int32, turned : Bool, turn : Int32,
                     phase : Int32, color : UInt32, dst : UInt32*) : Bool
    if walled && now &- wall < LED_WALL_MS
      i = 0
      while i < 4
        dst[i] = WALL_COLOR
        i = i &+ 1
      end
      return true
    end
    return false unless turned && now &- turn < LED_TURN_HOLD_MS
    pos = phase.unsafe_div(COUNTS.unsafe_div(LED_DOT_STEPS)) & 3 # int(), then % 4
    i = 0
    while i < 4
      dst[i] = i == pos ? color : C_OFF
      i = i &+ 1
    end
    true
  end

  # Fills dst[0..7] with this tick's LED colors (0xRRGGBB); true when they
  # differ from the last frame returned (write the LEDs only then).
  # panel_busy = an e-paper refresh is in progress.
  def self.led_frame(now : Int32, panel_busy : Bool, dst : UInt32*) : Bool
    l = knob_leds(now, @@walled_x, @@wall_x, @@turned_x, @@turn_x, @@phase_x, X_COLOR, dst)
    r = knob_leds(now, @@walled_y, @@wall_y, @@turned_y, @@turn_y, @@phase_y, Y_COLOR, dst + 4_i64)
    if !l && !r
      c = panel_busy ? C_CYAN : (@@dirty ? C_YELLOW : C_GREEN)
      i = 0
      while i < 8
        dst[i] = c
        i = i &+ 1
      end
    else
      i = 0
      while i < 4
        dst[i] = C_OFF unless l
        dst[i &+ 4] = C_OFF unless r
        i = i &+ 1
      end
    end
    return true if @@led_last.null?
    changed = !@@led_valid
    i = 0
    while i < 8
      changed = true if dst[i] != @@led_last[i]
      @@led_last[i] = dst[i]
      i = i &+ 1
    end
    @@led_valid = true
    changed
  end

  # Force the next led_frame to report a change (e.g. after a blink).
  def self.led_invalidate : Nil
    @@led_valid = false
  end
end
