# Host specs for the Sketch band driver (src/sketch_epd.cr) against a model
# of the two CoGs (test/sketch_fake_epd.cr): register sequence, RAM
# contents between pulls, what each pull drives, band splitting, the twin
# strategies, cleanup, session handling and the bars test.
#   crystal spec test/sketch_drv_spec.cr
require "spec"
require "./sketch_fake_epd"
require "../src/sketch_epd"

private alias B = SkBand

private def fresh
  SkEPD.close
  FakePanel.reset
  EPD.fake_init
  B.reset
  SkEPD.ready?.should be_true
  SkEPD.reg_clear
  SkEPD.sync_shown(Pointer(UInt8).null, Pointer(UInt8).null)
  SkEPD.stats_reset
  SkEPD.qd = false
  FakeLog.clear
end

private def planes
  {Pointer(UInt8).malloc(B::PLANE), Pointer(UInt8).malloc(B::PLANE)}
end

# Command c on the box x0..x1 x y0..y1; returns the pixels.
private def box(cn, co, x0, x1, y0, y1, c = 1)
  px = [] of {Int32, Int32}
  (y0..y1).each { |y| (x0..x1).each { |x| B.put_cmd(cn, co, x, y, c); px << {x, y} } }
  px
end

private def pull_logs
  FakeLog.lines.select(&.starts_with?("drv2: pull y0"))
end

private def pull_ms
  pull_logs.map { |l| l.split(' ').last.to_i }
end

describe "SkEPD session" do
  it "opens with the ink session registers from the parameters" do
    fresh
    SkEPD.open.should be_true
    SkEPD.open?.should be_true
    m, s = FakePanel.cogs
    m.last(0x61).should eq [1] # STV_DIR to the master only
    s.last(0x61).should be_nil
    m.last(0x60).should eq [0x25]
    s.last(0x60).should eq [0x25]
    m.last(0x01).should eq [0x0C] # DCTL = OTP byte 0x10
    s.last(0x01).should eq [0x0C]
    m.last(0x03).should eq [0x00, 0x11]
    m.last(0x13).should eq [0x00, 0x3B, 0x00, 0x00, 0x9F, 0x02]
    m.last(0x90).should eq [0x00, 0x3B, 0x00, 0xA9]
    m.last(0xB0).not_nil!.size.should eq 400
    FakePanel.ram_zero_except?([] of Int32).should be_true
  end

  it "sends STV_DIR, TCON and DCTL as set (or not at all)" do
    fresh
    B.set(B::P_STVM, -1)
    B.set(B::P_STVS, 3)
    B.set(B::P_TCON, -1)
    B.set(B::P_DCTL, 0x22)
    B.set(B::P_DCTLT, 2)
    SkEPD.open
    m, s = FakePanel.cogs
    m.last(0x61).should be_nil
    s.last(0x61).should eq [3]
    m.last(0x60).should be_nil
    m.last(0x01).should be_nil
    s.last(0x01).should eq [0x22]
  end

  it "applies extra registers at open and before every pull" do
    fresh
    d = Pointer(Int32).malloc(6)
    d[0] = 0x07
    SkEPD.reg_set(-1, 1, 0, 0xC2, 1, d).should eq 0
    d[0] = 0x00
    SkEPD.reg_set(-1, 2, 1, 0x61, 1, d).should eq 1
    cn, co = planes
    box(cn, co, 10, 20, 200, 201)
    SkEPD.pull_cmds(cn, co, 0, 671)
    m, s = FakePanel.cogs
    m.last(0xC2).should eq [0x07]
    s.last(0xC2).should be_nil
    s.last(0x61).should eq [0x00]
    # the pull register comes after the DRFW
    ks = s.regs.map(&.[0])
    ks.rindex(0x61).not_nil!.should be > ks.rindex(0x90).not_nil!
  end

  it "notices EPD taking the panel back and reopens" do
    fresh
    cn, co = planes
    box(cn, co, 10, 20, 200, 201)
    SkEPD.pull_cmds(cn, co, 0, 671)
    r = FakePanel.resets
    EPD.refresh(true, EPD::LUT_BASE) # e.g. Sketch's full frame
    SkEPD.open?.should be_false
    box(cn, co, 10, 20, 300, 301)
    SkEPD.pull_cmds(cn, co, 300, 301)
    FakePanel.resets.should eq r + 2 # EPD's reset, then ours
    SkEPD.open?.should be_true
  end

  it "reopens after `session` pulls and after a parameter change" do
    fresh
    B.set(B::P_SESSION, 2)
    cn, co = planes
    r = FakePanel.resets
    3.times do |i|
      box(cn, co, 10, 20, 200 + i * 40, 201 + i * 40)
      SkEPD.pull_cmds(cn, co, 200 + i * 40, 201 + i * 40)
      cn.clear(B::PLANE)
      co.clear(B::PLANE)
    end
    FakePanel.resets.should eq r + 2
    SkEPD.stale!
    box(cn, co, 10, 20, 400, 401)
    SkEPD.pull_cmds(cn, co, 400, 401)
    FakePanel.resets.should eq r + 3
  end
