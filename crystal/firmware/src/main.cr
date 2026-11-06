# Badge firmware in Crystal (--prelude=empty: compiler primitives, `lib`
# bindings and `fun` only; no stdlib, GC or exceptions).
#
# - crystal_knob_task (FreeRTOS task, started from main.c): blinks the status
#   LED at a rate set by the left knob and logs both knobs once a second.
# - crystal_app_main: draws a test pattern on the e-paper and refreshes it,
#   logging the time each phase takes (src/epd.cr).

require "./rt"

lib LibIDF
  # driver/gpio.h (gpio_num_t / gpio_mode_t are C enums -> int)
  fun gpio_reset_pin(gpio_num : Int32) : Int32
  fun gpio_set_direction(gpio_num : Int32, mode : Int32) : Int32
  fun gpio_set_level(gpio_num : Int32, level : UInt32) : Int32

  # freertos/task.h: a real function (not a macro); TickType_t is uint32_t
  fun vTaskDelay(ticks : UInt32) : Void

  # esp_adc/adc_oneshot.h
  struct AdcOneshotUnitInitCfg
    unit_id : Int32  # adc_unit_t
    clk_src : Int32  # adc_oneshot_clk_src_t (0 = default)
    ulp_mode : Int32 # adc_ulp_mode_t (0 = disabled)
  end

  struct AdcOneshotChanCfg
    atten : Int32    # adc_atten_t
    bitwidth : Int32 # adc_bitwidth_t (0 = default, 12 bits on S3)
  end

  # esp_adc/adc_cali_scheme.h
  struct AdcCaliCurveFittingCfg
    unit_id : Int32
    chan : Int32
    atten : Int32
    bitwidth : Int32
  end

  alias AdcHandle = Void*
  fun adc_oneshot_new_unit(cfg : AdcOneshotUnitInitCfg*, handle : AdcHandle*) : Int32
  fun adc_oneshot_config_channel(handle : AdcHandle, channel : Int32, cfg : AdcOneshotChanCfg*) : Int32
  fun adc_oneshot_read(handle : AdcHandle, channel : Int32, out_raw : Int32*) : Int32
  fun adc_cali_create_scheme_curve_fitting(cfg : AdcCaliCurveFittingCfg*, handle : Void**) : Int32
  fun adc_cali_raw_to_voltage(handle : Void*, raw : Int32, mv : Int32*) : Int32

  # main/main.c: configTICK_RATE_HZ
  $crystal_tick_rate_hz : UInt32
  # main/main.c: embedded images
  fun cr_hello_png : UInt8*
  fun cr_hello_png_size : Int32
  fun cr_font5x7 : UInt8*
  fun cr_portrait_png : UInt8*
  fun cr_portrait_png_size : Int32
  fun cr_sketch_png : UInt8*
  fun cr_sketch_png_size : Int32
  fun cr_etch_png : UInt8*
  fun cr_etch_png_size : Int32
end

require "./epd"
require "./png"
require "./leds"
require "./games/badge"
require "./games/menu"

STATUS_LED       = 1
GPIO_MODE_OUTPUT = 2 # GPIO_MODE_DEF_OUTPUT (BIT1)
ADC_UNIT_1       = 0
ADC_ATTEN_DB_12  = 3
ADC_BITWIDTH_12  = 12
KNOB_LEFT_CH     = 1 # GPIO2 = ADC1_CH1 (SAO1 GPIO1)
KNOB_RIGHT_CH    = 6 # GPIO7 = ADC1_CH6
MIN_MS           = 50_u32

def ms_to_ticks(ms : UInt32) : UInt32
  ticks = (ms &* LibIDF.crystal_tick_rate_hz).unsafe_div(1000_u32)
  ticks == 0_u32 ? 1_u32 : ticks
end

def knob_channel(adc : Void*, ch : Int32) : Void*
  chan_cfg = LibIDF::AdcOneshotChanCfg.new
  chan_cfg.atten = ADC_ATTEN_DB_12
  LibIDF.adc_oneshot_config_channel(adc, ch, pointerof(chan_cfg))
  cal_cfg = LibIDF::AdcCaliCurveFittingCfg.new
  cal_cfg.unit_id = ADC_UNIT_1
  cal_cfg.chan = ch
  cal_cfg.atten = ADC_ATTEN_DB_12
  cal_cfg.bitwidth = ADC_BITWIDTH_12
  cal = Pointer(Void).null
  err = LibIDF.adc_cali_create_scheme_curve_fitting(pointerof(cal_cfg), pointerof(cal))
  log2("knob: channel / adc_cali err", ch, err)
  err == 0 ? cal : Pointer(Void).null
end

def knob_mv(cal : Void*, raw : Int32) : Int32
  return -1 if cal.null?
  mv = 0
  LibIDF.adc_cali_raw_to_voltage(cal, raw, pointerof(mv))
  mv
end

# Knob ranges measured on the badge (calibrated mV).
LEFT_MV_LO  =  694
LEFT_MV_HI  = 2963
RIGHT_MV_LO =   70
RIGHT_MV_HI = 2703
LED_LEFT    =   42 # SAO1 GPIO2: WS2812 on the left knob
LED_RIGHT   =    6 # SAO2 GPIO2: WS2812 on the right knob
LED_LEVEL   =   64 # brightness, 0..255
LOOP_MS     =   50 # 20 Hz
LED_YELLOW  =    1
LED_GREEN   =    2
LED_CYAN    =    3

# State shared between the main task and the knob task (word-sized fields).
module Shared
  @@mv_l = 0
  @@mv_r = 0
  @@held = 0_u32    # buttons held at the last poll
  @@latched = 0_u32 # buttons seen held since the main loop last took them
  @@leds_ready = false
  @@ch_l = Pointer(Void).null
  @@enc_l = Pointer(Void).null
  @@ch_r = Pointer(Void).null
  @@enc_r = Pointer(Void).null

  def self.mv_l : Int32
    @@mv_l
  end

  def self.mv_r : Int32
    @@mv_r
  end

  def self.set_knobs(l : Int32, r : Int32, held : UInt32) : Nil
    @@mv_l = l
    @@mv_r = r
    @@held = held
    @@latched = @@latched | held
  end

  # Buttons held now or at any poll since the last call.
  def self.take_buttons : UInt32
    b = @@latched | @@held
    @@latched = 0_u32
    b
  end

  @@label = Pointer(UInt8).null

  @@ps = Pointer(Int32).null

  def self.ps_times : Int32*
    @@ps = EPD.dma_alloc(64).as(Int32*) if @@ps.null?
    @@ps
  end

  def self.label_buf : UInt8*
    @@label = EPD.dma_alloc(32) if @@label.null?
    @@label
  end

  # Right-knob LED: 0 = live hue from the knob, else a fixed status colour
  # (LED_YELLOW / LED_GREEN / LED_CYAN), as upstream Sketch does.
  @@led_mode = 0

  def self.led_mode : Int32
    @@led_mode
  end

  def self.led_mode=(m : Int32) : Nil
    @@led_mode = m
  end

  def self.leds_ready? : Bool
    @@leds_ready
  end

  def self.set_leds(cl : Void*, el : Void*, cr : Void*, er : Void*) : Nil
    @@ch_l = cl
    @@enc_l = el
    @@ch_r = cr
    @@enc_r = er
    @@leds_ready = true
  end

  def self.ch_l : Void*
    @@ch_l
  end

  def self.enc_l : Void*
    @@enc_l
  end

  def self.ch_r : Void*
    @@ch_r
  end

  def self.enc_r : Void*
    @@enc_r
  end
