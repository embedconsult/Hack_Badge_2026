# Conway's Game of Life on a coarse toroidal grid (default 20 px cells ->
# 48x33). Each row is one UInt64 (bit x = column x), so cols <= 64; two
# generation buffers. While writing generation n+1 over the buffer holding
# n-1 we compare against both n (static) and n-1 (period 2); in either case
# changed? is false so the caller can skip the refresh, and after
# STABLE_RESEED such generations the board is reseeded.
#
# Controls: User A = reseed (density from the left knob, 5..60 %),
#           User B = pause / resume; right knob = generation interval.

require "./common"

module Life
  MAX_COLS      = 64
  MAX_ROWS      = 64
  STABLE_RESEED = 8
  MIN_INTERVAL  = 200  # ms between generations, right knob at 0
  MAX_INTERVAL  = 4000 # right knob at 1

  @@a = Pointer(UInt64).null # current generation
  @@b = Pointer(UInt64).null # previous generation, then scratch
  @@cell = 20
  @@cols = 48
  @@rows = 33
  @@x0 = 0
  @@y0 = 6
  @@prev_valid = false
  @@changed = true
  @@static = false
  @@period2 = false
  @@stable = 0
  @@gen = 0
  @@density = 1229 # Q12 (30 %)
  @@paused = false
  @@last = 0
  @@started = false

  def self.cols : Int32
    @@cols
  end

  def self.rows : Int32
    @@rows
  end

  def self.cell : Int32
    @@cell
  end

  def self.gen : Int32
    @@gen
  end

  def self.changed? : Bool
    @@changed
  end

  def self.static? : Bool
    @@static
  end

  def self.period2? : Bool
    @@period2
  end

  def self.stable_count : Int32
    @@stable
  end

  # cell >= 15 (64 columns max). Returns false if allocation failed.
  def self.init(cell : Int32 = 20) : Bool
    cell = 15 if cell < 15
    @@cell = cell
    @@cols = Games::W.unsafe_div(cell)
    @@rows = Games::H.unsafe_div(cell)
    @@cols = MAX_COLS if @@cols > MAX_COLS
    @@rows = MAX_ROWS if @@rows > MAX_ROWS
    @@x0 = (Games::W &- @@cols &* cell).unsafe_div(2)
    @@y0 = (Games::H &- @@rows &* cell).unsafe_div(2)
    if @@a.null?
      @@a = game_alloc(MAX_ROWS &* 8).as(UInt64*)
      @@b = game_alloc(MAX_ROWS &* 8).as(UInt64*)
      return false if @@a.null? || @@b.null?
    end
    @@paused = false
    @@started = false
    seed(@@density)
    true
  end

  def self.resync : Nil
    @@started = false
  end

  def self.clear : Nil
    i = 0
    while i < MAX_ROWS
      @@a[i] = 0_u64
      @@b[i] = 0_u64
      i = i &+ 1
    end
    @@prev_valid = false
    @@changed = true
    @@static = false
    @@period2 = false
    @@stable = 0
    @@gen = 0
  end

  # Random board; each cell alive with probability density/4096.
  def self.seed(density : Int32) : Nil
    clear
    @@density = density
    y = 0
    while y < @@rows
      x = 0
      while x < @@cols
        set_cell(x, y, true) if (Games.rand & 0xFFF_u32).to_i32! < density
        x = x &+ 1
      end
      y = y &+ 1
    end
  end

  def self.set_cell(x : Int32, y : Int32, on : Bool) : Nil
    return if x < 0 || y < 0 || x >= @@cols || y >= @@rows
    bit = 1_u64.unsafe_shl(x.to_u64!)
    @@a[y] = on ? (@@a[y] | bit) : (@@a[y] & (bit ^ 0xFFFFFFFFFFFFFFFF_u64))
  end

  def self.alive?(x : Int32, y : Int32) : Bool
    return false if x < 0 || y < 0 || x >= @@cols || y >= @@rows
    (@@a[y].unsafe_shr(x.to_u64!) & 1_u64) != 0_u64
  end

  def self.population : Int32
    n = 0
    y = 0
    while y < @@rows
      r = @@a[y]
      while r != 0_u64
        r = r & (r &- 1_u64)
        n = n &+ 1
      end
      y = y &+ 1
    end
    n
  end

  @[AlwaysInline]
  def self.bit(r : UInt64, x : Int32) : Int32
    (r.unsafe_shr(x.to_u64!) & 1_u64).to_i32!
  end

  # Advance one generation (toroidal).
  def self.step : Nil
    rows = @@rows
    cols = @@cols
    same1 = true # n+1 == n
    same2 = @@prev_valid # n+1 == n-1
    y = 0
    while y < rows
      up = @@a[y == 0 ? rows &- 1 : y &- 1]
      mid = @@a[y]
      dn = @@a[y &+ 1 == rows ? 0 : y &+ 1]
      out = 0_u64
      x = 0
      while x < cols
        xl = x == 0 ? cols &- 1 : x &- 1
        xr = x &+ 1 == cols ? 0 : x &+ 1
        n = bit(up, xl) &+ bit(up, x) &+ bit(up, xr) &+
            bit(mid, xl) &+ bit(mid, xr) &+
            bit(dn, xl) &+ bit(dn, x) &+ bit(dn, xr)
        if n == 3 || (n == 2 && bit(mid, x) == 1)
          out = out | 1_u64.unsafe_shl(x.to_u64!)
        end
        x = x &+ 1
      end
      same1 = false if out != mid
      same2 = false if out != @@b[y]
      @@b[y] = out
      y = y &+ 1
    end
    t = @@a
    @@a = @@b
    @@b = t
    @@prev_valid = true
    @@gen = @@gen &+ 1
    @@static = same1
    @@period2 = same2 && !same1
    @@changed = !(same1 || same2)
    @@stable = @@changed ? 0 : @@stable &+ 1
  end

  # true = the board changed and needs a refresh.
  def self.tick(now : Int32, inp : LibGames::Input) : Bool
    unless @@started
      @@started = true
      @@last = now
    end
    if Games.pressed?(inp, Games::BTN_A)
      Games.seed(Games.rand ^ now.to_u32!)
      seed(205 &+ (Games.knob_left(inp) &* 2253).unsafe_div(Games::KNOB_ONE))
      @@last = now
      return true
    end
    @@paused = !@@paused if Games.pressed?(inp, Games::BTN_B)
    return false if @@paused
    interval = MIN_INTERVAL &+ ((MAX_INTERVAL &- MIN_INTERVAL) &* Games.knob_right(inp)).unsafe_div(Games::KNOB_ONE)
    return false if now &- @@last < interval
    @@last = now
    step
    if @@stable >= STABLE_RESEED
      seed(@@density)
      return true
    end
    @@changed
  end

  # Live cells as filled squares with a 2 px gap; black plane only.
  def self.render(black : UInt8*, red : UInt8*) : Nil
    Games.clear(black, red)
    c = @@cell
    y = 0
    while y < @@rows
      r = @@a[y]
      x = 0
      while x < @@cols
        if bit(r, x) == 1
          Games.fill_rect(black, @@x0 &+ x &* c &+ 1, @@y0 &+ y &* c &+ 1, c &- 2, c &- 2)
        end
        x = x &+ 1
      end
      y = y &+ 1
    end
  end
end
