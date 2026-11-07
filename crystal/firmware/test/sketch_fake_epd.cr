# Host stand-in for the parts of epd.cr (and the C shims) that
# src/sketch_epd.cr uses, with a model of the two CoGs: per CoG the DUW
# window, the RAM_RW pointer, both RAM banks (0x10 / 0x11, 672 x 60), the
# DRFW, and a 0x15 pull that applies (0x11 << 1) | 0x10 to every pixel of
# the scanned rows and then swaps the banks, as the CoG does. `twin` makes
# the model also drive row r + twin with row r's command (the effect seen
# on the badge). Used by test/sketch_drv_spec.cr only.

module LibIDF
  def self.heap_caps_malloc(n : UInt32, caps : UInt32) : Void*
    Pointer(UInt8).malloc(n).as(Void*)
  end

  def self.cr_log(msg : UInt8*, v : Int32) : Nil
    FakeLog.add(String.new(msg) + ": #{v}")
  end

  def self.cr_log3(msg : UInt8*, a : Int32, b : Int32, c : Int32) : Nil
    FakeLog.add(String.new(msg) + ": #{a} #{b} #{c}")
  end

  def self.cr_hex(msg : UInt8*, data : UInt8*, n : Int32) : Nil
    FakeLog.add(String.new(msg) + ":" + (0...n).map { |i| " %02X" % data[i] }.join)
  end
end

module FakeLog
  @@lines = [] of String

  def self.add(s : String) : Nil
    @@lines << s
  end

  def self.lines : Array(String)
    @@lines
  end

  def self.clear : Nil
    @@lines.clear
  end
end

module FakeClock
  @@now = 1000

  def self.now : Int32
    @@now
  end

  def self.advance(ms : Int32) : Nil
    @@now += ms
  end
end

def log(msg : String, v : Int32) : Nil
  FakeLog.add("#{msg}: #{v}")
end

def log2(msg : String, a : Int32, b : Int32) : Nil
  FakeLog.add("#{msg}: #{a} #{b}")
end

def log3(msg : String, a : Int32, b : Int32, c : Int32) : Nil
  FakeLog.add("#{msg}: #{a} #{b} #{c}")
end

def millis : Int32
  FakeClock.now
end

def delay_ms(ms : Int32) : Nil
  FakeClock.advance(ms)
end

class FakeCog
  property duw = {0, 59, 0, 671}
  property ptr_x = 0
  property ptr_y = 0
  property idx = 0
  property drfw = {0, 59, 0, 0xA9}
  property banks = [Bytes.new(672 * 60), Bytes.new(672 * 60)] # [0x10, 0x11]
  property regs = [] of {Int32, Array(Int32)}                 # non-RAM commands
  property args = [] of Int32

  def ram_put(v : UInt8) : Nil
    b = idx == 0x10 ? 0 : 1
    if ptr_y <= 671
      banks[b][ptr_y * 60 + ptr_x] = v
    end
    @ptr_x += 1
    if @ptr_x > duw[1]
      @ptr_x = duw[0]
      @ptr_y += 1
    end
  end

  def byte(v : UInt8) : Nil
    if idx == 0x10 || idx == 0x11
      ram_put(v)
      return
    end
    args << v.to_i
    case idx
    when 0x13
      if args.size == 6
        @duw = {args[0], args[1], args[2] | (args[3] << 8), args[4] | (args[5] << 8)}
      end
    when 0x12
      if args.size == 3
        @ptr_x = args[0]
        @ptr_y = args[1] | ((args[2] & 0x0F) << 8)
      end
    when 0x90
      @drfw = {args[0], args[1], args[2], args[3]} if args.size == 4
    end
  end

  def start(i : Int32) : Nil
    flush
    @idx = i
  end

  def flush : Nil
    regs << {idx, args.dup} unless idx == 0 || idx == 0x10 || idx == 0x11
    @idx = 0
    @args = [] of Int32
  end

  # Last data of command i, nil if never sent.
  def last(i : Int32) : Array(Int32)?
    r = regs.reverse.find { |(k, _)| k == i }
    r ? r[1] : nil
  end

  def scan_rows : Range(Int32, Int32)
    u0 = drfw[2]
    u1 = drfw[3]
    r1 = u1 >= 0xA9 ? 671 : {u1 * 4 + 3, 671}.min
    (u0 * 4)..r1
  end
