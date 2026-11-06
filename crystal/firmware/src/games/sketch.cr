# Sketch: port of upstream apps/sketch.py (branch claude_development), the
# knob-drawing toy. Left knob moves the pen left/right, right knob up/down
# (clockwise = right / up); the trace is drawn as you turn and the panel
# redraws shortly after the knobs stop.
#
#   User A - erase (blank frame, cleaning-flash refresh)
#   User B - two knobs: cleaning-flash refresh of the current drawing
#            one knob:  switch which axis the knob drives
#
# Knobs: upstream reads AS5600 angles (0..4095 counts). Here the analog
# knob millivolts are mapped onto 0..4095 counts and upstream's delta logic
# runs unchanged on them: wrap to -2048..2047, ignore |d| <= DEADBAND without
# advancing the reference (so slow turns still accumulate).
#
# Frame / branding: everything upstream shows comes from
# sketch_frame.png (960x672 red/black/white; embed main/sketch_frame.png),
# plus, only when a single knob drives the pen, a status line in white over
# the red frame at (STATUS_X, STATUS_Y) in an 8x8 font at STATUS_SCALE.
#
# Firmware contract (per tick):
#   if Sketch.tick(now, inp)                  # true = refresh the panel
#     if Sketch.needs_background?             # planes don't hold the frame
#       PNG.draw(frame_png, ..., EPD.black, EPD.red, 0, 0, ...)
#       draw Sketch.status_text (if non-empty) white-on-red
#     Sketch.render(EPD.black, EPD.red)       # overlay trace + pen
#     Sketch.want_clean? ? cleaning-flash fast refresh
#                        : 1-pass B/W fast refresh, no flash
# The trace lives in a private 1-bit canvas, so the planes can be redrawn
# from the PNG at any time. LEDs upstream: cyan = panel busy, yellow =
# dirty? (drawn, waiting), green = up to date; blink_request = white blinks
# owed after an axis switch.

require "./common"

