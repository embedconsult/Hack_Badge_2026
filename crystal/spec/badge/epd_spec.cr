require "../spec_helper"

# One decoded CoG transfer: which CoG(s) were selected, the index byte (sent
# with DC low) and the data bytes (sent with DC high).
private record Cmd, target : Char, index : UInt8, data : Array(UInt8) do
  def to_s(io)
    io << target << ' ' << index.to_s(16, upcase: true).rjust(2, '0')
    data.each { |b| io << ' ' << b.to_s(16, upcase: true).rjust(2, '0') }
  end
end

private def decode(mock : Badge::HAL::Mock) : Array(Cmd)
  cmds = [] of Cmd
  mock.spi_writes.each do |w|
    cs1 = !w.level(Badge::Pins::EPD_CS1)
    cs2 = !w.level(Badge::Pins::EPD_CS2)
    target = cs1 && cs2 ? 'B' : cs1 ? 'L' : cs2 ? 'R' : '?'
    if !w.level(Badge::Pins::EPD_DC)
      w.data.size.should eq 1
      cmds << Cmd.new(target, w.data[0], [] of UInt8)
    else
      cmds.last.target.should eq target
      cmds.last.data.concat(w.data)
    end
  end
  cmds
end

# Short form for commands with small payloads: only first `max` data bytes.
private def lines(cmds : Array(Cmd), max = 8) : Array(String)
  cmds.map do |c|
    c.data.size > max ? "#{c.target} #{c.index.to_s(16, upcase: true).rjust(2, '0')} <#{c.data.size}>" : c.to_s
  end
end

private def parse(text : String) : Array(String)
  text.lines.map(&.strip).reject(&.empty?)
end

# lib/epd.py cog_initial(), written out by hand.
COG_INITIAL = parse(<<-TXT)
  B 05 7D
  B 05 00
  B D8 80
  B D6 00
  B A7 10
  B A7 00
  B 03 00 11
  L 44 00
  L 45 80
  L A7 10
  L A7 00
  L 44 06
  L 45 82
  L A7 10
  L A7 00
  R 44 00
  R 45 80
  R A7 10
  R A7 00
  R 44 06
  R 45 82
  R A7 10
  R A7 00
  B 60 25
  L 61 01
  B 02 00
  TXT

# lib/epd.py _dcdc_soft_start(), loops unrolled by hand.
SOFT_START = parse(<<-TXT)
  B 51 50 01
  B 09 1F
  B 51 50 01
  B 09 9F
  B 09 1F
  B 51 50 02
  B 09 9F
  B 09 1F
  B 51 50 03
  B 09 9F
  B 09 1F
  B 51 50 04
  B 09 9F
  B 09 1F
  B 51 0A 01
  B 09 9F
  B 09 1F
  B 51 0A 02
  B 09 9F
  B 09 1F
  B 51 0A 03
  B 09 9F
  B 09 1F
  B 51 0A 04
  B 09 9F
  B 09 1F
  B 51 0A 05
  B 09 9F
  B 09 1F
  B 51 0A 06
  B 09 9F
  B 09 1F
  B 51 0A 07
  B 09 9F
  B 09 1F
  B 51 0A 08
  B 09 9F
  B 09 1F
  B 51 0A 09
  B 09 9F
  B 09 1F
  B 51 0A 0A
  B 09 9F
  B 09 7F
  B 51 0A 03
  B 09 FF
  B 09 7F
  B 51 0A 04
  B 09 FF
  B 09 7F
  B 51 0A 05
  B 09 FF
  B 09 7F
  B 51 0A 06
  B 09 FF
  B 09 7F
  B 51 0A 07
  B 09 FF
  B 09 7F
  B 51 0A 08
  B 09 FF
  B 09 7F
  B 51 0A 09
  B 09 FF
  B 09 7F
  B 51 0A 0A
  B 09 FF
  B 09 7F
  B 51 09 0A
  B 09 FF
  B 09 7F
  B 51 08 0A
  B 09 FF
  B 09 7F
  B 51 07 0A
  B 09 FF
  B 09 7F
  B 51 06 0A
  B 09 FF
  B 09 7F
  B 51 05 0A
  B 09 FF
  B 09 7F
  B 51 04 0A
  B 09 FF
  B 09 7F
  B 51 03 0A
  B 09 FF
  B 09 7F
  B 51 02 0A
  B 09 FF
  B 09 FF
  TXT

# _send_images(): DUW, DRFW, then RAM_RW + plane per half.
SEND_IMAGES = parse(<<-TXT)
  B 13 00 3B 00 00 9F 02
  B 90 00 3B 00 A9
  L 12 3B 00 14
  L 10 <40320>
  L 12 3B 00 14
  L 11 <40320>
  R 12 3B 00 14
  R 10 <40320>
  R 12 3B 00 14
  R 11 <40320>
  TXT