end

# Buttons: active low with pull-ups. (The Menu +/- silkscreen is swapped.)
BTN_A_GPIO     = 39
BTN_B_GPIO     = 16
BTN_PLUS_GPIO  = 15
BTN_MINUS_GPIO = 40

def read_buttons : UInt32
  b = 0_u32
  b = b | Games::BTN_A if LibIDF.gpio_get_level(BTN_A_GPIO) == 0
  b = b | Games::BTN_B if LibIDF.gpio_get_level(BTN_B_GPIO) == 0
  b = b | Games::BTN_PLUS if LibIDF.gpio_get_level(BTN_PLUS_GPIO) == 0
  b = b | Games::BTN_MINUS if LibIDF.gpio_get_level(BTN_MINUS_GPIO) == 0
  b
end

# mV in [lo, hi] -> hue 0..1535
def mv_to_hue(mv : Int32, lo : Int32, hi : Int32) : Int32
  mv = lo if mv < lo
  mv = hi if mv > hi
  ((mv &- lo) &* 1535).unsafe_div(hi &- lo)
end

# Knob task (started from main.c): every 50 ms read both knobs and set each
# knob's WS2812 to a hue from its position; blink the status LED at a rate
# set by the left knob; log both knobs once a second. Runs independently of
# the e-paper refresh on the main task.
fun crystal_knob_task(arg : Void*) : Void
  LibIDF.gpio_reset_pin(STATUS_LED)
  LibIDF.gpio_set_direction(STATUS_LED, GPIO_MODE_OUTPUT)

  unit_cfg = LibIDF::AdcOneshotUnitInitCfg.new
  unit_cfg.unit_id = ADC_UNIT_1
  adc = uninitialized Void*
  LibIDF.adc_oneshot_new_unit(pointerof(unit_cfg), pointerof(adc))
  cal_l = knob_channel(adc, KNOB_LEFT_CH)
  cal_r = knob_channel(adc, KNOB_RIGHT_CH)

  EPD.in_pin(BTN_A_GPIO)
  EPD.in_pin(BTN_B_GPIO)
  EPD.in_pin(BTN_PLUS_GPIO)
  EPD.in_pin(BTN_MINUS_GPIO)
  buf_l = EPD.dma_alloc(4)
  buf_r = EPD.dma_alloc(4)
  rgb = EPD.dma_alloc(4)

  log("knob: loop starting", 0)
  on = false
  raw_l = 0
  raw_r = 0
  now = millis
  last_log = now
  last_blink = now
  while true
    # Average ADC_SAMPLES reads per knob (Sketch's deadband assumes this).
    sum_l = 0
    sum_r = 0
    k = 0
    while k < Sketch::ADC_SAMPLES
      LibIDF.adc_oneshot_read(adc, KNOB_LEFT_CH, pointerof(raw_l))
      LibIDF.adc_oneshot_read(adc, KNOB_RIGHT_CH, pointerof(raw_r))
      sum_l = sum_l &+ raw_l
      sum_r = sum_r &+ raw_r
      k = k &+ 1
    end
    raw_l = sum_l.unsafe_div(Sketch::ADC_SAMPLES)
    raw_r = sum_r.unsafe_div(Sketch::ADC_SAMPLES)
    raw_l = 0 if raw_l < 0
    raw_r = 0 if raw_r < 0
    mv_l = knob_mv(cal_l, raw_l)
    mv_r = knob_mv(cal_r, raw_r)
    hue_l = mv_to_hue(mv_l, LEFT_MV_LO, LEFT_MV_HI)
    hue_r = mv_to_hue(mv_r, RIGHT_MV_LO, RIGHT_MV_HI)
    btns = read_buttons
    Shared.set_knobs(mv_l, mv_r, btns)
    # A Menu press aborts a slow (colour) refresh in progress.
    if (btns & (Games::BTN_PLUS | Games::BTN_MINUS)) != 0_u32 && EPD.abortable?
      EPD.request_abort
    end
    if Shared.leds_ready?
      unless Shared.ch_l.null?
        Pixel.hue(hue_l, LED_LEVEL, rgb)
        Pixel.show(Shared.ch_l, Shared.enc_l, buf_l, rgb[0], rgb[1], rgb[2])
      end
      lm = Shared.led_mode
      if lm == LED_YELLOW
        Pixel.show(Shared.ch_r, Shared.enc_r, buf_r, 48_u8, 40_u8, 0_u8)
      elsif lm == LED_GREEN
        Pixel.show(Shared.ch_r, Shared.enc_r, buf_r, 0_u8, 48_u8, 0_u8)
      elsif lm == LED_CYAN
        Pixel.show(Shared.ch_r, Shared.enc_r, buf_r, 0_u8, 40_u8, 48_u8)
      else
        Pixel.hue(hue_r, LED_LEVEL, rgb)
        Pixel.show(Shared.ch_r, Shared.enc_r, buf_r, rgb[0], rgb[1], rgb[2])
      end
    end

    now = millis
    half_period = 50 &+ (raw_l &* 950).unsafe_div(4095)
    if now &- last_blink >= half_period
      last_blink = now
      on = !on
      LibIDF.gpio_set_level(STATUS_LED, on ? 0_u32 : 1_u32) # active low
    end
    if now &- last_log >= 1000
      last_log = now
      log2("knob: left GPIO2 raw / mV", raw_l, mv_l)
      log2("knob: right GPIO7 raw / mV", raw_r, mv_r)
      log2("knob: hue left / right (0..1535)", hue_l, hue_r)
    end
    LibIDF.vTaskDelay(ms_to_ticks(LOOP_MS.to_u32!))
  end
end

