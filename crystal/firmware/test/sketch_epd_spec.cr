# Host specs for the Sketch e-paper driver's band math (src/sketch_band.cr):
# band planning, twin mapping, row sources, command bytes, packing, the ink
# table and the ghost bookkeeping.
#   crystal spec test/sketch_epd_spec.cr
require "spec"
require "../src/sketch_band"

private alias B = SkBand

private def pend(*rows)
  p = Pointer(UInt8).malloc(B::H)
  rows.each { |r| p[r] = 1_u8 }
  p
end

private def pend_range(r0, r1)
  p = Pointer(UInt8).malloc(B::H)
  (r0..r1).each { |r| p[r] = 1_u8 }
  p
end

private def plan_of(p, y0 = 0, y1 = B::H - 1)
  res = Pointer(Int32).malloc(64)
  n = B.plan(p, y0, y1, res, 32)
  (0...n).map { |i| {res[2 * i], res[2 * i + 1]} }
end

private def bytes(n)
  Pointer(UInt8).malloc(n)
end

private def list(p, n)
  (0...n).map { |i| p[i].to_i }
end

private def planes
  {Pointer(UInt8).malloc(B::PLANE), Pointer(UInt8).malloc(B::PLANE)}
end

describe "SkBand parameters" do
  it "has one name per parameter" do
    B.reset
    B::NAMES.split(' ').size.should eq B::P_COUNT
  end

  it "finds names and maps them back" do
    B.reset
    B.find("strat".to_unsafe, 5).should eq B::P_STRAT
    B.find("maxrows".to_unsafe, 7).should eq B::P_MAXROWS
    B.find("stvs".to_unsafe, 4).should eq B::P_STVS
    B.find("st".to_unsafe, 2).should eq -1
    B.find("nope".to_unsafe, 4).should eq -1
    len = Pointer(Int32).malloc(1)
    B::P_COUNT.times do |i|
      s = B.name_at(i, len)
      B.find(B::NAMES.to_unsafe + s, len[0]).should eq i
    end
  end

  it "defaults keep today's ink session registers" do
    B.reset
    B.get(B::P_STVM).should eq 1     # 0x61 01 to the master only (PDi, diff_open)
    B.get(B::P_STVS).should eq -1
    B.get(B::P_TCON).should eq 0x25
    B.get(B::P_DCTL).should eq -2    # OTP byte 0x10
    B.get(B::P_UMAX).should eq 0xA9
    B.get(B::P_STRAT).should eq B::S_PLAIN
  end

  it "ignores res-of-range indices" do
    B.reset
    B.set(-1, 5)
    B.set(B::P_COUNT, 5)
    B.get(B::P_COUNT).should eq 0
  end
end

describe "SkBand twin mapping" do
  it "maps rows 336 lower and drops the ones off the panel" do
    B.reset
    B.twin_row(0).should eq 336
    B.twin_row(335).should eq 671
    B.twin_row(336).should eq -1
    B.twin_row(671).should eq -1
  end

  it "wraps when asked" do
    B.reset
    B.set(B::P_WRAP, 1)
    B.twin_row(336).should eq 0
    B.twin_row(671).should eq 335
    B.set(B::P_TWIN, -336)
    B.twin_row(0).should eq 336
    B.twin_row(400).should eq 64
  end

  it "gives twin bands as ranges" do
    B.reset
    res = Pointer(Int32).malloc(4)
    B.twin_ranges(100, 139, res).should eq 1
    {res[0], res[1]}.should eq({436, 475})
    B.twin_ranges(320, 359, res).should eq 1 # 656..695 clipped
    {res[0], res[1]}.should eq({656, 671})
    B.twin_ranges(400, 439, res).should eq 0
    B.set(B::P_WRAP, 1)
    B.twin_ranges(320, 359, res).should eq 2
    {res[0], res[1], res[2], res[3]}.should eq({0, 23, 656, 671})
  end
end