end

describe "SkEPD pulls" do
  it "drives exactly the stroke's pixels with one band pull" do
    fresh
    cn, co = planes
    px = box(cn, co, 100, 140, 200, 202) + box(cn, co, 470, 500, 201, 201, 3)
    SkEPD.pull_cmds(cn, co, 0, 671).should be > 0
    FakePanel.pulls.size.should eq 1
    FakePanel.pulls[0].should eq({200..203, 200..203})
    got = FakePanel.driven_pixels(1) + FakePanel.driven_pixels(3)
    got.sort.should eq px.sort
    FakePanel.driven_pixels(2).should be_empty
    FakePanel.drives(3, 480, 201).should eq 1 # slave half, x 480
    pull_logs.should eq ["drv2: pull y0 / rows / panel ms: 200 4 23"]
  end

  it "zeroes the last band's rows, so a later scan never drives them again" do
    fresh
    cn, co = planes
    box(cn, co, 100, 140, 200, 202)
    SkEPD.pull_cmds(cn, co, 0, 671)
    FakePanel.ram_zero_except?((200..203).to_a).should be_true
    cn.clear(B::PLANE)
    co.clear(B::PLANE)
    B.set(B::P_STRAT, B::S_FULL) # scans every row
    box(cn, co, 300, 310, 400, 400)
    SkEPD.pull_cmds(cn, co, 0, 671)
    FakePanel.pulls.last.should eq({0..671, 0..671})
    FakePanel.drives(1, 100, 200).should eq 1
    FakePanel.drives(1, 300, 400).should eq 1
    FakePanel.ram_zero_except?((400..403).to_a).should be_true
    pull_logs.last.should contain "(OVER 250)"
  end

  it "splits a tall drawing into bands that each stay under 250 ms" do
    fresh
    cn, co = planes
    px = box(cn, co, 134, 824, 123, 123) + box(cn, co, 400, 402, 124, 522) + box(cn, co, 134, 824, 522, 522)
    SkEPD.pull_cmds(cn, co, 123, 522)
    FakePanel.pulls.size.should be > 1
    pull_ms.each { |ms| ms.should be <= 250 }
    pull_logs.none?(&.includes?("OVER")).should be_true
    px.each { |(x, y)| FakePanel.drives(1, x, y).should eq 1 }
    FakePanel.driven_pixels(1).size.should eq px.uniq.size
  end

  it "logs quick draw pulls in the format morning_checks parses" do
    fresh
    SkEPD.qd = true
    cn, co = planes
    box(cn, co, 100, 140, 200, 202)
    SkEPD.pull_cmds(cn, co, 0, 671)
    FakeLog.lines.any?(&.=~(/^sketch: qd pull panel \/ upload ms: \d+ \d+$/)).should be_true
  end

  it "uses per-CoG windows when asked" do
    fresh
    B.set(B::P_WIN, B::W_PERCOG)
    B.set(B::P_SD0, 2)
    B.set(B::P_SD1, 2)
    cn, co = planes
    box(cn, co, 100, 140, 200, 202)
    SkEPD.pull_cmds(cn, co, 0, 671)
    m, s = FakePanel.cogs
    m.last(0x90).should eq [0, 0x3B, 50, 50]
    s.last(0x90).should eq [0, 0x3B, 52, 52]
  end

  it "narrows DUW to the scan rows before the pull with duw 2" do
    fresh
    B.set(B::P_DUW, 2)
    cn, co = planes
    box(cn, co, 100, 140, 200, 202)
    SkEPD.pull_cmds(cn, co, 0, 671)
    m, _ = FakePanel.cogs
    m.last(0x13).should eq [0, 0x3B, 200, 0, 203, 0]
  end
end