# Test pattern: 12 px black border, diagonal stripes (red, or black when
# red = false), white centre with a black block whose x position moves with
# `frame`, and a black square top-left (inside the border) to show orientation.
def draw_pattern(frame : Int32, red : Bool) : Nil
  EPD.fill(EPD::WHITE)
  stripe = red ? EPD::RED : EPD::BLACK
  y = 0
  while y < EPD::HEIGHT
    x = 0
    while x < EPD::WIDTH
      c = EPD::WHITE
      if x < 12 || y < 12 || x >= EPD::WIDTH &- 12 || y >= EPD::HEIGHT &- 12
        c = EPD::BLACK
      elsif x >= 24 && x < 64 && y >= 24 && y < 64
        c = EPD::BLACK
      elsif x >= 240 && x < 720 && y >= 168 && y < 504
        c = EPD::WHITE
      elsif ((x &+ y).unsafe_div(24) & 1) == 0
        c = stripe
      end
      EPD.set_pixel(x, y, c) if c != EPD::WHITE
      x = x &+ 1
    end
    y = y &+ 1
  end
  EPD.fill_rect(280 &+ frame &* 80, 280, 160, 112, EPD::BLACK)
end

# Text in the 5x7 font (6x8 cell), each font pixel a scale x scale block.
def text_width(s : String, scale : Int32) : Int32
  n = s.bytesize
  n == 0 ? 0 : (n &* 6 &- 1) &* scale
end

def draw_text(x : Int32, y : Int32, s : String, color : Int32, scale : Int32) : Nil
  font = LibIDF.cr_font5x7
  p = s.to_unsafe
  i = 0
  while i < s.bytesize
    ch = p[i].to_i32!
    ch = 0x3F if ch < 0x20 || ch > 0x7E
    g = font + ((ch &- 0x20) &* 5).to_i64!
    col = 0
    while col < 5
      bits = g[col]
      row = 0
      while row < 7
        if (bits.unsafe_shr(row) & 1_u8) != 0_u8
          EPD.fill_rect(x &+ col &* scale, y &+ row &* scale, scale, scale, color)
        end
        row = row &+ 1
      end
      col = col &+ 1
    end
    x = x &+ 6 &* scale
    i = i &+ 1
  end
end

# The white name band of hello_i_am_blank.png is rows 221..557.
BAND_TOP    = 221
BAND_BOTTOM = 558
NAME_SCALE  =  18

def draw_name(first : String, last : String) : Nil
  line_h = 7 &* NAME_SCALE
  gap = 2 &* NAME_SCALE
  top = BAND_TOP &+ (BAND_BOTTOM &- BAND_TOP &- (2 &* line_h &+ gap)).unsafe_div(2)
  draw_text((EPD::WIDTH &- text_width(first, NAME_SCALE)).unsafe_div(2), top, first, EPD::BLACK, NAME_SCALE)
  draw_text((EPD::WIDTH &- text_width(last, NAME_SCALE)).unsafe_div(2), top &+ line_h &+ gap, last, EPD::BLACK, NAME_SCALE)
end

SPI_HZ      = 20_000_000
SPEED_TEST  = false # boot-time 1-pull vs 3-pull fast refresh comparison
GAME_PULLS  = 1    # waveform pulls per fast refresh in the game modes
CLEAN_EVERY = 30   # game frames between clean (shaking, 3-pull) refreshes
GAME_LUT    = EPD::LUT_NOSHAKE_BW
LUT_TIMING  = false # boot: time one pull of each fast LUT kind, show results on the panel
LUT_PROBE   = false # boot-time experiment: which (red, bw) pairs select which table
PANEL_SPEED = true  # boot: run panel_speed (DIAG A runs it too)

# Bring-up test for the knob WS2812s: left red, right blue for 10 s, then
# off, with blocking transmits and a log line around every call. On success
# the handles go to the knob task for the live hue display.
def led_test : Nil
  ch_r = Pointer(Void).null
  enc_r = Pointer(Void).null
  buf = EPD.dma_alloc(4)
  # The left knob's pixel (GPIO42) never lit on the badge even though RMT
  # reports success; parked, no RMT channel is created on GPIO42.
  log("led: opening right pixel (GPIO6)", 0)
  unless Pixel.open(LED_RIGHT, pointerof(ch_r), pointerof(enc_r))
    log("led: open failed, live LED disabled", 0)
    return
  end
  log("led: right = blue 50% for 3 s", 0)
  Pixel.show_blocking(ch_r, enc_r, buf, 0_u8, 0_u8, 128_u8)
  delay_ms(3000)
  Shared.set_leds(Pointer(Void).null, Pointer(Void).null, ch_r, enc_r)
  log("led: right pixel handed to the knob task", 0)
end

def mode_name(m : Int32) : String
  if m == Menu::SKETCH
    "SKETCH"
  elsif m == Menu::LIFE
    "LIFE"
  elsif m == Menu::SNAKE
    "SNAKE"
  else
    "NAMETAG"
  end
end

# Decimal digits of n (>= 0) into buf; returns the count.
def put_decimal(buf : UInt8*, n : Int32) : Int32
  tmp = 0
  k = 0
  if n <= 0
    buf[0] = 0x30_u8
    return 1
  end
  t = n
  while t > 0
    t = t.unsafe_div(10)
    k = k &+ 1
  end
  i = k
  t = n
  while i > 0
    i = i &- 1
    buf[i] = (0x30 &+ t.unsafe_mod(10)).to_u8!
    t = t.unsafe_div(10)
  end
  k
end

# Draws n bytes of buf in the 5x7 font (like draw_text, for built strings).
def draw_bytes(x : Int32, y : Int32, buf : UInt8*, n : Int32, color : Int32, scale : Int32) : Int32
  font = LibIDF.cr_font5x7
  i = 0
  while i < n
    ch = buf[i].to_i32!
    ch = 0x3F if ch < 0x20 || ch > 0x7E
    g = font + ((ch &- 0x20) &* 5).to_i64!
    col = 0
    while col < 5
      bits = g[col]
      row = 0
      while row < 7
        if (bits.unsafe_shr(row) & 1_u8) != 0_u8
          EPD.fill_rect(x &+ col &* scale, y &+ row &* scale, scale, scale, color)
        end
        row = row &+ 1
      end
      col = col &+ 1
    end
    x = x &+ 6 &* scale
    i = i &+ 1
  end
  x
end

def short_name(m : Int32) : String
  if m == Menu::SKETCH
    "SK"
  elsif m == Menu::LIFE
    "LIFE"
  elsif m == Menu::SNAKE
    "SNAKE"
  else
    "TAG"
  end
end

# Appends "/<v>" (or "<v>" when first) to buf at n; returns the new length.
def put_field(buf : UInt8*, n : Int32, v : Int32, first : Bool) : Int32
  unless first
    buf[n] = 0x2F_u8 # '/'
    n = n &+ 1
  end
  n &+ put_decimal(buf + n.to_i64!, v)
end