REFRESH       = ["B 15 3C"]
SOFT_SHUTDOWN = parse(<<-TXT)
  B 09 7F
  B 05 7D
  B 09 00
  TXT

# Full (OTP waveform) update = original lib/epd.py global_update().
FULL_UPDATE = SEND_IMAGES + COG_INITIAL + SOFT_START + REFRESH + SOFT_SHUTDOWN

private def new_epd(panel = Badge::EPD::Panel::B1)
  mock = Badge::HAL::Mock.new
  epd = Badge::EPD.new(mock, panel)
  mock.clear_log
  {mock, epd}
end

# Make BUSY go low (busy) for `ms` after every 0x15 refresh command.
private def busy_after_refresh(mock, ms)
  mock.on_spi = ->(w : Badge::HAL::Mock::SpiWrite) do
    if !w.level(Badge::Pins::EPD_DC) && w.data[0] == 0x15
      mock.script_input(Badge::Pins::EPD_BUSY1, Array.new(ms // 10, false) + [true])
    end
    nil
  end
end

describe Badge::EPD do
  it "configures pins and SPI like lib/epd.py" do
    mock = Badge::HAL::Mock.new
    Badge::EPD.new(mock)
    {10, 11, 13, 3}.each { |p| mock.levels[p].should be_true }
    mock.spi_config.should eq({21, 47, 45, 8_000_000})
    mock.pulls[12].should eq Badge::HAL::Pull::None
    mock.pulls[8].should eq Badge::HAL::Pull::None
  end

  it "frames a both-CoG command exactly like _send_index_data" do
    mock, epd = new_epd
    epd.send(Badge::EPD::Target::Both, 0x05_u8, Bytes[0x7D])
    mock.pin_writes.map { |w| {w.pin, w.level} }.should eq [
      {10, false}, {13, false}, {3, false}, # DC low, CS1+CS2 low
      {13, true}, {3, true}, {10, true},    # after index
      {13, false}, {3, false},              # data
      {13, true}, {3, true},
    ]
    mock.spi_bytes.should eq [0x05_u8, 0x7D_u8]
  end

  it "frames left/right commands like upstream _send_one" do
    mock, epd = new_epd
    epd.send(Badge::EPD::Target::Left, 0x44_u8, Bytes[0x06])
    epd.send(Badge::EPD::Target::Right, 0x45_u8, Bytes[0x82])
    mock.pin_writes.map { |w| {w.pin, w.level} }.should eq [
      {10, false}, {13, false}, {3, true}, {13, true}, {10, true}, {13, false}, {13, true},
      {10, false}, {3, false}, {13, true}, {3, true}, {10, true}, {3, false}, {3, true},
    ]
    lines(decode(mock)).should eq ["L 44 06", "R 45 82"]
  end

  it "sends the COG init sequence and sleeps like cog_initial" do
    mock, epd = new_epd
    epd.cog_initial
    lines(decode(mock)).should eq COG_INITIAL
    mock.sleeps.should eq [200, 10, 100, 100] + [100] * 8
  end

  it "sends the DC/DC soft start sequence" do
    mock, epd = new_epd
    epd.dcdc_soft_start
    lines(decode(mock)).should eq SOFT_START
    mock.sleeps.should eq [2] * 30 + [10]
  end

  it "resets with the PDi timing" do
    mock, epd = new_epd
    epd.reset
    mock.sleeps.should eq [200, 20, 200, 200, 5]
    mock.pin_writes.map { |w| {w.pin, w.level} }.should eq [{11, true}, {11, false}, {11, true}, {13, true}, {3, true}]
  end

  it "powers off the CoG" do
    mock, epd = new_epd
    epd.cog_poweroff
    lines(decode(mock)).should eq ["B 09 7F 7D 00"]
    mock.pin_writes.last(3).map { |w| {w.pin, w.level} }.should eq [{10, false}, {13, false}, {11, false}]
  end

  describe "framebuffer" do
    it "packs MONO_HLSB pixels and splits into 60-byte halves" do
      _mock, epd = new_epd(Badge::EPD::Panel::P84)
      epd.set_pixel(0, 0, Badge::EPD::Ink::Black)
      epd.set_pixel(479, 0, Badge::EPD::Ink::Black) # last pixel of the left half
      epd.set_pixel(480, 1, Badge::EPD::Ink::Black) # first pixel of the right half
      epd.set_pixel(959, 671, Badge::EPD::Ink::Red)
      epd.black[0].should eq 0x80
      epd.black[59].should eq 0x01
      epd.black[120 + 60].should eq 0x80

      bl, rl, br, rr = epd.halves
      Badge::EPD.split_halves(epd.black, bl, br, false)
      Badge::EPD.split_halves(epd.red, rl, rr, false)
      bl[0].should eq 0x80
      bl[59].should eq 0x01
      br[60].should eq 0x80 # row 1, byte 0 of the right half
      rr[671 * 60 + 59].should eq 0x01
      bl.count(&.!=(0)).should eq 2
      br.count(&.!=(0)).should eq 1
    end

    it "bit-reverses for B1 panels" do
      src = Bytes.new(Badge::EPD::PLANE_SIZE)
      src[0] = 0x80; src[60] = 0x03
      l = Bytes.new(Badge::EPD::HALF_PLANE_SIZE)
      r = Bytes.new(Badge::EPD::HALF_PLANE_SIZE)
      Badge::EPD.split_halves(src, l, r, true)
      l[0].should eq 0x01
      r[0].should eq 0xC0
    end

    it "reverses bytes" do
      Badge::EPD.reverse_byte(0x01_u8).should eq 0x80
      Badge::EPD.reverse_byte(0xA0_u8).should eq 0x05
      256.times { |i| Badge::EPD.reverse_byte(Badge::EPD.reverse_byte(i.to_u8)).should eq i }
    end

    it "red and black are exclusive per pixel" do
      _mock, epd = new_epd
      epd.set_pixel(5, 5, Badge::EPD::Ink::Black)
      epd.set_pixel(5, 5, Badge::EPD::Ink::Red)
      epd.pixel(5, 5).should eq Badge::EPD::Ink::Red
      epd.set_pixel(5, 5, Badge::EPD::Ink::White)
      epd.pixel(5, 5).should eq Badge::EPD::Ink::White
    end

    it "converts RGB565 like the LVGL flush" do
      _mock, epd = new_epd
      # red F800, black 0000, white FFFF, green 07E0 -> white
      src = Bytes[0x00, 0xF8, 0x00, 0x00, 0xFF, 0xFF, 0xE0, 0x07]
      epd.blit_rgb565(src, 8, 4, 1, 10, 3)
      epd.pixel(10, 3).should eq Badge::EPD::Ink::Red
      epd.pixel(11, 3).should eq Badge::EPD::Ink::Black
      epd.pixel(12, 3).should eq Badge::EPD::Ink::White
      epd.pixel(13, 3).should eq Badge::EPD::Ink::White
    end
  end

  describe "LUTs" do
    it "carries the tables from data/rendered_luts.py" do
      {Badge::LUTs::LUT8_NORED_NOCLEAR, Badge::LUTs::LUT8_NORED_CLEAR,
       Badge::LUTs::LUT8_RED_NOCLEAR, Badge::LUTs::LUT8_RED_CLEAR}.each(&.size.should eq 180)
      Badge::LUTs::LUTB_BASE.size.should eq 400
      Badge::LUTs::LUT8_NORED_NOCLEAR[0, 8].should eq Bytes[0x66, 0x33, 0x33, 0x02, 0x88, 0x31, 0x31, 0x09]
      Badge::LUTs::LUTB_BASE.sum(0).should eq 6063
      Badge::LUTs::LUT8_RED_CLEAR.sum(0).should eq 11987
    end

    it "derives the driver-B black/white table by idling red groups 5..9" do
      _mock, epd = new_epd
      bw = epd.bw_lut_b
      base = Badge::LUTs::LUTB_BASE
      400.times do |i|
        if 200 <= i < 240
          bw[i].should eq(i % 8 == 0 ? 0 : 1)
        else
          bw[i].should eq base[i]
        end
      end
    end

    it "picks tables by CoG driver and red content" do
      _m, b1 = new_epd(Badge::EPD::Panel::B1)
      b1.fast_lut(true).should eq Badge::LUTs::LUTB_BASE
      b1.fast_lut(false).should eq b1.bw_lut_b
      b1.bw_fast_lut = false
      b1.fast_lut(false).should eq Badge::LUTs::LUTB_BASE
      _m, p84 = new_epd(Badge::EPD::Panel::P84)
      p84.fast_lut(true).should eq Badge::LUTs::LUT8_RED_CLEAR
      p84.fast_lut(false).should eq Badge::LUTs::LUT8_NORED_CLEAR
    end
  end

  describe "updates" do
    it "a full update sends the original global_update sequence" do
      mock, epd = new_epd(Badge::EPD::Panel::P84)
      epd.set_pixel(0, 0, Badge::EPD::Ink::Black)
      epd.set_pixel(959, 0, Badge::EPD::Ink::Red)
      epd.update(fast: false)
      epd.done_updating?.should be_false
      epd.service.should be_true
      epd.done_updating?.should be_true
      cmds = decode(mock)
      lines(cmds).should eq FULL_UPDATE
      cmds[3].data[0].should eq 0x80  # black left, P84 = not reversed
      cmds[9].data[59].should eq 0x01 # red right
      cmds[5].data.all?(&.==(0)).should be_true
      epd.service.should be_false # nothing pending
    end

    it "a fast update flashes black then white, loads the LUT and runs 3 passes" do
      mock, epd = new_epd(Badge::EPD::Panel::B1)
      busy_after_refresh(mock, 3000)
      epd.update
      epd.service
      l = lines(decode(mock))
      prep = SEND_IMAGES + COG_INITIAL + ["B B0 <400>"] + SOFT_START
      flash = prep + REFRESH + SOFT_SHUTDOWN
      l.should eq flash + flash + prep + REFRESH * 3 + SOFT_SHUTDOWN
      cmds = decode(mock)
      # flash black: black planes all 0xFF, red all 0x00; then white: all 0x00
      cmds[3].data.all?(&.==(0xFF)).should be_true
      cmds[5].data.all?(&.==(0x00)).should be_true
      lut_cmds = cmds.select(&.index.==(0xB0))
      lut_cmds.size.should eq 3
      lut_cmds.each(&.data.should eq epd.bw_lut_b.to_a) # no red anywhere
      epd.repeat_refresh_ok.should be_true
      epd.fast_count.should eq 1
    end

    it "uses the red table when the frame has red" do
      mock, epd = new_epd(Badge::EPD::Panel::B1)
      epd.set_pixel(1, 1, Badge::EPD::Ink::Red)
      epd.update(flash: false, passes: 1)
      epd.service
      cmds = decode(mock)
      cmds.select(&.index.==(0xB0)).map(&.data).should eq [Badge::LUTs::LUTB_BASE.to_a]
      cmds.count(&.index.==(0x15)).should eq 1
    end

    it "redoes the whole cycle per pass when the CoG ignores repeat refreshes" do
      mock, epd = new_epd
      # BUSY never goes low: the second refresh "takes" 5 ms -> ignored
      epd.update(flash: false, passes: 3)
      epd.service
      epd.repeat_refresh_ok.should be_false
      l = lines(decode(mock))
      prep = SEND_IMAGES + COG_INITIAL + ["B B0 <400>"] + SOFT_START
      cycle = prep + REFRESH + SOFT_SHUTDOWN
      l.should eq prep + REFRESH * 2 + SOFT_SHUTDOWN + cycle + cycle
      # next time it goes straight to full cycles
      mock.clear_log
      epd.update(flash: false, passes: 2)
      epd.service
      lines(decode(mock)).should eq cycle + cycle
    end

    it "forces a full refresh every full_refresh_every fast updates" do
      mock, epd = new_epd
      epd.full_refresh_every = 2
      kinds = (1..4).map do
        mock.clear_log
        epd.update(flash: false, passes: 1)
        epd.service
        decode(mock).any?(&.index.==(0xB0)) ? :fast : :full
      end
      kinds.should eq [:fast, :fast, :full, :fast]
    end

    it "does not count auto_full: false updates" do
      _mock, epd = new_epd
      epd.update(flash: false, passes: 1, auto_full: false)
      epd.service
      epd.fast_count.should eq 0
    end

    it "keeps an update requested during a refresh" do
      mock, epd = new_epd
      mock.on_spi = ->(w : Badge::HAL::Mock::SpiWrite) do
        epd.update(fast: false) if !w.level(Badge::Pins::EPD_DC) && w.data[0] == 0x15
        nil
      end
      epd.update(fast: false)
      epd.service
      epd.update_pending?.should be_true
      epd.done_updating?.should be_false
      mock.on_spi = nil
      epd.service
      epd.done_updating?.should be_true
    end

    it "polls BUSY every 10 ms through the HAL" do
      mock, epd = new_epd
      mock.script_input(Badge::Pins::EPD_BUSY2, [false, false, false, true])
      epd.wait_not_busy.should be_true
      mock.sleeps.should eq [10, 10, 10]
    end

    it "gives up on BUSY after the timeout" do
      mock, epd = new_epd
      mock.set_input(Badge::Pins::EPD_BUSY1, false)
      epd.wait_not_busy.should be_false
      epd.busy_timeouts.should eq 1
      mock.total_sleep_ms.should eq 120_010
    end

    it "uploads images in 4 kB chunks, yielding between them" do
      mock, epd = new_epd
      epd.update(fast: false)
      epd.service
      # 4 planes x ceil(40320 / 4096) = 4 x 10 chunks
      mock.yields.should eq 40
      mock.spi_writes.map(&.data.size).max.should eq 4096
    end
  end
end
