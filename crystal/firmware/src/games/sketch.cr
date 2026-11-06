# Etch-a-sketch. The pen moves by accumulated knob deltas: left knob = x,
# right knob = y, clockwise (rising mV) = right / up, PX_PER_RANGE px for the
# whole 0..1 knob range. Deltas smaller than DEADBAND (ADC noise) are ignored
# without moving the reference, so slow turns still accumulate; a jump of
# more than half the range is taken as a wrap past the end stop. Strokes are
# 3 px wide Bresenham lines into a private 1-bit canvas (survives mode
# switches); render copies it to the black plane plus a small pen cursor.
#
# Refresh policy: after the knobs pause PAUSE_MS, or every MAX_MS while the
# pen keeps moving. User A = erase.

require "./common"

module Sketch
  PX_PER_RANGE = 240
  DEADBAND     =  20 # Q12 units (~1.2 px)
  PAUSE_MS     = 1000 # refresh only once the knobs have been still this long
  WIDTH        =   3

  @@canvas = Pointer(UInt8).null
  @@x = 480
  @@y = 336
  @@kl = 0 # last accepted knob positions (Q12)
  @@kr = 0
  @@accx = 0 # sub-pixel remainders, in px * KNOB_ONE
  @@accy = 0
  @@synced = false
  @@dirty = false
  @@last_move = 0
  @@last_refresh = 0

  def self.x : Int32
    @@x
  end

  def self.y : Int32
    @@y
  end

  def self.dirty? : Bool
    @@dirty
  end

  def self.canvas : UInt8*
    @@canvas
  end

  def self.init : Bool
    if @@canvas.null?
      @@canvas = game_alloc(Games::PLANE)
      return false if @@canvas.null?
    end
    erase
    @@x = Games::W.unsafe_div(2)
    @@y = Games::H.unsafe_div(2)
    @@synced = false
    true
  end

  # Forget the knob reference (call when (re)entering the mode).
  def self.resync : Nil
    @@synced = false
  end

  def self.erase : Nil
    Games.zero(@@canvas, Games::PLANE)
    @@dirty = true
  end

  # Wrap-aware knob delta (Q12) with deadband; 0 = no movement.
  def self.knob_delta(prev : Int32, cur : Int32) : Int32
    d = cur &- prev
    half = Games::KNOB_ONE.unsafe_div(2)
    d = d &- Games::KNOB_ONE if d > half
    d = d &+ Games::KNOB_ONE if d < 0 &- half
    return 0 if d < DEADBAND && d > 0 &- DEADBAND
    d
  end

  # 3x3 (WIDTH) square brush centred on (x, y).
  def self.dot(p : UInt8*, x : Int32, y : Int32, w : Int32) : Nil
    h = w.unsafe_div(2)
    Games.fill_rect(p, x &- h, y &- h, w, w)
  end

  # Bresenham line from (x0, y0) to (x1, y1) inclusive, brush width w.
  def self.line(p : UInt8*, x0 : Int32, y0 : Int32, x1 : Int32, y1 : Int32, w : Int32) : Nil
    dx = x1 &- x0
    dx = 0 &- dx if dx < 0
    dy = y1 &- y0
    dy = 0 &- dy if dy < 0
    sx = x0 < x1 ? 1 : -1
    sy = y0 < y1 ? 1 : -1
    err = dx &- dy
    while true
      dot(p, x0, y0, w)
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

  # Move the pen by (dx, dy) px (screen coords), clamped; draws the stroke.
  def self.move_pen(dx : Int32, dy : Int32) : Nil
    nx = @@x &+ dx
    ny = @@y &+ dy
    nx = 0 if nx < 0
    ny = 0 if ny < 0
    nx = Games::W &- 1 if nx >= Games::W
    ny = Games::H &- 1 if ny >= Games::H
    line(@@canvas, @@x, @@y, nx, ny, WIDTH)
    @@x = nx
    @@y = ny
  end

  # Q12 knob delta -> whole px, keeping the remainder in acc (trunc to 0).
  def self.to_px(d : Int32, acc : Int32*) : Int32
    a = acc.value &+ d &* PX_PER_RANGE
    px = a.unsafe_div(Games::KNOB_ONE)
    acc.value = a &- px &* Games::KNOB_ONE
    px
  end

  # true = refresh the panel now.
  def self.tick(now : Int32, inp : LibGames::Input) : Bool
    kl = Games.knob_left(inp)
    kr = Games.knob_right(inp)
    unless @@synced
      @@synced = true
      @@kl = kl
      @@kr = kr
      @@accx = 0
      @@accy = 0
      @@last_move = now
      @@last_refresh = now
      @@dirty = true # show the canvas on entry
    end
    if Games.pressed?(inp, Games::BTN_A)
      erase
      @@last_refresh = now
      @@dirty = false
      return true
    end

    px = 0
    py = 0
    d = knob_delta(@@kl, kl)
    if d != 0
      @@kl = kl
      px = to_px(d, pointerof(@@accx))
    end
    d = knob_delta(@@kr, kr)
    if d != 0
      @@kr = kr
      py = 0 &- to_px(d, pointerof(@@accy)) # clockwise = up
    end
    if px != 0 || py != 0
      move_pen(px, py)
      @@dirty = true
      @@last_move = now
    end

    if @@dirty && now &- @@last_move >= PAUSE_MS
      @@dirty = false
      @@last_refresh = now
      return true
    end
    false
  end

  # Canvas -> black plane, red cleared, plus a 9 px hollow pen cursor.
  def self.render(black : UInt8*, red : UInt8*) : Nil
    Games.copy(black, @@canvas, Games::PLANE)
    Games.zero(red, Games::PLANE)
    Games.rect_outline(black, @@x &- 6, @@y &- 6, 13, 13, 1)
  end
end