describe "SkBand bands" do
  it "aligns and pads" do
    B.reset
    res = Pointer(Int32).malloc(2)
    B.align_band(101, 106, res)
    {res[0], res[1]}.should eq({100, 107})
    B.set(B::P_PAD, 8)
    B.align_band(101, 106, res)
    {res[0], res[1]}.should eq({92, 115})
    B.align_band(2, 670, res)
    {res[0], res[1]}.should eq({0, 671})
  end

  it "derives max rows from the timing model" do
    B.reset
    B.max_rows.should eq 244 # (230 - 20) / 0.85 = 247, down to a multiple of 4
    B.predict_ms(244).should be <= 250
    B.set(B::P_MAXROWS, 41)
    B.max_rows.should eq 40
    B.set(B::P_MAXROWS, 1)
    B.max_rows.should eq 4
  end

  it "plans one band per stroke" do
    B.reset
    plan_of(pend_range(201, 230)).should eq [{200, 231}]
  end

  it "merges strokes closer than gap rows" do
    B.reset
    plan_of(pend(100, 120)).should eq [{100, 123}] # gap of 19 rows < 24
    plan_of(pend(100, 130)).should eq [{100, 103}, {128, 131}]
  end

  it "merges bands that overlap after padding" do
    B.reset
    B.set(B::P_GAP, 1)
    B.set(B::P_PAD, 8)
    plan_of(pend(100, 110)).should eq [{92, 119}]
  end

  it "splits tall strokes so every pull fits the budget" do
    B.reset
    bands = plan_of(pend_range(100, 599))
    bands.should eq [{100, 343}, {344, 587}, {588, 599}]
    bands.each { |(a, b)| B.predict_ms(b - a + 1).should be <= 250 }
  end

  it "keeps split pieces at max rows when a later run merges in" do
    B.reset
    p = pend_range(100, 400)
    p[410] = 1_u8
    bands = plan_of(p)
    bands.each { |(a, b)| (b - a + 1).should be <= B.max_rows }
    bands.last[1].should eq 411
    bands.first[0].should eq 100
  end

  it "plans only inside y0..y1 and returns nothing for no commands" do
    B.reset
    plan_of(pend(50, 300), 100, 400).should eq [{300, 303}]
    plan_of(pend).should eq [] of {Int32, Int32}
  end

  it "covers every pending row with bands that do not overlap" do
    B.reset
    rnd = Random.new(7)
    20.times do
      p = Pointer(UInt8).malloc(B::H)
      rows = (0...30).map { rnd.rand(B::H) }
      rows.each { |r| p[r] = 1_u8 }
      bands = plan_of(p)
      rows.each { |r| bands.any? { |(a, b)| a <= r && r <= b }.should be_true }
      bands.each_cons(2) { |(x, y)| (x[1] < y[0]).should be_true }
      bands.each { |(a, b)| ((b - a + 1) <= B.max_rows).should be_true }
      bands.each { |(a, b)| (a % 4).should eq 0; ((b + 1) % 4).should eq 0 }
    end
  end
end

describe "SkBand scan ranges" do
  it "scans the band, or more for the twin and control strategies" do
    B.reset
    s = Pointer(Int32).malloc(2)
    B.scan_range(B::S_PLAIN, 100, 139, s)
    {s[0], s[1]}.should eq({100, 139})
    B.scan_range(B::S_TWINRAM, 100, 139, s)
    {s[0], s[1]}.should eq({100, 139})
    B.scan_range(B::S_TWINSPAN, 100, 139, s)
    {s[0], s[1]}.should eq({100, 475})
    B.scan_range(B::S_TAIL, 100, 139, s)
    {s[0], s[1]}.should eq({100, 671})
    B.scan_range(B::S_HEAD, 100, 139, s)
    {s[0], s[1]}.should eq({0, 139})
    B.scan_range(B::S_FULL, 100, 139, s)
    {s[0], s[1]}.should eq({0, 671})
    B.scan_range(B::S_TWINSPAN, 400, 439, s) # no twin below the panel
    {s[0], s[1]}.should eq({400, 439})
  end
end