# Top-left label (5x7 font x4 on a white box) with the previous frame's
# timing, since reading the console resets the chip:
#   "SK wait/upload/panel/total" in ms, wait = last input -> refresh start.
def draw_mode_label(m : Int32, wait : Int32, up : Int32, panel : Int32, total : Int32) : Nil
  name = short_name(m)
  buf = Shared.label_buf
  buf[0] = 0x20_u8
  n = 1
  n = put_field(buf, n, wait, true)
  n = put_field(buf, n, up, false)
  n = put_field(buf, n, panel, false)
  n = put_field(buf, n, total, false)
  w = text_width(name, 4) &+ n &* 6 &* 4
  EPD.fill_rect(0, 0, w &+ 16, 7 &* 4 &+ 16, EPD::WHITE)
  draw_text(8, 8, name, EPD::BLACK, 4)
  draw_bytes(8 &+ name.bytesize &* 6 &* 4, 8, buf, n, EPD::BLACK, 4)
end

# Large centred mode name, for the slow red-clearing refresh on mode entry.
def draw_mode_banner(m : Int32) : Nil
  name = mode_name(m)
  scale = 16
  w = text_width(name, scale)
  h = 7 &* scale
  x = (EPD::WIDTH &- w).unsafe_div(2)
  y = (EPD::HEIGHT &- h).unsafe_div(2)
  EPD.fill_rect(x &- 24, y &- 24, w &+ 48, h &+ 48, EPD::WHITE)
  draw_text(x, y, name, EPD::BLACK, scale)
end

def show_nametag : Nil
  EPD.fill(EPD::WHITE)
  t = millis
  ok = PNG.draw(LibIDF.cr_hello_png, LibIDF.cr_hello_png_size, EPD.black, EPD.red, 0, 0, true)
  log2("main: png decode ms / err", millis &- t, ok ? 0 : PNG.err)
  draw_pattern(0, true) unless ok
  draw_name("Jason", "Kridner")
  EPD.refresh(false)
end

# Alternates two black/white frames with 1 pull, then with 3 pulls, so the
# ghosting can be compared on video. The first fast refresh after red is run
# slow by the driver (red has to be cleared with the panel's own waveform).
def speed_test : Nil
  log("speed: start (first frame clears red, runs slow)", 0)
  EPD.keep_awake = true
  draw_pattern(1, false)
  EPD.refresh(true)
  pulls = 1
  while pulls <= 3
    EPD.fast_pulls = pulls
    i = 0
    while i < 4
      draw_pattern((i & 1) == 0 ? 4 : 1, false)
      t = millis
      EPD.refresh(true)
      log2("speed: pulls / refresh ms", pulls, millis &- t)
      i = i &+ 1
    end
    pulls = pulls &+ 2
  end
  log("speed: done", 0)
end

# White base (clean 3-pull fast refresh of a blank frame).
def probe_white : Nil
  EPD.raw = false
  EPD.probe = -1
  EPD.fast_pulls = 3
  EPD.fill(EPD::WHITE)
  EPD.refresh(true, EPD::LUT_BASE)
end

# For k = 0..3: white base, then one 1-pull refresh with the planes as
# quadrants (bw bit set on the LEFT half, red bit set on the TOP half) and a
# LUT that drives only table k black. The quadrants that darken are the
# (red, bw) pairs that select table k:
#   top-left (1,1)  top-right (1,0)  bottom-left (0,1)  bottom-right (0,0)
def lut_probe : Nil
  EPD.keep_awake = true
  log("probe: white base (runs slow first if red is on the panel)", 0)
  probe_white
  k = 0
  while k < 4
    probe_white
    EPD.fill(EPD::WHITE)
    i = 0
    while i < EPD::PLANE
      col = i.unsafe_mod(EPD::ROW_BYTES)
      row = i.unsafe_div(EPD::ROW_BYTES)
      EPD.black[i] = col < 60 ? 0xFF_u8 : 0x00_u8
      EPD.red[i] = row < 336 ? 0xFF_u8 : 0x00_u8
      i = i &+ 1
    end
    EPD.raw = true
    EPD.probe = k
    EPD.fast_pulls = 1
    log2("probe: table, at ms", k, millis)
    EPD.refresh(true, EPD::LUT_NOSHAKE)
    delay_ms(4000) # time to look
    k = k &+ 1
  end
  EPD.raw = false
  EPD.probe = -1
  EPD.prev_has_red = true # nothing known about the red pigment now
  log("probe: done", 0)
end

# Portrait screen (960x672 white/black/red PNG), one slow full-colour refresh.
def show_portrait : Nil
  EPD.fill(EPD::WHITE)
  t = millis
  ok = PNG.draw(LibIDF.cr_portrait_png, LibIDF.cr_portrait_png_size, EPD.black, EPD.red, 0, 0, true)
  log2("main: portrait decode ms / err", millis &- t, ok ? 0 : PNG.err)
  draw_pattern(0, true) unless ok
  EPD.refresh(false)
end

# ---- Sketch (port of upstream apps/sketch.py) -------------------------------

module SketchFx
  @@save = Pointer(UInt8).null

  def self.save_buf : UInt8*
    @@save = LibIDF.heap_caps_malloc(EPD::PLANE.to_u32!, 0x404_u32).as(UInt8*) if @@save.null?
    @@save
  end
end

# Sketch background (upstream 5665ab1): prep (white, rows 668..671 red), then
# EtchASketch.png on top, then the single-knob status line if any.
def sketch_background : Nil
  Sketch.prep_background(EPD.black, EPD.red)
  ok = PNG.draw(LibIDF.cr_etch_png, LibIDF.cr_etch_png_size, EPD.black, EPD.red, 0, 0, false)
  log2("sketch: background ok / err", ok ? 1 : 0, PNG.err)
  st = Sketch.status_text
  draw_text(Sketch::STATUS_X, Sketch::STATUS_Y, st, EPD::WHITE, Sketch::STATUS_SCALE) if st.bytesize > 0
end

# Flash area: the frame's white screen around the drawable area.
SK_X0 = Sketch::X_MIN - 6
SK_Y0 = Sketch::Y_MIN - 6
SK_W  = Sketch::X_MAX - Sketch::X_MIN + 13
SK_H  = Sketch::Y_MAX - Sketch::Y_MIN + 13

# Upstream's cleaning flash, limited to the screen area so the red frame is
# never driven: area black, area white, then the frame (3 pulls). Raw planes
# with the keep-red LUT: red pixels select ground-only tables.
def sketch_clean : Nil
  save = SketchFx.save_buf
  i = 0
  while i < EPD::PLANE
    save[i] = EPD.black[i]
    i = i &+ 1
  end
  EPD.fast_pulls = 1
  EPD.fill_rect(SK_X0, SK_Y0, SK_W, SK_H, EPD::BLACK)
  EPD.refresh(true, EPD::LUT_KEEPRED)
  EPD.fill_rect(SK_X0, SK_Y0, SK_W, SK_H, EPD::WHITE)
  EPD.refresh(true, EPD::LUT_KEEPRED)
  i = 0
  while i < EPD::PLANE
    EPD.black[i] = save[i]
    i = i &+ 1
  end
  EPD.fast_pulls = 3
  EPD.refresh(true, EPD::LUT_KEEPRED)