module Sketch
  # Drawable area inside the frame's white screen (inclusive)
  X_MIN = 80
  Y_MIN = 68
  X_MAX = 880
  Y_MAX = 522

  PX_PER_REV      =  240 # pen travel per full knob turn (0..1 knob range)
  LINE_W          =    3 # trace thickness in pixels
  DEADBAND        =    3 # counts of jitter to ignore (of 4096)
  IDLE_REFRESH_MS =  700 # refresh this long after the knobs stop...
  MAX_WAIT_MS     = 4000 # ...or at most this long while still drawing
  INVERT_X        = false
  INVERT_Y        = false
  SWAP_KNOBS      = false # if the knobs come out backwards

  COUNTS = 4096

  # Upstream status line (only shown with a single knob)
  STATUS_X     = 200
  STATUS_Y     = 552
  STATUS_SCALE =   2

  # refresh_reason values
  R_NONE  = 0
  R_CLEAN = 1 # launch / erase / User B: cleaning flash
  R_IDLE  = 2 # knobs idle IDLE_REFRESH_MS
  R_MAX   = 3 # still drawing, MAX_WAIT_MS since the first change

  @@canvas = Pointer(UInt8).null
  @@knobs = 2           # 1 = single-knob mode (X knob only, B toggles axis)
  @@single_y = false    # single-knob mode drives Y
  @@px = 480
  @@py = 295
  @@fx = 0 # sub-pixel remainders in px * COUNTS (exact for 240/4096)
  @@fy = 0
  @@last_x = -1 # last accepted counts, -1 = none yet
  @@last_y = -1
  @@dirty = false
  @@pending_clean = false
  @@want_clean = false
  @@needs_bg = true
  @@blink = 0
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

  # The planes must be repainted from sketch_frame.png before render.
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
    SWAP_KNOBS ? "1 knob (right) - B switches X/Y" : "1 knob (left) - B switches X/Y"
  end

  # knobs: 2 (default) or 1 (single-knob mode, as upstream with one AS5600).
  def self.init(knobs : Int32 = 2) : Bool
    if @@canvas.null?
      @@canvas = game_alloc(Games::PLANE)
      return false if @@canvas.null?
    end
    @@knobs = knobs == 1 ? 1 : 2
    @@single_y = false
    @@px = (X_MIN &+ X_MAX).unsafe_div(2)
    @@py = (Y_MIN &+ Y_MAX).unsafe_div(2)
    @@fx = 0
    @@fy = 0
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

  # Empty frame with the pen dot; owes a cleaning-flash refresh.
  def self.blank : Nil
    Games.zero(@@canvas, Games::PLANE)
    pen_dot
    @@needs_bg = true
    @@pending_clean = true
    @@dirty = false
  end

  def self.pen_dot : Nil
    r = LINE_W.unsafe_div(2)
    Games.fill_rect(@@canvas, @@px &- r, @@py &- r, LINE_W, LINE_W)
  end

  # Millivolts in [lo, hi] -> encoder-style counts 0..4095.
  def self.counts(mv : Int32, lo : Int32, hi : Int32) : Int32
    c = Games.knob(mv, lo, hi)
    c > COUNTS &- 1 ? COUNTS &- 1 : c
  end

  # Upstream Knob.delta on counts; *last = -1 means no reading yet.
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

  # Line of width LINE_W: the 3x3 brush at every Bresenham point, which is
  # the same pixel set as upstream's 9 offset lines.
  def self.line(p : UInt8*, x0 : Int32, y0 : Int32, x1 : Int32, y1 : Int32) : Nil
    lo = 0 &- LINE_W.unsafe_div(2)
    dx = x1 &- x0
    dx = 0 &- dx if dx < 0
    dy = y1 &- y0
    dy = 0 &- dy if dy < 0
    sx = x0 < x1 ? 1 : -1
    sy = y0 < y1 ? 1 : -1
    err = dx &- dy
    while true
      Games.fill_rect(p, x0 &+ lo, y0 &+ lo, LINE_W, LINE_W)
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

  # Upstream _poll_knobs, on counts (cx = X knob, cy = Y knob).
  def self.poll(now : Int32, cx : Int32, cy : Int32) : Nil
    dx = 0
    dy = 0
    if @@knobs == 2
      dx = delta(cx, pointerof(@@last_x))
      dy = 0 &- delta(cy, pointerof(@@last_y)) # clockwise = up
    else
      d = delta(cx, pointerof(@@last_x))
      if @@single_y
        dy = 0 &- d
      else
        dx = d
      end
    end
    dx = 0 &- dx if INVERT_X
    dy = 0 &- dy if INVERT_Y
    return if dx == 0 && dy == 0

    @@fx = @@fx &+ dx &* PX_PER_REV
    @@fy = @@fy &+ dy &* PX_PER_REV
    mx = @@fx.unsafe_div(COUNTS) # truncates toward zero, like int()
    my = @@fy.unsafe_div(COUNTS)
    return if mx == 0 && my == 0
    @@fx = @@fx &- mx &* COUNTS
    @@fy = @@fy &- my &* COUNTS
    nx = @@px &+ mx
    ny = @@py &+ my
    nx = X_MIN if nx < X_MIN
    nx = X_MAX if nx > X_MAX
    ny = Y_MIN if ny < Y_MIN
    ny = Y_MAX if ny > Y_MAX
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
    cx = SWAP_KNOBS ? cr : cl
    cy = SWAP_KNOBS ? cl : cr
    poll(now, cx, cy)

    if clean
      @@want_clean = true
      @@dirty = false
      @@refresh_at = now
      @@reason = R_CLEAN
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
    true
  end

  # true = refresh the panel now (want_clean? picks the waveform).
  def self.tick(now : Int32, inp : LibGames::Input) : Bool
    tick_counts(now,
      counts(inp.left_mv, Games::LEFT_MV_LO, Games::LEFT_MV_HI),
      counts(inp.right_mv, Games::RIGHT_MV_LO, Games::RIGHT_MV_HI),
      inp.pressed)
  end

  # Overlay the trace (black, red cleared under it) onto planes that hold
  # the frame (see needs_background?). Byte-wise, so cheap enough per frame.
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
end