describe "SkBand row sources" do
  it "writes the band, zeroes dirty rows elsewhere" do
    B.reset
    src = bytes(B::H)
    dirty = bytes(B::H)
    (40..47).each { |r| dirty[r] = 1_u8 }
    (100..103).each { |r| dirty[r] = 1_u8 }
    B.mark_writes(B::S_PLAIN, 100, 139, dirty, src)
    src[39].should eq B::SRC_NONE
    src[40].should eq B::SRC_ZEROS
    src[47].should eq B::SRC_ZEROS
    src[100].should eq B::SRC_CMDS
    src[139].should eq B::SRC_CMDS
    src[140].should eq B::SRC_NONE
    src[436].should eq B::SRC_NONE
  end

  it "writes the twin rows under TWINRAM, zeros or commands" do
    B.reset
    src = bytes(B::H)
    B.mark_writes(B::S_TWINRAM, 100, 139, Pointer(UInt8).null, src)
    src[436].should eq B::SRC_ZEROS
    src[475].should eq B::SRC_ZEROS
    src[476].should eq B::SRC_NONE
    B.set(B::P_TWINCMD, 1)
    B.mark_writes(B::S_TWINSPAN, 100, 139, Pointer(UInt8).null, src)
    src[436].should eq B::SRC_CMDS
    src[300].should eq B::SRC_NONE # rows between: RAM already zero, not rewritten
  end

  it "lets the band win where it overlaps its own twin" do
    B.reset
    B.set(B::P_TWIN, 20)
    src = bytes(B::H)
    B.mark_writes(B::S_TWINRAM, 100, 139, Pointer(UInt8).null, src)
    (100..139).each { |r| src[r].should eq B::SRC_CMDS }
    (140..159).each { |r| src[r].should eq B::SRC_ZEROS }
  end

  it "walks runs of one source" do
    src = bytes(B::H)
    (10..19).each { |r| src[r] = B::SRC_ZEROS }
    (30..31).each { |r| src[r] = B::SRC_ZEROS }
    res = Pointer(Int32).malloc(2)
    B.next_run(src, B::SRC_ZEROS, 0, res).should be_true
    {res[0], res[1]}.should eq({10, 19})
    B.next_run(src, B::SRC_ZEROS, 20, res).should be_true
    {res[0], res[1]}.should eq({30, 31})
    B.next_run(src, B::SRC_ZEROS, 32, res).should be_false
    src[671] = B::SRC_CMDS
    B.next_run(src, B::SRC_CMDS, 0, res).should be_true
    {res[0], res[1]}.should eq({671, 671})
  end
end

describe "SkBand command bytes" do
  it "builds DUW for full-width rows" do
    b = bytes(6)
    B.duw_bytes(0, 671, b)
    list(b, 6).should eq [0x00, 0x3B, 0x00, 0x00, 0x9F, 0x02] # = OTP / PDi full DUW
    B.duw_bytes(300, 339, b)
    list(b, 6).should eq [0x00, 0x3B, 0x2C, 0x01, 0x53, 0x01]
  end

  it "builds RAM_RW like window mode 8" do
    b = bytes(3)
    B.ramrw_bytes(0, 0x10_u8, b)
    list(b, 3).should eq [0x00, 0x00, 0x10] # = OTP 00 00 10
    B.ramrw_bytes(300, 0x10_u8, b)
    list(b, 3).should eq [0x00, 0x2C, 0x11]
  end

  it "builds DRFW in 4-row units, full panel = 0..0xA9" do
    B.reset
    b = bytes(4)
    B.drfw_bytes(1, 0, 671, b)
    list(b, 4).should eq [0x00, 0x3B, 0x00, 0xA9]
    B.drfw_bytes(1, 100, 139, b)
    list(b, 4).should eq [0x00, 0x3B, 25, 34]
    B.drfw_bytes(2, 100, 139, b)
    list(b, 4).should eq [0x00, 0x3B, 25, 34] # shared window
    B.drfw_bytes(1, 400, 671, b)
    list(b, 4).should eq [0x00, 0x3B, 100, 0xA9]
  end

  it "applies offsets, units and per-CoG modes" do
    B.reset
    b = bytes(4)
    B.set(B::P_D0, -2)
    B.set(B::P_D1, 2)
    B.drfw_bytes(1, 100, 139, b)
    list(b, 4).should eq [0x00, 0x3B, 23, 36]
    B.set(B::P_WIN, B::W_PERCOG)
    B.set(B::P_SD0, -84)
    B.set(B::P_SD1, -84)
    B.drfw_bytes(2, 400, 439, b)
    list(b, 4).should eq [0x00, 0x3B, 16, 25]
    B.drfw_bytes(2, 100, 139, b) # clipped at 0
    list(b, 4).should eq [0x00, 0x3B, 0, 0]
    B.set(B::P_WIN, B::W_MASTER)
    B.drfw_bytes(2, 100, 139, b)
    list(b, 4).should eq [0x00, 0x3B, 0, 0xA9]
    B.set(B::P_WIN, B::W_SLAVEIDLE)
    B.drfw_bytes(2, 100, 139, b)
    list(b, 4).should eq [0x00, 0x3B, 84, 84]
    B.reset
    B.set(B::P_UNIT, 2)
    B.drfw_bytes(1, 100, 139, b)
    list(b, 4).should eq [0x00, 0x3B, 50, 69]
    B.set(B::P_X0, 10)
    B.set(B::P_X1, 300)
    B.drfw_bytes(1, 100, 139, b)
    list(b, 4).should eq [10, 255, 50, 69]
  end