end

# One Sketch frame. entry = first frame after switching to Sketch: the red
# frame is put on the panel with a slow full-colour refresh (a fast
# refresh cannot make a solid red). After that, frames are raw keep-red
# fast refreshes, so the red frame is never touched.
def sketch_frame(entry : Bool, wait : Int32, up : Int32, panel : Int32, total : Int32) : Nil
  if Menu.needs_background? || entry
    sketch_background
  end
  Menu.render(EPD.black, EPD.red)
  draw_sketch_label(wait, up, panel, total)
  Shared.led_mode = LED_CYAN
  if entry
    EPD.raw = false
    EPD.refresh(false)
  else
    EPD.raw = true
    if Menu.want_clean?
      sketch_clean
    else
      EPD.fast_pulls = 1
      EPD.refresh(true, EPD::LUT_NOSHAKE_KEEPRED)
    end
    EPD.raw = false
  end
end

# "SK wait/upload/panel/total" inside the screen area (top-left), x3.
def draw_sketch_label(wait : Int32, up : Int32, panel : Int32, total : Int32) : Nil
  buf = Shared.label_buf
  buf[0] = 0x53_u8 # S
  buf[1] = 0x4B_u8 # K
  buf[2] = 0x20_u8
  n = 3
  n = put_field(buf, n, wait, true)
  n = put_field(buf, n, up, false)
  n = put_field(buf, n, panel, false)
  n = put_field(buf, n, total, false)
  EPD.fill_rect(Sketch::X_MIN, Sketch::Y_MIN, n &* 18 &+ 6, 7 &* 3 &+ 6, EPD::WHITE)
  draw_bytes(Sketch::X_MIN &+ 3, Sketch::Y_MIN &+ 3, buf, n, EPD::BLACK, 3)
end

# DIAG mode help screen (fast refresh; the driver runs it slow if red is up).
def show_diag : Nil
  EPD.fill(EPD::WHITE)
  draw_text(40, 40, "DIAG", EPD::BLACK, 10)
  draw_text(40, 200, "A: PANEL SPEED TEST (~3 MIN)", EPD::BLACK, 4)
  draw_text(40, 260, "B: LAST PANEL SPEED RESULTS", EPD::BLACK, 4)
  draw_text(40, 320, "MENU +/-: LEAVE", EPD::BLACK, 4)
  draw_text(40, 420, "PROBE QUADRANTS (RED,BW):", EPD::BLACK, 3)
  draw_text(40, 460, "TL 1,1  TR 1,0  BL 0,1  BR 0,0", EPD::BLACK, 3)
  draw_text(40, 500, "ORDER: TABLE 0,1,2,3, WHITE BETWEEN", EPD::BLACK, 3)
  EPD.fast_pulls = 3
  EPD.refresh(true, EPD::LUT_BASE)
end

# One 1-pull refresh with each fast LUT kind on alternating frames; the panel
# busy times are then drawn on the panel and logged.
def lut_timing : Nil
  EPD.keep_awake = true
  EPD.fast_pulls = 1
  times = EPD.dma_alloc(32).as(Int32*)
  k = 0
  while k < 6
    draw_pattern((k & 1) == 0 ? 1 : 4, false)
    EPD.refresh(true, k)
    times[k] = EPD.panel_ms
    log2("lut: kind / 1-pull panel ms", k, EPD.panel_ms)
    k = k &+ 1
  end
  EPD.fill(EPD::WHITE)
  draw_text(40, 40, "1-PULL PANEL MS BY LUT", EPD::BLACK, 5)
  buf = Shared.label_buf
  k = 0
  while k < 6
    name = k == 0 ? "BASE" : (k == 1 ? "NOSHAKE" : (k == 2 ? "UPSTREAM BW" : (k == 3 ? "NOSHAKE+BW" : (k == 4 ? "KEEPRED" : "NOSHAKE KEEPRED"))))
    draw_text(40, 130 &+ k &* 80, name, EPD::BLACK, 4)
    n = put_decimal(buf, times[k])
    draw_bytes(720, 130 &+ k &* 80, buf, n, EPD::BLACK, 4)
    k = k &+ 1
  end
  EPD.fast_pulls = 3
  EPD.refresh(true, EPD::LUT_BASE)
  delay_ms(8000) # time to read it
end

# ---- panel speed experiment ---------------------------------------------------
# One refresh, red plane raw (no promotion to slow); returns panel busy ms.
def ps_run(kind : Int32, pulls : Int32) : Int32
  EPD.raw = true
  EPD.fast_pulls = pulls
  EPD.refresh(true, kind)
  EPD.raw = false
  EPD.panel_ms
end

def ps_text(x : Int32, y : Int32, s : String, v : Int32, scale : Int32) : Int32
  draw_text(x, y, s, EPD::BLACK, scale)
  buf = Shared.label_buf
  n = put_decimal(buf, v < 0 ? 0 : v)
  buf[n] = 0x20_u8
  draw_bytes(x &+ (s.bytesize &+ 1) &* 6 &* scale, y, buf, n &+ 1, EPD::BLACK, scale)
end

BAND_H    = 80
BAND_C1   = 77  # bands use frame bytes 0..77 (x 0..623); results to the right
PS_BANDS  = 7

def ps_band(i : Int32, name : String, desc : String) : Nil
  y = i &* BAND_H
  draw_text(12, y &+ 10, name, EPD::BLACK, 3)
  draw_text(12, y &+ 46, desc, EPD::BLACK, 2)
  EPD.fill_rect(380, y &+ 8, 230, 64, EPD::BLACK)
  EPD.window(true, 0, BAND_C1, y, y &+ BAND_H &- 1)
end

