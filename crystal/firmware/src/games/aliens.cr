# Descending aliens: a wave of 8 x 4 invaders marches sideways and steps
# down at the edges; shoot them from a cannon at the bottom before they
# land. Four shields erode under shots and bombs. Our own sprites.
#
# Controls: left knob = cannon position (absolute, like a paddle),
#           User A or B = fire (up to MAX_SHOTS shots in the air).
#           After game over, A or B restarts.
#
# Timing: everything advances one step per Arcade::STEP_MS (one ~0.65 s
# panel frame): the wave moves STEP_X px (faster as it thins out), shots
# climb SHOT_V px with a swept hit test, bombs fall BOMB_V px. A cannon
# move is drawn on the next frame without waiting for the step.

require "./common"
require "./arcade"

module Aliens
  ACOLS = 8
  AROWS = 4
  N     = 32
  SCALE = 4 # sprite pixel size
  AW    = 44 # 11 sprite px
  AH    = 32 # 8 sprite px
  GAP_X = 84
  GAP_Y = 60
  TOP   = 88  # first wave's top row
  FIELD_L = 16
  FIELD_R = 944
  CANNON_Y = 612
  CANNON_W = 52
  CANNON_H = 28
  SHOT_W = 6
  SHOT_H = 28
  SHOT_V = 96
  BOMB_W = 8
  BOMB_H = 20
  BOMB_V = 44
  MAX_SHOTS = 2
  MAX_BOMBS = 3
  SHIELDS = 4
  SH_COLS = 8
  SH_ROWS = 4
  SH_CELL = 14
  SHIELD_Y = 500
  LAND_Y = 560 # an alien's bottom at or below this = invasion

  @@alive = Pointer(UInt8).null   # N
  @@shield = Pointer(UInt8).null  # SHIELDS * SH_ROWS * SH_COLS
  @@shots = Pointer(Int32).null   # MAX_SHOTS * {x, y}, y < 0 = free
  @@bombs = Pointer(Int32).null   # MAX_BOMBS * {x, y}, y < 0 = free
  @@ox = 0 # formation origin (left of column 0, top of row 0)
  @@oy = TOP
  @@dir = 1
  @@cx = 480 # cannon centre
  @@score = 0
  @@lives = 3
  @@wave = 1
  @@over = false
  @@hit = 0 # steps left showing the cannon hit
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

  def self.cannon_x : Int32
    @@cx
  end

  def self.origin_x : Int32
    @@ox
  end

  def self.origin_y : Int32
    @@oy
  end

  def self.dir : Int32
    @@dir
  end

  def self.alive?(i : Int32) : Bool
    @@alive[i] != 0_u8
  end

  def self.kill(i : Int32) : Nil
    @@alive[i] = 0_u8
  end

  def self.alive_count : Int32
    n = 0
    i = 0
    while i < N
      n = n &+ 1 if @@alive[i] != 0_u8
      i = i &+ 1
    end
    n
  end

  def self.alien_x(i : Int32) : Int32
    @@ox &+ i.unsafe_mod(ACOLS) &* GAP_X
  end

  def self.alien_y(i : Int32) : Int32
    @@oy &+ i.unsafe_div(ACOLS) &* GAP_Y
  end

  def self.shot_y(i : Int32) : Int32
    @@shots[i &* 2 &+ 1]
  end

  def self.shot_x(i : Int32) : Int32
    @@shots[i &* 2]
  end

  def self.bomb_y(i : Int32) : Int32
    @@bombs[i &* 2 &+ 1]
  end

  def self.set_bomb(i : Int32, x : Int32, y : Int32) : Nil
    @@bombs[i &* 2] = x
    @@bombs[i &* 2 &+ 1] = y
  end

  def self.shield_cells : Int32
    n = 0
    i = 0
    while i < SHIELDS &* SH_ROWS &* SH_COLS
      n = n &+ 1 if @@shield[i] != 0_u8
      i = i &+ 1
    end
    n
  end

  def self.init : Bool
    if @@alive.null?
      @@alive = game_alloc(N)
      @@shield = game_alloc(SHIELDS &* SH_ROWS &* SH_COLS)
      @@shots = game_alloc(MAX_SHOTS &* 8).as(Int32*)
      @@bombs = game_alloc(MAX_BOMBS &* 8).as(Int32*)
      return false if @@alive.null? || @@shield.null? || @@shots.null? || @@bombs.null?
    end
    restart
    true
  end

  def self.resync : Nil
    @@started = false
  end

  def self.restart : Nil
    @@score = 0
    @@lives = 3
    @@wave = 1
    @@over = false
    @@cx = 480
    i = 0
    while i < SHIELDS &* SH_ROWS &* SH_COLS
      # shield shape: a block with the bottom middle notched out
      c = i.unsafe_mod(SH_COLS)
      r = i.unsafe_div(SH_COLS).unsafe_mod(SH_ROWS)
      notch = r == SH_ROWS &- 1 && c >= 3 && c <= 4
      @@shield[i] = notch ? 0_u8 : 1_u8
      i = i &+ 1
    end
    new_wave
  end

  def self.new_wave : Nil
    i = 0
    while i < N
      @@alive[i] = 1_u8
      i = i &+ 1
    end
    @@ox = FIELD_L &+ 40
    top = TOP &+ (@@wave &- 1) &* 24
    top = TOP &+ 96 if top > TOP &+ 96
    @@oy = top
    @@dir = 1
    @@hit = 0
    clear_missiles
  end

  def self.clear_missiles : Nil
    i = 0
    while i < MAX_SHOTS
      @@shots[i &* 2 &+ 1] = -1
      i = i &+ 1
    end
    i = 0
    while i < MAX_BOMBS
      @@bombs[i &* 2 &+ 1] = -1
      i = i &+ 1
    end
  end

  # Horizontal speed: STEP 16 px with the full wave, up to 64 with one left.
  def self.step_x : Int32
    16 &+ ((N &- alive_count) &* 48).unsafe_div(N &- 1)
  end

  # Pixel extent of the live aliens.
  def self.extent(lo : Int32*, hi : Int32*, bottom : Int32*) : Bool
    l = 9999
    h = -9999
    b = -9999
    any = false
    i = 0
    while i < N
      if @@alive[i] != 0_u8
        any = true
        x = alien_x(i)
        y = alien_y(i)
        l = x if x < l
        h = x &+ AW if x &+ AW > h
        b = y &+ AH if y &+ AH > b
      end
      i = i &+ 1
    end
    lo.value = l
    hi.value = h
    bottom.value = b
    any
  end

  def self.fire : Bool
    i = 0
    while i < MAX_SHOTS
      if @@shots[i &* 2 &+ 1] < 0
        @@shots[i &* 2] = @@cx &- SHOT_W.unsafe_div(2)
        @@shots[i &* 2 &+ 1] = CANNON_Y &- SHOT_H
        return true
      end
      i = i &+ 1
    end
    false
  end

  # Shield cell under pixel (x, y), or -1.
  def self.shield_at(x : Int32, y : Int32) : Int32
    return -1 if y < SHIELD_Y || y >= SHIELD_Y &+ SH_ROWS &* SH_CELL
    s = 0
    while s < SHIELDS
      sx = shield_x(s)
      if x >= sx && x < sx &+ SH_COLS &* SH_CELL
        idx = (s &* SH_ROWS &+ (y &- SHIELD_Y).unsafe_div(SH_CELL)) &* SH_COLS &+ (x &- sx).unsafe_div(SH_CELL)
        return @@shield[idx] != 0_u8 ? idx : -1
      end
      s = s &+ 1
    end
    -1
  end

  def self.shield_x(s : Int32) : Int32
    # four shields spread evenly: centres at 120, 360, 600, 840
    120 &+ s &* 240 &- (SH_COLS &* SH_CELL).unsafe_div(2)
  end

  # First shield cell crossed by a vertical segment at columns x..x+w-1,
  # rows y0..y1, scanning from `from_bottom` side; -1 if none.
  def self.shield_hit(x : Int32, w : Int32, y0 : Int32, y1 : Int32, from_bottom : Bool) : Int32
    y = from_bottom ? y1 : y0
    while from_bottom ? y >= y0 : y <= y1
      xx = x
      while xx < x &+ w
        c = shield_at(xx, y)
        return c if c >= 0
        xx = xx &+ 2
      end
      y = from_bottom ? y &- 2 : y &+ 2
    end
    -1
  end

  def self.move_shots : Nil
    i = 0
    while i < MAX_SHOTS
      y = @@shots[i &* 2 &+ 1]
      if y >= 0
        x = @@shots[i &* 2]
        ny = y &- SHOT_V
        # swept test over [ny, y + SHOT_H): lowest alien hit wins
        best = -1
        by = -1
        k = 0
        while k < N
          if @@alive[k] != 0_u8
            ax = alien_x(k)
            ay = alien_y(k)
            if x &+ SHOT_W > ax && x < ax &+ AW && ay &+ AH > ny && ay < y &+ SHOT_H && ay > by
              best = k
              by = ay
            end
          end
          k = k &+ 1
        end
        sc = shield_hit(x, SHOT_W, ny < 0 ? 0 : ny, y &+ SHOT_H &- 1, true)
        sy = sc >= 0 ? SHIELD_Y &+ (sc.unsafe_div(SH_COLS).unsafe_mod(SH_ROWS)) &* SH_CELL : -1
        if sc >= 0 && (best < 0 || sy > by)
          @@shield[sc] = 0_u8
          @@shots[i &* 2 &+ 1] = -1
        elsif best >= 0
          @@alive[best] = 0_u8
          row = best.unsafe_div(ACOLS)
          @@score = @@score &+ (row == 0 ? 30 : (row == 1 ? 20 : 10))
          @@shots[i &* 2 &+ 1] = -1
        elsif ny < Arcade::LABEL_H
          @@shots[i &* 2 &+ 1] = -1
        else
          @@shots[i &* 2 &+ 1] = ny
        end
      end
      i = i &+ 1
    end
  end

  def self.move_bombs : Nil
    i = 0
    while i < MAX_BOMBS
      y = @@bombs[i &* 2 &+ 1]
      if y >= 0
        x = @@bombs[i &* 2]
        ny = y &+ BOMB_V
        sc = shield_hit(x, BOMB_W, y, ny &+ BOMB_H &- 1, false)
        if sc >= 0
          @@shield[sc] = 0_u8
          @@bombs[i &* 2 &+ 1] = -1
        elsif @@hit == 0 && ny &+ BOMB_H > CANNON_Y && y < CANNON_Y &+ CANNON_H &&
              x &+ BOMB_W > @@cx &- CANNON_W.unsafe_div(2) && x < @@cx &+ CANNON_W.unsafe_div(2)
          @@bombs[i &* 2 &+ 1] = -1
          cannon_hit
        elsif ny &+ BOMB_H > CANNON_Y &+ CANNON_H &+ 8 # hits the ground
          @@bombs[i &* 2 &+ 1] = -1
        else
          @@bombs[i &* 2 &+ 1] = ny
        end
      end
      i = i &+ 1
    end
  end

  def self.cannon_hit : Nil
    @@lives = @@lives &- 1
    @@hit = 2
    @@over = true if @@lives <= 0
  end

  # A bomb from the lowest alien of a random column (chance grows per wave).
  def self.drop_bomb : Nil
    return if Games.rand_below(100) >= 35 &+ @@wave &* 5
    slot = -1
    i = 0
    while i < MAX_BOMBS
      slot = i if slot < 0 && @@bombs[i &* 2 &+ 1] < 0
      i = i &+ 1
    end
    return if slot < 0
    c0 = Games.rand_below(ACOLS)
    k = 0
    while k < ACOLS
      c = (c0 &+ k).unsafe_mod(ACOLS)
      r = AROWS &- 1
      while r >= 0
        a = r &* ACOLS &+ c
        if @@alive[a] != 0_u8
          @@bombs[slot &* 2] = alien_x(a) &+ AW.unsafe_div(2) &- BOMB_W.unsafe_div(2)
          @@bombs[slot &* 2 &+ 1] = alien_y(a) &+ AH
          return
        end
        r = r &- 1
      end
      k = k &+ 1
    end
  end

  # Wave march: sideways, or down + reverse at an edge.
  def self.march : Nil
    lo = 0
    hi = 0
    bot = 0
    return unless extent(pointerof(lo), pointerof(hi), pointerof(bot))
    dx = step_x &* @@dir
    if hi &+ dx > FIELD_R || lo &+ dx < FIELD_L
      @@oy = @@oy &+ 24
      @@dir = 0 &- @@dir
    else
      @@ox = @@ox &+ dx
    end
    # aliens crush shield cells they overlap
    i = 0
    while i < N
      if @@alive[i] != 0_u8 && alien_y(i) &+ AH > SHIELD_Y
        x = alien_x(i)
        y = alien_y(i)
        yy = y
        while yy < y &+ AH
          xx = x
          while xx < x &+ AW
            c = shield_at(xx, yy)
            @@shield[c] = 0_u8 if c >= 0
            xx = xx &+ 4
          end
          yy = yy &+ 4
        end
      end
      i = i &+ 1
    end
    extent(pointerof(lo), pointerof(hi), pointerof(bot))
    @@over = true if bot >= LAND_Y
  end

  # One game step (no input). Public for tests.
  def self.step : Nil
    return if @@over
    @@hit = @@hit &- 1 if @@hit > 0
    move_shots
    if alive_count == 0
      @@wave = @@wave &+ 1
      new_wave
      return
    end
    march
    return if @@over
    move_bombs
    drop_bomb
  end

  def self.knob_cannon(k : Int32) : Int32
    half = CANNON_W.unsafe_div(2)
    x = FIELD_L &+ half &+ ((k &* (FIELD_R &- FIELD_L &- CANNON_W)).unsafe_div(Games::KNOB_ONE))
    x & -8 # 8 px steps: a resting knob doesn't jitter the cannon
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
    nx = knob_cannon(Games.knob_left(inp))
    if nx != @@cx
      @@cx = nx
      changed = true
    end
    changed = true if Games.pressed?(inp, Games::BTN_A | Games::BTN_B) && fire
    if now &- @@last >= Arcade::STEP_MS
      @@last = now
      step
      changed = true
    end
    changed
  end

  # ---- drawing -------------------------------------------------------------------
  # Sprites: 8 rows of 11 bits (bit 10 = left), our own designs.

  def self.sprite_row(kind : Int32, r : Int32) : Int32
    if kind == 0 # top row: a squid-like thing with feelers
      r == 0 ? 0b00001110000 : r == 1 ? 0b00111111100 : r == 2 ? 0b01101110110 : r == 3 ? 0b11111111111 :
        r == 4 ? 0b11011111011 : r == 5 ? 0b00110001100 : r == 6 ? 0b01100000110 : 0b11000000011
    elsif kind == 1 # middle rows: a horned crawler
      r == 0 ? 0b10000000001 : r == 1 ? 0b01000000010 : r == 2 ? 0b01111111110 : r == 3 ? 0b11011111011 :
        r == 4 ? 0b11111111111 : r == 5 ? 0b01111111110 : r == 6 ? 0b01010001010 : 0b10010001001
    else # bottom row: a blob with eye slots
      r == 0 ? 0b00111111100 : r == 1 ? 0b01111111110 : r == 2 ? 0b11001110011 : r == 3 ? 0b11111111111 :
        r == 4 ? 0b11111111111 : r == 5 ? 0b00100100100 : r == 6 ? 0b01001010010 : 0b10000000001
    end
  end

  def self.draw_sprite(p : UInt8*, kind : Int32, x : Int32, y : Int32) : Nil
    r = 0
    while r < 8
      bits = sprite_row(kind, r)
      c = 0
      while c < 11
        Games.fill_rect(p, x &+ c &* SCALE, y &+ r &* SCALE, SCALE, SCALE) if (bits.unsafe_shr(10 &- c) & 1) != 0
        c = c &+ 1
      end
      r = r &+ 1
    end
  end

  def self.render(black : UInt8*, red : UInt8*) : Nil
    Games.clear(black, red)
    # HUD: score left, wave, lives as small cannons right.
    Arcade.draw_number(black, 24, 56, @@score, 4, 4)
    Arcade.draw_text(black, 420, 56, "WAVE", 4)
    Arcade.draw_number(black, 500, 56, @@wave, 4)
    l = 0
    while l < @@lives
      x = 920 &- l &* 48
      Games.fill_rect(black, x &- 16, 64, 32, 10)
      Games.fill_rect(black, x &- 4, 56, 8, 8)
      l = l &+ 1
    end
    i = 0
    while i < N
      if @@alive[i] != 0_u8
        row = i.unsafe_div(ACOLS)
        draw_sprite(black, row == 0 ? 0 : (row == AROWS &- 1 ? 2 : 1), alien_x(i), alien_y(i))
      end
      i = i &+ 1
    end
    i = 0
    while i < SHIELDS &* SH_ROWS &* SH_COLS
      if @@shield[i] != 0_u8
        s = i.unsafe_div(SH_ROWS &* SH_COLS)
        r = i.unsafe_div(SH_COLS).unsafe_mod(SH_ROWS)
        c = i.unsafe_mod(SH_COLS)
        Games.fill_rect(black, shield_x(s) &+ c &* SH_CELL, SHIELD_Y &+ r &* SH_CELL, SH_CELL, SH_CELL)
      end
      i = i &+ 1
    end
    i = 0
    while i < MAX_SHOTS
      y = @@shots[i &* 2 &+ 1]
      Games.fill_rect(black, @@shots[i &* 2], y, SHOT_W, SHOT_H) if y >= 0
      i = i &+ 1
    end
    i = 0
    while i < MAX_BOMBS
      y = @@bombs[i &* 2 &+ 1]
      if y >= 0
        x = @@bombs[i &* 2]
        # zigzag bomb: three offset blocks
        Games.fill_rect(black, x, y, 4, 7)
        Games.fill_rect(black, x &+ 4, y &+ 7, 4, 6)
        Games.fill_rect(black, x, y &+ 13, 4, 7)
      end
      i = i &+ 1
    end
    # Cannon (hollow while hit).
    cx = @@cx &- CANNON_W.unsafe_div(2)
    if @@hit > 0
      Games.rect_outline(black, cx, CANNON_Y &+ 10, CANNON_W, CANNON_H &- 10, 4)
    else
      Games.fill_rect(black, cx, CANNON_Y &+ 10, CANNON_W, CANNON_H &- 10)
      Games.fill_rect(black, @@cx &- 4, CANNON_Y, 8, 10)
    end
    Games.fill_rect(black, 0, CANNON_Y &+ CANNON_H &+ 8, Games::W, 4) # ground
    if @@over
      Arcade.over_frame(black)
      Arcade.banner(black, "GAME OVER", 10, 340)
    end
  end
end
