# Rocks: a field of drifting rocks that split when shot (big -> 2 medium ->
# 2 small). Everything wraps around the playfield edges.
#
# Controls: right knob = ship heading (absolute dial, 32 directions over
#           the knob's travel), User B = thrust (held or tapped since the
#           last step), User A = fire. After game over, A or B restarts.
#
# Timing: one physics step per Arcade::STEP_MS (~1.5 fps). Velocities are
# per step in Q4 pixels; bullets move in SUB substeps so they can't skip
# over a small rock. Turning the knob is drawn on the next frame without
# waiting for the step. Black only: outlines 4 px thick.

require "./common"
require "./arcade"

module Rocks
  FX0 = 0
  FY0 = Arcade::LABEL_H
  FW  = Games::W
  FH  = Games::H - Arcade::LABEL_H
  Q   = 16 # position fixed point
  MAX_ROCKS = 32
  MAX_BULLETS = 4
  BULLET_V = 72   # px per step
  BULLET_LIFE = 6 # steps
  SUB = 4
  THRUST = 56 # Q4 px/step^2 per thrust step (3.5 px)
  VMAX = 640  # Q4 px/step (40 px)
  SHIP_R = 18
  KNOB_HYST = 48
  INVULN = 4 # steps after a respawn

  # rocks: {x, y, vx, vy, size (0 = free, 3 big, 2 medium, 1 small), seed}
  @@rocks = Pointer(Int32).null
  # bullets: {x, y, vx, vy, life}
  @@bul = Pointer(Int32).null
  @@sx = 0 # ship (Q4, field coordinates)
  @@sy = 0
  @@vx = 0
  @@vy = 0
  @@dir = 24 # up
  @@dir_b = -1
  @@thrusting = false
  @@score = 0
  @@lives = 3
  @@wave = 1
  @@over = false
  @@inv = 0
  @@last = 0
  @@started = false

  def self.score : Int32
    @@score
  end

  def self.lives : Int32
    @@lives
  end

  def self.wave : Int32
    @@wave
  end

  def self.over? : Bool
    @@over
  end

  def self.dir : Int32
    @@dir
  end

  def self.ship_x : Int32
    @@sx.unsafe_div(Q)
  end

  def self.ship_y : Int32
    @@sy.unsafe_div(Q)
  end

  def self.ship_vx : Int32
    @@vx
  end

  def self.ship_vy : Int32
    @@vy
  end

  def self.invulnerable? : Bool
    @@inv > 0
  end

  def self.rock(i : Int32) : Int32*
    @@rocks + (i &* 6).to_i64!
  end

  def self.bullet(i : Int32) : Int32*
    @@bul + (i &* 5).to_i64!
  end

  def self.radius(size : Int32) : Int32
    size == 3 ? 56 : (size == 2 ? 32 : 16)
  end

  def self.rock_count : Int32
    n = 0
    i = 0
    while i < MAX_ROCKS
      n = n &+ 1 if rock(i)[4] != 0
      i = i &+ 1
    end
    n
  end

  def self.bullet_count : Int32
    n = 0
    i = 0
    while i < MAX_BULLETS
      n = n &+ 1 if bullet(i)[4] > 0
      i = i &+ 1
    end
    n
  end

  # Test hooks.
  def self.clear_rocks : Nil
    i = 0
    while i < MAX_ROCKS
      rock(i)[4] = 0
      i = i &+ 1
    end
  end

  def self.place_ship(x : Int32, y : Int32, vx : Int32, vy : Int32) : Nil
    @@sx = x &* Q
    @@sy = y &* Q
    @@vx = vx
    @@vy = vy
  end

  def self.set_dir(d : Int32) : Nil
    @@dir = d & 31
  end

  def self.set_invuln(n : Int32) : Nil
    @@inv = n
  end

  # Adds a rock (pixel position, Q4 velocity); returns its slot or -1.
  def self.add_rock(x : Int32, y : Int32, vx : Int32, vy : Int32, size : Int32) : Int32
    i = 0
    while i < MAX_ROCKS
      r = rock(i)
      if r[4] == 0
        r[0] = x &* Q
        r[1] = y &* Q
        r[2] = vx
        r[3] = vy
        r[4] = size
        r[5] = Games.rand.to_i32! & 0x7FFFFFFF
        return i
      end
      i = i &+ 1
    end
    -1
  end

  def self.init : Bool
    if @@rocks.null?
      @@rocks = game_alloc(MAX_ROCKS &* 6 &* 4).as(Int32*)
      @@bul = game_alloc(MAX_BULLETS &* 5 &* 4).as(Int32*)
      return false if @@rocks.null? || @@bul.null?
    end
    restart
    true
  end

  def self.resync : Nil
    @@started = false
    @@dir_b = -1
  end

  def self.restart : Nil
    @@score = 0
    @@lives = 3
    @@wave = 1
    @@over = false
    respawn
    new_wave
  end

  def self.respawn : Nil
    @@sx = (FW &* Q).unsafe_div(2)
    @@sy = (FH &* Q).unsafe_div(2)
    @@vx = 0
    @@vy = 0
    @@inv = INVULN
    i = 0
    while i < MAX_BULLETS
      bullet(i)[4] = 0
      i = i &+ 1
    end
  end

  # 3 + wave big rocks (max 6) on the field edges, drifting inwards-ish.
  def self.new_wave : Nil
    clear_rocks
    n = 3 &+ @@wave
    n = 6 if n > 6
    k = 0
    while k < n
      # along the left/right edges, well away from the ship in the centre
      x = Games.rand_below(2) == 0 ? Games.rand_below(160) : FW &- Games.rand_below(160)
      y = Games.rand_below(FH)
      d = Games.rand_below(32)
      sp = 96 &+ Games.rand_below(96) &+ @@wave &* 16 # Q4: 6..12+ px/step
      add_rock(x, y, (Arcade.cos32(d) &* sp).unsafe_shr(10), (Arcade.sin32(d) &* sp).unsafe_shr(10), 3)
      k = k &+ 1
    end
  end

  def self.wrap(v : Int32, span : Int32) : Int32
    s = span &* Q
    while v < 0
      v = v &+ s
    end
    while v >= s
      v = v &- s
    end
    v
  end

  # Shortest wrapped distance on one axis (pixels).
  def self.wdist(a : Int32, b : Int32, span : Int32) : Int32
    d = a &- b
    d = 0 &- d if d < 0
    d = span &- d if d > span.unsafe_div(2)
    d
  end

  def self.near?(ax : Int32, ay : Int32, bx : Int32, by : Int32, r : Int32) : Bool
    dx = wdist(ax, bx, FW)
    dy = wdist(ay, by, FH)
    dx &* dx &+ dy &* dy < r &* r
  end

  def self.fire : Bool
    i = 0
    while i < MAX_BULLETS
      b = bullet(i)
      if b[4] <= 0
        c = Arcade.cos32(@@dir)
        s = Arcade.sin32(@@dir)
        b[0] = @@sx &+ (c &* SHIP_R &* Q).unsafe_shr(10)
        b[1] = @@sy &+ (s &* SHIP_R &* Q).unsafe_shr(10)
        b[2] = (c &* BULLET_V &* Q).unsafe_shr(10) &+ @@vx
        b[3] = (s &* BULLET_V &* Q).unsafe_shr(10) &+ @@vy
        b[4] = BULLET_LIFE
        return true
      end
      i = i &+ 1
    end
    false
  end

  def self.split(i : Int32) : Nil
    r = rock(i)
    size = r[4]
    @@score = @@score &+ (size == 3 ? 20 : (size == 2 ? 50 : 100))
    r[4] = 0
    return if size == 1
    x = r[0].unsafe_div(Q)
    y = r[1].unsafe_div(Q)
    # two children, velocities rotated +-90 degrees from the parent's, faster
    vx = r[2]
    vy = r[3]
    add_rock(x, y, vx &+ (0 &- vy).unsafe_div(2) &+ 16, vy &+ vx.unsafe_div(2), size &- 1)
    add_rock(x, y, vx &+ vy.unsafe_div(2) &- 16, vy &- vx.unsafe_div(2), size &- 1)
  end

  def self.move_bullets : Nil
    i = 0
    while i < MAX_BULLETS
      b = bullet(i)
      if b[4] > 0
        k = 0
        while k < SUB && b[4] > 0
          b[0] = wrap(b[0] &+ b[2].unsafe_div(SUB), FW)
          b[1] = wrap(b[1] &+ b[3].unsafe_div(SUB), FH)
          bx = b[0].unsafe_div(Q)
          by = b[1].unsafe_div(Q)
          j = 0
          while j < MAX_ROCKS
            r = rock(j)
            if r[4] != 0 && near?(bx, by, r[0].unsafe_div(Q), r[1].unsafe_div(Q), radius(r[4]))
              split(j)
              b[4] = 0
              break
            end
            j = j &+ 1
          end
          k = k &+ 1
        end
        b[4] = b[4] &- 1 if b[4] > 0
      end
      i = i &+ 1
    end
  end

  def self.move_rocks : Nil
    i = 0
    while i < MAX_ROCKS
      r = rock(i)
      if r[4] != 0
        r[0] = wrap(r[0] &+ r[2], FW)
        r[1] = wrap(r[1] &+ r[3], FH)
      end
      i = i &+ 1
    end
  end

  def self.move_ship(thrust : Bool) : Nil
    if thrust
      @@vx = @@vx &+ (Arcade.cos32(@@dir) &* THRUST).unsafe_shr(10)
      @@vy = @@vy &+ (Arcade.sin32(@@dir) &* THRUST).unsafe_shr(10)
    else
      # drag: lose 1/8 of the speed per step without thrust
      @@vx = @@vx &- @@vx.unsafe_div(8)
      @@vy = @@vy &- @@vy.unsafe_div(8)
    end
    @@vx = VMAX if @@vx > VMAX
    @@vx = 0 &- VMAX if @@vx < 0 &- VMAX
    @@vy = VMAX if @@vy > VMAX
    @@vy = 0 &- VMAX if @@vy < 0 &- VMAX
    @@sx = wrap(@@sx &+ @@vx, FW)
    @@sy = wrap(@@sy &+ @@vy, FH)
  end

  def self.check_ship : Nil
    return if @@inv > 0
    x = ship_x
    y = ship_y
    i = 0
    while i < MAX_ROCKS
      r = rock(i)
      if r[4] != 0 && near?(x, y, r[0].unsafe_div(Q), r[1].unsafe_div(Q), radius(r[4]) &+ SHIP_R &- 6)
        @@lives = @@lives &- 1
        split(i) # the rock that hit us breaks too
        if @@lives <= 0
          @@over = true
        else
          respawn
        end
        return
      end
      i = i &+ 1
    end
  end

  # One physics step; `thrust` = B was held / tapped. Public for tests.
  def self.step(thrust : Bool) : Nil
    return if @@over
    @@thrusting = thrust
    @@inv = @@inv &- 1 if @@inv > 0
    move_ship(thrust)
    move_bullets
    move_rocks
    check_ship
    if !@@over && rock_count == 0
      @@wave = @@wave &+ 1
      new_wave
    end
  end

  def self.tick(now : Int32, inp : LibGames::Input) : Bool
    unless @@started
      @@started = true
      @@last = now
    end
    if @@over
      if Games.pressed?(inp, Games::BTN_A | Games::BTN_B)
        restart
        @@last = now
        return true
      end
      return false
    end
    changed = false
    nd = Arcade.bucket(Games.knob_right(inp), 32, @@dir_b, KNOB_HYST)
    @@dir_b = nd
    # knob fully left = pointing up, turning clockwise turns the ship clockwise
    nd = (nd &+ 24) & 31
    if nd != @@dir
      @@dir = nd
      changed = true
    end
    changed = true if Games.pressed?(inp, Games::BTN_A) && fire
    thrust = (inp.held & Games::BTN_B) != 0_u32 || Games.pressed?(inp, Games::BTN_B)
    @@thrust_req = true if thrust
    if now &- @@last >= Arcade::STEP_MS
      @@last = now
      step(@@thrust_req)
      @@thrust_req = false
      changed = true
    end
    changed
  end

  @@thrust_req = false

  # ---- drawing -------------------------------------------------------------------

  # Vertex k (of 10) of rock r at pixel (cx, cy): radius jittered 70..100 %.
  def self.vertex(seed : Int32, size : Int32, k : Int32, cx : Int32, cy : Int32, vx : Int32*, vy : Int32*) : Nil
    h = (seed ^ (k &* 0x9E37)).to_u32!
    h = h ^ h.unsafe_shr(7)
    h = h &* 0x2C1B3C6D_u32
    h = h ^ h.unsafe_shr(12)
    rr = radius(size)
    rr = rr &- (rr &* (h & 31_u32).to_i32!).unsafe_div(100)
    d = (k &* 32).unsafe_div(10) # 10 vertices around 32 directions
    vx.value = cx &+ (Arcade.cos32(d) &* rr).unsafe_shr(10)
    vy.value = cy &+ (Arcade.sin32(d) &* rr).unsafe_shr(10)
  end

  def self.draw_rock_at(p : UInt8*, r : Int32*, cx : Int32, cy : Int32) : Nil
    x0 = 0
    y0 = 0
    vertex(r[5], r[4], 9, cx, cy, pointerof(x0), pointerof(y0))
    k = 0
    while k < 10
      x1 = 0
      y1 = 0
      vertex(r[5], r[4], k, cx, cy, pointerof(x1), pointerof(y1))
      Arcade.line(p, x0, y0, x1, y1, 4)
      x0 = x1
      y0 = y1
      k = k &+ 1
    end
  end

  # Draws something of radius rad at field (x, y), plus its wrapped copies
  # where it overlaps an edge; the label band is cleared afterwards by render.
  def self.draw_rock(p : UInt8*, r : Int32*) : Nil
    x = r[0].unsafe_div(Q)
    y = r[1].unsafe_div(Q)
    rad = radius(r[4]) &+ 4
    ox = 0
    while ox < 3
      dx = ox == 0 ? 0 : (ox == 1 ? FW : 0 &- FW)
      oy = 0
      while oy < 3
        dy = oy == 0 ? 0 : (oy == 1 ? FH : 0 &- FH)
        px = x &+ dx
        py = y &+ dy
        if px &+ rad >= 0 && px &- rad < FW && py &+ rad >= 0 && py &- rad < FH
          draw_rock_at(p, r, FX0 &+ px, FY0 &+ py)
        end
        oy = oy &+ 1
      end
      ox = ox &+ 1
    end
  end

  def self.draw_ship(p : UInt8*) : Nil
    cx = FX0 &+ ship_x
    cy = FY0 &+ ship_y
    d = @@dir
    nx = cx &+ (Arcade.cos32(d) &* 28).unsafe_shr(10)
    ny = cy &+ (Arcade.sin32(d) &* 28).unsafe_shr(10)
    lx = cx &+ (Arcade.cos32(d &+ 13) &* 20).unsafe_shr(10)
    ly = cy &+ (Arcade.sin32(d &+ 13) &* 20).unsafe_shr(10)
    rx = cx &+ (Arcade.cos32(d &+ 19) &* 20).unsafe_shr(10)
    ry = cy &+ (Arcade.sin32(d &+ 19) &* 20).unsafe_shr(10)
    t = @@inv > 0 ? 2 : 5 # thin while invulnerable after a respawn
    Arcade.line(p, nx, ny, lx, ly, t)
    Arcade.line(p, nx, ny, rx, ry, t)
    Arcade.line(p, lx, ly, rx, ry, t)
    if @@thrusting
      fx = cx &+ (Arcade.cos32(d &+ 16) &* 32).unsafe_shr(10)
      fy = cy &+ (Arcade.sin32(d &+ 16) &* 32).unsafe_shr(10)
      Arcade.line(p, (lx &+ rx).unsafe_div(2), (ly &+ ry).unsafe_div(2), fx, fy, 6)
    end
  end

  def self.render(black : UInt8*, red : UInt8*) : Nil
    Games.clear(black, red)
    i = 0
    while i < MAX_ROCKS
      r = rock(i)
      draw_rock(black, r) if r[4] != 0
      i = i &+ 1
    end
    i = 0
    while i < MAX_BULLETS
      b = bullet(i)
      if b[4] > 0
        Games.fill_rect(black, FX0 &+ b[0].unsafe_div(Q) &- 4, FY0 &+ b[1].unsafe_div(Q) &- 4, 8, 8)
      end
      i = i &+ 1
    end
    draw_ship(black) unless @@over
    # Nothing may spill into the label band.
    Games.zero(black, Arcade::LABEL_H &* Games::ROW_BYTES)
    # HUD under the band (on white): score left, lives right.
    Arcade.clear_rect(black, 16, 50, Arcade.text_width(Arcade.digits(@@score) > 4 ? Arcade.digits(@@score) : 4, 4) &+ 16, 28)
    Arcade.clear_rect(black, 920 &- (@@lives &- 1) &* 40 &- 20, 50, (@@lives &- 1) &* 40 &+ 40, 36) if @@lives > 0
    Arcade.draw_number(black, 24, 56, @@score, 4, 4)
    l = 0
    while l < @@lives
      x = 920 &- l &* 40
      Arcade.line(black, x, 56, x &- 12, 80, 4)
      Arcade.line(black, x, 56, x &+ 12, 80, 4)
      Arcade.line(black, x &- 12, 80, x &+ 12, 80, 4)
      l = l &+ 1
    end
    if @@over
      Arcade.over_frame(black)
      Arcade.banner(black, "GAME OVER", 10, 340)
    end
  end
end
