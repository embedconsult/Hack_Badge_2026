# Sketch e-paper driver, "drv2" (`upd sketch drv2`; off by default). Used by
# Sketch only; every other app (and Sketch in its other modes) keeps
# epd.cr, which this file does not change. It drives the same CoGs through
# epd.cr's SPI/GPIO helpers (EPD.cmd / index / write / trigger, i.e. the C
# shims in main/*.c) and takes the panel over with its own session.
#
# ---- design note ---------------------------------------------------------
# Goal (GOALS.md): every pull <= 250 ms, strokes first, cleanup in idle
# bands, no displaced copies. A pull's time follows its DRFW rows (~0.85
# ms/row + 20 ms at 20 frames), so only row bands fit: a whole-panel pull
# is 580 ms. But a band pull over rows r0..r1 also drives the rows ~336
# lower with the same data (FINDINGS, `wbar`). Nothing measured so far
# says which register causes that, so this driver makes every candidate a
# runtime parameter and offers several strategies, so the hardware run can
# sweep them from the shell without rebuilding.
#
# Session (open): the ink session of EPD.diff_open (PDi / yigitabi
# register sequence, 0xB0 ink table, DC/DC on, DUW/DRFW whole panel, DCTL,
# both RAMs zero), with these registers taken from parameters: 0x03 OSC,
# 0x60 TCON, 0x61 STV_DIR per CoG (master only by default, as PDi), 0x01
# DCTL (value and target), the ink frames and 20/40-frame table, plus up
# to 8 raw registers (`drv2 reg`) sent at open or before every pull.
#
# Ink commands: both RAMs are written for every pulled row, so the table
# index (0x11 << 1) | 0x10 is a per-pixel command (0 none, 1 VDH f1, 2 VDL
# fe, 3 VDH f3). The CoG swaps 0x10 / 0x11 after a pull, so rows a pull
# wrote keep (swapped) commands: they are "dirty" and are rewritten with
# zeros before the next pull, whatever rows it scans. Every RAM row
# outside the written ones is zero in both banks, so any extra row a scan
# touches gets no drive from its own RAM.
#
# One pull (pull_band): rows to write (SkBand.mark_writes), RAM writes
# (DUW + RAM_RW at the run start, as window mode 8: verified addressing),
# DRFW for the scan rows (SkBand.drfw_bytes), 0x15, BUSY wait (the busy
# hook keeps the pen tracking), ms logged, "OVER 250" flagged.
# Planning (pull_cmds): the rows with commands become bands (strokes
# closer than `gap` rows share one), each split to fit `budget` ms by the
# model base + rows x msrow / 100 (SkBand.plan).
#
# Strategies (`drv2 strat N`):
#   0 plain    write band, scan band.
#   1 twinram  write band AND its twin rows (r + twin) with the data they
#              should get (zeros, or with twincmd 1 their own pending
#              commands), scan band. Cost: the twin rows' upload (~0.2 ms
#              per row). Fixes the copies if the twin is driven from its own
#              RAM rows; does nothing if it gets the band's data.
#   2 twinspan write band + twin, scan one DRFW range over both. Correct
#              data everywhere, but ~336 + h rows: ~310+ ms, so OVER 250;
#              there to measure the cost.
#   3 ghost    plain, and the driver books the copy it expects (each
#              command lands again at r + twin; wrap 0: copies below the
#              panel bottom vanish), then idle cleanup erases the booked
#              ghost pixels with command 2 (VDL fe frames; fe = f1 erases a
#              one-pass grey, EPD_NOTES cursor ticks). The erase pulls are
#              in the lower half, so their own twins fall off the panel.
#   4 tail     scan from the band to the panel bottom (r0..671): tests
#              "windows that end at the last row do not copy" (yigitabi:
#              "a shorter y1 copies the top rows down"). Fast low down only.
#   5 head     scan 0..r1 (the case yigitabi saw copying).
#   6 full     scan the whole panel (control: clean, ~580 ms).
#
# Twin-related registers (all runtime, `drv2 <name> <value>`):
#   stvm / stvs   0x61 STV_DIR value to master / slave, -1 = not sent
#                 (PDi: master 01 only; epd97: OTP 0x1C to both)
#   tcon          0x60 to both, -1 = not sent
#   dctl / dctlt  0x01 value (-2 = OTP 0x10, -1 = not sent), target 0 both
#                 1 master 2 slave
#   osc           0x03 second byte
#   unit / umax   rows per DRFW y unit (4), last unit of the full panel
#                 (0xA9: PDi / OTP use 0..0xA9 for 672 rows = 170 units)
#   align / pad   band row alignment and padding
#   d0 d1         DRFW start / end offset in units (master, and shared)
#   win           0 one shared 0x90, 1 per CoG (slave adds sd0 / sd1),
#                 2 master only (slave full panel), 3 slave idle at idleu
#   x0 x1         DRFW x bytes
#   duw           0 DUW full, 1 DUW = written rows, 2 = then DUW = scan
#                 rows before 0x15 ("DUW sets where the scan starts", window
#                 mode 5), 3 = then DUW full again
#   twin wrap     twin offset (336) and whether it wraps (ghost booking,
#                 twinram / twinspan rows)
#   f1 f3 fe f40  ink frames; 40-frame table (phases a-d; doubles msrow)
#   reg           `drv2 reg ...`: raw registers at open or before a pull
# Any change closes the session; the next pull reopens it (~0.4 s).
#
# Cleanup (cleanup_step, idle >= cleanms, one band per call, so knob
# motion between calls always comes first; the busy hook also keeps the
# pen moving during one): clean bit 0 = erase booked ghosts, bit 1 =
# reinforce (command 3 again on the last stroke bands).
#
# Test (`drv2 bars [y ...]`): a white base (EPD full refresh), then one
# black bar per window (barh rows, 120 px wide, x 60 + 150 i, command 3
# with barf frames, barpulls pulls) through the current strategy: one
# photo shows each bar and any twin.

