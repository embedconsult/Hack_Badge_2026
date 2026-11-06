# Conway's Game of Life on a coarse toroidal grid (default 20 px cells ->
# 48x33). Each row is one UInt64 (bit x = column x), so cols <= 64; two
# generation buffers. While writing generation n+1 over the buffer holding
# n-1 we compare against both n (static) and n-1 (period 2); in either case
# changed? is false so the caller can skip the refresh, and after
# STABLE_RESEED such generations the board is reseeded.
#
# Controls: User A = reseed (density from the left knob, 5..60 %),
#           User B = pause / resume; right knob = speed: the first quarter
#           (FAST_ZONE) runs MIN_INTERVAL with MAX_GENS..1 generations per
#           refresh (fully counter-clockwise = MAX_GENS), the rest maps onto
#           one generation every MIN_INTERVAL..MAX_INTERVAL ms.
#
# Partial refresh: every step XORs the flipped cells into @@d, so @@d is
# exactly "panel vs board" since the last reported refresh (a cell that
# flips back cancels out). When tick returns true it snapshots @@d (flush),
# and dirty_box / dirty_rects describe that snapshot in pixels (whole cells
# including their 2 px gaps, inclusive bounds). Reseeds report false
# (full refresh).

require "./common"

module Life
  MAX_COLS      = 64
  MAX_ROWS      = 64
  STABLE_RESEED = 8
  MIN_INTERVAL  = 200  # ms between generations, right knob at 0
  MAX_INTERVAL  = 4000 # right knob at 1
  FAST_ZONE     = 1024 # Q12 knob range that adds generations per refresh
  MAX_GENS      =    4 # generations per refresh, right knob at 0
  BANDS         =    4 # vertical bands for dirty_rects (2 per COG half)

  @@a = Pointer(UInt64).null # current generation
  @@b = Pointer(UInt64).null # previous generation, then scratch
  @@d = Pointer(UInt64).null # cells flipped since the last flush (XOR)
  @@r = Pointer(UInt64).null # flipped cells reported by dirty_box/rects
  @@rb = Pointer(Int32).null # scratch rects for dirty_rects
  @@full = true              # board replaced since the last flush
  @@r_full = true            # reported refresh must be full
  @@gens = 1
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

  # Generations advanced per refresh at the current right-knob setting.
  def self.gens_per_frame : Int32
    @@gens
  end

  # Right knob (Q12) -> generations per refresh.
  def self.gens_for(k : Int32) : Int32
    return 1 if k >= FAST_ZONE
    k = 0 if k < 0
    1 &+ ((FAST_ZONE &- k) &* (MAX_GENS &- 1)).unsafe_div(FAST_ZONE &- 1)
  end

  # Right knob (Q12) -> ms between generation batches.
  def self.interval_for(k : Int32) : Int32
    return MIN_INTERVAL if k <= FAST_ZONE
    MIN_INTERVAL &+ ((MAX_INTERVAL &- MIN_INTERVAL) &* (k &- FAST_ZONE)).unsafe_div(Games::KNOB_ONE &- FAST_ZONE)
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
      @@d = game_alloc(MAX_ROWS &* 8).as(UInt64*)
      @@r = game_alloc(MAX_ROWS &* 8).as(UInt64*)
      @@rb = game_alloc(BANDS &* 16).as(Int32*)
      return false if @@a.null? || @@b.null? || @@d.null? || @@r.null? || @@rb.null?
    end
    @@paused = false
    @@started = false
    seed(@@density)
    true
  end

  # Mode entry: the caller does a full refresh of the current board.
  def self.resync : Nil
    @@started = false
    zero_rows(@@d)
    @@full = false
    @@r_full = true
  end

  def self.zero_rows(p : UInt64*) : Nil
    i = 0
    while i < MAX_ROWS
      p[i] = 0_u64
      i = i &+ 1
    end
  end

  def self.clear : Nil
    i = 0
    while i < MAX_ROWS
      @@a[i] = 0_u64
      @@b[i] = 0_u64
      @@d[i] = 0_u64
      i = i &+ 1
    end
    @@full = true
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
      nxt = 0_u64
      x = 0
      while x < cols
        xl = x == 0 ? cols &- 1 : x &- 1
        xr = x &+ 1 == cols ? 0 : x &+ 1
        n = bit(up, xl) &+ bit(up, x) &+ bit(up, xr) &+
            bit(mid, xl) &+ bit(mid, xr) &+
            bit(dn, xl) &+ bit(dn, x) &+ bit(dn, xr)
        if n == 3 || (n == 2 && bit(mid, x) == 1)
          nxt = nxt | 1_u64.unsafe_shl(x.to_u64!)
        end
        x = x &+ 1
      end
      same1 = false if nxt != mid
      same2 = false if nxt != @@b[y]
      @@d[y] = @@d[y] ^ nxt ^ mid
      @@b[y] = nxt
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

  # true = the board changed and needs a refresh (dirty_box / dirty_rects
  # then describe it).
  def self.tick(now : Int32, inp : LibGames::Input) : Bool
    unless @@started
      @@started = true
      @@last = now
    end
    if Games.pressed?(inp, Games::BTN_A)
      Games.seed(Games.rand ^ now.to_u32!)
      seed(205 &+ (Games.knob_left(inp) &* 2253).unsafe_div(Games::KNOB_ONE))
      @@last = now
      flush
      return true
    end
    @@paused = !@@paused if Games.pressed?(inp, Games::BTN_B)
    return false if @@paused
    k = Games.knob_right(inp)
    @@gens = gens_for(k)
    return false if now &- @@last < interval_for(k)
    @@last = now
    any = false
    g = 0
    while g < @@gens
      step
      if @@stable >= STABLE_RESEED
        seed(@@density)
        flush
        return true
      end
      any = true if @@changed
      g = g &+ 1
    end
    return false unless any && (@@full || pending?)
    flush
    true
  end

  # Some cell differs from what the last flushed refresh showed.
  def self.pending? : Bool
    y = 0
    while y < @@rows
      return true if @@d[y] != 0_u64
      y = y &+ 1
    end
    false
  end

  # The caller is about to refresh: report the accumulated flips (or a full
  # refresh) and start accumulating afresh. tick() calls this itself.
  def self.flush : Nil
    i = 0
    while i < MAX_ROWS
      @@r[i] = @@d[i]
      @@d[i] = 0_u64
      i = i &+ 1
    end
    @@r_full = @@full
    @@full = false
  end

  # ---- partial-update windows ---------------------------------------------

  # Pixel box (inclusive) of the reported flipped cells in columns
  # cx_lo..cx_hi-1, written to dst[0..3]. false = none there.
  def self.band_box(cx_lo : Int32, cx_hi : Int32, dst : Int32*) : Bool
    mask = 0_u64
    x = cx_lo
    while x < cx_hi
      mask = mask | 1_u64.unsafe_shl(x.to_u64!)
      x = x &+ 1
    end
    y_lo = -1
    y_hi = -1
    cols = 0_u64
    y = 0
    while y < @@rows
      m = @@r[y] & mask
      if m != 0_u64
        y_lo = y if y_lo < 0
        y_hi = y
        cols = cols | m
      end
      y = y &+ 1
    end
    return false if y_lo < 0
    x_lo = -1
    x_hi = -1
    x = cx_lo
    while x < cx_hi
      if bit(cols, x) == 1
        x_lo = x if x_lo < 0
        x_hi = x
      end
      x = x &+ 1
    end
    c = @@cell
    dst[0] = @@x0 &+ x_lo &* c
    dst[1] = @@y0 &+ y_lo &* c
    dst[2] = @@x0 &+ (x_hi &+ 1) &* c &- 1
    dst[3] = @@y0 &+ (y_hi &+ 1) &* c &- 1
    true
  end

  # Inclusive pixel box of all cells flipped for the refresh tick() just
  # requested. false = full refresh (reseed / mode entry) or nothing.
  def self.dirty_box(x0 : Int32*, y0 : Int32*, x1 : Int32*, y1 : Int32*) : Bool
    return false if @@r_full || @@rb.null?
    return false unless band_box(0, @@cols, @@rb)
    x0.value = @@rb[0]
    y0.value = @@rb[1]
    x1.value = @@rb[2]
    y1.value = @@rb[3]
    true
  end

  # Up to `max` (<= BANDS) inclusive pixel rects {x0, y0, x1, y1} into
  # dst[4*i..]: one per vertical band of cols/BANDS columns that has flipped
  # cells (bands 0-1 = left COG, 2-3 = right COG at the default 20 px cell),
  # neighbouring rects merged (least added area first) while there are more
  # than `max`. Returns the count; 0 = full refresh or nothing.
  def self.dirty_rects(dst : Int32*, max : Int32) : Int32
    return 0 if @@r_full || @@rb.null? || max < 1
    n = 0
    b = 0
    while b < BANDS
      lo = (@@cols &* b).unsafe_div(BANDS)
      hi = (@@cols &* (b &+ 1)).unsafe_div(BANDS)
      n = n &+ 1 if band_box(lo, hi, @@rb + (n &* 4).to_i64!)
      b = b &+ 1
    end
    n = Games.merge_rects(@@rb, n, max)
    i = 0
    while i < n &* 4
      dst[i] = @@rb[i]
      i = i &+ 1
    end
    n
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
