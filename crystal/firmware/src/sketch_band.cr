# Band math for the Sketch e-paper driver (sketch_epd.cr, `upd sketch drv2`).
# Pure functions on pointers and the runtime parameters: no SPI, no GPIO, no
# allocation, so the same file runs in the firmware (--prelude=empty) and in
# the host specs (test/sketch_epd_spec.cr, plain `crystal spec`). The design
# note is at the top of sketch_epd.cr.
#
# Frame layout (as EPD): 672 rows x 120 bytes, MSB = leftmost pixel; bytes
# 0..59 of a row are the master CoG's half (left), 60..119 the slave's.
# Ink command per pixel = (0x11 bit << 1) | 0x10 bit:
#   0 = no drive, 1 = VDH f1 frames, 2 = VDL fe frames, 3 = VDH f3 frames.

module SkBand
  H         = 672
  ROW_BYTES = 120
  HALF      =  60
  PLANE     = 80640
  LUT_BYTES =   400

  # Strategies (param strat).
  S_PLAIN    = 0 # RAM = band rows, DRFW = band rows
  S_TWINRAM  = 1 # RAM = band + twin rows (correct data at both), DRFW = band
  S_TWINSPAN = 2 # RAM = band + twin rows, DRFW = one range over both
  S_GHOST    = 3 # plain, plus twin ghosts tracked and erased by idle cleanup
  S_TAIL     = 4 # RAM = band, DRFW = band start .. panel bottom
  S_HEAD     = 5 # RAM = band, DRFW = panel top .. band end
  S_FULL     = 6 # RAM = band, DRFW = whole panel (control: clean, ~580 ms)
  S_COUNT    = 7

  # DRFW per CoG (param win).
  W_SHARED    = 0 # one 0x90 to both CoGs
  W_PERCOG    = 1 # 0x90 to each CoG; the slave adds sd0 / sd1
  W_MASTER    = 2 # band to the master only, the slave gets the full panel
  W_SLAVEIDLE = 3 # band to the master, the slave a 1-unit window at idleu

  # Row sources (mark_writes).
  SRC_NONE  = 0_u8
  SRC_CMDS  = 1_u8 # the caller's command planes
  SRC_ZEROS = 2_u8 # zeros (no drive)

  # Parameters: index constants, NAMES in the same order (shell `drv2`).
  P_STRAT    =  0
  P_TWIN     =  1 # twin offset, rows
  P_WRAP     =  2 # twins wrap around the panel (1) or fall off it (0)
  P_TWINCMD  =  3 # TWINRAM/TWINSPAN: twin rows get 0 = zeros, 1 = their own pending commands
  P_UNIT     =  4 # rows per DRFW y unit
  P_ALIGN    =  5 # band rows aligned to this
  P_PAD      =  6 # rows added above and below a band
  P_D0       =  7 # master DRFW start offset, units
  P_D1       =  8 # master DRFW end offset, units
  P_SD0      =  9 # slave DRFW start offset, units (win 1)
  P_SD1      = 10
  P_X0       = 11 # DRFW x bytes
  P_X1       = 12
  P_UMAX     = 13 # DRFW last unit of the full panel (0xA9, PDi / OTP)
  P_WIN      = 14
  P_IDLEU    = 15 # slave idle window unit (win 3)
  P_DUW      = 16 # 0 DUW full, 1 DUW = written rows, 2 = 1 then DUW = scan rows, 3 = 1 then DUW full
  P_STVM     = 17 # 0x61 STV_DIR to the master (-1 = not sent)
  P_STVS     = 18 # 0x61 STV_DIR to the slave (-1 = not sent)
  P_TCON     = 19 # 0x60 TCON to both (-1 = not sent)
  P_DCTL     = 20 # 0x01 DCTL (-2 = OTP byte 0x10, -1 = not sent)
  P_DCTLT    = 21 # DCTL target: 0 both, 1 master, 2 slave
  P_OSC      = 22 # 0x03 second byte
  P_F1       = 23 # ink frames, command 1 (VDH)
  P_F3       = 24 # command 3 (VDH)
  P_FE       = 25 # command 2 (VDL)
  P_F40      = 26 # 1 = 40-frame table (phases a b c d) instead of 20
  P_BUDGET   = 27 # ms per pull the planner aims for
  P_BASE     = 28 # ms per pull, fixed part of the model
  P_MSROW    = 29 # ms per scanned row x 100 (0.85 ms -> 85)
  P_GAP      = 30 # rows with commands closer than this share a band
  P_SESSION  = 31 # pulls per session (then a fresh open)
  P_CLEAN    = 32 # idle cleanup: bit 0 ghost erase, bit 1 reinforce
  P_CLEANMS  = 33 # knobs still this long before cleanup
  P_BARH     = 34 # drv2 bars: bar height
  P_BARPULLS = 35 # drv2 bars: pulls per bar
  P_QDEVERY  = 36 # quick draw: a pull every N points too (0 = only at breaks)
  P_GHOSTREC = 37 # record twin ghosts under any strategy
  P_LOG      = 38 # 1 = log every pull
  P_REGS     = 39 # 1 = apply the extra registers (drv2 reg)
  P_MAXROWS  = 40 # rows per band (0 = from budget / base / msrow)
  P_HOLD     = 41 # ms idle before the session is closed (power stays on)
  P_BARF     = 42 # drv2 bars: VDH frames of the bars (command 3)
  P_COUNT    = 43

  NAMES = "strat twin wrap twincmd unit align pad d0 d1 sd0 sd1 x0 x1 umax win idleu duw stvm stvs tcon dctl dctlt osc f1 f3 fe f40 budget base msrow gap session clean cleanms barh barpulls qdevery ghost log regs maxrows hold barf"

  @@p = uninitialized StaticArray(Int32, 48)
  @@init = false

  def self.params : Int32*
    reset unless @@init
    pointerof(@@p).as(Int32*)
  end

  def self.reset : Nil
    @@init = true
    q = pointerof(@@p).as(Int32*)
    q[P_STRAT] = S_PLAIN
    q[P_TWIN] = 336
    q[P_WRAP] = 0
    q[P_TWINCMD] = 0
    q[P_UNIT] = 4
    q[P_ALIGN] = 4
    q[P_PAD] = 0
    q[P_D0] = 0
    q[P_D1] = 0
    q[P_SD0] = 0
    q[P_SD1] = 0
    q[P_X0] = 0
    q[P_X1] = HALF &- 1
    q[P_UMAX] = 0xA9
    q[P_WIN] = W_SHARED
    q[P_IDLEU] = 84
    q[P_DUW] = 1
    q[P_STVM] = 1
    q[P_STVS] = -1
    q[P_TCON] = 0x25
    q[P_DCTL] = -2
    q[P_DCTLT] = 0
    q[P_OSC] = 0x11
    q[P_F1] = 2
    q[P_F3] = 2
    q[P_FE] = 2
    q[P_F40] = 0
    q[P_BUDGET] = 230
    q[P_BASE] = 20
    q[P_MSROW] = 85
    q[P_GAP] = 24
    q[P_SESSION] = 60
    q[P_CLEAN] = 1
    q[P_CLEANMS] = 400
    q[P_BARH] = 16
    q[P_BARPULLS] = 2
    q[P_QDEVERY] = 0
    q[P_GHOSTREC] = 0
    q[P_LOG] = 1
    q[P_REGS] = 1
    q[P_MAXROWS] = 0
    q[P_HOLD] = 20_000
    q[P_BARF] = 12
  end

  def self.get(i : Int32) : Int32
    return 0 if i < 0 || i >= P_COUNT
    params[i]
  end

  def self.set(i : Int32, v : Int32) : Nil
    return if i < 0 || i >= P_COUNT
    params[i] = v
  end

  # Parameter index of the name s[0, n] (NAMES), -1 if none.
  def self.find(s : UInt8*, n : Int32) : Int32
    nm = NAMES.to_unsafe
    len = NAMES.bytesize
    idx = 0
    i = 0
    while i < len
      j = i
      while j < len && nm[j] != 0x20_u8
        j = j &+ 1
      end
      if j &- i == n
        k = 0
        while k < n && nm[i &+ k] == s[k]
          k = k &+ 1
        end
        return idx if k == n
      end
      idx = idx &+ 1
      i = j &+ 1
    end
    -1
  end

  # Name of parameter i: start offset into NAMES and length (len[0]).
  def self.name_at(i : Int32, len : Int32*) : Int32
    nm = NAMES.to_unsafe
    n = NAMES.bytesize
    idx = 0
    s = 0
    while s < n
      e = s
      while e < n && nm[e] != 0x20_u8
        e = e &+ 1
      end
      if idx == i
        len[0] = e &- s
        return s
      end
      idx = idx &+ 1
      s = e &+ 1
    end
    len[0] = 0
    0
  end

  # ---- twin mapping -------------------------------------------------------

  # Row driven together with r by a partial pull (FINDINGS: about 336 lower),
  # -1 if it falls off the panel (wrap 0).
  def self.twin_row(r : Int32) : Int32
    t = r &+ get(P_TWIN)
    if t >= 0 && t < H
      return t
    end
    return -1 if get(P_WRAP) == 0
    t = t >= H ? t &- H : t &+ H
    t >= 0 && t < H ? t : -1
  end

  # Twin rows of band b0..b1 as up to two ranges (pairs into res); count.
  def self.twin_ranges(b0 : Int32, b1 : Int32, res : Int32*) : Int32
    n = 0
    k = -1
    while k <= 1
      if k == 0 || get(P_WRAP) != 0
        sh = get(P_TWIN) &+ k &* H
        t0 = b0 &+ sh
        t1 = b1 &+ sh
        t0 = 0 if t0 < 0
        t1 = H &- 1 if t1 > H &- 1
        if t0 <= t1 && n < 2
          res[n &* 2] = t0
          res[n &* 2 &+ 1] = t1
          n = n &+ 1
        end
      end
      k = k &+ 1
    end
    n
  end

  # ---- bands ----------------------------------------------------------------

  # Pads and aligns rows y0..y1 (res[0], res[1]), clipped to the panel.
  def self.align_band(y0 : Int32, y1 : Int32, res : Int32*) : Nil
    a = get(P_ALIGN)
    a = 1 if a < 1
    y0 = y0 &- get(P_PAD)
    y1 = y1 &+ get(P_PAD)
    y0 = 0 if y0 < 0
    y1 = H &- 1 if y1 > H &- 1
    y0 = y0.unsafe_div(a) &* a
    y1 = (y1.unsafe_div(a) &+ 1) &* a &- 1
    y1 = H &- 1 if y1 > H &- 1
    res[0] = y0
    res[1] = y1
  end

  # Rows per band: P_MAXROWS, or what fits the budget by the timing model
  # (pull ms = base + rows x msrow / 100), a multiple of align, >= align.
  def self.max_rows : Int32
    a = get(P_ALIGN)
    a = 1 if a < 1
    m = get(P_MAXROWS)
    if m <= 0
      r = get(P_MSROW)
      r = 1 if r < 1
      m = ((get(P_BUDGET) &- get(P_BASE)) &* 100).unsafe_div(r)
    end
    m = m.unsafe_div(a) &* a
    m = a if m < a
    m = H if m > H
    m
  end

  # Predicted panel ms for a pull scanning `rows` rows.
  def self.predict_ms(rows : Int32) : Int32
    get(P_BASE) &+ (rows &* get(P_MSROW)).unsafe_div(100)
  end

  # Bands over the rows y0..y1 whose pending[r] != 0: runs closer than gap
  # rows merged, padded and aligned, merged again where they overlap, split
  # into max_rows. Pairs into res (at most max_out bands); count.
  def self.plan(pending : UInt8*, y0 : Int32, y1 : Int32, res : Int32*, max_out : Int32) : Int32
    y0 = 0 if y0 < 0
    y1 = H &- 1 if y1 > H &- 1
    gap = get(P_GAP)
    mr = max_rows
    ab = uninitialized StaticArray(Int32, 2)
    abp = pointerof(ab).as(Int32*)
    n = 0
    cur0 = -1
    cur1 = -1
    r = y0
    while r <= y1 &+ 1
      hit = r <= y1 && pending[r] != 0_u8
      if hit
        if cur0 < 0
          cur0 = r
        elsif r &- cur1 &- 1 >= gap
          n = emit(cur0, cur1, res, n, max_out, mr, abp)
          cur0 = r
        end
        cur1 = r
      end
      r = r &+ 1
    end
    n = emit(cur0, cur1, res, n, max_out, mr, abp) if cur0 >= 0
    n
  end

  # plan helper: aligns run r0..r1, merges it into the previous band if they
  # overlap (or touch), then re-splits the tail into max_rows bands.
  def self.emit(r0 : Int32, r1 : Int32, res : Int32*, n : Int32, max_out : Int32, mr : Int32, ab : Int32*) : Int32
    align_band(r0, r1, ab)
    a0 = ab[0]
    a1 = ab[1]
    if n > 0 && a0 <= res[n &* 2 &- 1] &+ 1
      # overlaps the last band: take it back and extend
      n = n &- 1
      a0 = res[n &* 2]
      # the last band may be one piece of a split run: reach back over
      # touching pieces so the re-split keeps max_rows pieces
      a1 = res[n &* 2 &+ 1] if res[n &* 2 &+ 1] > a1
    end
    s = a0
    while s <= a1 && n < max_out
      e = s &+ mr &- 1
      e = a1 if e > a1
      res[n &* 2] = s
      res[n &* 2 &+ 1] = e
      n = n &+ 1
      s = e &+ 1
    end
    n
  end

  # Rows the pull scans (s[0], s[1]) for band b0..b1 under strategy strat.
  def self.scan_range(strat : Int32, b0 : Int32, b1 : Int32, s : Int32*) : Nil
    s0 = b0
    s1 = b1
    if strat == S_TWINSPAN
      tw = uninitialized StaticArray(Int32, 4)
      tp = pointerof(tw).as(Int32*)
      k = twin_ranges(b0, b1, tp)
      i = 0
      while i < k
        s0 = tp[i &* 2] if tp[i &* 2] < s0
        s1 = tp[i &* 2 &+ 1] if tp[i &* 2 &+ 1] > s1
        i = i &+ 1
      end
    elsif strat == S_TAIL
      s1 = H &- 1
    elsif strat == S_HEAD
      s0 = 0
    elsif strat == S_FULL
      s0 = 0
      s1 = H &- 1
    end
    s[0] = s0
    s[1] = s1
  end

  # Row sources for one pull into src[0, H]: band rows = commands; under
  # TWINRAM / TWINSPAN the twin rows too (zeros, or commands with twincmd
  # 1); rows in dirty[] (they still hold the previous pull's swapped
  # commands) that are not written otherwise = zeros.
  def self.mark_writes(strat : Int32, b0 : Int32, b1 : Int32, dirty : UInt8*, src : UInt8*) : Nil
    r = 0
    while r < H
      src[r] = dirty.null? || dirty[r] == 0_u8 ? SRC_NONE : SRC_ZEROS
      r = r &+ 1
    end
    if strat == S_TWINRAM || strat == S_TWINSPAN
      tv = get(P_TWINCMD) != 0 ? SRC_CMDS : SRC_ZEROS
      tw = uninitialized StaticArray(Int32, 4)
      tp = pointerof(tw).as(Int32*)
      k = twin_ranges(b0, b1, tp)
      i = 0
      while i < k
        r = tp[i &* 2]
        while r <= tp[i &* 2 &+ 1]
          src[r] = tv
          r = r &+ 1
        end
        i = i &+ 1
      end
    end
    r = b0 < 0 ? 0 : b0
    while r <= b1 && r < H
      src[r] = SRC_CMDS
      r = r &+ 1
    end
  end

  # Next run of rows with src[r] == v at or after `from`: res[0], res[1];
  # false if none.
  def self.next_run(src : UInt8*, v : UInt8, from : Int32, res : Int32*) : Bool
    r = from < 0 ? 0 : from
    while r < H && src[r] != v
      r = r &+ 1
    end
    return false if r >= H
    s = r
    while r < H && src[r] == v
      r = r &+ 1
    end
    res[0] = s
    res[1] = r &- 1
    true
  end

  # ---- command bytes ------------------------------------------------------

  # 0x13 DUW, full width x rows y0..y1: [x0, x1, y0 lo, y0 hi, y1 lo, y1 hi].
  def self.duw_bytes(y0 : Int32, y1 : Int32, res : UInt8*) : Nil
    res[0] = 0_u8
    res[1] = (HALF &- 1).to_u8!
    res[2] = (y0 & 0xFF).to_u8!
    res[3] = y0.unsafe_shr(8).to_u8!
    res[4] = (y1 & 0xFF).to_u8!
    res[5] = y1.unsafe_shr(8).to_u8!
  end

  # 0x12 RAM_RW at row y (OTP order, verified by window mode 8):
  # [x start, y lo, flags | y hi], flags = OTP byte 0x15 (0x10).
  def self.ramrw_bytes(y : Int32, flags : UInt8, res : UInt8*) : Nil
    res[0] = 0_u8
    res[1] = (y & 0xFF).to_u8!
    res[2] = flags | y.unsafe_shr(8).to_u8!
  end

  # DRFW unit of row r (rows per unit = P_UNIT).
  def self.unit_of(r : Int32) : Int32
    u = get(P_UNIT)
    u = 1 if u < 1
    r.unsafe_div(u)
  end

  # 0x90 DRFW bytes [x0, x1, u0, u1] for scan rows s0..s1 on CoG `cog`
  # (1 = master, 2 = slave) under P_WIN. The whole panel is [0, umax]; a
  # range that reaches the last row ends at umax. Offsets d0 / d1 (master;
  # slave with win 0) or sd0 / sd1 (slave, win 1) are added, then clipped to
  # a byte.
  def self.drfw_bytes(cog : Int32, s0 : Int32, s1 : Int32, res : UInt8*) : Nil
    w = get(P_WIN)
    x0 = get(P_X0)
    x1 = get(P_X1)
    umax = get(P_UMAX)
    u0 = s0 <= 0 ? 0 : unit_of(s0)
    u1 = s1 >= H &- 1 ? umax : unit_of(s1)
    if cog == 2 && w == W_MASTER
      u0 = 0
      u1 = umax
    elsif cog == 2 && w == W_SLAVEIDLE
      u0 = get(P_IDLEU)
      u1 = u0
    elsif cog == 2 && w == W_PERCOG
      u0 = u0 &+ get(P_SD0)
      u1 = u1 &+ get(P_SD1)
    else
      u0 = u0 &+ get(P_D0)
      u1 = u1 &+ get(P_D1)
    end
    res[0] = clip8(x0)
    res[1] = clip8(x1)
    res[2] = clip8(u0)
    res[3] = clip8(u1)
  end

  def self.clip8(v : Int32) : UInt8
    v < 0 ? 0_u8 : (v > 255 ? 255_u8 : v.to_u8!)
  end

  # ---- waveform table (0xB0, driver B) --------------------------------------
  # 5 tables x 10 groups x 8 bytes [levels a|b|c|d, TPa, TPb, SRab, TPc,
  # TPd, SRcd, RP]. Every TP and RP is 1 and SRcd 1 (a zero TP, RP 0 or
  # SRab = SRcd = 0 hangs the CoG). 20-frame form (as EPD.build_ink): SRab
  # 0, frame f = group f / 2, phase c (even) or d (odd); the last frame
  # stays GND. 40-frame form (as EPD.build_ink40): SRab 1, phase f % 4.
  # Table 1 = command 1 (VDH f1 frames), 2 = command 2 (VDL fe), 3 =
  # command 3 (VDH f3); table 0, 4 (VCOM) GND.
  def self.build_table(lut : UInt8*, f1 : Int32, f3 : Int32, fe : Int32, f40 : Bool) : Nil
    k = 0
    while k < 50
      q = lut + (k &* 8).to_i64!
      q[0] = 0_u8; q[1] = 1_u8; q[2] = 1_u8; q[3] = f40 ? 1_u8 : 0_u8
      q[4] = 1_u8; q[5] = 1_u8; q[6] = 1_u8; q[7] = 1_u8
      k = k &+ 1
    end
    nf = f40 ? 40 : 19
    f = 0
    while f < nf
      g = f40 ? f.unsafe_div(4) : f.unsafe_div(2)
      shift = f40 ? 6 &- 2 &* (f & 3) : ((f & 1) == 1 ? 0 : 2)
      if f < f1
        q = lut + ((10 &+ g) &* 8).to_i64!
        q[0] = q[0] | 1.unsafe_shl(shift).to_u8!
      end
      if f < fe
        q = lut + ((20 &+ g) &* 8).to_i64!
        q[0] = q[0] | 2.unsafe_shl(shift).to_u8!
      end
      if f < f3
        q = lut + ((30 &+ g) &* 8).to_i64!
        q[0] = q[0] | 1.unsafe_shl(shift).to_u8!
      end
      f = f &+ 1
    end
  end

  # ---- planes ----------------------------------------------------------------

  # Rows row..row+n-1 of one CoG's half (half 0 = master) of a frame plane
  # into dst (60 bytes per row); a null plane gives zeros.
  def self.pack_rows(dst : UInt8*, plane : UInt8*, half : Int32, row : Int32, n : Int32) : Nil
    k = 0
    r = 0
    while r < n
      if plane.null?
        c = 0
        while c < HALF
          dst[k] = 0_u8
          k = k &+ 1
          c = c &+ 1
        end
      else
        src = plane + ((row &+ r) &* ROW_BYTES &+ half &* HALF).to_i64!
        c = 0
        while c < HALF
          dst[k] = src[c]
          k = k &+ 1
          c = c &+ 1
        end
      end
      r = r &+ 1
    end
  end

  # Any command in row r of the planes.
  def self.row_any(cn : UInt8*, co : UInt8*, r : Int32) : Bool
    i = r &* ROW_BYTES
    e = i &+ ROW_BYTES
    while i < e
      return true if (cn[i] | co[i]) != 0_u8
      i = i &+ 1
    end
    false
  end

  # Command (0..3) of pixel x, y.
  def self.cmd_at(cn : UInt8*, co : UInt8*, x : Int32, y : Int32) : Int32
    i = y &* ROW_BYTES &+ x.unsafe_shr(3)
    m = 0x80_u8.unsafe_shr(x & 7)
    ((co[i] & m) != 0_u8 ? 2 : 0) | ((cn[i] & m) != 0_u8 ? 1 : 0)
  end

  # Sets pixel x, y of the planes to command c.
  def self.put_cmd(cn : UInt8*, co : UInt8*, x : Int32, y : Int32, c : Int32) : Nil
    i = y &* ROW_BYTES &+ x.unsafe_shr(3)
    m = 0x80_u8.unsafe_shr(x & 7)
    nm = m ^ 0xFF_u8
    cn[i] = (c & 1) != 0 ? (cn[i] | m) : (cn[i] & nm)
    co[i] = (c & 2) != 0 ? (co[i] | m) : (co[i] & nm)
  end

  # ---- ghosts ----------------------------------------------------------------
  # After a pull that scanned s0..s1 with the commands of the rows where
  # src[r] == SRC_CMDS: the pixels' own state and the twin ghosts.
  #   own row:  1 / 3 = ink (driven bit set, any ghost there gone);
  #             2 = erase a ghost if there is one, else lighten (driven off)
  #   twin row (not itself scanned), with record true:
  #             1 / 3 on a pixel without ink = one more ghost level;
  #             2 removes a ghost level, or (on ink) counts as lightened.
  # ghost: one byte per pixel (levels), driven: one bit per pixel, rowg:
  # pixels with ghosts per row (Int32 x H). Returns the ghosts added; the
  # count of inked pixels the twin lightened goes to lt[0].
  def self.record(cn : UInt8*, co : UInt8*, src : UInt8*, s0 : Int32, s1 : Int32, rec : Bool,
                  ghost : UInt8*, driven : UInt8*, rowg : Int32*, lt : Int32*) : Int32
    added = 0
    r = s0 < 0 ? 0 : s0
    while r <= s1 && r < H
      if src[r] == SRC_CMDS && row_any(cn, co, r)
        t = rec ? twin_row(r) : -1
        t = -1 if t >= s0 && t <= s1
        b = 0
        while b < ROW_BYTES
          i = r &* ROW_BYTES &+ b
          nv = cn[i]
          ov = co[i]
          if (nv | ov) != 0_u8
            k = 0
            while k < 8
              m = 0x80_u8.unsafe_shr(k)
              c = ((ov & m) != 0_u8 ? 2 : 0) | ((nv & m) != 0_u8 ? 1 : 0)
              if c != 0
                x = b &* 8 &+ k
                own_effect(r, x, c, ghost, driven, rowg)
                added = added &+ twin_effect(t, x, c, ghost, driven, rowg, lt) if t >= 0
              end
              k = k &+ 1
            end
          end
          b = b &+ 1
        end
      end
      r = r &+ 1
    end
    added
  end

  def self.driven?(driven : UInt8*, x : Int32, y : Int32) : Bool
    (driven[y &* ROW_BYTES &+ x.unsafe_shr(3)] & 0x80_u8.unsafe_shr(x & 7)) != 0_u8
  end

  def self.set_driven(driven : UInt8*, x : Int32, y : Int32, on : Bool) : Nil
    i = y &* ROW_BYTES &+ x.unsafe_shr(3)
    m = 0x80_u8.unsafe_shr(x & 7)
    driven[i] = on ? (driven[i] | m) : (driven[i] & (m ^ 0xFF_u8))
  end

  def self.own_effect(r : Int32, x : Int32, c : Int32, ghost : UInt8*, driven : UInt8*, rowg : Int32*) : Nil
    gi = r &* (ROW_BYTES &* 8) &+ x
    if c == 2
      if !ghost.null? && ghost[gi] != 0_u8
        ghost[gi] = ghost[gi] &- 1_u8
        rowg[r] = rowg[r] &- 1 if ghost[gi] == 0_u8
      else
        set_driven(driven, x, r, false)
      end
    else
      set_driven(driven, x, r, true)
      if !ghost.null? && ghost[gi] != 0_u8
        ghost[gi] = 0_u8
        rowg[r] = rowg[r] &- 1
      end
    end
  end

  def self.twin_effect(t : Int32, x : Int32, c : Int32, ghost : UInt8*, driven : UInt8*, rowg : Int32*, lt : Int32*) : Int32
    return 0 if ghost.null?
    gi = t &* (ROW_BYTES &* 8) &+ x
    if c == 2
      if ghost[gi] != 0_u8
        ghost[gi] = ghost[gi] &- 1_u8
        rowg[t] = rowg[t] &- 1 if ghost[gi] == 0_u8
      elsif driven?(driven, x, t)
        lt[0] = lt[0] &+ 1
      end
      return 0
    end
    return 0 if driven?(driven, x, t)
    rowg[t] = rowg[t] &+ 1 if ghost[gi] == 0_u8
    ghost[gi] = ghost[gi] &+ 1_u8 if ghost[gi] < 250_u8
    1
  end

  # Ghost erase commands for rows b0..b1: command 2 on every ghost pixel
  # (not on ink). Returns the pixels set.
  def self.erase_cmds(ghost : UInt8*, driven : UInt8*, b0 : Int32, b1 : Int32, cn : UInt8*, co : UInt8*) : Int32
    n = 0
    r = b0
    while r <= b1
      x = 0
      while x < ROW_BYTES &* 8
        if ghost[r &* (ROW_BYTES &* 8) &+ x] != 0_u8 && !driven?(driven, x, r)
          put_cmd(cn, co, x, r, 2)
          n = n &+ 1
        end
        x = x &+ 1
      end
      r = r &+ 1
    end
    n
  end

  # Reinforce commands for rows b0..b1: command 3 on every inked pixel.
  def self.reinforce_cmds(driven : UInt8*, b0 : Int32, b1 : Int32, cn : UInt8*, co : UInt8*) : Int32
    n = 0
    i = b0 &* ROW_BYTES
    e = (b1 &+ 1) &* ROW_BYTES
    while i < e
      d = driven[i]
      if d != 0_u8
        cn[i] = cn[i] | d
        co[i] = co[i] | d
        k = 0
        while k < 8
          n = n &+ 1 if (d & 0x80_u8.unsafe_shr(k)) != 0_u8
          k = k &+ 1
        end
      end
      i = i &+ 1
    end
    n
  end

  # First band of ghost rows at or after `from` (rowg[r] > 0), at most
  # max_rows, aligned: res[0], res[1]. False if no ghosts are left.
  def self.ghost_band(rowg : Int32*, from : Int32, res : Int32*) : Bool
    r = from < 0 ? 0 : from
    while r < H && rowg[r] <= 0
      r = r &+ 1
    end
    if r >= H
      return false if from <= 0
      return ghost_band(rowg, 0, res)
    end
    mr = max_rows
    e = r
    k = r
    while k < H && k &- r < mr
      e = k if rowg[k] > 0
      k = k &+ 1
    end
    align_band(r, e, res)
    res[1] = res[0] &+ mr &- 1 if res[1] &- res[0] &+ 1 > mr
    true
  end
end