end

describe "SkBand ink table" do
  it "matches EPD.build_ink for the 20-frame form" do
    lut = bytes(B::LUT_BYTES)
    B.build_table(lut, 2, 2, 2, false)
    50.times do |k|
      q = lut + k * 8
      list(q + 1, 7).should eq [1, 1, 0, 1, 1, 1, 1]
    end
    lut[0].should eq 0           # table 0: GND
    lut[10 * 8].should eq 0b0101 # table 1, group 0: VDH in phases c and d
    lut[11 * 8].should eq 0
    lut[20 * 8].should eq 0b1010 # table 2: VDL
    lut[30 * 8].should eq 0b0101 # table 3: VDH
    lut[40 * 8].should eq 0      # VCOM
  end

  it "never builds a table that hangs the CoG" do
    lut = bytes(B::LUT_BYTES)
    [false, true].each do |f40|
      [1, 2, 5, 19, 40].each do |f|
        B.build_table(lut, f, f, f, f40)
        50.times do |k|
          q = lut + k * 8
          [q[1], q[2], q[4], q[5], q[7]].each { |v| v.should_not eq 0 } # TP and RP
          (q[3] | q[6]).should_not eq 0                                  # SRab / SRcd
        end
      end
    end
  end

  it "keeps the last frame of the 20-frame form at GND" do
    lut = bytes(B::LUT_BYTES)
    B.build_table(lut, 19, 19, 19, false)
    (lut[19 * 8] & 3).should eq 0 # table 1 group 9 phase d
    (lut[19 * 8] & 12).should eq 4
  end

  it "builds the 40-frame form like EPD.build_ink40" do
    lut = bytes(B::LUT_BYTES)
    B.build_table(lut, 3, 1, 5, true)
    lut[10 * 8 + 3].should eq 1      # SRab on
    lut[10 * 8].should eq 0b01010100 # VDH a b c
    lut[30 * 8].should eq 0b01000000 # VDH a
    lut[20 * 8].should eq 0b10101010 # VDL a b c d
    lut[21 * 8].should eq 0b10000000 # frame 5 = group 1 phase a
  end
end

describe "SkBand planes" do
  it "packs one CoG's half of the rows" do
    pl = bytes(B::PLANE)
    pl[300 * 120 + 0] = 0xAA_u8
    pl[300 * 120 + 59] = 0x55_u8
    pl[300 * 120 + 60] = 0x11_u8
    pl[301 * 120 + 119] = 0x22_u8
    d = bytes(120)
    B.pack_rows(d, pl, 0, 300, 2)
    d[0].should eq 0xAA
    d[59].should eq 0x55
    d[60].should eq 0
    B.pack_rows(d, pl, 1, 300, 2)
    d[0].should eq 0x11
    d[119].should eq 0x22
    B.pack_rows(d, Pointer(UInt8).null, 0, 300, 2)
    (0...120).all? { |i| d[i] == 0 }.should be_true
  end

  it "reads and writes commands" do
    cn, co = planes
    B.put_cmd(cn, co, 13, 7, 3)
    B.cmd_at(cn, co, 13, 7).should eq 3
    B.put_cmd(cn, co, 13, 7, 2)
    B.cmd_at(cn, co, 13, 7).should eq 2
    B.put_cmd(cn, co, 13, 7, 1)
    B.cmd_at(cn, co, 13, 7).should eq 1
    B.cmd_at(cn, co, 12, 7).should eq 0
    B.row_any(cn, co, 7).should be_true
    B.row_any(cn, co, 8).should be_false
  end
end