# Questions: does panel busy time scale with LUT frame counts once every
# table (VCOM included) carries them; does a smaller DUW/DRFW window shorten
# it; does an oscillator write (0x03) change it; what is the shortest LUT
# that turns white solidly black. Timing first (full screen), then a clean
# white, then one band per ink variant (each refreshed only in its band, so
# they can be compared side by side), then all times on the panel.
def panel_speed : Nil
  log("ps: start", 0)
  EPD.keep_awake = true
  tm = Shared.ps_times
  # -- timing phase --
  EPD.window(false)
  draw_pattern(1, false)
  tm[0] = ps_run(EPD::LUT_BASE, 1)                     # base, full screen
  draw_pattern(4, false)
  EPD.window(true, 58, 61, 332, 339)                   # 32 x 8 px box
  tm[1] = ps_run(EPD::LUT_BASE, 1)
  draw_pattern(1, false)
  EPD.window(true, 0, 119, 0, 335)                     # top half
  tm[2] = ps_run(EPD::LUT_BASE, 1)
  EPD.window(false)
  EPD.custom(0x55_u8, 0xAA_u8, 0, 9, 1_u8, 1_u8, 1_u8, 1_u8)
  draw_pattern(4, false)
  tm[3] = ps_run(EPD::LUT_CUSTOM, 1)                   # full-duty, all groups minimal
  EPD.osc = 0x11
  draw_pattern(1, false)
  tm[4] = ps_run(EPD::LUT_CUSTOM, 1)
  EPD.osc = 0x12
  draw_pattern(4, false)
  tm[5] = ps_run(EPD::LUT_CUSTOM, 1)
  EPD.osc = -1
  # (Zero-count tests removed: rep 0 / ph2 0 in a group hung the panel.)
  tm[6] = 0
  tm[7] = 0
  k = 0
  while k < 6
    log2("ps: timing test / panel ms", k, tm[k])
    k = k &+ 1
  end
  # -- clean white --
  EPD.fill(EPD::WHITE)
  ps_run(EPD::LUT_BASE, 3)
  ps_run(EPD::LUT_BASE, 3)
  # -- ink bands (white -> black), each refreshed in its own band only --
  ps_band(0, "BASE 1P", "SHAKE+4X45/1X3, VCOM 1/1")
  tm[8] = ps_run(EPD::LUT_BASE, 1)
  ps_band(1, "BASE 3P", "CURRENT CLEAN")
  tm[9] = ps_run(EPD::LUT_BASE, 3)
  EPD.custom(0x44_u8, 0xAA_u8, 1, 4, 4_u8, 1_u8, 1_u8, 1_u8)
  ps_band(2, "N4", "44/AA 4 GRP 4/1/1 ALL TBL")
  tm[10] = ps_run(EPD::LUT_CUSTOM, 1)
  EPD.custom(0x44_u8, 0xAA_u8, 1, 4, 10_u8, 1_u8, 1_u8, 1_u8)
  ps_band(3, "N10", "44/AA 4 GRP 10/1/1 ALL TBL")
  tm[11] = ps_run(EPD::LUT_CUSTOM, 1)
  EPD.custom(0x44_u8, 0xAA_u8, 1, 4, 20_u8, 1_u8, 1_u8, 1_u8)
  ps_band(4, "N20", "44/AA 4 GRP 20/1/1 ALL TBL")
  tm[12] = ps_run(EPD::LUT_CUSTOM, 1)
  EPD.custom(0x44_u8, 0xAA_u8, 0, 9, 1_u8, 1_u8, 1_u8, 1_u8)
  ps_band(5, "HALF60", "44/AA ALL 10 GRP 1/1/1")
  tm[13] = ps_run(EPD::LUT_CUSTOM, 1)
  EPD.custom(0x55_u8, 0xAA_u8, 0, 9, 1_u8, 1_u8, 1_u8, 1_u8)
  ps_band(6, "FULL60", "55/AA ALL 10 GRP 1/1/1")
  tm[14] = ps_run(EPD::LUT_CUSTOM, 1)
  k = 8
  while k < 15
    log2("ps: band test / panel ms", k, tm[k])
    k = k &+ 1
  end
  Store.save_ps(tm)
  # -- results, refreshed only right of and below the bands --
  ps_results(tm)
  EPD.window(true, BAND_C1 &+ 1, EPD::ROW_BYTES &- 1, 0, PS_BANDS &* BAND_H &- 1)
  ps_run(EPD::LUT_BASE, 3)
  EPD.window(true, 0, EPD::ROW_BYTES &- 1, PS_BANDS &* BAND_H, EPD::HEIGHT &- 1)
  ps_run(EPD::LUT_BASE, 3)
  EPD.window(false)
  log("ps: done, waiting for a button", 0)
  ps_wait_button
end

def ps_name(k : Int32) : String
  k == 0 ? "BASE 1P" : (k == 1 ? "BASE 3P" : (k == 2 ? "N4" : (k == 3 ? "N10" : (k == 4 ? "N20" : (k == 5 ? "HALF60" : "FULL60")))))
end

# Times into the frame buffer: band times in the right column, the timing
# tests below the bands.
def ps_results(tm : Int32*) : Nil
  k = 0
  while k < PS_BANDS
    ps_text(636, k &* BAND_H &+ 24, "MS", tm[8 &+ k], 4)
    k = k &+ 1
  end
  y = PS_BANDS &* BAND_H &+ 8
  x = ps_text(12, y, "FULL", tm[0], 3)
  x = ps_text(x &+ 12, y, "WIN8", tm[1], 3)
  ps_text(x &+ 12, y, "HALFH", tm[2], 3)
  y = y &+ 34
  x = ps_text(12, y, "F60", tm[3], 3)
  x = ps_text(x &+ 12, y, "OSC11", tm[4], 3)
  ps_text(x &+ 12, y, "OSC12", tm[5], 3)
  y = y &+ 34
  draw_text(12, y, "ANY BUTTON: CONTINUE", EPD::BLACK, 3)
end

# Blocks until a button is pressed (and released).
def ps_wait_button : Nil
  Shared.take_buttons
  while Shared.take_buttons == 0_u32
    delay_ms(50)
  end
  while Shared.take_buttons != 0_u32
    delay_ms(50)
  end
end

# DIAG B: the last stored run's numbers (band names instead of the ink
# samples), one clean refresh, held until a button is pressed.
def ps_show_last : Nil
  tm = Shared.ps_times
  EPD.fill(EPD::WHITE)
  if Store.load_ps(tm)
    k = 0
    while k < PS_BANDS
      draw_text(12, k &* BAND_H &+ 28, ps_name(k), EPD::BLACK, 4)
      k = k &+ 1
    end
    ps_results(tm)
  else
    draw_text(40, 40, "NO STORED PANEL SPEED RUN", EPD::BLACK, 4)
  end
  EPD.keep_awake = true
  ps_run(EPD::LUT_BASE, 3)
  ps_wait_button
end

# ---- screens, NVS, previews ------------------------------------------------

lib LibIDF
  fun nvs_flash_init : Int32
  fun nvs_open(name : UInt8*, mode : Int32, handle : UInt32*) : Int32
  fun nvs_get_u8(h : UInt32, key : UInt8*, v : UInt8*) : Int32
  fun nvs_set_u8(h : UInt32, key : UInt8*, v : UInt8) : Int32
  fun nvs_commit(h : UInt32) : Int32
  fun nvs_set_blob(h : UInt32, key : UInt8*, v : Void*, n : UInt32) : Int32
  fun nvs_get_blob(h : UInt32, key : UInt8*, v : Void*, n : UInt32*) : Int32
end

SCR_NAMETAG  = 0
SCR_PORTRAIT = 1
SCR_SKETCH   = 2
SCR_LIFE     = 3
SCR_SNAKE    = 4
SCR_DIAG     = 5
SCR_COUNT    = 6
HOLD_MS      = 1000 # Sketch: hold User B this long for the colour refresh

