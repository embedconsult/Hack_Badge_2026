# Host render of the registry apps (home grid, settings, schedule) to PBM
# files, with stubbed panel and C side (stubs.c + ../../main/qr.c):
#   cd test/render && cc -c stubs.c ../../main/qr.c && crystal run render_apps.cr
@[Link(ldflags: "#{__DIR__}/stubs.o #{__DIR__}/qr.o")]
lib LibIDF
  fun cr_font5x7 : UInt8*
  fun cr_version : UInt8*
  fun heap_caps_malloc(n : UInt32, caps : UInt32) : Void*
  fun heap_caps_free(p : Void*) : Void
  fun set_time(y : Int32, mo : Int32, d : Int32, h : Int32, mi : Int32) : Void
end

module EPD
  WIDTH = 960; HEIGHT = 672; ROW_BYTES = 120; PLANE = 80640
  WHITE = 0; BLACK = 1; RED = 2
  LUT_BASE = 0
  @@black = Pointer(UInt8).malloc(PLANE)
  @@red = Pointer(UInt8).malloc(PLANE)
  def self.black; @@black; end
  def self.red; @@red; end
  def self.fill(c : Int32); PLANE.times { |i| @@black[i] = c == BLACK ? 0xFF_u8 : 0_u8 }; end
  def self.fill_rect(x0 : Int32, y0 : Int32, w : Int32, h : Int32, c : Int32)
    (y0...(y0 + h)).each do |y|
      next if y < 0 || y >= HEIGHT
      (x0...(x0 + w)).each do |x|
        next if x < 0 || x >= WIDTH
        i = y * ROW_BYTES + (x >> 3)
        m = 0x80_u8 >> (x & 7)
        @@black[i] = c == BLACK ? (@@black[i] | m) : (@@black[i] & ~m)
      end
    end
  end
  class_property fast_pulls = 1
  def self.refresh_diff; Render.frame("diff"); 0; end
end

module Shared
  @@buf = Pointer(UInt8).malloc(128)
  def self.label_buf; @@buf; end
  class_property rendering = false
  class_property target = 255
  class_property screen = 255
end

def fast_bw(p, k); Render.frame("clean"); end
def millis : Int32; 1000; end
def log(m, v); puts "#{m}: #{v}"; end

def text_width(s : String, scale : Int32) : Int32
  n = s.bytesize
  n == 0 ? 0 : (n * 6 - 1) * scale
end

def draw_bytes(x : Int32, y : Int32, buf : UInt8*, n : Int32, color : Int32, scale : Int32) : Int32
  font = LibIDF.cr_font5x7
  n.times do |i|
    ch = buf[i].to_i32
    ch = 0x3F if ch < 0x20 || ch > 0x7E
    5.times do |col|
      bits = font[(ch - 0x20) * 5 + col]
      7.times { |row| EPD.fill_rect(x + col * scale, y + row * scale, scale, scale, color) if (bits >> row) & 1 != 0 }
    end
    x += 6 * scale
  end
  x
end

def draw_text(x : Int32, y : Int32, s : String, color : Int32, scale : Int32) : Nil
  draw_bytes(x, y, s.to_unsafe, s.bytesize, color, scale)
end

def put_decimal(buf : UInt8*, n : Int32) : Int32
  s = n.to_s
  s.bytesize.times { |i| buf[i] = s.to_unsafe[i] }
  s.bytesize
end

module Render
  @@n = 0
  @@name = "x"
  def self.name=(s); @@name = s; @@n = 0; end
  def self.frame(kind)
    @@n += 1
    File.open("#{__DIR__}/out/#{@@name}-#{@@n}-#{kind}.pbm", "w") do |f|
      f << "P4\n960 672\n"
      f.write(Bytes.new(EPD.black, EPD::PLANE))
    end
  end
end

def game_alloc(n : Int32) : UInt8*
  Pointer(UInt8).malloc(n)
end
require "../../src/games/common"
require "../../src/apps/app"
require "../../src/apps/builtin"
require "../../src/apps/home"
require "../../src/apps/settings"
require "../../src/apps/schedule"

inp = Games.input(1000, 1000, 0_u32, 0_u32)
press = ->(b : UInt32) { Games.input(1000, 1000, b, 0_u32) }
Render.name = "home"
Home.enter
Home.tick(1, press.call(Games::BTN_PLUS))
Home.sel = 7
Home.tick(1, press.call(Games::BTN_PLUS))
Render.name = "settings"
SettingsApp.enter
Render.name = "sched"
ScheduleApp.enter
ScheduleApp.tick(1, press.call(Games::BTN_B))
ScheduleApp.tick(1, press.call(Games::BTN_B))
Render.name = "schednow"
LibIDF.set_time(2026, 11, 7, 14, 10)
ScheduleApp.enter
