# Falling blocks: our own take on the stacking game, 10 x 20 well of 30 px
# cells, seven four-cell pieces from a shuffled bag, line clears, levels.
#
# Controls (absolute knobs, like paddles):
#   left knob  = the piece's column (the piece slides there, stopping at
#                anything in the way; a new piece spawns under the knob)
#   right knob = rotation: each quarter of its travel is one orientation,
#                turning it rotates the piece by the quarters crossed
#   User A     = rotate clockwise        User B = hard drop
#   after game over, A or B restarts.
#
# Timing: gravity runs every panel frame (Arcade::STEP_MS) and drops
# drop_rows rows (2 at level 1, more later), so a piece crosses the well in
# ~10 frames. Slower gravity (1.3 s per row, the first version) left gaps
# between frames that the firmware fills with erase-settle pulls and
# session restarts: on the badge one piece took ~45 s to land (hardware
# report). A piece that lands rests for one frame (it can still slide) and
# locks on the next. Knob moves and rotations are drawn on the next frame.
# Rendering is black only: settled cells filled, the falling piece hollow
# (fewer changed pixels), the next piece in the side panel.

require "./common"
require "./arcade"

module Blocks
  COLS = 10
  ROWS = 20
  CELL = 30
  BX   = 330 # well's left pixel
  BY   =  56 # well's top pixel
  SIDE = 680 # side panel x
  KNOB_HYST = 100

  @@well = Pointer(UInt8).null # ROWS * COLS, 0 = empty, else 1
  @@bag = Pointer(UInt8).null  # 7-bag + index
  @@bagi = 7
  @@kind = 0
  @@rot = 0
  @@px = 3 # piece origin (4x4 box) column, may be < 0
  @@py = 0 # row of the box's top, may be < 0
  @@next = 0
  @@score = 0
  @@lines = 0
  @@level = 1
  @@over = false
  @@last = 0
  @@started = false
  @@col_b = -1 # knob column bucket
  @@rot_b = -1 # knob quarter
  @@cleared = 0 # rows cleared by the last lock (for tests)
  @@pieces = 0  # pieces spawned since restart
  @@resting = false # landed last frame: locks on the next gravity frame

  # 4x4 masks, bit 15 = row 0 col 0, bit 0 = row 3 col 3. kind 0..6 = I J L O S T Z.
  def self.shape(kind : Int32, rot : Int32) : Int32
    r = rot & 3
    if kind == 0
      r == 0 ? 0x0F00 : (r == 1 ? 0x2222 : (r == 2 ? 0x00F0 : 0x4444))
    elsif kind == 1
      r == 0 ? 0x8E00 : (r == 1 ? 0x6440 : (r == 2 ? 0x0E20 : 0x44C0))
    elsif kind == 2
      r == 0 ? 0x2E00 : (r == 1 ? 0x4460 : (r == 2 ? 0x0E80 : 0xC440))
    elsif kind == 3
      0x6600
    elsif kind == 4
      r == 0 ? 0x6C00 : (r == 1 ? 0x4620 : (r == 2 ? 0x06C0 : 0x8C40))
    elsif kind == 5
      r == 0 ? 0x4E00 : (r == 1 ? 0x4640 : (r == 2 ? 0x0E40 : 0x4C40))
    else
      r == 0 ? 0xC600 : (r == 1 ? 0x2640 : (r == 2 ? 0x0C60 : 0x4C80))
    end
  end

  def self.bit?(m : Int32, r : Int32, c : Int32) : Bool
    (m.unsafe_shr(15 &- (r &* 4 &+ c)) & 1) != 0
  end

  # Leftmost / rightmost occupied box column of a mask.
  def self.min_col(m : Int32) : Int32
    c = 0
    while c < 4
      r = 0
      while r < 4
        return c if bit?(m, r, c)
        r = r &+ 1
      end
      c = c &+ 1
    end
    0
  end

  def self.max_col(m : Int32) : Int32
    c = 3
    while c >= 0
      r = 0
      while r < 4
        return c if bit?(m, r, c)
        r = r &+ 1
      end
      c = c &- 1
    end
    3
  end

  # ---- state accessors (tests) ---------------------------------------------

  def self.score : Int32
    @@score
  end

  def self.lines : Int32
    @@lines
  end

  def self.level : Int32
    @@level
  end

  def self.over? : Bool
    @@over
  end

  def self.kind : Int32
    @@kind
  end

  def self.next_kind : Int32
    @@next
  end

  def self.rot : Int32
    @@rot
  end

  def self.px : Int32
    @@px
  end

  def self.py : Int32
    @@py
  end

  def self.cleared : Int32
    @@cleared
  end

  def self.cell?(c : Int32, r : Int32) : Bool
    return true if c < 0 || c >= COLS || r >= ROWS
    return false if r < 0
    @@well[r &* COLS &+ c] != 0_u8
  end

  def self.set_cell(c : Int32, r : Int32, v : Bool) : Nil
    @@well[r &* COLS &+ c] = v ? 1_u8 : 0_u8
  end

  # Test hook: put a given piece at a given place.
  def self.set_piece(kind : Int32, rot : Int32, x : Int32, y : Int32) : Nil
    @@kind = kind
    @@rot = rot & 3
    @@px = x
    @@py = y
  end

  def self.set_next(kind : Int32) : Nil
    @@next = kind
  end

  def self.interval : Int32
    Arcade::STEP_MS
  end

  # Gravity rows per frame.
  def self.drop_rows : Int32
    @@level <= 3 ? 2 : (@@level <= 6 ? 3 : 4)
  end

  def self.pieces : Int32
    @@pieces
  end

  def self.resting? : Bool
    @@resting
  end

  # ---- lifecycle ---------------------------------------------------------------

  def self.init : Bool
    if @@well.null?
      @@well = game_alloc(ROWS &* COLS)
      @@bag = game_alloc(8)
      return false if @@well.null? || @@bag.null?
    end
    restart
    true
  end

  def self.resync : Nil
    @@started = false
    @@col_b = -1
    @@rot_b = -1
  end

  def self.restart : Nil
    Games.zero(@@well, ROWS &* COLS)
    @@score = 0
    @@lines = 0
    @@level = 1
    @@pieces = 0
    @@over = false
    @@bagi = 7
    @@next = draw_bag
    spawn(-1)
  end

  def self.draw_bag : Int32
    if @@bagi >= 7
      i = 0
      while i < 7
        @@bag[i] = i.to_u8!
        i = i &+ 1
      end
      i = 6
      while i > 0
        j = Games.rand_below(i &+ 1)
        t = @@bag[i]
        @@bag[i] = @@bag[j]
        @@bag[j] = t
        i = i &- 1
      end
      @@bagi = 0
    end
    k = @@bag[@@bagi].to_i32!
    @@bagi = @@bagi &+ 1
    k
  end

  # Next piece in; `col` = wanted leftmost column (-1 = centre). Game over
  # if it doesn't fit.
  def self.spawn(col : Int32) : Nil
    @@pieces = @@pieces &+ 1
    @@resting = false
    @@kind = @@next
    @@next = draw_bag
    @@rot = 0
    m = shape(@@kind, 0)
    @@py = 0 &- first_row(m)
    @@px = 3
    if col >= 0
      w = max_col(m) &- min_col(m) &+ 1
      col = COLS &- w if col > COLS &- w
      @@px = col &- min_col(m)
    end
    @@over = true if collides?(@@px, @@py, @@rot)
  end

  def self.first_row(m : Int32) : Int32
    r = 0
    while r < 4
      c = 0
      while c < 4
        return r if bit?(m, r, c)
        c = c &+ 1
      end
      r = r &+ 1
    end
    0
  end

  def self.collides?(x : Int32, y : Int32, rot : Int32) : Bool
    m = shape(@@kind, rot)
    r = 0
    while r < 4
      c = 0
      while c < 4
        return true if bit?(m, r, c) && cell?(x &+ c, y &+ r)
        c = c &+ 1
      end
      r = r &+ 1
    end
    false
  end

  # ---- moves -------------------------------------------------------------------

  def self.shift(dx : Int32) : Bool
    return false if collides?(@@px &+ dx, @@py, @@rot)
    @@px = @@px &+ dx
    true
  end

  # Slides the piece so its leftmost cell is at column `col`, one column at a
  # time, stopping at the first obstacle. True if it moved.
  def self.move_to(col : Int32) : Bool
    moved = false
    guard = 0
    while guard < COLS
      cur = @@px &+ min_col(shape(@@kind, @@rot))
      break if cur == col
      break unless shift(cur < col ? 1 : -1)
      moved = true
      guard = guard &+ 1
    end
    moved
  end

  # Rotation by dir (+1 cw, -1 ccw) with simple wall kicks.
  def self.rotate(dir : Int32) : Bool
    nr = (@@rot &+ dir) & 3
    k = 0
    while k < 5
      dx = k == 0 ? 0 : (k == 1 ? -1 : (k == 2 ? 1 : (k == 3 ? -2 : 2)))
      unless collides?(@@px &+ dx, @@py, nr)
        @@px = @@px &+ dx
        @@rot = nr
        return true
      end
      k = k &+ 1
    end
    false
  end

  # Gravity step: down one row, or lock + clear + spawn.
  def self.step : Nil
    return if @@over
    if collides?(@@px, @@py &+ 1, @@rot)
      lock
    else
      @@py = @@py &+ 1
    end
  end

  # One gravity frame: drop_rows rows, or rest / lock when blocked.
  def self.fall : Nil
    return if @@over
    n = drop_rows
    while n > 0
      if collides?(@@px, @@py &+ 1, @@rot)
        if @@resting
          lock
        else
          @@resting = true
        end
        return
      end
      @@py = @@py &+ 1
      @@resting = false
      n = n &- 1
    end
  end

  def self.hard_drop : Nil
    return if @@over
    n = 0
    while !collides?(@@px, @@py &+ 1, @@rot)
      @@py = @@py &+ 1
      n = n &+ 1
    end
    @@score = @@score &+ n &* 2
    lock
  end

  def self.lock : Nil
    m = shape(@@kind, @@rot)
    col = @@px &+ min_col(m)
    r = 0
    while r < 4
      c = 0
      while c < 4
        if bit?(m, r, c)
          y = @@py &+ r
          if y < 0
            @@over = true # locked above the well
          else
            set_cell(@@px &+ c, y, true)
          end
        end
        c = c &+ 1
      end
      r = r &+ 1
    end
    @@cleared = clear_lines
    if @@cleared > 0
      pts = @@cleared == 1 ? 100 : (@@cleared == 2 ? 300 : (@@cleared == 3 ? 500 : 800))
      @@score = @@score &+ pts &* @@level
      @@lines = @@lines &+ @@cleared
      @@level = @@lines.unsafe_div(10) &+ 1
    end
    spawn(col) unless @@over
  end

  def self.clear_lines : Int32
    n = 0
    r = ROWS &- 1
    while r >= 0
      full = true
      c = 0
      while c < COLS
        full = false unless cell?(c, r)
        c = c &+ 1
      end
      if full
        n = n &+ 1
        rr = r
        while rr > 0
          c = 0
          while c < COLS
            @@well[rr &* COLS &+ c] = @@well[(rr &- 1) &* COLS &+ c]
            c = c &+ 1
          end
          rr = rr &- 1
        end
        c = 0
        while c < COLS
          @@well[c] = 0_u8
          c = c &+ 1
        end
      else
        r = r &- 1
      end
    end
    n
  end

  # Knob column bucket -> leftmost column for the current piece.
  def self.knob_col(k : Int32) : Int32
    m = shape(@@kind, @@rot)
    w = max_col(m) &- min_col(m) &+ 1
    @@col_b = Arcade.bucket(k, COLS, @@col_b, KNOB_HYST)
    c = @@col_b
    c = COLS &- w if c > COLS &- w
    c
  end

  # true = redraw.
  def self.tick(now : Int32, inp : LibGames::Input) : Bool
    first = !@@started
    if first
      @@started = true
      @@last = now
    end
    if @@over
      if Games.pressed?(inp, Games::BTN_A | Games::BTN_B)
        restart
        @@last = now
        @@col_b = -1
        @@rot_b = -1
        return true
      end
      return false
    end
    changed = false
    # Rotation: right knob quarters (relative), A = clockwise.
    q = Arcade.bucket(Games.knob_right(inp), 4, @@rot_b, KNOB_HYST)
    if @@rot_b >= 0 && q != @@rot_b
      d = q &- @@rot_b
      while d > 0
        changed = true if rotate(1)
        d = d &- 1
      end
      while d < 0
        changed = true if rotate(-1)
        d = d &+ 1
      end
    end
    @@rot_b = q
    changed = true if Games.pressed?(inp, Games::BTN_A) && rotate(1)
    # Column from the left knob (not on the first tick: the knob reference
    # is only taken then).
    col = knob_col(Games.knob_left(inp))
    changed = true if !first && move_to(col)
    if Games.pressed?(inp, Games::BTN_B)
      hard_drop
      @@last = now
      return true
    end
    if now &- @@last >= interval
      @@last = now
      fall
      changed = true
    end
    changed
  end

  # ---- drawing -------------------------------------------------------------------

  def self.render(black : UInt8*, red : UInt8*) : Nil
    Games.clear(black, red)
    # Well: walls and floor (open top).
    Games.fill_rect(black, BX &- 10, BY, 6, ROWS &* CELL &+ 10)
    Games.fill_rect(black, BX &+ COLS &* CELL &+ 4, BY, 6, ROWS &* CELL &+ 10)
    Games.fill_rect(black, BX &- 10, BY &+ ROWS &* CELL &+ 4, COLS &* CELL &+ 20, 6)
    r = 0
    while r < ROWS
      c = 0
      while c < COLS
        if @@well[r &* COLS &+ c] != 0_u8
          Games.fill_rect(black, BX &+ c &* CELL &+ 1, BY &+ r &* CELL &+ 1, CELL &- 2, CELL &- 2)
        end
        c = c &+ 1
      end
      r = r &+ 1
    end
    unless @@over
      m = shape(@@kind, @@rot)
      r = 0
      while r < 4
        c = 0
        while c < 4
          y = @@py &+ r
          if bit?(m, r, c) && y >= 0
            Games.rect_outline(black, BX &+ (@@px &+ c) &* CELL &+ 1, BY &+ y &* CELL &+ 1, CELL &- 2, CELL &- 2, 6)
          end
          c = c &+ 1
        end
        r = r &+ 1
      end
    end
    # Side panel: next piece, score, lines, level.
    Arcade.draw_text(black, SIDE, 64, "NEXT", 6)
    m = shape(@@next, 0)
    r = 0
    while r < 4
      c = 0
      while c < 4
        Games.fill_rect(black, SIDE &+ c &* CELL &+ 1, 112 &+ r &* CELL &+ 1, CELL &- 2, CELL &- 2) if bit?(m, r, c)
        c = c &+ 1
      end
      r = r &+ 1
    end
    Arcade.draw_text(black, SIDE, 260, "SCORE", 6)
    Arcade.draw_number(black, SIDE, 300, @@score, 6)
    Arcade.draw_text(black, SIDE, 380, "LINES", 6)
    Arcade.draw_number(black, SIDE, 420, @@lines, 6)
    Arcade.draw_text(black, SIDE, 500, "LEVEL", 6)
    Arcade.draw_number(black, SIDE, 540, @@level, 6)
    # Left panel: controls.
    Arcade.draw_text(black, 24, 80, "KNOBS:", 4)
    Arcade.draw_text(black, 24, 112, "MOVE", 4)
    Arcade.draw_text(black, 24, 136, "TURN", 4)
    Arcade.draw_text(black, 24, 184, "A: TURN", 4)
    Arcade.draw_text(black, 24, 216, "B: DROP", 4)
    if @@over
      Arcade.over_frame(black)
      Arcade.banner(black, "GAME OVER", 10, 340)
    end
  end
end