module Store
  @@ok = false
  @@h = 0_u32

  # Opens NVS namespace "crystal". Never erases: the partition is shared with
  # the MicroPython firmware, so on any error the mode just isn't persisted.
  def self.open : Nil
    err = LibIDF.nvs_flash_init
    err = LibIDF.nvs_open("crystal".to_unsafe, 1, pointerof(@@h)) if err == 0
    @@ok = err == 0
    log("nvs: open err", err)
  end

  def self.screen : Int32
    return SCR_NAMETAG unless @@ok
    v = 0_u8
    return SCR_NAMETAG if LibIDF.nvs_get_u8(@@h, "screen".to_unsafe, pointerof(v)) != 0
    v.to_i32! < SCR_COUNT ? v.to_i32! : SCR_NAMETAG
  end

  # Panel-speed results: 16 x Int32.
  def self.save_ps(tm : Int32*) : Nil
    return unless @@ok
    err = LibIDF.nvs_set_blob(@@h, "ps".to_unsafe, tm.as(Void*), 64_u32)
    LibIDF.nvs_commit(@@h)
    log("nvs: save panel speed err", err)
  end

  def self.load_ps(tm : Int32*) : Bool
    return false unless @@ok
    n = 64_u32
    LibIDF.nvs_get_blob(@@h, "ps".to_unsafe, tm.as(Void*), pointerof(n)) == 0 && n == 64
  end

  def self.screen=(v : Int32) : Nil
    return unless @@ok
    LibIDF.nvs_set_u8(@@h, "screen".to_unsafe, v.to_u8!)
    LibIDF.nvs_commit(@@h)
  end
end

def menu_mode_for(scr : Int32) : Int32
  if scr == SCR_SKETCH
    Menu::SKETCH
  elsif scr == SCR_LIFE
    Menu::LIFE
  elsif scr == SCR_SNAKE
    Menu::SNAKE
  else
    Menu::NAMETAG
  end
end

# Red pixels -> 50% checker in the black plane; red plane cleared. A fast
# black/white refresh can then show a colour image without driving red.
def red_to_checker : Nil
  bk = EPD.black
  rd = EPD.red
  i = 0
  while i < EPD::PLANE
    r = rd[i]
    if r != 0_u8
      mask = (i.unsafe_div(EPD::ROW_BYTES) & 1) == 0 ? 0xAA_u8 : 0x55_u8
      bk[i] = bk[i] | (r & mask)
      rd[i] = 0_u8
    end
    i = i &+ 1
  end
end

def draw_nametag_planes : Nil
  EPD.fill(EPD::WHITE)
  ok = PNG.draw(LibIDF.cr_hello_png, LibIDF.cr_hello_png_size, EPD.black, EPD.red, 0, 0, true)
  draw_pattern(0, true) unless ok
  draw_name("Jason", "Kridner")
end

def draw_portrait_planes : Nil
  EPD.fill(EPD::WHITE)
  ok = PNG.draw(LibIDF.cr_portrait_png, LibIDF.cr_portrait_png_size, EPD.black, EPD.red, 0, 0, true)
  draw_pattern(0, true) unless ok
end

# Fast black/white refresh of the planes (red already folded into black).
# pulls = 3 with the base LUT at boot, to pull down red left on the panel.
def fast_bw(pulls : Int32, kind : Int32) : Nil
  EPD.raw = true # red plane is empty; raw only skips the red-as-ink path
  EPD.fast_pulls = pulls
  EPD.refresh(true, kind)
  EPD.raw = false
end

# Slow full-colour refresh that a Menu press can abort.
def colour_refresh : Bool
  EPD.abortable = true
  ok = EPD.refresh(false)
  aborted = EPD.aborted?
  EPD.abortable = false
  log2("main: colour refresh ok / aborted", ok ? 1 : 0, aborted ? 1 : 0)
  ok
end

SK_WINDOWED = true # Sketch ink updates refresh only the changed box (DUW+DRFW)

module SkState
  @@colour = false # the red frame is on the panel (keep-red frames)
  @@shown = Pointer(UInt8).null # black plane as last sent to the panel
  @@box = Pointer(Int32).null   # r0, r1, c0, c1 of the last diff
  @@last_lat = 0                # input -> ink on panel, last incremental frame

  def self.last_lat : Int32
    @@last_lat
  end

  def self.last_lat=(v : Int32) : Nil
    @@last_lat = v
  end

  def self.shown : UInt8*
    @@shown = LibIDF.heap_caps_malloc(EPD::PLANE.to_u32!, 0x404_u32).as(UInt8*) if @@shown.null?
    @@shown
  end

  def self.box : Int32*
    @@box = EPD.dma_alloc(16).as(Int32*) if @@box.null?
    @@box
  end

  # Remember the planes as shown (after any full Sketch refresh).
  def self.mark_shown : Nil
    sh = shown
    bk = EPD.black
    i = 0
    while i < EPD::PLANE
      sh[i] = bk[i]
      i = i &+ 1
    end
  end

  # Bounding box (rows, byte columns) of black-plane bytes that differ from
  # what is shown; copies them into `shown`. False if nothing changed.
  def self.diff : Bool
    sh = shown
    bk = EPD.black
    r0 = EPD::HEIGHT
    r1 = -1
    c0 = EPD::ROW_BYTES
    c1 = -1
    row = 0
    i = 0
    while row < EPD::HEIGHT
      col = 0
      while col < EPD::ROW_BYTES
        v = bk[i]
        if v != sh[i]
          sh[i] = v
          r0 = row if row < r0
          r1 = row
          c0 = col if col < c0
          c1 = col if col > c1
        end
        col = col &+ 1
        i = i &+ 1
      end
      row = row &+ 1
    end
    b = box
    b[0] = r0
    b[1] = r1
    b[2] = c0
    b[3] = c1
    r1 >= 0
  end

  def self.colour? : Bool
    @@colour
  end

  def self.colour=(v : Bool) : Nil
    @@colour = v
  end
end

# Sketch frame in preview (B/W) mode: frame red as checker, normal fast LUT.
def sketch_frame_bw(wait : Int32, up : Int32, panel : Int32, total : Int32) : Nil
  if Menu.needs_background?
    sketch_background
    red_to_checker
  end
  Menu.render(EPD.black, EPD.red)
  red_to_checker # render may touch red; keep the red plane empty
  draw_sketch_label(wait, up, panel, total)
  Shared.led_mode = LED_CYAN
  if Menu.want_clean?
    EPD.raw = true
    sketch_clean
    EPD.raw = false
  else
    fast_bw(1, GAME_LUT)
  end
end

# Sketch colour: redraw the frame with red, overlay the drawing, slow refresh.
def sketch_colour : Nil
  sketch_background
  Sketch.render(EPD.black, EPD.red)
  SkState.colour = colour_refresh
  SkState.mark_shown