end

module FakePanel
  @@cogs = [FakeCog.new, FakeCog.new]
  @@twin = 0
  # drives[c][y * 960 + x]: how often command c (1..3) reached the pixel
  @@drives = [Bytes.new(1), Bytes.new(672 * 960), Bytes.new(672 * 960), Bytes.new(672 * 960)]
  @@pulls = [] of {Range(Int32, Int32), Range(Int32, Int32)}
  @@resets = 0

  def self.reset : Nil
    @@cogs = [FakeCog.new, FakeCog.new]
    @@twin = 0
    @@drives = [Bytes.new(1), Bytes.new(672 * 960), Bytes.new(672 * 960), Bytes.new(672 * 960)]
    @@pulls = [] of {Range(Int32, Int32), Range(Int32, Int32)}
    @@resets = 0
  end

  def self.cogs
    @@cogs
  end

  def self.twin=(v : Int32)
    @@twin = v
  end

  def self.pulls
    @@pulls
  end

  def self.resets
    @@resets
  end

  def self.reset_count : Nil
    @@resets += 1
  end

  def self.drives(c : Int32, x : Int32, y : Int32) : Int32
    @@drives[c][y * 960 + x].to_i
  end

  # Pixels (x, y) that got any command c.
  def self.driven_pixels(c : Int32) : Array({Int32, Int32})
    res = [] of {Int32, Int32}
    (0...672).each { |y| (0...960).each { |x| res << {x, y} if @@drives[c][y * 960 + x] != 0 } }
    res
  end

  def self.any_drive?(x : Int32, y : Int32) : Bool
    (1..3).any? { |c| @@drives[c][y * 960 + x] != 0 }
  end

  def self.pull : Int32
    rows = 0
    @@pulls << {@@cogs[0].scan_rows, @@cogs[1].scan_rows}
    2.times do |h|
      cg = @@cogs[h]
      sr = cg.scan_rows
      rows = sr.size if sr.size > rows
      sr.each do |r|
        60.times do |b|
          nv = cg.banks[0][r * 60 + b]
          ov = cg.banks[1][r * 60 + b]
          next if (nv | ov) == 0
          8.times do |k|
            m = 0x80_u8 >> k
            c = ((ov & m) != 0 ? 2 : 0) | ((nv & m) != 0 ? 1 : 0)
            next if c == 0
            x = h * 480 + b * 8 + k
            @@drives[c][r * 960 + x] &+= 1
            t = r + @@twin
            @@drives[c][t * 960 + x] &+= 1 if @@twin != 0 && t < 672 && !sr.includes?(t)
          end
        end
      end
      cg.banks.reverse! # the CoG swaps 0x10 and 0x11 after every pull
    end
    20 + rows * 85 // 100
  end

  # The RAM of both banks of both CoGs is zero outside `rows`.
  def self.ram_zero_except?(rows : Array(Int32)) : Bool
    @@cogs.all? do |cg|
      cg.banks.all? do |bk|
        (0...672).all? { |r| rows.includes?(r) || (0...60).all? { |b| bk[r * 60 + b] == 0 } }
      end
    end
  end
end

