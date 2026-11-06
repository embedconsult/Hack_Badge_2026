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
end

require "./epd"
require "./png"

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

fun crystal_knob_task(arg : Void*) : Void
  LibIDF.gpio_reset_pin(STATUS_LED)
  LibIDF.gpio_set_direction(STATUS_LED, GPIO_MODE_OUTPUT)

  unit_cfg = LibIDF::AdcOneshotUnitInitCfg.new
  unit_cfg.unit_id = ADC_UNIT_1
  adc = uninitialized Void*
  LibIDF.adc_oneshot_new_unit(pointerof(unit_cfg), pointerof(adc))
  cal_l = knob_channel(adc, KNOB_LEFT_CH)
  cal_r = knob_channel(adc, KNOB_RIGHT_CH)

  on = false
  raw = 0
  raw_r = 0
  last_log = millis
  while true
    on = !on
    LibIDF.gpio_set_level(STATUS_LED, on ? 0_u32 : 1_u32) # active low
    LibIDF.adc_oneshot_read(adc, KNOB_LEFT_CH, pointerof(raw))
    raw = 0 if raw < 0
    if millis &- last_log >= 1000
      last_log = millis
      LibIDF.adc_oneshot_read(adc, KNOB_RIGHT_CH, pointerof(raw_r))
      log2("knob: left GPIO2 raw / mV", raw, knob_mv(cal_l, raw))
      log2("knob: right GPIO7 raw / mV", raw_r, knob_mv(cal_r, raw_r))
    end
    half_period = MIN_MS &+ (raw.to_u32! &* 950_u32).unsafe_div(4095_u32)
    LibIDF.vTaskDelay(ms_to_ticks(half_period))
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

SPI_HZ = 20_000_000

fun crystal_app_main : Void
  log("main: EPD demo, SPI Hz", SPI_HZ)
  t = millis
  unless EPD.init(SPI_HZ)
    log("main: EPD init failed", 0)
    return
  end
  log("main: EPD init (incl. OTP probe) ms", millis &- t)

  # Decode the embedded PNG (960x672, red/white palette) straight into the
  # planes, then one slow refresh (red needs the panel's own waveform).
  EPD.fill(EPD::WHITE)
  t = millis
  ok = PNG.draw(LibIDF.cr_hello_png, LibIDF.cr_hello_png_size, EPD.black, EPD.red, 0, 0, true)
  log2("main: png decode ms / bytes", millis &- t, LibIDF.cr_hello_png_size)
  log2("main: png size", PNG.width, PNG.height)
  unless ok
    log("main: png error code", PNG.err)
    draw_pattern(0, true)
  end
  t = millis
  draw_name("Jason", "Kridner")
  log("main: name draw ms", millis &- t)
  EPD.refresh(false)
  log("main: image on the panel at ms since boot", millis)
end