end

# Shows a screen on entry: always a fast black/white frame.
def enter_screen(scr : Int32, boot : Bool) : Nil
  pulls = boot ? 3 : 1
  kind = boot ? EPD::LUT_BASE : GAME_LUT
  log2("main: screen / boot", scr, boot ? 1 : 0)
  if scr == SCR_NAMETAG
    draw_nametag_planes
    red_to_checker
    fast_bw(pulls, kind)
  elsif scr == SCR_PORTRAIT
    draw_portrait_planes
    red_to_checker
    fast_bw(pulls, kind)
  elsif scr == SCR_DIAG
    show_diag
  else
    Menu.enter(menu_mode_for(scr))
    SkState.colour = false
    if scr == SCR_SKETCH
      sketch_background
      Menu.render(EPD.black, EPD.red)
      red_to_checker
      draw_sketch_label(SkState.last_lat, EPD.upload_ms, EPD.panel_ms, 0)
    else
      Menu.render(EPD.black, EPD.red)
      draw_mode_label(Menu.mode, 0, 0, 0, 0)
    end
    fast_bw(pulls, kind)
    SkState.mark_shown if scr == SCR_SKETCH
  end
end

fun crystal_app_main : Void
  led_test
  Store.open
  log("main: EPD, SPI Hz", SPI_HZ)
  t = millis
  unless EPD.init(SPI_HZ)
    log("main: EPD init failed", 0)
    return
  end
  log("main: EPD init (incl. OTP probe) ms", millis &- t)

  speed_test if SPEED_TEST
  lut_probe if LUT_PROBE
  lut_timing if LUT_TIMING
  panel_speed if PANEL_SPEED

  # Browsing never waits for the slow waveform: no red-clearing promotion.
  EPD.promote = false
  EPD.keep_awake = true
  Menu.init(Menu::NAMETAG)
  scr = Store.screen
  enter_screen(scr, true)

  prev = 0_u32
  frames = 0
  last_total = 0
  last_wait = 0
  last_input = millis
  pl = Shared.mv_l
  pr = Shared.mv_r
  b_down = 0      # Sketch: when User B went down (0 = up)
  b_fired = false # Sketch: the hold already triggered the colour refresh
  while true
    held = Shared.take_buttons
    now = millis
    raw_held = held
    # Sketch: User B is short (clean, passed on at release) or held (colour).
    if scr == SCR_SKETCH
      inject = false
      if (held & Games::BTN_B) != 0_u32
        b_down = now if b_down == 0
        if !b_fired && now &- b_down >= HOLD_MS
          b_fired = true
          log("sketch: B held, colour refresh", 0)
          sketch_colour
        end
      elsif b_down != 0
        inject = !b_fired
        b_down = 0
        b_fired = false
      end
      held = held & (Games::BTN_B ^ 0xFFFFFFFF_u32)
      held = held | Games::BTN_B if inject
    end
    inp = Games.input(Shared.mv_l, Shared.mv_r, held, prev)
    prev = held
    dl = Shared.mv_l &- pl
    dr = Shared.mv_r &- pr
    if dl > 15 || dl < -15 || dr > 15 || dr < -15 || raw_held != 0_u32
      last_input = now
      pl = Shared.mv_l
      pr = Shared.mv_r
    end

    plus = Games.pressed?(inp, Games::BTN_PLUS)
    minus = Games.pressed?(inp, Games::BTN_MINUS)
    if plus || minus
      scr = plus ? (scr &+ 1 == SCR_COUNT ? 0 : scr &+ 1) : (scr == 0 ? SCR_COUNT &- 1 : scr &- 1)
      Store.screen = scr
      frames = 0
      t = millis
      enter_screen(scr, false)
      last_total = millis &- t
      log2("main: screen / entry ms", scr, last_total)
    elsif scr == SCR_NAMETAG || scr == SCR_PORTRAIT
      if Games.pressed?(inp, Games::BTN_A)
        if scr == SCR_NAMETAG
          draw_nametag_planes
        else
          draw_portrait_planes
        end
        colour_refresh
      end
    elsif scr == SCR_DIAG
      if Games.pressed?(inp, Games::BTN_A)
        panel_speed
      elsif Games.pressed?(inp, Games::BTN_B)
        ps_show_last
        show_diag
      end
    elsif scr == SCR_SKETCH
      ticked = Menu.tick(now, inp)
      if ticked && (Menu.needs_background? || Sketch.want_clean?)
        # Erase / clean / background: the full path, then remember the planes.
        t = millis
        lw = last_wait
        last_wait = millis &- last_input
        lat = SkState.last_lat
        if SkState.colour?
          sketch_frame(false, lat, EPD.upload_ms, EPD.panel_ms, last_total)
        else
          sketch_frame_bw(lat, EPD.upload_ms, EPD.panel_ms, last_total)
        end
        SkState.mark_shown
        last_total = millis &- t
      else
        # Live ink: render, diff against what is shown, refresh that box now.
        Menu.render(EPD.black, EPD.red)
        red_to_checker unless SkState.colour?
        if SkState.diff
          b = SkState.box
          t = millis
          Shared.led_mode = LED_CYAN
          kind = SkState.colour? ? EPD::LUT_NOSHAKE_KEEPRED : GAME_LUT
          EPD.fast_pulls = 1
          if SK_WINDOWED
            EPD.refresh_window(b[2], b[3], b[0], b[1], kind)
          else
            EPD.raw = true
            EPD.refresh(true, kind)
            EPD.raw = false
          end
          last_total = millis &- t
          SkState.last_lat = millis &- last_input
          log2("sketch: ink rows / latency ms", b[1] &- b[0] &+ 1, SkState.last_lat)
        end
      end
    elsif Menu.tick(now, inp)
      t = millis
      lw = last_wait
      last_wait = millis &- last_input
      if scr == SCR_SKETCH
        if SkState.colour?
          sketch_frame(false, lw, EPD.upload_ms, EPD.panel_ms, last_total)
        else
          sketch_frame_bw(lw, EPD.upload_ms, EPD.panel_ms, last_total)
        end
      else
        Menu.render(EPD.black, EPD.red)
        clean = frames >= CLEAN_EVERY
        frames = clean ? 0 : frames &+ 1
        draw_mode_label(Menu.mode, lw, EPD.upload_ms, EPD.panel_ms, last_total)
        EPD.fast_pulls = clean ? 3 : GAME_PULLS
        EPD.refresh(true, clean ? EPD::LUT_BASE : GAME_LUT)
      end
      last_total = millis &- t
      log2("main: screen / frame ms", scr, last_total)
    end
    if scr == SCR_SKETCH
      Shared.led_mode = Sketch.dirty? ? LED_YELLOW : LED_GREEN
    else
      Shared.led_mode = 0
    end
    delay_ms(20)
  end
end