require "./sketch_band"

# Read-only accessors for the Sketch driver, plus the session marker. They
# add nothing to epd.cr's own paths: EPD's refreshes reset the marker
# (cog_initial zeroes session_images, cog_stop resets diff_rows), which is
# how SkEPD sees that EPD took the panel back.
module EPD
  DRV2_IMAGES = 0x5D27 # session_images while SkEPD owns the CoG
  DRV2_ROWS   = -0x5D2 # diff_rows likewise (EPD only reads it while diff_open)

  def self.drv2_otp(i : Int32) : UInt8
    @@otp[i]
  end

  def self.drv2_spi_fail? : Bool
    @@spi_fail
  end

  def self.drv2_spi_clear : Nil
    @@spi_fail = false
  end

  def self.drv2_claim : Nil
    @@session_images = DRV2_IMAGES
    @@diff_rows = DRV2_ROWS
  end

  def self.drv2_claimed? : Bool
    !@@session_open && @@session_images == DRV2_IMAGES && @@diff_rows == DRV2_ROWS
  end

  def self.drv2_release : Nil
    @@session_images = 0
    @@diff_rows = HEIGHT
  end
end

module SkEPD
  CHUNK_ROWS = 68 # rows per SPI write (4080 bytes, one internal DMA buffer)
  BANDS_MAX  = 32
  RING       = 16 # recent stroke bands (reinforce)
  REGS_MAX   =  8
  REG_SZ     = 12 # [used, target 0 both 1 m 2 s, when 0 open 1 pull, idx, n, d0..d6]
  OVER_MS    = 250

  @@ok = false
  @@open = false
  @@stale = false
  @@pulls = 0 # this session
  @@buf = Pointer(UInt8).null
  @@lut = Pointer(UInt8).null
  @@cn = Pointer(UInt8).null # own command planes (cleanup, bars)
  @@co = Pointer(UInt8).null
  @@driven = Pointer(UInt8).null # inked pixels (bit per pixel)
  @@ghost = Pointer(UInt8).null  # booked twin ghosts (byte per pixel), lazily
  @@rowg = Pointer(Int32).null   # ghost pixels per row
  @@src = Pointer(UInt8).null    # row sources of the current pull
  @@dirty = Pointer(UInt8).null  # RAM rows holding commands
  @@pend = Pointer(UInt8).null   # rows with commands (planning)
  @@bands = Pointer(Int32).null
  @@ring = Pointer(Int32).null
  @@ring_n = 0
  @@lt = 0 # inked pixels a twin erase lightened
  @@clean_from = 0
  @@last_use = 0
  @@qd = false
  @@need_sync = true # driven[] not yet taken from the canvas
  @@regs = uninitialized StaticArray(UInt8, 96)
  @@regs_init = false
  # stats
  @@n = 0
  @@over = 0
  @@max = 0
  @@sum = 0
  @@last_ms = 0
  @@last_up = 0

  def self.p(i : Int32) : Int32
    SkBand.get(i)
  end

  def self.psram(n : Int32) : UInt8*
    q = LibIDF.heap_caps_malloc(n.to_u32!, EPD::MALLOC_CAP_SPIRAM | EPD::MALLOC_CAP_8BIT).as(UInt8*)
    EPD.zero(q, n) unless q.null?
    q
  end

  def self.ready? : Bool
    return true if @@ok
    @@buf = EPD.dma_alloc(CHUNK_ROWS &* SkBand::HALF) if @@buf.null?
    @@lut = EPD.dma_alloc(SkBand::LUT_BYTES) if @@lut.null?
    @@cn = psram(SkBand::PLANE) if @@cn.null?
    @@co = psram(SkBand::PLANE) if @@co.null?
    @@driven = psram(SkBand::PLANE) if @@driven.null?
    @@rowg = psram(SkBand::H &* 4).as(Int32*) if @@rowg.null?
    @@src = psram(SkBand::H) if @@src.null?
    @@dirty = psram(SkBand::H) if @@dirty.null?
    @@pend = psram(SkBand::H) if @@pend.null?
    @@bands = psram(BANDS_MAX &* 8).as(Int32*) if @@bands.null?
    @@ring = psram(RING &* 8).as(Int32*) if @@ring.null?
    @@ok = !(@@buf.null? || @@lut.null? || @@cn.null? || @@co.null? || @@driven.null? || @@rowg.null? ||
             @@src.null? || @@dirty.null? || @@pend.null? || @@bands.null? || @@ring.null?)
    log("drv2: buffers ready (1) or out of memory (0)", @@ok ? 1 : 0) unless @@ok
    @@ok
  end

  def self.ghost_map : UInt8*
    @@ghost = psram(SkBand::PLANE &* 8) if @@ghost.null?
    @@ghost
  end

  def self.open? : Bool
    @@open && EPD.drv2_claimed?
  end

  # Parameters changed (shell task): reopen before the next pull.
  def self.stale! : Nil
    @@stale = true
  end

  def self.qd=(v : Bool) : Nil
    @@qd = v
  end

  # ---- registers -----------------------------------------------------------

  def self.target_of(t : Int32) : Int32
    t == 1 ? EPD::LEFT : (t == 2 ? EPD::RIGHT : EPD::BOTH)
  end

  def self.regs : UInt8*
    q = pointerof(@@regs).as(UInt8*)
    unless @@regs_init
      @@regs_init = true
      i = 0
      while i < REGS_MAX &* REG_SZ
        q[i] = 0_u8
        i = i &+ 1
      end
    end
    q
  end

  # Extra register `idx` with n (<= 6) bytes from d, to target (0 both, 1
  # master, 2 slave), at open (wh 0) or before every pull (wh 1). Slot -1:
  # the first free one. Returns the slot or -1.
  def self.reg_set(slot : Int32, target : Int32, wh : Int32, idx : Int32, n : Int32, d : Int32*) : Int32
    q = regs
    if slot < 0
      s = 0
      while s < REGS_MAX && q[s &* REG_SZ] != 0_u8
        s = s &+ 1
      end
      slot = s
    end
    return -1 if slot >= REGS_MAX || n < 0 || n > 6
    e = q + (slot &* REG_SZ).to_i64!
    e[0] = 1_u8
    e[1] = target.to_u8!
    e[2] = wh.to_u8!
    e[3] = idx.to_u8!
    e[4] = n.to_u8!
    k = 0
    while k < 6
      e[5 &+ k] = k < n ? d[k].to_u8! : 0_u8
      k = k &+ 1
    end
    @@stale = true
    slot
  end

  def self.reg_clear : Nil
    q = regs
    i = 0
    while i < REGS_MAX &* REG_SZ
      q[i] = 0_u8
      i = i &+ 1
    end
    @@stale = true
  end

  def self.apply_regs(wh : Int32) : Nil
    return if p(SkBand::P_REGS) == 0
    q = regs
    s = 0
    while s < REGS_MAX
      e = q + (s &* REG_SZ).to_i64!
      if e[0] != 0_u8 && e[2].to_i32! == wh
        EPD.cmd(target_of(e[1].to_i32!), e[3], e[4].to_i32!, e[5], e[6], e[7], e[8], e[9], e[10])
      end
      s = s &+ 1
    end
  end

  def self.reg_print : Nil
    q = regs
    s = 0
    while s < REGS_MAX
      e = q + (s &* REG_SZ).to_i64!
      if e[0] != 0_u8
        LibIDF.cr_log3("drv2 reg: slot / target (0 both 1 m 2 s) / when (0 open 1 pull)".to_unsafe, s, e[1].to_i32!, e[2].to_i32!)
        LibIDF.cr_hex("drv2 reg:   index, bytes".to_unsafe, e + 3_i64, 1 &+ 1 &+ e[4].to_i32!)
      end
      s = s &+ 1
    end
  end

  # ---- session -------------------------------------------------------------

  def self.dctl_value : Int32
    d = p(SkBand::P_DCTL)
    d == -2 ? EPD.drv2_otp(0x10).to_i32! : d
  end

  # Opens our ink session (EPD.diff_open's sequence, registers from the
  # parameters). False (CoG stopped) on an SPI error.
  def self.open : Bool
    return false unless ready?
    t0 = millis
    EPD.finish_aborted
    close
    EPD.cog_stop if EPD.session_open? # EPD's session: shut it down cleanly first
    EPD.drv2_spi_clear
    EPD.cog_initial(EPD.quick_open?) # reset (quick if the supply is on) + 0x70 71 36
    EPD.cmd1(0x05_u8, 0x7D_u8); delay_ms(51)
    EPD.cmd1(0x05_u8, 0x00_u8); delay_ms(2)
    EPD.cmd1(0xD8_u8, 0x80_u8)
    EPD.cmd1(0xD6_u8, 0x00_u8)
    EPD.cmd1(0xA7_u8, 0x10_u8); delay_ms(3)
    EPD.cmd1(0xA7_u8, 0x00_u8); delay_ms(11)
    EPD.cmd(EPD::BOTH, 0x03_u8, 2, 0x00_u8, p(SkBand::P_OSC).to_u8!)
    t = EPD::LEFT
    while t <= EPD::RIGHT
      EPD.cmd(t, 0x44_u8, 1, 0x00_u8)
      EPD.cmd(t, 0x45_u8, 1, 0x80_u8)
      EPD.cmd(t, 0xA7_u8, 1, 0x10_u8); delay_ms(3)
      EPD.cmd(t, 0xA7_u8, 1, 0x00_u8); delay_ms(11)
      EPD.cmd(t, 0x44_u8, 1, 0x06_u8)
      EPD.cmd(t, 0x45_u8, 1, 0x84_u8)
      EPD.cmd(t, 0xA7_u8, 1, 0x10_u8); delay_ms(3)
      EPD.cmd(t, 0xA7_u8, 1, 0x00_u8); delay_ms(11)
      t = t &+ 1
    end
    EPD.cmd1(0x60_u8, p(SkBand::P_TCON).to_u8!) if p(SkBand::P_TCON) >= 0
    EPD.cmd(EPD::LEFT, 0x61_u8, 1, p(SkBand::P_STVM).to_u8!) if p(SkBand::P_STVM) >= 0
    EPD.cmd(EPD::RIGHT, 0x61_u8, 1, p(SkBand::P_STVS).to_u8!) if p(SkBand::P_STVS) >= 0
    EPD.cmd1(0x02_u8, 0x00_u8)
    SkBand.build_table(@@lut, p(SkBand::P_F1), p(SkBand::P_F3), p(SkBand::P_FE), p(SkBand::P_F40) != 0)
    EPD.send(EPD::BOTH, 0xB0_u8, @@lut, SkBand::LUT_BYTES)
    EPD.diff_dcdc_on
    EPD.cmd(EPD::BOTH, 0x13_u8, 6, 0x00_u8, 0x3B_u8, 0x00_u8, 0x00_u8, 0x9F_u8, 0x02_u8) # DUW whole panel
    EPD.cmd(EPD::BOTH, 0x90_u8, 4, 0x00_u8, 0x3B_u8, 0x00_u8, p(SkBand::P_UMAX).to_u8!) # DRFW whole panel
    dv = dctl_value
    EPD.cmd(target_of(p(SkBand::P_DCTLT)), 0x01_u8, 1, dv.to_u8!) if dv >= 0
    apply_regs(0)
    t = EPD::LEFT
    while t <= EPD::RIGHT # both RAMs zero: no command anywhere
      EPD.ram_rw_full(t)
      EPD.send_plane(t, 0x10_u8, Pointer(UInt8).null, Pointer(UInt8).null)
      EPD.ram_rw_full(t)
      EPD.send_plane(t, 0x11_u8, Pointer(UInt8).null, Pointer(UInt8).null)
      t = t &+ 1
    end
    if EPD.drv2_spi_fail?
      log("drv2: session open failed (SPI), CoG stopped", 0)
      EPD.cog_stop
      return false
    end
    EPD.drv2_claim
    EPD.zero(@@dirty, SkBand::H)
    @@open = true
    @@stale = false
    @@pulls = 0
    @@last_use = millis
    log3("drv2: session open ms / strat / dctl", millis &- t0, p(SkBand::P_STRAT), dv)
    log3("drv2:   stv m / stv s / tcon", p(SkBand::P_STVM), p(SkBand::P_STVS), p(SkBand::P_TCON))
    true
  end

  # Closes our session (DC/DC soft shutdown; the supply stays on after a
  # quick session, as EPD). Nothing to do if EPD took the panel back.
  def self.close : Nil
    return unless @@open
    @@open = false
    if EPD.drv2_claimed?
      EPD.cog_stop
      EPD.drv2_release
    end
  end

  def self.session_ok? : Bool
    s = p(SkBand::P_SESSION)
    open? && !@@stale && @@pulls < (s < 1 ? 1 : s)
  end

  def self.ensure_open : Bool
    return true if session_ok?
    open
  end

  # Main loop: before anything else may use EPD, and when the knobs have
  # rested `hold` ms.
  def self.release : Nil
    close if @@open
  end

  def self.idle_release(now : Int32) : Nil
    close if @@open && now &- @@last_use >= p(SkBand::P_HOLD)
  end

  # ---- RAM writes ------------------------------------------------------------

  # Rows y0..y1 of `plane` (null = zeros), this CoG's half, after index idx.
  def self.write_rows(t : Int32, idx : UInt8, plane : UInt8*, y0 : Int32, y1 : Int32) : Nil
    half = t == EPD::RIGHT ? 1 : 0
    EPD.index(t, idx)
    EPD.cs_lo(t)
    row = y0
    while row <= y1 && !EPD.drv2_spi_fail?
      n = y1 &- row &+ 1
      n = CHUNK_ROWS if n > CHUNK_ROWS
      SkBand.pack_rows(@@buf, plane, half, row, n)
      EPD.write(@@buf, n &* SkBand::HALF)
      row = row &+ n
    end
    EPD.cs_hi
  end

  def self.duw_rows(t : Int32, y0 : Int32, y1 : Int32) : Nil
    b = uninitialized StaticArray(UInt8, 6)
    q = pointerof(b).as(UInt8*)
    SkBand.duw_bytes(y0, y1, q)
    EPD.cmd(t, 0x13_u8, 6, q[0], q[1], q[2], q[3], q[4], q[5])
  end

  def self.ram_rw(t : Int32, y : Int32) : Nil
    b = uninitialized StaticArray(UInt8, 3)
    q = pointerof(b).as(UInt8*)
    SkBand.ramrw_bytes(y, EPD.drv2_otp(0x15), q)
    EPD.cmd(t, 0x12_u8, 3, q[0], q[1], q[2])
  end

  # Both planes of rows y0..y1 to both CoGs (null planes = zeros).
  def self.write_run(y0 : Int32, y1 : Int32, cn : UInt8*, co : UInt8*) : Nil
    t = EPD::LEFT
    while t <= EPD::RIGHT
      if p(SkBand::P_DUW) == 0
        duw_rows(t, 0, SkBand::H &- 1)
      else
        duw_rows(t, y0, y1)
      end
      ram_rw(t, y0)
      write_rows(t, 0x10_u8, cn, y0, y1)
      ram_rw(t, y0)
      write_rows(t, 0x11_u8, co, y0, y1)
      t = t &+ 1
    end
  end

  def self.drfw(t : Int32, cog : Int32, s0 : Int32, s1 : Int32) : Nil
    b = uninitialized StaticArray(UInt8, 4)
    q = pointerof(b).as(UInt8*)
    SkBand.drfw_bytes(cog, s0, s1, q)
    EPD.cmd(t, 0x90_u8, 4, q[0], q[1], q[2], q[3])
  end

  # ---- one pull --------------------------------------------------------------

  # One pull for band b0..b1 with the commands in cn / co under the current
  # strategy. Returns panel ms, or -1 (session closed).
  def self.pull_band(b0 : Int32, b1 : Int32, cn : UInt8*, co : UInt8*, ring : Bool) : Int32
    return -1 unless ensure_open
    strat = p(SkBand::P_STRAT)
    src = @@src
    SkBand.mark_writes(strat, b0, b1, @@dirty, src)
    sr = uninitialized StaticArray(Int32, 2)
    s = pointerof(sr).as(Int32*)
    SkBand.scan_range(strat, b0, b1, s)
    run = uninitialized StaticArray(Int32, 2)
    rp = pointerof(run).as(Int32*)
    t_up = millis
    EPD.drv2_spi_clear
    written = 0
    v = SkBand::SRC_ZEROS
    while true
      from = 0
      while SkBand.next_run(src, v, from, rp)
        if v == SkBand::SRC_CMDS
          write_run(rp[0], rp[1], cn, co)
        else
          write_run(rp[0], rp[1], Pointer(UInt8).null, Pointer(UInt8).null)
        end
        written = written &+ (rp[1] &- rp[0] &+ 1)
        from = rp[1] &+ 1
      end
      break if v == SkBand::SRC_CMDS
      v = SkBand::SRC_CMDS
    end
    du = p(SkBand::P_DUW)
    if du == 2
      duw_rows(EPD::BOTH, s[0], s[1])
    elsif du == 3
      duw_rows(EPD::BOTH, 0, SkBand::H &- 1)
    end
    if p(SkBand::P_WIN) == SkBand::W_SHARED
      drfw(EPD::BOTH, 1, s[0], s[1])
    else
      drfw(EPD::LEFT, 1, s[0], s[1])
      drfw(EPD::RIGHT, 2, s[0], s[1])
    end
    apply_regs(1)
    up = millis &- t_up
    if EPD.drv2_spi_fail?
      log("drv2: upload failed (SPI), session closed", 0)
      close
      return -1
    end
    rc = EPD.trigger(false, EPD::FAST_TIMEOUT_MS)
    @@last_use = millis
    if rc < 0 || EPD.drv2_spi_fail?
      log("drv2: pull failed, session closed", rc)
      close
      return -1
    end
    @@pulls = @@pulls &+ 1
    # RAM state after the pull, and commands consumed outside the band
    r = 0
    while r < SkBand::H
      if src[r] == SkBand::SRC_ZEROS
        @@dirty[r] = 0_u8
      elsif src[r] == SkBand::SRC_CMDS
        @@dirty[r] = SkBand.row_any(cn, co, r) ? 1_u8 : 0_u8
      end
      r = r &+ 1
    end
    rec = strat == SkBand::S_GHOST || p(SkBand::P_GHOSTREC) != 0
    g = rec ? ghost_map : Pointer(UInt8).null
    rec = false if g.null?
    added = SkBand.record(cn, co, src, s[0], s[1], rec, g, @@driven, @@rowg, pointerof(@@lt))
    r = 0
    while r < SkBand::H # twin rows written with their own commands (twincmd 1): consumed
      if src[r] == SkBand::SRC_CMDS && (r < b0 || r > b1)
        i = r &* SkBand::ROW_BYTES
        e = i &+ SkBand::ROW_BYTES
        while i < e
          cn[i] = 0_u8
          co[i] = 0_u8
          i = i &+ 1
        end
      end
      r = r &+ 1
    end
    ring_push(b0, b1) if ring
    stats(rc, up)
    rows = s[1] &- s[0] &+ 1
    log3(rc > OVER_MS ? "drv2: pull y0 / rows / panel ms (OVER 250)" : "drv2: pull y0 / rows / panel ms", s[0], rows, rc)
    if p(SkBand::P_LOG) != 0
      log3("drv2:   band y0 / y1 / upload ms", b0, b1, up)
      log3("drv2:   rows written / predicted ms / ghosts booked", written, SkBand.predict_ms(rows), added)
    end
    if @@qd
      log2(rc > OVER_MS ? "sketch: qd pull panel / upload ms (OVER 250)" : "sketch: qd pull panel / upload ms", rc, up)
    end
    rc
  end

  def self.stats(rc : Int32, up : Int32) : Nil
    @@n = @@n &+ 1
    @@over = @@over &+ 1 if rc > OVER_MS
    @@max = rc if rc > @@max
    @@sum = @@sum &+ rc
    @@last_ms = rc
    @@last_up = up
  end

  def self.last_ms : Int32
    @@last_ms
  end

  def self.last_up : Int32
    @@last_up
  end

  def self.print_stats : Nil
    LibIDF.cr_log3("drv2: pulls / over 250 ms / max ms".to_unsafe, @@n, @@over, @@max)
    LibIDF.cr_log3("drv2: mean ms / ghost rows / lightened px".to_unsafe, @@n > 0 ? @@sum.unsafe_div(@@n) : 0, ghost_rows, @@lt)
  end

  def self.stats_reset : Nil
    @@n = 0
    @@over = 0
    @@max = 0
    @@sum = 0
  end

  def self.ring_push(b0 : Int32, b1 : Int32) : Nil
    if @@ring_n > 0
      k = (@@ring_n &- 1) &* 2
      return if @@ring[k] == b0 && @@ring[k &+ 1] == b1
    end
    if @@ring_n >= RING
      i = 0
      while i < (RING &- 1) &* 2
        @@ring[i] = @@ring[i &+ 2]
        i = i &+ 1
      end
      @@ring_n = RING &- 1
    end
    @@ring[@@ring_n &* 2] = b0
    @@ring[@@ring_n &* 2 &+ 1] = b1
    @@ring_n = @@ring_n &+ 1
  end

  # ---- strokes ---------------------------------------------------------------

  # Pulls the commands in cn / co (rows y0..y1) as bands that each fit the
  # budget. The planes' rows are left as they are (except twin rows
  # consumed under twincmd 1); the caller clears them. Returns the total
  # panel ms, or -1.
  def self.pull_cmds(cn : UInt8*, co : UInt8*, y0 : Int32, y1 : Int32) : Int32
    return 0 unless ready?
    y0 = 0 if y0 < 0
    y1 = SkBand::H &- 1 if y1 > SkBand::H &- 1
    r = 0
    while r < SkBand::H
      @@pend[r] = r >= y0 && r <= y1 && SkBand.row_any(cn, co, r) ? 1_u8 : 0_u8
      r = r &+ 1
    end
    n = SkBand.plan(@@pend, y0, y1, @@bands, BANDS_MAX)
    total = 0
    i = 0
    while i < n
      b0 = @@bands[i &* 2]
      b1 = @@bands[i &* 2 &+ 1]
      any = false
      r = b0
      while r <= b1 && !any
        any = SkBand.row_any(cn, co, r)
        r = r &+ 1
      end
      if any
        rc = pull_band(b0, b1, cn, co, true)
        return -1 if rc < 0
        total = total &+ rc
      end
      i = i &+ 1
    end
    total
  end

  def self.need_sync? : Bool
    @@need_sync
  end

  # After a full refresh: the panel shows `cv` (1 = ink); no ghosts.
  def self.sync_canvas(cv : UInt8*) : Nil
    return unless @@ok
    @@need_sync = false
    i = 0
    while i < SkBand::PLANE
      @@driven[i] = cv.null? ? 0_u8 : cv[i]
      i = i &+ 1
    end
    EPD.zero(@@ghost, SkBand::PLANE &* 8) unless @@ghost.null?
    EPD.zero(@@rowg.as(UInt8*), SkBand::H &* 4)
    @@ring_n = 0
    @@clean_from = 0
  end

  # ---- idle cleanup ------------------------------------------------------------

  def self.ghost_rows : Int32
    return 0 if !@@ok || @@ghost.null?
    n = 0
    r = 0
    while r < SkBand::H
      n = n &+ 1 if @@rowg[r] > 0
      r = r &+ 1
    end
    n
  end

  def self.cleanup_pending? : Bool
    return false unless @@ok
    c = p(SkBand::P_CLEAN)
    ((c & 1) != 0 && ghost_rows > 0) || ((c & 2) != 0 && @@ring_n > 0)
  end

  def self.clear_own(b0 : Int32, b1 : Int32) : Nil
    i = b0 &* SkBand::ROW_BYTES
    e = (b1 &+ 1) &* SkBand::ROW_BYTES
    while i < e
      @@cn[i] = 0_u8
      @@co[i] = 0_u8
      i = i &+ 1
    end
  end

  # One cleanup band (<= budget). The caller runs it only while the knobs
  # rest and checks them again before the next. Returns panel ms (0 = none).
  def self.cleanup_step : Int32
    return 0 unless @@ok
    c = p(SkBand::P_CLEAN)
    bb = uninitialized StaticArray(Int32, 2)
    b = pointerof(bb).as(Int32*)
    if (c & 1) != 0 && !@@ghost.null? && SkBand.ghost_band(@@rowg, @@clean_from, b)
      n = SkBand.erase_cmds(@@ghost, @@driven, b[0], b[1], @@cn, @@co)
      if n == 0
        drop_ghosts(b[0], b[1]) # only ghosts on ink there: nothing to erase
        @@clean_from = b[1] &+ 1
        return 0
      end
      rc = pull_band(b[0], b[1], @@cn, @@co, false)
      clear_own(b[0], b[1])
      @@clean_from = b[1] &+ 1
      log3("drv2: cleanup ghosts y0 / pixels / ms", b[0], n, rc)
      return rc
    end
    if (c & 2) != 0 && @@ring_n > 0
      @@ring_n = @@ring_n &- 1
      b0 = @@ring[@@ring_n &* 2]
      b1 = @@ring[@@ring_n &* 2 &+ 1]
      n = SkBand.reinforce_cmds(@@driven, b0, b1, @@cn, @@co)
      rc = 0
      rc = pull_band(b0, b1, @@cn, @@co, false) if n > 0
      clear_own(b0, b1)
      log3("drv2: cleanup reinforce y0 / pixels / ms", b0, n, rc)
      return rc
    end
    0
  end

  def self.drop_ghosts(b0 : Int32, b1 : Int32) : Nil
    r = b0
    while r <= b1
      i = r &* (SkBand::ROW_BYTES &* 8)
      e = i &+ SkBand::ROW_BYTES &* 8
      while i < e
        @@ghost[i] = 0_u8
        i = i &+ 1
      end
      @@rowg[r] = 0
      r = r &+ 1
    end
  end

  # ---- test: one bar per window ------------------------------------------------

  # Bars at rows ys[0..n-1] (n <= 6), barh rows, x 60 + 150 i, 120 px wide,
  # command 3 at barf frames, barpulls pulls each, after a white base.
  def self.bars(ys : Int32*, n : Int32) : Nil
    return unless ready?
    close
    EPD.fill(EPD::WHITE)
    EPD.raw = true
    EPD.fast_pulls = 3
    EPD.refresh(true, EPD::LUT_BASE)
    EPD.raw = false
    sync_canvas(Pointer(UInt8).null)
    keep_f3 = p(SkBand::P_F3)
    SkBand.set(SkBand::P_F3, p(SkBand::P_BARF))
    @@stale = true
    h = p(SkBand::P_BARH)
    h = 1 if h < 1
    ab = uninitialized StaticArray(Int32, 2)
    a = pointerof(ab).as(Int32*)
    i = 0
    while i < n
      y = ys[i]
      y = 0 if y < 0
      y = SkBand::H &- h if y > SkBand::H &- h
      x0 = 60 &+ i &* 150
      yy = y
      while yy < y &+ h
        xx = x0
        while xx < x0 &+ 120
          SkBand.put_cmd(@@cn, @@co, xx, yy, 3)
          xx = xx &+ 1
        end
        yy = yy &+ 1
      end
      SkBand.align_band(y, y &+ h &- 1, a)
      k = 0
      while k < p(SkBand::P_BARPULLS)
        rc = pull_band(a[0], a[1], @@cn, @@co, false)
        log3("drv2 bars: bar y / pull / panel ms", y, k, rc)
        k = k &+ 1
      end
      clear_own(a[0], a[1])
      i = i &+ 1
    end
    SkBand.set(SkBand::P_F3, keep_f3)
    @@stale = true
    print_stats
  end

  @@bar_y = uninitialized StaticArray(Int32, 6)
  @@bar_n = 0

  # Shell task: the bar rows for the next bars_run (n 0 = 100 300 400 560,
  # as wbar).
  def self.set_bars(ys : Int32*, n : Int32) : Nil
    q = pointerof(@@bar_y).as(Int32*)
    if n <= 0
      q[0] = 100
      q[1] = 300
      q[2] = 400
      q[3] = 560
      n = 4
    else
      n = 6 if n > 6
      i = 0
      while i < n
        q[i] = ys[i]
        i = i &+ 1
      end
    end
    @@bar_n = n
  end

  def self.bars_run : Nil
    set_bars(Pointer(Int32).null, 0) if @@bar_n == 0
    bars(pointerof(@@bar_y).as(Int32*), @@bar_n)
  end

  # ---- shell -------------------------------------------------------------------

  def self.print_params : Nil
    buf = uninitialized StaticArray(UInt8, 40)
    q = pointerof(buf).as(UInt8*)
    ln = uninitialized StaticArray(Int32, 1)
    lp = pointerof(ln).as(Int32*)
    nm = SkBand::NAMES.to_unsafe
    i = 0
    while i < SkBand::P_COUNT
      s = SkBand.name_at(i, lp)
      q[0] = 0x64_u8 # "drv2 "
      q[1] = 0x72_u8
      q[2] = 0x76_u8
      q[3] = 0x32_u8
      q[4] = 0x20_u8
      k = 0
      while k < lp[0] && k < 30
        q[5 &+ k] = nm[s &+ k]
        k = k &+ 1
      end
      q[5 &+ k] = 0_u8
      LibIDF.cr_log(q, SkBand.get(i))
      i = i &+ 1
    end
    reg_print
    LibIDF.cr_log3("drv2: session open / pulls in it / stale".to_unsafe, open? ? 1 : 0, @@pulls, @@stale ? 1 : 0)
    print_stats
  end
end