module EPD
  LEFT               = 1
  RIGHT              = 2
  BOTH               = 0
  WHITE              = 0
  HEIGHT             = 672
  LUT_BASE           = 0
  FAST_TIMEOUT_MS    = 5_000
  MALLOC_CAP_SPIRAM  = 0x400_u32
  MALLOC_CAP_8BIT    =   0x4_u32
  @@otp = Pointer(UInt8).malloc(88)
  @@spi_fail = false
  @@session_images = 0
  @@diff_rows = HEIGHT
  @@session_open = false
  @@sel = 0
  @@black = Pointer(UInt8).malloc(80640)
  @@red = Pointer(UInt8).malloc(80640)
  @@fake_init = false

  def self.fake_init : Nil
    @@otp[0x10] = 0x0C_u8 # DCTL (some value)
    @@otp[0x15] = 0x10_u8 # RAM_RW flags
    @@session_images = 0
    @@diff_rows = HEIGHT
    @@session_open = false
    @@spi_fail = false
  end

  def self.zero(p : UInt8*, n : Int32) : Nil
    n.times { |i| p[i] = 0_u8 }
  end

  def self.dma_alloc(n : Int32) : UInt8*
    Pointer(UInt8).malloc(n)
  end

  def self.finish_aborted : Nil
  end

  def self.session_open? : Bool
    @@session_open
  end

  def self.quick_open? : Bool
    true
  end

  def self.cog_stop : Nil
    @@session_open = false
    @@diff_rows = HEIGHT
  end

  def self.cog_initial(quick : Bool = false) : Nil
    @@session_images = 0
    FakePanel.reset_count
  end

  # EPD's own refresh (e.g. Sketch's full frame): takes the CoG back.
  def self.refresh(fast : Bool, kind : Int32) : Bool
    cog_stop if @@session_open
    cog_initial(true)
    @@session_open = true
    @@session_images = 1
    true
  end

  def self.fill(c : Int32) : Nil
  end

  def self.raw=(v : Bool) : Nil
  end

  def self.fast_pulls=(n : Int32) : Nil
  end

  def self.black : UInt8*
    @@black
  end

  def self.red : UInt8*
    @@red
  end

  def self.cogs_of(t : Int32) : Array(FakeCog)
    t == LEFT ? [FakePanel.cogs[0]] : (t == RIGHT ? [FakePanel.cogs[1]] : FakePanel.cogs)
  end

  def self.index(target : Int32, idx : UInt8) : Nil
    cogs_of(target).each { |c| c.start(idx.to_i) }
  end

  def self.cs_lo(target : Int32) : Nil
    @@sel = target
  end

  def self.cs_hi : Nil
  end

  def self.write(buf : UInt8*, n : Int32) : Nil
    cogs_of(@@sel).each { |c| n.times { |i| c.byte(buf[i]) } }
  end

  def self.send(target : Int32, idx : UInt8, buf : UInt8*, n : Int32) : Nil
    index(target, idx)
    cs_lo(target)
    write(buf, n)
    cogs_of(target).each(&.flush)
  end

  def self.cmd(target : Int32, idx : UInt8, n : Int32, a : UInt8, b : UInt8 = 0_u8, c : UInt8 = 0_u8,
               d : UInt8 = 0_u8, e : UInt8 = 0_u8, f : UInt8 = 0_u8) : Nil
    bytes = [a, b, c, d, e, f]
    index(target, idx)
    cs_lo(target)
    cogs_of(target).each { |cg| n.times { |i| cg.byte(bytes[i]) } }
    cogs_of(target).each(&.flush)
  end

  def self.cmd1(idx : UInt8, a : UInt8) : Nil
    cmd(BOTH, idx, 1, a)
  end

  def self.diff_dcdc_on : Nil
  end

  def self.ram_rw_full(t : Int32) : Nil
    cmd(t, 0x12_u8, 3, 0_u8, 0_u8, 0x10_u8)
  end

  def self.send_plane(target : Int32, idx : UInt8, plane : UInt8*, orp : UInt8*) : Nil
    index(target, idx)
    cs_lo(target)
    z = Pointer(UInt8).malloc(60)
    672.times { write(z, 60) }
  end

  def self.trigger(watch : Bool, timeout_ms : Int32) : Int32
    FakePanel.cogs.each(&.flush)
    ms = FakePanel.pull
    FakeClock.advance(ms)
    ms
  end
end