private def ghost_kit
  cn, co = planes
  {cn, co, bytes(B::PLANE * 8), bytes(B::PLANE), Pointer(Int32).malloc(B::H), Pointer(Int32).malloc(1), bytes(B::H)}
end

describe "SkBand ghosts" do
  it "records a ghost 336 rows below each new ink pixel" do
    B.reset
    cn, co, ghost, driven, rowg, lt, src = ghost_kit
    B.mark_writes(B::S_PLAIN, 100, 103, Pointer(UInt8).null, src)
    B.put_cmd(cn, co, 200, 101, 1)
    B.put_cmd(cn, co, 201, 101, 3)
    B.record(cn, co, src, 100, 103, true, ghost, driven, rowg, lt).should eq 2
    B.driven?(driven, 200, 101).should be_true
    ghost[437 * 960 + 200].should eq 1
    rowg[437].should eq 2
    # the same again: two levels, still two pixels in the row
    B.record(cn, co, src, 100, 103, true, ghost, driven, rowg, lt).should eq 2
    ghost[437 * 960 + 200].should eq 2
    rowg[437].should eq 2
  end

  it "does not count a ghost on ink, nor a twin inside the scan" do
    B.reset
    cn, co, ghost, driven, rowg, lt, src = ghost_kit
    B.set_driven(driven, 200, 437, true)
    B.mark_writes(B::S_PLAIN, 100, 103, Pointer(UInt8).null, src)
    B.put_cmd(cn, co, 200, 101, 1)
    B.record(cn, co, src, 100, 103, true, ghost, driven, rowg, lt).should eq 0
    B.put_cmd(cn, co, 300, 101, 1)
    B.record(cn, co, src, 0, 671, true, ghost, driven, rowg, lt).should eq 0  # full scan
    B.record(cn, co, src, 100, 103, false, ghost, driven, rowg, lt).should eq 0 # not recording
  end

  it "erases ghosts with command 2 and plans the erase bands" do
    B.reset
    cn, co, ghost, driven, rowg, lt, src = ghost_kit
    B.mark_writes(B::S_PLAIN, 100, 103, Pointer(UInt8).null, src)
    B.put_cmd(cn, co, 200, 101, 1)
    B.put_cmd(cn, co, 300, 102, 1)
    B.record(cn, co, src, 100, 103, true, ghost, driven, rowg, lt)
    res = Pointer(Int32).malloc(2)
    B.ghost_band(rowg, 0, res).should be_true
    {res[0], res[1]}.should eq({436, 439})
    ecn, eco = planes
    B.erase_cmds(ghost, driven, res[0], res[1], ecn, eco).should eq 2
    B.cmd_at(ecn, eco, 200, 437).should eq 2
    B.cmd_at(ecn, eco, 300, 438).should eq 2
    B.cmd_at(ecn, eco, 201, 437).should eq 0
    # the erase pull of 436..439: its twin (772..) is off the panel
    B.mark_writes(B::S_PLAIN, 436, 439, Pointer(UInt8).null, src)
    B.record(ecn, eco, src, 436, 439, true, ghost, driven, rowg, lt).should eq 0
    rowg[437].should eq 0
    rowg[438].should eq 0
    B.ghost_band(rowg, 0, res).should be_false
    B.driven?(driven, 200, 101).should be_true # the stroke is untouched
  end

  it "counts ink lightened by a wrapped twin of an erase" do
    B.reset
    B.set(B::P_WRAP, 1)
    cn, co, ghost, driven, rowg, lt, src = ghost_kit
    B.set_driven(driven, 50, 10, true)
    B.mark_writes(B::S_PLAIN, 344, 347, Pointer(UInt8).null, src)
    B.put_cmd(cn, co, 50, 346, 2)
    B.record(cn, co, src, 344, 347, true, ghost, driven, rowg, lt)
    lt[0].should eq 1
  end

  it "reinforces inked pixels with command 3" do
    driven = bytes(B::PLANE)
    B.set_driven(driven, 8, 5, true)
    B.set_driven(driven, 9, 5, true)
    cn, co = planes
    B.reinforce_cmds(driven, 4, 7, cn, co).should eq 2
    B.cmd_at(cn, co, 8, 5).should eq 3
    B.cmd_at(cn, co, 10, 5).should eq 0
  end
end