describe "SkEPD twin strategies (model with twin = 336)" do
  it "plain: the model shows the copy 336 rows lower" do
    fresh
    FakePanel.twin = 336
    cn, co = planes
    box(cn, co, 300, 340, 150, 152)
    SkEPD.pull_cmds(cn, co, 0, 671)
    FakePanel.drives(1, 300, 486).should eq 1
    SkEPD.cleanup_pending?.should be_false # nothing booked under plain
  end

  it "twinram: writes zeros into the twin rows" do
    fresh
    B.set(B::P_STRAT, B::S_TWINRAM)
    FakePanel.cogs.each { |cg| cg.banks[0][486 * 60 + 5] = 0xFF_u8 } # stale data there
    cn, co = planes
    box(cn, co, 300, 340, 150, 152)
    SkEPD.pull_cmds(cn, co, 0, 671)
    FakePanel.pulls.last.should eq({148..155, 148..155})
    FakePanel.ram_zero_except?((148..155).to_a).should be_true
    FakePanel.cogs[0].banks.all? { |bk| bk[486 * 60 + 5] == 0 }.should be_true
  end

  it "twinspan: one scan over band and twin, flagged over 250 ms" do
    fresh
    B.set(B::P_STRAT, B::S_TWINSPAN)
    cn, co = planes
    box(cn, co, 300, 340, 150, 152)
    SkEPD.pull_cmds(cn, co, 0, 671)
    FakePanel.pulls.last.should eq({148..491, 148..491})
    pull_logs.last.should contain "(OVER 250)"
    FakePanel.driven_pixels(1).size.should eq 41 * 3
  end

  it "ghost: books the copy and erases it in idle cleanup, strokes untouched" do
    fresh
    FakePanel.twin = 336
    B.set(B::P_STRAT, B::S_GHOST)
    cn, co = planes
    px = box(cn, co, 300, 340, 150, 152)
    SkEPD.pull_cmds(cn, co, 0, 671)
    SkEPD.cleanup_pending?.should be_true
    n = 0
    while SkEPD.cleanup_pending? && n < 10
      SkEPD.cleanup_step
      n += 1
    end
    SkEPD.cleanup_pending?.should be_false
    px.each do |(x, y)|
      FakePanel.drives(1, x, y).should eq 1
      FakePanel.drives(2, x, y).should eq 0
      FakePanel.drives(1, x, y + 336).should eq 1 # the copy...
      FakePanel.drives(2, x, y + 336).should eq 1 # ...erased once
    end
    FakePanel.driven_pixels(2).size.should eq px.size
    pull_ms.each { |ms| ms.should be <= 250 }
  end

  it "ghost: never erases on shown ink (frame art, old strokes)" do
    fresh
    FakePanel.twin = 336
    B.set(B::P_STRAT, B::S_GHOST)
    bk = Pointer(UInt8).malloc(B::PLANE)
    bk[487 * 120 + 300 // 8] = 0xFF_u8 # pixels 296..303 of row 487 are black
    SkEPD.sync_shown(bk, Pointer(UInt8).null)
    cn, co = planes
    box(cn, co, 300, 300, 150, 152)
    SkEPD.pull_cmds(cn, co, 0, 671)
    while SkEPD.cleanup_pending?
      SkEPD.cleanup_step
    end
    FakePanel.drives(2, 300, 486).should eq 1
    FakePanel.drives(2, 300, 487).should eq 0
    FakePanel.drives(2, 300, 488).should eq 1
  end
end

describe "SkEPD cleanup reinforce" do
  it "runs command 3 over the last stroke bands, one band per step" do
    fresh
    B.set(B::P_CLEAN, 2)
    cn, co = planes
    box(cn, co, 100, 110, 200, 200)
    SkEPD.pull_cmds(cn, co, 0, 671)
    cn.clear(B::PLANE)
    co.clear(B::PLANE)
    box(cn, co, 100, 110, 400, 400)
    SkEPD.pull_cmds(cn, co, 0, 671)
    SkEPD.cleanup_pending?.should be_true
    SkEPD.cleanup_step
    FakePanel.drives(3, 100, 400).should eq 1
    FakePanel.drives(3, 100, 200).should eq 0
    SkEPD.cleanup_step
    FakePanel.drives(3, 100, 200).should eq 1
    SkEPD.cleanup_pending?.should be_false
  end
end

describe "SkEPD bars" do
  it "draws one bar per window at the given rows" do
    fresh
    SkEPD.set_bars(Pointer(Int32).null, 0)
    SkEPD.bars_run
    FakePanel.pulls.size.should eq 4 * B.get(B::P_BARPULLS)
    [100, 300, 400, 560].each_with_index do |y, i|
      x = 60 + 150 * i
      FakePanel.drives(3, x, y).should eq B.get(B::P_BARPULLS)
      FakePanel.drives(3, x + 119, y + 15).should eq B.get(B::P_BARPULLS)
      FakePanel.any_drive?(x - 1, y).should be_false
      FakePanel.any_drive?(x, y + 16).should be_false
    end
    B.get(B::P_F3).should eq 2 # restored after the bars
  end

  it "builds the bars session with barf frames for command 3" do
    fresh
    SkEPD.set_bars(Pointer(Int32).null, 0)
    SkEPD.bars_run
    t = FakePanel.cogs[0].last(0xB0).not_nil!
    t[30 * 8].should eq 0b0101 # table 3 group 0: VDH (12 frames reach group 5)
    t[35 * 8].should eq 0b0101
    t[36 * 8].should eq 0
  end
end
