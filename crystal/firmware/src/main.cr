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
  fun cr_version : UInt8* # "<git describe> <HH:MM>" (main/version.h)
  fun cr_atomic_or(p : UInt32*, v : UInt32) : UInt32
  fun cr_atomic_xchg(p : UInt32*, v : UInt32) : UInt32
  fun cr_notify_main : Void
  fun cr_wait_notify(ms : UInt32) : UInt32
  fun cr_stack_free(main_task : Bool) : UInt32 # bytes never used (high-water mark)
  fun cr_stack_free_self : UInt32
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
# Our own game_alloc (instead of games/badge.cr's newlib malloc): every
# large buffer comes from the same heap_caps allocator (PSRAM, 8-bit), so
# allocations can be audited together (see SkState.check_overlap).
def game_alloc(n : Int32) : UInt8*
  p = LibIDF.heap_caps_malloc(n.to_u32!, 0x404_u32).as(UInt8*) # SPIRAM | 8BIT
  p = LibIDF.heap_caps_malloc(n.to_u32!, 0x4_u32).as(UInt8*) if p.null?
  log2("game_alloc: bytes / addr low 24 bits", n, (p.address & 0xFFFFFF_u64).to_i32!)
  p
end
require "./games/menu"
require "./shell"
require "./ota"
require "./net"
require "./apps/app"
require "./apps/*"

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
LOOP_MS     =   15 # knob/button sampling period
KNOB_WAKE_MV =  15 # knob change that wakes the main task
LED_YELLOW  =    1
LED_GREEN   =    2
LED_CYAN    =    3
BAR_GPIO    =   38 # 8-LED WS2812 bar along the top edge
BAR_SHIFT   =    3 # brightness: colour >> 3

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
    LibIDF.cr_atomic_or(pointerof(@@latched), held)
  end

  # Buttons held now or at any poll since the last call (atomic swap, so a
  # press latched by the knob task between read and clear is not lost).
  def self.take_buttons : UInt32
    LibIDF.cr_atomic_xchg(pointerof(@@latched), 0_u32) | @@held
  end

  def self.disable_leds : Nil
    @@leds_ready = false
  end

  @@label = Pointer(UInt8).null
  @@times = Pointer(Int32).null

  def self.times_buf : Int32*
    @@times = EPD.dma_alloc(32).as(Int32*) if @@times.null?
    @@times
  end

  def self.label_buf : UInt8*
    @@label = EPD.dma_alloc(128) if @@label.null?
    @@label
  end

  # Right-knob LED: 0 = live hue from the knob, else a fixed status colour
  # (LED_YELLOW / LED_GREEN / LED_CYAN), as upstream Sketch does.
  @@led_mode = 0
  @@target = 0         # screen the user has asked for (knob task, on Menu edges)
  @@live = false       # Sketch: the main loop is idle and knob input draws NOW
  # Debug shell (shell.cr)
  @@ovr_l = -1         # knob override mV (-1 = real ADC)
  @@ovr_r = -1
  @@red_ink_plain = false # = SK_RED_INK_PLAIN, switchable at run time
  # Per-app update mode (UPD_*), shell `upd`, saved in NVS: Sketch ink,
  # Life frames, Snake frames.
  @@upd_sk = UPD_INK
  @@upd_li = UPD_DIFF
  @@upd_sn = UPD_DIFF
  @@req = 0_u32        # REQ_* bits for the main loop (atomic)
  @@sx0 = 0
  @@sy0 = 0
  @@sx1 = 0
  @@sy1 = 0
  REQ_HOLD_A = 1_u32
  REQ_CLEAN  = 2_u32
  REQ_STROKE = 4_u32
  REQ_QUICKDRAW = 16_u32 # (8 = REQ_REDRAW, src/net.cr)
  REQ_FORGET    = 32_u32 # knob override switched on/off: no pen jump

  def self.ovr_l : Int32
    @@ovr_l
  end

  def self.ovr_r : Int32
    @@ovr_r
  end

  def self.knob_ovr? : Bool
    @@ovr_l >= 0 || @@ovr_r >= 0
  end

  def self.knob_override(l : Int32, r : Int32) : Nil
    request(REQ_FORGET) if (l < 0) != (@@ovr_l < 0)
    @@ovr_l = l
    @@ovr_r = r
  end

  def self.red_ink_plain? : Bool
    @@red_ink_plain
  end

  def self.red_ink_plain=(v : Bool) : Nil
    @@red_ink_plain = v
  end

  def self.sk_win? : Bool
    @@upd_sk == UPD_WIN
  end

  # Old `flag SK_WIN`: 1 = windows, 0 = full.
  def self.sk_win=(v : Bool) : Nil
    @@upd_sk = v ? UPD_WIN : UPD_FULL
  end

  # Sketch ink pulls scan only the stroke's rows (flag INK_WIN). OFF: the
  # windowed RAM writes did not show and the window edges left seams
  # (camera, 7:5x); whole-panel ink pulls are clean.
  @@ink_win = false

  def self.ink_win? : Bool
    @@ink_win
  end

  def self.ink_win=(v : Bool) : Nil
    @@ink_win = v
  end

  def self.upd(app : Int32) : Int32
    app == SCR_SKETCH ? @@upd_sk : (app == SCR_LIFE ? @@upd_li : (app == SCR_SNAKE ? @@upd_sn : UPD_FULL))
  end

  def self.set_upd(app : Int32, m : Int32) : Nil
    if app == SCR_SKETCH
      @@upd_sk = m
    elsif app == SCR_LIFE
      @@upd_li = m
    elsif app == SCR_SNAKE
      @@upd_sn = m
    end
  end

  def self.inject_buttons(bits : UInt32) : Nil
    LibIDF.cr_atomic_or(pointerof(@@latched), bits)
  end

  def self.request(bits : UInt32) : Nil
    LibIDF.cr_atomic_or(pointerof(@@req), bits)
  end

  def self.take_requests : UInt32
    LibIDF.cr_atomic_xchg(pointerof(@@req), 0_u32)
  end

  def self.request_stroke(x0 : Int32, y0 : Int32, x1 : Int32, y1 : Int32) : Nil
    @@sx0 = x0
    @@sy0 = y0
    @@sx1 = x1
    @@sy1 = y1
    request(REQ_STROKE)
  end

  def self.sx0 : Int32
    @@sx0
  end

  def self.sy0 : Int32
    @@sy0
  end

  def self.sx1 : Int32
    @@sx1
  end

  def self.sy1 : Int32
    @@sy1
  end
  @@rendering = false  # main task is drawing a screen (LED indicator pulses)

  def self.target : Int32
    @@target
  end

  def self.target=(v : Int32) : Nil
    @@target = v
  end

  def self.rendering? : Bool
    @@rendering
  end

  def self.live? : Bool
    @@live
  end

  def self.live=(v : Bool) : Nil
    @@live = v
  end

  def self.rendering=(v : Bool) : Nil
    @@rendering = v
  end
  @@label_bytes = 0

  def self.label_bytes : Int32
    @@label_bytes
  end

  def self.label_bytes=(v : Int32) : Nil
    @@label_bytes = v
  end
  @@screen = 0

  def self.screen : Int32
    @@screen
  end

  def self.screen=(v : Int32) : Nil
    @@screen = v
  end

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

# Per-screen indicator colour (full scale; shown at 1/8 on the LEDs):
# NAMETAG red, PORTRAIT magenta, SKETCH yellow, LIFE green, SNAKE cyan,
# DIAG white.
def mode_rgb(m : Int32, rgb : UInt8*) : Nil
  c = Apps.rgb(m) # registry COLOR (src/apps/builtin.cr keeps the old ones)
  rgb[0] = c.unsafe_shr(16).to_u8!
  rgb[1] = c.unsafe_shr(8).to_u8!
  rgb[2] = c.to_u8!
end

# Next / previous app for Menu +/- inside an app (home not included).
def step_screen(tg : Int32, up : Bool) : Int32
  n = Apps.count
  return 0 if tg == SCR_HOME || tg < 0 || tg >= n
  up ? (tg &+ 1 == n ? 0 : tg &+ 1) : (tg == 0 ? n &- 1 : tg &- 1)
end

MENU_DEBOUNCE_MS = 150

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
  adc = Pointer(Void).null
  adc_err = LibIDF.adc_oneshot_new_unit(pointerof(unit_cfg), pointerof(adc))
  adc_ok = adc_err == 0
  log("knob: adc_oneshot_new_unit err (knobs read 0 if nonzero)", adc_err) unless adc_ok
  cal_l = adc_ok ? knob_channel(adc, KNOB_LEFT_CH) : Pointer(Void).null
  cal_r = adc_ok ? knob_channel(adc, KNOB_RIGHT_CH) : Pointer(Void).null

  EPD.in_pin(BTN_A_GPIO)
  EPD.in_pin(BTN_B_GPIO)
  EPD.in_pin(BTN_PLUS_GPIO)
  EPD.in_pin(BTN_MINUS_GPIO)
  buf_l = EPD.dma_alloc(4)
  buf_r = EPD.dma_alloc(4)
  rgb = EPD.dma_alloc(4)

  bar_ch = Pointer(Void).null
  bar_enc = Pointer(Void).null
  bar_ok = Pixel.open(BAR_GPIO, pointerof(bar_ch), pointerof(bar_enc))
  bar_buf = EPD.dma_alloc(24)
  bar_cols = EPD.dma_alloc(32).as(UInt32*)
  bar_scr = -1
  bar_key = -1   # last indicator frame sent (target * 2 + pulse phase)
  prev_btns = 0_u32
  last_menu = 0
  menu_first = 0    # Menu gesture: first button (+1 plus, -1 minus)
  menu_both = false # both Menu buttons were down together
  menu_t0 = 0
  log("knob: loop starting", 0)
  on = false
  raw_l = 0
  raw_r = 0
  woke_l = 0     # knob mV at the last wake-up of the main task
  woke_r = 0
  woke_btns = 0_u32
  now = millis
  last_log = now
  last_blink = now
  last_stack = now
  while true
    # Average ADC_SAMPLES reads per knob (Sketch's deadband assumes this).
    sum_l = 0
    sum_r = 0
    k = 0
    while adc_ok && k < Sketch::ADC_SAMPLES
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
    mv_l = Shared.ovr_l if Shared.ovr_l >= 0 # debug shell: knob <l|r> <mV>
    mv_r = Shared.ovr_r if Shared.ovr_r >= 0
    hue_l = mv_to_hue(mv_l, LEFT_MV_LO, LEFT_MV_HI)
    hue_r = mv_to_hue(mv_r, RIGHT_MV_LO, RIGHT_MV_HI)
    btns = read_buttons
    now_ms = millis
    # Menu edges move the target screen right away (the main task may be
    # busy rendering); it renders Shared.target when it gets to it.
    # A Menu gesture ends when both Menu buttons are up: if both were down
    # together at any point it goes home, else (in an app that does not
    # own the Menu buttons) one step to the next / previous app.
    menu = btns & (Games::BTN_PLUS | Games::BTN_MINUS)
    pmenu = prev_btns & (Games::BTN_PLUS | Games::BTN_MINUS)
    if menu != 0_u32 && pmenu == 0_u32
      menu_first = (menu & Games::BTN_PLUS) != 0_u32 ? 1 : -1
      menu_both = false
      menu_t0 = now_ms
    end
    menu_both = true if menu == (Games::BTN_PLUS | Games::BTN_MINUS)
    if menu_both && menu != 0_u32 && now_ms &- menu_t0 >= 0 && Shared.target != SCR_HOME
      Shared.target = SCR_HOME # both held: home right away (no need to let go)
      last_menu = now_ms
    end
    if menu == 0_u32 && pmenu != 0_u32
      tg = Shared.target
      if !menu_both && !Apps.owns_menu?(tg) && now_ms &- last_menu >= MENU_DEBOUNCE_MS
        Shared.target = step_screen(tg, menu_first > 0)
        last_menu = now_ms
      end
      menu_both = false
    end
    prev_btns = btns

    # ONE LED rule for the whole badge: only the bar LED at the current /
    # target screen's index is lit, in its mode colour; all others are off.
    # PULSING = busy (rendering, colour render, cleaning flash; input is
    # ignored). STEADY = ready (input accepted; in Sketch: knobs draw NOW).
    tgt = Shared.target
    led_id = tgt == SCR_HOME ? Home.sel : tgt # home: the selected app's LED
    working = Shared.rendering? || Shared.screen != tgt || EPD.busy? ||
              (tgt == SCR_SKETCH && !Shared.live?)
    pulse_dim = working && (now_ms.unsafe_div(250) & 1) == 1
    mode_rgb(led_id, rgb)
    shift = pulse_dim ? BAR_SHIFT &+ 3 : BAR_SHIFT
    ind_r = rgb[0].unsafe_shr(shift)
    ind_g = rgb[1].unsafe_shr(shift)
    ind_b = rgb[2].unsafe_shr(shift)
    if bar_ok
      key = led_id &* 2 &+ (pulse_dim ? 1 : 0)
      if key != bar_key
        Pixel.wait(bar_ch)
        i = 0
        while i < 8
          lit = i == (led_id & 7)
          bar_buf[i &* 3] = lit ? ind_g : 0_u8
          bar_buf[i &* 3 &+ 1] = lit ? ind_r : 0_u8
          bar_buf[i &* 3 &+ 2] = lit ? ind_b : 0_u8
          i = i &+ 1
        end
        if Pixel.show_bytes(bar_ch, bar_enc, bar_buf, 24) != 0
          log("led: bar rmt_transmit failed, bar disabled", 0)
          bar_ok = false
        end
        bar_key = key
      end
    end
    Shared.set_knobs(mv_l, mv_r, btns)
    LibIDF.cr_net_input(mv_l, mv_r, btns) # Pong paddle (main/net.c)
    # Wake the main loop on a button change or knob motion past the deadband.
    dl = mv_l &- woke_l
    dr = mv_r &- woke_r
    if btns != woke_btns || dl > KNOB_WAKE_MV || dl < 0 &- KNOB_WAKE_MV || dr > KNOB_WAKE_MV || dr < 0 &- KNOB_WAKE_MV
      woke_l = mv_l
      woke_r = mv_r
      woke_btns = btns
      LibIDF.cr_notify_main
    end
    # A Menu press aborts a slow (colour) refresh in progress.
    if (btns & (Games::BTN_PLUS | Games::BTN_MINUS)) != 0_u32 && EPD.abortable?
      EPD.request_abort
    end
    if Shared.leds_ready?
      err = 0
      unless Shared.ch_l.null?
        Pixel.hue(hue_l, LED_LEVEL, rgb)
        err = Pixel.show(Shared.ch_l, Shared.enc_l, buf_l, rgb[0], rgb[1], rgb[2])
      end
      lm = 0 # the knob LED follows the same rule as the bar: mode colour, pulse = busy
      if lm == LED_YELLOW
        rgb[0] = 48_u8; rgb[1] = 40_u8; rgb[2] = 0_u8
      elsif lm == LED_GREEN
        rgb[0] = 0_u8; rgb[1] = 48_u8; rgb[2] = 0_u8
      elsif lm == LED_CYAN
        rgb[0] = 0_u8; rgb[1] = 40_u8; rgb[2] = 48_u8
      else
        rgb[0] = ind_r # same colour (and pulse) as the bar's mode indicator
        rgb[1] = ind_g
        rgb[2] = ind_b
      end
      e2 = Pixel.show(Shared.ch_r, Shared.enc_r, buf_r, rgb[0], rgb[1], rgb[2])
      err = e2 if err == 0
      if err != 0
        log("led: knob pixel rmt_transmit failed, knob LEDs disabled", err)
        Shared.disable_leds
      end
    end

    now = millis
    half_period = 50 &+ (raw_l &* 950).unsafe_div(4095)
    if now &- last_blink >= half_period
      last_blink = now
      on = !on
      LibIDF.gpio_set_level(STATUS_LED, on ? 0_u32 : 1_u32) # active low
    end
    if now &- last_stack >= 10_000
      last_stack = now
      log2("stack: free bytes knob / main", LibIDF.cr_stack_free(false).to_i32!, LibIDF.cr_stack_free(true).to_i32!)
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
# LUT for windowed / live frames (Sketch ink, game frames and their cleans).
# HALF60 inks white -> solid black in one pull and leaves red alone (tables
# 2/3 ground), but erases black -> white weakly (ghosted text after a 3-pull
# white base, window test v5). If dead Life cells / the snake's tail stay
# grey, try EPD::LUT_NOSHAKE_BW here.
# Diagnostic: HALF60 (all groups minimal) is suspected of the row-repeat
# corruption seen with full-screen refreshes (000bd1e); back to the no-shake
# table that showed no corruption, to rule it in or out.
WIN_LUT     = EPD::LUT_NOSHAKE_BW
LUT_TIMING  = false # boot: time one pull of each fast LUT kind, show results on the panel
LUT_PROBE   = false # boot-time experiment: which (red, bw) pairs select which table

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
  help = m == Menu::LIFE ? "A: RESEED  B: PAUSE  KNOBS: DENSITY/SPEED" : (m == Menu::SNAKE ? "KNOB/B: TURN  A: RESTART" : "")
  hx = 8 &+ w &+ 16
  hw = help.bytesize &* 12
  hw = 0 if hx &+ hw > EPD::WIDTH # no room: label only
  EPD.fill_rect(0, 0, hx &+ hw &+ 8, LABEL_H, EPD::WHITE)
  draw_text(8, 8, name, EPD::BLACK, 4)
  draw_bytes(8 &+ name.bytesize &* 6 &* 4, 8, buf, n, EPD::BLACK, 4)
  draw_text(hx, 14, help, EPD::BLACK, 2) if hw > 0
  # restore_label keeps label and help strip on non-clean frames
  Shared.label_bytes = (hx &+ hw &+ 8 &+ 7).unsafe_div(8)
end

LABEL_H = 7 * 4 + 16

# Puts the label box back from what is shown, so a game frame that is not
# a clean one keeps the old label instead of changing those pixels.
def restore_label : Nil
  sh = SkState.shown
  bk = EPD.black
  wb = Shared.label_bytes
  wb = EPD::ROW_BYTES if wb > EPD::ROW_BYTES
  row = 0
  while row < LABEL_H
    i = row &* EPD::ROW_BYTES
    c = 0
    while c < wb
      bk[i &+ c] = sh[i &+ c]
      c = c &+ 1
    end
    row = row &+ 1
  end
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
def sketch_clean(kind : Int32) : Nil
  Shared.rendering = true # busy: LED pulses, input waits
  sketch_clean_frames(kind)
  Shared.rendering = false
end

def sketch_clean_frames(kind : Int32) : Nil
  save = SketchFx.save_buf
  i = 0
  while i < EPD::PLANE
    save[i] = EPD.black[i]
    i = i &+ 1
  end
  EPD.fast_pulls = 1
  EPD.fill_rect(SK_X0, SK_Y0, SK_W, SK_H, EPD::BLACK)
  EPD.refresh(true, kind)
  EPD.fill_rect(SK_X0, SK_Y0, SK_W, SK_H, EPD::WHITE)
  EPD.refresh(true, kind)
  i = 0
  while i < EPD::PLANE
    EPD.black[i] = save[i]
    i = i &+ 1
  end
  EPD.fast_pulls = 3
  EPD.refresh(true, kind)
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
  draw_sketch_label(wait, up, panel, total, true)
  Shared.led_mode = LED_CYAN
  if entry
    EPD.raw = false
    EPD.refresh(false)
  else
    EPD.raw = true
    if Menu.want_clean?
      sketch_clean(red_ink_kind) # red tables ground: the red frame is never driven
    else
      EPD.fast_pulls = 1
      EPD.refresh(true, red_ink_kind)
    end
    EPD.raw = false
  end
end

# "SK wait/upload/panel/total" inside the screen area (top-left), x3.
# Exact red-plane check: the red plane must equal the Etch background's red
# with the canvas ink cleared (colour frames), or be all zero (B/W frames).
# Returns the number of mismatching bytes; @@first_row gets the first one.
module RedCheck
  @@sb = Pointer(UInt8).null
  @@sr = Pointer(UInt8).null
  @@first_row = -1
  @@last = -1

  def self.last : Int32
    @@last
  end

  def self.first_row : Int32
    @@first_row
  end

  def self.run(colour : Bool) : Int32
    rd = EPD.red
    cv = Sketch.canvas
    @@first_row = -1
    if colour
      @@sb = LibIDF.heap_caps_malloc(EPD::PLANE.to_u32!, 0x404_u32).as(UInt8*) if @@sb.null?
      @@sr = LibIDF.heap_caps_malloc(EPD::PLANE.to_u32!, 0x404_u32).as(UInt8*) if @@sr.null?
      return -1 if @@sb.null? || @@sr.null?
      Sketch.prep_background(@@sb, @@sr)
      PNG.draw(LibIDF.cr_etch_png, LibIDF.cr_etch_png_size, @@sb, @@sr, 0, 0, false)
    end
    bad = 0
    i = 0
    while i < EPD::PLANE
      want = colour ? (@@sr[i] & (cv[i] ^ 0xFF_u8)) : 0_u8
      if rd[i] != want
        bad = bad &+ 1
        @@first_row = i.unsafe_div(EPD::ROW_BYTES) if @@first_row < 0
      end
      i = i &+ 1
    end
    log2("redcheck: mismatching red bytes / first row", bad, @@first_row)
    @@last = bad
    bad
  end
end

def draw_sketch_label(wait : Int32, up : Int32, panel : Int32, total : Int32, colour : Bool = false) : Nil
  # Nothing on screen (the version is in `status` and on DIAG); timings
  # go to the log.
  log2("sketch: last ink latency / panel ms", wait, panel)
end

# Asymmetric marker for the window test: 120x80 outline (6 px), a solid
# 32x32 square in its top-left corner and a bar along its bottom-right.
def window_marker(x : Int32, y : Int32) : Nil
  EPD.fill_rect(x, y, 120, 80, EPD::BLACK)
  EPD.fill_rect(x &+ 6, y &+ 6, 108, 68, EPD::WHITE)
  EPD.fill_rect(x &+ 6, y &+ 6, 32, 32, EPD::BLACK)
  EPD.fill_rect(x &+ 60, y &+ 58, 54, 16, EPD::BLACK)
end

# Seam test v10 (DIAG, User B). Sketch's windows leave thin full-width
# lines at their edges. White screen (full refresh, WIN_LUT, labels and edge
# ticks), then five white-on-white rows-only windows (mode 8, WIN_LUT, as
# Sketch ink), each run 3 times, nothing changes in the planes:
#   V1 rows 92..155   DRFW = DUW rows (as Sketch now)
#   V2 rows 212..275  DRFW end   +1 unit (4 rows past DUW)
#   V3 rows 332..395  DRFW start -1 unit
#   V4 rows 452..515  DRFW inside DUW by 1 unit each side
#   V5 rows 572..635  DRFW outside DUW by 1 unit each side
# The DUW rows of each band are marked by ticks at x 0..39 and 920..959,
# 4 rows OUTSIDE each edge (tick rows y0-6..y0-5 and y1+5..y1+6). The result
# stays on screen (no reference frame): photograph any time after.
WT_STEPS = 5

def wt_y(i : Int32) : Int32
  100 &+ i &* 120 # requested box top; padded by EPD to y-8 .. y+55
end

# Ink ladder (DIAG, User B): how short can the window ink waveform get?
# White base (full, WIN_LUT x3, labels), then one 16-row black bar per band
# (x 200..759, across the COG split), each drawn by a rows-only window with
# a different LUT: CUR = WIN_LUT (current Sketch ink, ~1160 ms full-screen
# pull), then WFAST (20-frame pull, ~475 ms full screen) with 19, 12, 8 and
# 5 black drive frames. Before each WFAST bar the COG is restarted with that LUT by a
# full refresh of an EMPTY black plane (paper is ground in WFAST: nothing on
# the panel moves). Panel ms logged per step; the result stays on screen.
LAD_STEPS = 5

def lad_y(i : Int32) : Int32
  90 &+ i &* 110
end

# WFAST drive frames (of the 20-frame pull) per ladder step 1..4.
def lad_frames(i : Int32) : Int32
  i == 1 ? 19 : (i == 2 ? 12 : (i == 3 ? 8 : 5))
end

# Ink command test (DIAG B): which RAM bit pattern drives what, and the
# pass ladder. White base (full, base LUT x3) with a black bar at row 420;
# then EPD.refresh_ink pulls on rows (x 200..759, 16 rows):
#   y 120: 0x10 = 1, 0x11 = 0 (one pull)    y 200: 0x10 = 1, 0x11 = 1 (one pull)
#   y 280: 0x10 = 0, 0x11 = 1 (one pull)    y 420: black bar, 0x10 = 0, 0x11 = 1
#   y 520: ladder, 5 segments of 112 px with 1..5 passes (first 0x10 only,
#          later both). Result stays on screen.
def ink_bar(p : UInt8*, x0 : Int32, x1 : Int32, y : Int32) : Nil
  Games.fill_rect(p, x0, y, x1 &- x0, 16)
end

def ink_test : Nil
  log("inktest: white base", 0)
  EPD.fill(EPD::WHITE)
  draw_text(40, 20, "INK COMMAND TEST", EPD::BLACK, 3)
  draw_text(40, 124, "N1 O0", EPD::BLACK, 2)
  draw_text(40, 204, "N1 O1", EPD::BLACK, 2)
  draw_text(40, 284, "N0 O1", EPD::BLACK, 2)
  draw_text(40, 424, "BLACK N0 O1", EPD::BLACK, 2)
  draw_text(40, 524, "PASSES 1-5", EPD::BLACK, 2)
  ink_bar(EPD.black, 200, 760, 420)
  fast_bw(3, EPD::LUT_BASE)
  return unless SkInk.ready?
  pn = LibIDF.heap_caps_malloc(EPD::PLANE.to_u32!, 0x404_u32).as(UInt8*)
  po = LibIDF.heap_caps_malloc(EPD::PLANE.to_u32!, 0x404_u32).as(UInt8*)
  return if pn.null? || po.null?
  Games.zero(pn, EPD::PLANE)
  Games.zero(po, EPD::PLANE)
  ink_bar(pn, 200, 760, 120)
  ink_bar(pn, 200, 760, 200)
  ink_bar(po, 200, 760, 200)
  ink_bar(po, 200, 760, 280)
  ink_bar(po, 200, 760, 420)
  ink_bar(pn, 200, 760, 520) # ladder pass 1: all five segments
  log("inktest: pull 1 ms", EPD.refresh_ink(pn, po))
  k = 2
  while k <= 5
    Games.zero(pn, EPD::PLANE)
    Games.zero(po, EPD::PLANE)
    x0 = 200 &+ (k &- 1) &* 112
    ink_bar(pn, x0, 760, 520)
    ink_bar(po, x0, 760, 520)
    log2("inktest: pass / ms", k, EPD.refresh_ink(pn, po))
    k = k &+ 1
  end
  LibIDF.heap_caps_free(pn.as(Void*))
  LibIDF.heap_caps_free(po.as(Void*))
  EPD.cog_stop
  log("inktest: done", 0)
end

def ink_ladder : Nil
  log("ladder: white base", 0)
  EPD.fill(EPD::WHITE)
  draw_text(40, 20, "INK LADDER: BAR DARKNESS PER LUT", EPD::BLACK, 3)
  draw_text(40, lad_y(0) &+ 20, "CUR", EPD::BLACK, 3)
  draw_text(40, lad_y(1) &+ 20, "F19", EPD::BLACK, 3)
  draw_text(40, lad_y(2) &+ 20, "F12", EPD::BLACK, 3)
  draw_text(40, lad_y(3) &+ 20, "F8", EPD::BLACK, 3)
  draw_text(40, lad_y(4) &+ 20, "F5", EPD::BLACK, 3)
  fast_bw(3, WIN_LUT)
  save = SketchFx.save_buf
  bk = EPD.black
  i = 0
  while i < LAD_STEPS
    y = lad_y(i)
    kind = WIN_LUT
    if i > 0
      kind = EPD::LUT_WFAST
      j = 0
      while j < EPD::PLANE
        save[j] = bk[j]
        bk[j] = 0_u8
        j = j &+ 1
      end
      EPD.cog_stop
      EPD.wfast(lad_frames(i))
      EPD.fast_pulls = 1
      EPD.raw = true
      EPD.refresh(true, kind)
      EPD.raw = false
      log2("ladder: step / full-screen WFAST pull ms", i &+ 1, EPD.panel_ms)
      j = 0
      while j < EPD::PLANE
        bk[j] = save[j]
        j = j &+ 1
      end
    end
    EPD.fill_rect(200, y &+ 20, 560, 16, EPD::BLACK)
    EPD.fast_pulls = 1
    t = millis
    EPD.refresh_window2(y &+ 20, y &+ 35, 0, EPD::HALF_BYTES &- 1, y &+ 20, y &+ 35, 0, EPD::HALF_BYTES &- 1, kind, 8)
    log2("ladder: step / window panel ms", i &+ 1, EPD.panel_ms)
    log2("ladder: step / window total ms (upload+panel)", i &+ 1, millis &- t)
    delay_ms(300)
    i = i &+ 1
  end
  EPD.cog_stop # next refresh reopens with its own LUT
  EPD.wfast(SK_INK_FRAMES)
  log("ladder: done, result stays on screen", 0)
end

def window_test : Nil
  log("wtest v10: seam test, white base", 0)
  EPD.fill(EPD::WHITE)
  draw_text(40, 20, "SEAM TEST V10: LINES AT BAND EDGES?", EPD::BLACK, 3)
  i = 0
  while i < WT_STEPS
    y0 = wt_y(i) &- 8
    y1 = wt_y(i) &+ 55
    EPD.fill_rect(0, y0 &- 6, 40, 2, EPD::BLACK)
    EPD.fill_rect(920, y0 &- 6, 40, 2, EPD::BLACK)
    EPD.fill_rect(0, y1 &+ 5, 40, 2, EPD::BLACK)
    EPD.fill_rect(920, y1 &+ 5, 40, 2, EPD::BLACK)
    i = i &+ 1
  end
  draw_text(60, wt_y(0) &+ 16, "V1 DRFW = DUW", EPD::BLACK, 3)
  draw_text(60, wt_y(1) &+ 16, "V2 DRFW END +4 ROWS", EPD::BLACK, 3)
  draw_text(60, wt_y(2) &+ 16, "V3 DRFW START -4 ROWS", EPD::BLACK, 3)
  draw_text(60, wt_y(3) &+ 16, "V4 DRFW INSIDE BY 4", EPD::BLACK, 3)
  draw_text(60, wt_y(4) &+ 16, "V5 DRFW OUTSIDE BY 4", EPD::BLACK, 3)
  fast_bw(3, WIN_LUT)
  i = 0
  while i < WT_STEPS
    y = wt_y(i)
    d0 = i == 2 || i == 4 ? -1 : (i == 3 ? 1 : 0)
    d1 = i == 1 || i == 4 ? 1 : (i == 3 ? -1 : 0)
    EPD.drfw_shift(d0, d1)
    r = 0
    while r < 3
      EPD.fast_pulls = 1
      EPD.refresh_window2(y, y &+ 47, 0, EPD::HALF_BYTES &- 1, y, y &+ 47, 0, EPD::HALF_BYTES &- 1, WIN_LUT, 8)
      log2("wtest v10: band / panel ms", i &+ 1, EPD.panel_ms)
      delay_ms(300)
      r = r &+ 1
    end
    i = i &+ 1
  end
  EPD.drfw_shift(0, 0)
  EPD.cog_stop # full COG re-init on the next refresh
  log("wtest v10: done, result stays on screen", 0)
end

# Build version (git describe + build time), 5x7 font x2, right-aligned to
# x_right with its top at y, on a white box.
def draw_version(x_right : Int32, y : Int32) : Nil
  v = LibIDF.cr_version
  n = 0
  while n < 40 && v[n] != 0_u8
    n = n &+ 1
  end
  w = n &* 12
  x = x_right &- w
  EPD.fill_rect(x &- 4, y &- 4, w &+ 8, 7 &* 2 &+ 8, EPD::WHITE)
  draw_bytes(x, y, v, n, EPD::BLACK, 2)
end

# "A: COLOR" hint, bottom-left of the B/W previews (x2 on a white box).
def draw_colour_hint : Nil
  EPD.fill_rect(4, EPD::HEIGHT &- 26, 36 &* 12 &+ 8, 7 &* 2 &+ 8, EPD::WHITE)
  draw_text(8, EPD::HEIGHT &- 22, "HOLD A: COLOR (AUTO 30S)  MENU: NEXT", EPD::BLACK, 2)
end

# DIAG mode help screen (fast refresh; the driver runs it slow if red is up).
def show_diag : Nil
  EPD.fill(EPD::WHITE)
  draw_text(40, 40, "DIAG", EPD::BLACK, 10)
  draw_version(EPD::WIDTH &- 12, 12)
  draw_text(40, 200, "A: LUT TIMING  HOLD A: CLEAN (SLOW)", EPD::BLACK, 4)
  draw_text(40, 260, "B: INK LADDER (~40 S)  HOLD B: UPDATE", EPD::BLACK, 4)
  draw_text(40, 320, "MENU +/-: LEAVE", EPD::BLACK, 4)
  draw_text(40, 370, "LED: STEADY = READY, PULSING = BUSY", EPD::BLACK, 3)
  draw_text(40, 420, "INK LADDER: CUR, F19, F12, F8, F5. RESULT", EPD::BLACK, 3)
  draw_text(40, 460, "STAYS ON SCREEN", EPD::BLACK, 3)
  EPD.fast_pulls = 3
  EPD.raw = true
  EPD.refresh(true, EPD::LUT_BASE) # static screen: clean (shaking) preview
  EPD.raw = false
end

# One 1-pull refresh with each fast LUT kind on alternating frames; the panel
# busy times are then drawn on the panel and logged.
def lut_timing : Nil
  EPD.keep_awake = true
  EPD.fast_pulls = 1
  times = Shared.times_buf
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

# ---- screens, NVS, previews ------------------------------------------------

lib LibIDF
  fun nvs_flash_init : Int32
  fun nvs_open(name : UInt8*, mode : Int32, handle : UInt32*) : Int32
  fun nvs_get_u8(h : UInt32, key : UInt8*, v : UInt8*) : Int32
  fun nvs_set_u8(h : UInt32, key : UInt8*, v : UInt8) : Int32
  fun nvs_commit(h : UInt32) : Int32
  fun nvs_get_u32(h : UInt32, key : UInt8*, v : UInt32*) : Int32
  fun nvs_set_u32(h : UInt32, key : UInt8*, v : UInt32) : Int32
  fun esp_reset_reason : Int32
end

SCR_NAMETAG  = 0
SCR_PORTRAIT = 1
SCR_SKETCH   = 2
SCR_LIFE     = 3
SCR_SNAKE    = 4
SCR_DIAG     = 5
SCR_LINK     = 6 # src/net.cr
SCR_PONG     = 7
SCR_COUNT    = 8 # built-ins; all apps: Apps.count (src/apps/app.cr)

# Partial-update modes (per app, `upd` in the shell).
UPD_FULL    = 0 # full-screen fast refresh (WIN_LUT)
UPD_WIN     = 1 # rows-only window (EPD.refresh_window2 mode 8)
UPD_DIFF    = 2 # whole-panel differential (EPD.refresh_diff, yigitabi5444)
UPD_DIFFWIN = 3 # differential, DRFW rows 0 .. last changed row
UPD_INK     = 4 # Sketch: ink commands with incremental strength (SkInk)
UPD_COUNT   = 5
HOLD_MS      = 1000 # hold User A this long for the colour refresh
AUTO_COLOUR_MS = 30_000 # NAMETAG/PORTRAIT/SKETCH: colour refresh after this long idle

# Fast LUT for frames over Sketch's red frame: red tables must be ground so
# the red is never driven. HALF60 already is; otherwise the no-shake keep-red.
SK_RED_INK_PLAIN = false # experiment default; run time: Shared.red_ink_plain (shell flag)
def red_ink_kind : Int32
  return EPD::LUT_NOSHAKE_BW if Shared.red_ink_plain?
  WIN_LUT == EPD::LUT_HALF60 ? EPD::LUT_HALF60 : EPD::LUT_NOSHAKE_KEEPRED
end

SK_HINT_Y = Sketch::Y_MAX - 16 # help strip text top (rows 506..519)
QD_HOLD_MS = 2000 # Sketch: hold B this long for Quick draw
SK_INK_FRAMES = 19 # WFAST black drive frames (of 20) for Sketch window ink
SK_INK_WFAST  = false # WFAST windows copy ink ~336 rows lower: keep OFF (DIAG B only)

# Help strip at the bottom of Sketch's white area; `ready` adds the
# "READY" line (entry frame only, removed on the first stroke).
def draw_sketch_hint(ready : Bool) : Nil
  # One small centred line at the bottom of the white screen; the pen
  # stays above it (Sketch::PEN_Y_MAX). `ready` is no longer drawn.
  EPD.fill_rect(Sketch::X_MIN, SK_HINT_Y &- 4, Sketch::X_MAX &- Sketch::X_MIN, 7 &* 2 &+ 6, EPD::WHITE)
  t = "A: ERASE   B: CLEAN   HOLD A: COLOR   HOLD B: QUICK DRAW"
  x = Sketch::X_MIN &+ (Sketch::X_MAX &- Sketch::X_MIN &- t.bytesize &* 12).unsafe_div(2)
  draw_text(x, SK_HINT_Y, t, EPD::BLACK, 2)
end

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
    # Boot diagnostics: reset reason (esp_reset_reason_t: 1 power-on,
    # 3 software, 4 panic, 5 int WDT, 6 task WDT, 7 other WDT, 9 brownout,
    # 11 USB, 12 JTAG) and a boot counter kept in NVS.
    @@reset_reason = LibIDF.esp_reset_reason
    if @@ok
      c = 0_u32
      LibIDF.nvs_get_u32(@@h, "boots".to_unsafe, pointerof(c))
      c = c &+ 1
      LibIDF.nvs_set_u32(@@h, "boots".to_unsafe, c)
      LibIDF.nvs_commit(@@h)
      load_upd(SCR_SKETCH, "upd_sk")
      load_upd(SCR_LIFE, "upd_li")
      load_upd(SCR_SNAKE, "upd_sn")
      @@boots = c.to_i32!
    end
    @@saved_sk = Shared.upd(SCR_SKETCH)
    @@saved_li = Shared.upd(SCR_LIFE)
    @@saved_sn = Shared.upd(SCR_SNAKE)
    LibIDF.cr_log3("boot: count / reset reason / -".to_unsafe, @@boots, @@reset_reason, 0)
    LibIDF.cr_log3("boot: upd sketch / life / snake".to_unsafe, @@saved_sk, @@saved_li, @@saved_sn)
  end

  @@reset_reason = 0
  @@boots = 0
  @@saved_sk = UPD_INK # values last stored in NVS
  @@saved_li = UPD_DIFF
  @@saved_sn = UPD_DIFF

  def self.load_upd(app : Int32, key : String) : Nil
    v = 0xFF_u8
    return if LibIDF.nvs_get_u8(@@h, key.to_unsafe, pointerof(v)) != 0
    Shared.set_upd(app, v.to_i32!) if v.to_i32! < UPD_COUNT
  end

  def self.save_upd(key : String, v : Int32) : Nil
    return unless @@ok
    LibIDF.nvs_set_u8(@@h, key.to_unsafe, v.to_u8!)
    LibIDF.nvs_commit(@@h)
    log("nvs: update mode saved", v)
  end

  def self.reset_reason : Int32
    @@reset_reason
  end

  def self.boots : Int32
    @@boots
  end

  # Main loop: persist update modes the shell changed (NVS writes stay off
  # the small shell stack).
  def self.sync_upd : Nil
    v = Shared.upd(SCR_SKETCH)
    if v != @@saved_sk
      @@saved_sk = v
      save_upd("upd_sk", v)
    end
    v = Shared.upd(SCR_LIFE)
    if v != @@saved_li
      @@saved_li = v
      save_upd("upd_li", v)
    end
    v = Shared.upd(SCR_SNAKE)
    if v != @@saved_sn
      @@saved_sn = v
      save_upd("upd_sn", v)
    end
  end

  def self.screen : Int32
    return SCR_NAMETAG unless @@ok
    v = 0_u8
    return SCR_NAMETAG if LibIDF.nvs_get_u8(@@h, "screen".to_unsafe, pointerof(v)) != 0
    v.to_i32! < Apps.count || v.to_i32! == SCR_HOME ? v.to_i32! : SCR_NAMETAG
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

# Red pixels -> solid black, red plane cleared: Sketch's Etch frame (red and
# white only) becomes a clean black-and-white design for fast refreshes.
def red_to_black : Nil
  bk = EPD.black.as(UInt32*)
  rd = EPD.red.as(UInt32*)
  i = 0
  while i < EPD::PLANE.unsafe_div(4)
    r = rd[i]
    if r != 0_u32
      bk[i] = bk[i] | r
      rd[i] = 0_u32
    end
    i = i &+ 1
  end
end

def draw_nametag_planes : Nil
  EPD.fill(EPD::WHITE)
  ok = PNG.draw(LibIDF.cr_hello_png, LibIDF.cr_hello_png_size, EPD.black, EPD.red, 0, 0, true)
  draw_pattern(0, true) unless ok
  draw_name_net # src/net.cr: `text first|last`
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
  Shared.rendering = true
  EPD.abortable = true
  ok = EPD.refresh(false)
  aborted = EPD.aborted?
  EPD.abortable = false
  Shared.rendering = false
  log2("main: colour refresh ok / aborted", ok ? 1 : 0, aborted ? 1 : 0)
  ok
end

SK_WINDOWED   = false # Sketch ink: windowed refresh (EPD::WIN_MODE) - experimental, keep OFF
GAME_WINDOWED = false # same for Life / Snake frames - experimental, keep OFF

# Etch-a-Sketch ink with incremental line strength (UPD_INK): every pass of
# the pen over a pixel darkens it one step, like aluminium powder scraped
# off the glass again. A pass counter per pixel (PSRAM) picks the command
# for each covered pixel: first pass = EPD ink command 1 (light), later
# passes = command 3 (a step darker), up to INK_CAP passes; every other
# pixel gets no drive at all (EPD.refresh_ink).
INK_CAP = 5

module SkInk
  @@pass = Pointer(UInt8).null # one byte per pixel: passes so far
  @@cnew = Pointer(UInt8).null # command planes for the next pull
  @@cold = Pointer(UInt8).null
  @@lo = 0 # byte range of the command planes in use (to clear after)
  @@hi = -1

  def self.ready? : Bool
    if @@pass.null?
      @@pass = LibIDF.heap_caps_malloc((EPD::PLANE &* 8).to_u32!, 0x404_u32).as(UInt8*)
      @@cnew = LibIDF.heap_caps_malloc(EPD::PLANE.to_u32!, 0x404_u32).as(UInt8*)
      @@cold = LibIDF.heap_caps_malloc(EPD::PLANE.to_u32!, 0x404_u32).as(UInt8*)
      return false if @@pass.null? || @@cnew.null? || @@cold.null?
      Games.zero(@@cnew, EPD::PLANE)
      Games.zero(@@cold, EPD::PLANE)
      @@hi = -1
    end
    !@@pass.null? && !@@cnew.null? && !@@cold.null?
  end

  # After a full refresh: what the canvas shows is solid black (full
  # passes), the rest has none; pending touches are dropped.
  def self.sync_from_canvas : Nil
    return unless ready?
    @@pw0 = -1
    cv = Sketch.canvas
    tc = Sketch.touch
    i = 0
    while i < EPD::PLANE
      v = cv[i]
      q = @@pass + (i &* 8).to_i64!
      if v == 0_u8
        k = 0
        while k < 8
          q[k] = 0_u8
          k = k &+ 1
        end
      else
        k = 0
        while k < 8
          q[k] = (v & 0x80_u8.unsafe_shr(k)) != 0_u8 ? INK_CAP.to_u8! : 0_u8
          k = k &+ 1
        end
      end
      tc[i] = 0_u8 unless tc.null?
      i = i &+ 1
    end
  end

  # Marks byte i of the command planes as used.
  def self.use(i : Int32) : Nil
    @@lo = i if @@hi < 0 || i < @@lo
    @@hi = i if i > @@hi
  end

  # Pixels that just turned white in the black plane (before -> after) get
  # the lighten command (e.g. the help line removed with the first stroke).
  def self.lighten(i : Int32, before : UInt8, after : UInt8) : Nil
    return unless ready?
    m = before & (after ^ 0xFF_u8)
    return if m == 0_u8
    @@cold[i] = @@cold[i] | m
    @@cnew[i] = @@cnew[i] & (m ^ 0xFF_u8)
    use(i)
  end

  # Takes the pen's touches: pass counters up, ink commands set, black
  # plane updated. True if there is something to drive.
  def self.take_touches : Bool
    return false unless ready?
    tc = Sketch.touch
    bk = EPD.black
    rd = EPD.red
    any = @@hi >= 0
    i = 0
    while i < EPD::PLANE
      t = tc[i]
      if t != 0_u8
        tc[i] = 0_u8
        n = @@cnew[i]
        o = @@cold[i]
        q = @@pass + (i &* 8).to_i64!
        k = 0
        while k < 8
          m = 0x80_u8.unsafe_shr(k)
          if (t & m) != 0_u8
            c = q[k]
            if c == 0_u8
              n = n | m
            elsif c < INK_CAP.to_u8!
              n = n | m
              o = o | m
            end
            q[k] = c &+ 1 if c < INK_CAP.to_u8!
          end
          k = k &+ 1
        end
        if n != @@cnew[i] || o != @@cold[i]
          @@cnew[i] = n
          @@cold[i] = o
          use(i)
          any = true
        end
        bk[i] = bk[i] | t
        rd[i] = rd[i] & (t ^ 0xFF_u8)
      end
      i = i &+ 1
    end
    any
  end

  @@pw0 = -1 # rows of the previous windowed pull (both RAMs hold them)
  @@pw1 = -1

  # One ink pull with the pending commands, then the planes are cleared.
  # INK_WIN: only the command rows are written and scanned; the previous
  # window's rows are rewritten too (zeros there now).
  def self.pull : Int32
    rc = 0
    if Shared.ink_win? && @@hi >= 0
      u = EPD::WIN_Y_UNIT
      y0 = @@lo.unsafe_div(EPD::ROW_BYTES).unsafe_div(u) &* u
      y1 = @@hi.unsafe_div(EPD::ROW_BYTES).unsafe_div(u) &* u &+ u &- 1
      y1 = EPD::HEIGHT &- 1 if y1 > EPD::HEIGHT &- 1
      w0 = y0
      w1 = y1
      if @@pw0 >= 0
        w0 = @@pw0 if @@pw0 < w0
        w1 = @@pw1 if @@pw1 > w1
      end
      rc = EPD.refresh_ink_rows(@@cnew, @@cold, y0, y1, w0, w1)
      @@pw0 = y0
      @@pw1 = y1
      log3("sketch: ink window rows y0 / y1 / written rows", y0, y1, w1 &- w0 &+ 1)
    else
      rc = EPD.refresh_ink(@@cnew, @@cold)
      @@pw0 = -1
    end
    if @@hi >= 0
      i = @@lo
      while i <= @@hi
        @@cnew[i] = 0_u8
        @@cold[i] = 0_u8
        i = i &+ 1
      end
    end
    @@hi = -1
    rc
  end
end

# EPD busy hook: while an ink pull runs (~0.6 s) the pen keeps following
# the knobs every knob-task sample, so the next pull draws the path the
# knobs took (curves stay curves) instead of one straight chord.
module SkTrack
  @@ml = -1
  @@mr = -1

  def self.reset : Nil
    @@ml = -1
    @@mr = -1
  end

  def self.poll : Nil
    l = Shared.mv_l
    r = Shared.mv_r
    return if l == @@ml && r == @@mr # new knob-task sample only
    @@ml = l
    @@mr = r
    Sketch.track(millis, l, r)
  end
end

def epd_busy_hook : Nil
  SkTrack.poll if Shared.screen == SCR_SKETCH
end

# "Quick draw" (hold B 2 s in Sketch, shell `sketch quickdraw`): a six-
# shooter drawn in one continuous Etch-a-Sketch path of straight segments,
# fast, three passes so it ends darker (our own drawing, facing left):
# sight blade, rear notch, top strap, hammer spur, flared grip with
# checkering zigzag, rounded trigger guard and curved trigger, recoil
# shield, fluted cylinder with pin, ejector rod, muzzle with bore. Points in
# a 200 x 128 box (generated, curves as short segments), scaled x2.5 and
# centred on the pen area.
QD_PTS = "0C1E121E12171616191E621E621A8C1A921A9417971A99179C1A9E16A110A70DAB0FA913A417A21EA82EB046B55CB66AB570B473B176AE77AB78A778A476A174967690688E548C469350A04C9558A5549760AA5C9968AD649C70AD649968AA5C9760A5549558A04C93508C468842874C864F845180537D547A5476527350714D704A70407C407A45774A794C7C477F408A408A3E8A3D8F3B93379532962C952693218F1D8A1B841A7E1A6A1A671B651D64206438653B673D6A3E7E3E813D833B84388420831D811B7E1A6C1A6A2382236A236A2C822C6A2C6A3582356A35642C5C2B5C2E642E64322E322E2E2A2E2A34623462322E322E2C0C2C0C1E0C250D230E22102211231225112710280E280D270C250C2C" # x, y pairs as hex bytes
QD_N     = 138 # points

def qd_hex(i : Int32) : Int32
  p = QD_PTS.to_unsafe + (i &* 2).to_i64!
  h = p[0].to_i32!
  l = p[1].to_i32!
  (h >= 65 ? h &- 55 : h &- 48) &* 16 &+ (l >= 65 ? l &- 55 : l &- 48)
end

def qd_x(k : Int32) : Int32
  479 &- 250 &+ (qd_hex(k &* 2) &* 5).unsafe_div(2) # 200 x 128 box, x2.5
end

def qd_y(k : Int32) : Int32
  (Sketch::PEN_Y_MIN &+ Sketch::PEN_Y_MAX).unsafe_div(2) &- 160 &+ (qd_hex(k &* 2 &+ 1) &* 5).unsafe_div(2)
end

def quick_draw : Nil
  return unless SkInk.ready?
  log("sketch: quick draw", 0)
  t0 = millis
  pass = 0
  while pass < 3
    # first pass in three pulls (it "draws"), the others in one each
    parts = pass == 0 ? 4 : 1
    part = 0
    k = 0
    while part < parts
      last = (QD_N &* (part &+ 1)).unsafe_div(parts)
      while k < last
        Sketch.pen_to(qd_x(k), qd_y(k))
        k = k &+ 1
      end
      Shared.led_mode = (part &+ pass) & 1 == 0 ? LED_YELLOW : LED_CYAN
      SkInk.take_touches
      SkInk.pull
      part = part &+ 1
    end
    pass = pass &+ 1
  end
  Sketch.forget_knobs
  SkState.pen_seen(Sketch.x, Sketch.y)
  log("sketch: quick draw ms", millis &- t0)
end

module SkState
  @@colour = false # the red frame is on the panel (keep-red frames)
  @@red_frame = false # the red frame is still on the panel (survives re-entry)
  @@hint = false      # the "B: COLOR" hint is in the planes
  @@after_colour = false # colour show-off on the panel, planes already B/W

  def self.after_colour? : Bool
    @@after_colour
  end

  def self.after_colour=(v : Bool) : Nil
    @@after_colour = v
  end

  def self.red_frame? : Bool
    @@red_frame
  end

  def self.red_frame=(v : Bool) : Nil
    @@red_frame = v
  end

  def self.hint? : Bool
    @@hint
  end

  def self.hint=(v : Bool) : Nil
    @@hint = v
  end
  @@shown = Pointer(UInt8).null # black plane as last sent to the panel
  @@box = Pointer(Int32).null   # r0, r1, c0, c1 of the last diff
  @@last_lat = 0                # input -> ink on panel, last incremental frame
  @@e_dec = 0                   # last Sketch entry: background decode,
  @@e_up = 0                    # upload, panel busy and COG restart ms
  @@e_pan = 0
  @@e_rst = 0

  def self.entry_decode : Int32
    @@e_dec
  end

  def self.entry_decode=(v : Int32) : Nil
    @@e_dec = v
  end

  def self.set_entry(up : Int32, pan : Int32, rst : Int32) : Nil
    @@e_up = up
    @@e_pan = pan
    @@e_rst = rst
  end

  def self.e_up : Int32
    @@e_up
  end

  def self.e_pan : Int32
    @@e_pan
  end

  def self.e_rst : Int32
    @@e_rst
  end

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
    @@box = EPD.dma_alloc(48).as(Int32*) if @@box.null?
    @@box
  end

  # Does [a, a+n) overlap [b, b+n)? Logged with the offset.
  def self.overlap?(what : String, a : UInt8*, b : UInt8*, n : Int32) : Bool
    return false if a.null? || b.null?
    d = a.address.to_i64! &- b.address.to_i64!
    hit = d > 0_i64 &- n.to_i64! && d < n.to_i64!
    log2(what, hit ? 1 : 0, d.to_i32!)
    hit
  end

  # Audit: the Sketch canvas against the EPD planes and our plane copies.
  # Returns canvas - red (40320 would mean the canvas aliases red row 336).
  def self.check_overlap : Int32
    cv = Sketch.canvas
    n = EPD::PLANE
    overlap?("alloc: canvas vs red (overlap, offset)", cv, EPD.red, n)
    overlap?("alloc: canvas vs black (overlap, offset)", cv, EPD.black, n)
    overlap?("alloc: canvas vs shown (overlap, offset)", cv, shown, n)
    overlap?("alloc: canvas vs save (overlap, offset)", cv, SketchFx.save_buf, n)
    overlap?("alloc: red vs black (overlap, offset)", EPD.red, EPD.black, n)
    overlap?("alloc: shown vs red (overlap, offset)", shown, EPD.red, n)
    (cv.address.to_i64! &- EPD.red.address.to_i64!).to_i32!
  end

  # Remember the planes as shown (after any full refresh).
  def self.mark_shown : Nil
    SkInk.sync_from_canvas if Shared.screen == SCR_SKETCH
    pen_seen(Sketch.x, Sketch.y)
    sh = shown
    bk = EPD.black
    i = 0
    while i < EPD::PLANE
      sh[i] = bk[i]
      i = i &+ 1
    end
  end

  # Bounding box (rows, byte columns) of black-plane bytes that differ from
  # what is shown, within rows y0..y1 and 32-bit words w0..w1 of each row;
  # copies the changed words into `shown`. False if nothing changed.
  def self.diff_words(y0 : Int32, y1 : Int32, w0 : Int32, w1 : Int32) : Bool
    sh = shown.as(UInt32*)
    bk = EPD.black.as(UInt32*)
    wpr = EPD::ROW_BYTES.unsafe_div(4) # 30 words per row
    half_w = wpr.unsafe_div(2) # words 0..14 = left COG, 15..29 = right
    b = box
    # b[0..3]: whole box; b[4..7]: left half; b[8..11]: right half
    # (rows r0, r1, then words c0, c1 until converted to bytes below).
    k = 0
    while k < 12
      b[k] = EPD::HEIGHT # r0
      b[k &+ 1] = -1     # r1
      b[k &+ 2] = wpr    # c0 (words)
      b[k &+ 3] = -1     # c1 (words)
      k = k &+ 4
    end
    row = y0
    while row <= y1
      i = row &* wpr
      w = w0
      while w <= w1
        v = bk[i &+ w]
        if v != sh[i &+ w]
          sh[i &+ w] = v
          h = w < half_w ? 4 : 8
          k = 0
          while k <= h
            b[k] = row if row < b[k]
            b[k &+ 1] = row
            b[k &+ 2] = w if w < b[k &+ 2]
            b[k &+ 3] = w if w > b[k &+ 3]
            k = k &+ h
          end
        end
        w = w &+ 1
      end
      row = row &+ 1
    end
    k = 0
    while k < 12
      b[k &+ 2] = b[k &+ 2] &* 4
      b[k &+ 3] = b[k &+ 3] &* 4 &+ 3
      k = k &+ 4
    end
    b[1] >= 0
  end

  def self.diff : Bool
    diff_words(0, EPD::HEIGHT &- 1, 0, EPD::ROW_BYTES.unsafe_div(4) &- 1)
  end

  # Pen position the planes were last brought up to date with.
  @@px = -1
  @@py = -1

  def self.pen_seen(x : Int32, y : Int32) : Nil
    @@px = x
    @@py = y
  end

  def self.px : Int32
    @@px
  end

  def self.py : Int32
    @@py
  end

  # Sketch.render limited to rows y0..y1 and bytes c0..c1: canvas ink ORed
  # into black, red cleared under it (same per-byte rule as Sketch.render).
  def self.render_box(y0 : Int32, y1 : Int32, c0 : Int32, c1 : Int32) : Nil
    cv = Sketch.canvas
    bk = EPD.black
    rd = EPD.red
    row = y0
    while row <= y1
      i = row &* EPD::ROW_BYTES &+ c0
      e = row &* EPD::ROW_BYTES &+ c1
      while i <= e
        v = cv[i]
        if v != 0_u8
          bk[i] = bk[i] | v
          rd[i] = rd[i] & (v ^ 0xFF_u8)
        end
        i = i &+ 1
      end
      row = row &+ 1
    end
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
  erase = Menu.needs_background? # A (erase): fresh background, pen at the centre
  if erase
    sketch_background
    red_to_black
  end
  Menu.render(EPD.black, EPD.red) # only clears red under ink; red plane stays empty
  draw_sketch_label(wait, up, panel, total)
  draw_sketch_hint(false)
  Shared.led_mode = LED_CYAN
  if Menu.want_clean? && !erase
    # B (clean): black flash, white, then the drawing, all full drive with
    # the shake: incremental (diff/window) updates never clean residue.
    EPD.raw = true
    sketch_clean(EPD::LUT_BASE)
    EPD.raw = false
  else
    fast_bw(3, EPD::LUT_BASE) # A (erase): one full-drive frame, as entry
  end
  Sketch.forget_knobs # turns during the refresh must not make the pen jump
end

# Sketch colour: redraw the frame with red, overlay the drawing, slow refresh.
def sketch_colour : Nil
  Shared.live = false
  sketch_background
  Sketch.render(EPD.black, EPD.red)
  draw_sketch_hint(false)
  # Label with the R/B/O plane check + version also on the colour frame
  # (and logged), so the colour render can be diagnosed from a photo.
  draw_sketch_label(SkState.last_lat, EPD.upload_ms, EPD.panel_ms, 0, true)
  colour_refresh
  # Show-off render only: drawing stays black/white. Back to the B/W planes
  # (frame red -> black) now; the next stroke does one full B/W refresh
  # (SkState.after_colour), then windows again.
  Sketch.render(EPD.black, EPD.red)
  red_to_black
  draw_sketch_hint(false)
  draw_sketch_label(SkState.last_lat, EPD.upload_ms, EPD.panel_ms, 0)
  SkState.colour = false
  SkState.red_frame = false
  SkState.after_colour = true
  SkState.hint = false
  SkState.mark_shown
end

# Shows a screen on entry: always a fast black/white frame.
def enter_screen(scr : Int32, boot : Bool) : Nil
  Shared.screen = scr
  LibIDF.cr_net_screen(scr)
  SkState.red_frame = false unless scr == SCR_SKETCH # another screen replaces it
  # Every preview uses WIN_LUT (HALF60), the kind game frames and Sketch ink
  # use too, so the COG session stays latched across screen switches (no ~5 s
  # restart on the first frame). Static screens get 2 pulls (HALF60 erases
  # black -> white weakly), game screens 1 so they are usable at once.
  static_scr = scr == SCR_NAMETAG || scr == SCR_PORTRAIT || scr == SCR_DIAG
  pulls = boot ? 3 : (static_scr ? 3 : 2)
  # Static screens: base LUT (with its shake) x3 so the B/W preview of a
  # dithered image comes out clean (no-shake previews never cleaned up). It
  # costs one COG restart when coming from a game; the screen is static.
  # Every entry is a real full-drive refresh (base LUT, shake, >= 2 pulls):
  # the incremental modes (diff, diffwin, window) never clean film residue.
  kind = EPD::LUT_BASE
  log2("main: screen / boot", scr, boot ? 1 : 0)
  if scr == SCR_HOME
    Home.enter
  elsif !Apps.builtin?(scr)
    Apps.enter(scr) # registry app (src/apps/)
  elsif scr == SCR_NAMETAG
    draw_nametag_planes
    red_to_checker
    draw_version(EPD::WIDTH &- 8, EPD::HEIGHT &- 22) # preview only, not the colour image
    draw_colour_hint
    fast_bw(pulls, kind)
  elsif scr == SCR_PORTRAIT
    draw_portrait_planes
    red_to_checker
    draw_version(EPD::WIDTH &- 8, EPD::HEIGHT &- 22)
    draw_colour_hint
    fast_bw(pulls, kind)
  elsif scr == SCR_DIAG
    show_diag
  elsif scr == SCR_LINK || scr == SCR_PONG
    LinkUI.enter(scr)
  else
    Menu.enter(menu_mode_for(scr))
    SkState.colour = false
    if scr == SCR_SKETCH && SkState.red_frame?
      # The red frame from an earlier colour render is still on the panel:
      # keep it. Flash the drawing area black (clears the old drawing's
      # ghosts), then the frame + blank canvas, all with red tables ground.
      t_dec = millis
      sketch_background
      SkState.entry_decode = millis &- t_dec
      Menu.render(EPD.black, EPD.red)
      draw_sketch_label(SkState.last_lat, EPD.upload_ms, EPD.panel_ms, 0, true)
      EPD.raw = true
      save = SketchFx.save_buf
      i = 0
      while i < EPD::PLANE
        save[i] = EPD.black[i]
        i = i &+ 1
      end
      EPD.fill_rect(SK_X0, SK_Y0, SK_W, SK_H, EPD::BLACK)
      EPD.fast_pulls = 1
      EPD.refresh(true, red_ink_kind)
      i = 0
      while i < EPD::PLANE
        EPD.black[i] = save[i]
        i = i &+ 1
      end
      EPD.fast_pulls = 2
      EPD.refresh(true, red_ink_kind)
      EPD.raw = false
      SkState.colour = true
      SkState.hint = false
      SkState.mark_shown
      SkState.set_entry(EPD.upload_ms, EPD.panel_ms, EPD.restart_ms)
      return
    end
    if scr == SCR_SKETCH
      t_dec = millis
      sketch_background
      SkState.entry_decode = millis &- t_dec
      Menu.render(EPD.black, EPD.red)
      red_to_black
      draw_sketch_label(SkState.last_lat, EPD.upload_ms, EPD.panel_ms, 0)
      draw_sketch_hint(true)
      SkState.hint = false # the help strip is permanent (nothing to remove)
      pulls = 3 # full-drive entry (base LUT, shake): cleans residue of earlier updates
    else
      Menu.render(EPD.black, EPD.red)
      draw_mode_label(Menu.mode, 0, 0, 0, 0)
    end
    fast_bw(pulls, kind)
    Sketch.forget_knobs if scr == SCR_SKETCH # no jump from turns during the entry refresh
    SkState.mark_shown
    if scr == SCR_SKETCH
      SkState.set_entry(EPD.upload_ms, EPD.panel_ms, EPD.restart_ms)
      log2("sketch entry: decode / upload ms", SkState.entry_decode, EPD.upload_ms)
      log2("sketch entry: panel / restart ms", EPD.panel_ms, EPD.restart_ms)
    end
  end
end

fun crystal_app_main : Void
  led_test
  Store.open
  log("main: EPD, SPI Hz", SPI_HZ)
  t = millis
  unless EPD.init(SPI_HZ)
    log("main: EPD init failed", 0)
    Ota.boot_failed # a new OTA image rolls back here
    return
  end
  log("main: EPD init (incl. OTP probe) ms", millis &- t)

  speed_test if SPEED_TEST
  lut_probe if LUT_PROBE
  lut_timing if LUT_TIMING

  # Browsing never waits for the slow waveform: no red-clearing promotion.
  EPD.promote = false
  EPD.keep_awake = true
  EPD.wfast(SK_INK_FRAMES)
  Menu.init(Menu::NAMETAG)
  scr = Store.screen
  Shared.target = scr
  Shared.rendering = true
  enter_screen(scr, true)
  Shared.rendering = false
  Ota.boot_ok # display works: keep this image (OTA rollback)

  prev = 0_u32
  frames = 0
  last_total = 0
  last_wait = 0
  last_input = millis
  pl = Shared.mv_l
  pr = Shared.mv_r
  colour_shown = false # NAMETAG/PORTRAIT: its colour image is on the panel
  colour_due = millis &+ AUTO_COLOUR_MS
  a_down = 0      # when User A went down (0 = up)
  a_fired = false # the hold already fired (no tap on release)
  b_down = 0      # Sketch: User B down since (Quick draw hold)
  b_fired = false
  forget_until = millis # knob references dropped until then (REQ_FORGET)
  while true
    Ota.ui(scr) if Ota.running? # OTA (shell or DIAG): no other e-paper work meanwhile
    held = Shared.take_buttons
    now = millis
    raw_held = held
    # User A, the same on every screen: a TAP is delivered on release (so a
    # hold never also taps); a HOLD of HOLD_MS is the full-colour render on
    # NAMETAG / PORTRAIT / SKETCH. B passes straight through.
    a_tap = false
    a_hold = false
    if (held & Games::BTN_A) != 0_u32
      a_down = now if a_down == 0
      if !a_fired && now &- a_down >= HOLD_MS
        a_fired = true
        a_hold = true
      end
    elsif a_down != 0
      a_tap = !a_fired
      a_down = 0
      a_fired = false
    end
    held = held & (Games::BTN_A ^ 0xFFFFFFFF_u32)
    held = held | Games::BTN_A if a_tap
    # Sketch: B tap = clean (on release), B held QD_HOLD_MS = Quick draw.
    if scr == SCR_SKETCH
      b_tap = false
      if (held & Games::BTN_B) != 0_u32
        b_down = now if b_down == 0
        if !b_fired && now &- b_down >= QD_HOLD_MS
          b_fired = true
          Shared.request(Shared::REQ_QUICKDRAW)
        end
      elsif b_down != 0
        b_tap = !b_fired
        b_down = 0
        b_fired = false
      end
      held = held & (Games::BTN_B ^ 0xFFFFFFFF_u32)
      held = held | Games::BTN_B if b_tap
    end
    # Debug shell requests (shell.cr): hold A, clean, scripted stroke.
    reqs = Shared.take_requests
    a_hold = true if (reqs & Shared::REQ_HOLD_A) != 0_u32
    if (reqs & Shared::REQ_CLEAN) != 0_u32
      log("shell: clean (slow white, zero red)", 0)
      EPD.fill(EPD::WHITE)
      colour_refresh
      SkState.red_frame = false # the panel is white now
      SkState.colour = false
      Shared.rendering = true
      enter_screen(scr, false)
      Shared.rendering = false
    end
    if (reqs & Shared::REQ_REDRAW) != 0_u32 && Shared.target == scr
      Shared.rendering = true
      enter_screen(scr, false) # new nametag text (net.cr)
      Shared.rendering = false
    end
    forget_until = now &+ 80 if (reqs & Shared::REQ_FORGET) != 0_u32
    if now &- forget_until < 0 # the knob task may still deliver the old source
      Sketch.forget_knobs
      SkTrack.reset
    end
    if (reqs & Shared::REQ_QUICKDRAW) != 0_u32 && scr == SCR_SKETCH
      Shared.rendering = true
      quick_draw
      Shared.rendering = false
    end
    if (reqs & Shared::REQ_STROKE) != 0_u32 && scr == SCR_SKETCH
      Sketch.line(Sketch.canvas, Shared.sx0, Shared.sy0, Shared.sx1, Shared.sy1)
      Menu.render(EPD.black, EPD.red)
      red_to_black unless SkState.colour?
      Shared.rendering = true
      EPD.raw = true
      EPD.fast_pulls = 1
      EPD.refresh(true, SkState.colour? ? red_ink_kind : WIN_LUT)
      EPD.raw = false
      Shared.rendering = false
      SkState.mark_shown
      log2("shell: stroke refreshed, kind / panel ms", EPD.latched_kind, EPD.panel_ms)
    end
    if a_hold && scr == SCR_SKETCH
      log("sketch: A held, colour refresh", 0)
      sketch_colour
    end
    # Menu: the knob task switches apps, unless this app owns the buttons
    held = held & ((Games::BTN_PLUS | Games::BTN_MINUS) ^ 0xFFFFFFFF_u32) unless Apps.owns_menu?(scr)
    inp = Games.input(Shared.mv_l, Shared.mv_r, held, prev)
    prev = held
    dl = Shared.mv_l &- pl
    dr = Shared.mv_r &- pr
    if dl > 15 || dl < -15 || dr > 15 || dr < -15 || raw_held != 0_u32
      last_input = now
      pl = Shared.mv_l
      pr = Shared.mv_r
    end

    # The knob task turns Menu presses into Shared.target at once (and the
    # LEDs show it); render whatever the target is now, so several presses
    # during one render only draw the last screen.
    Shared.live = false # set again at the bottom of the loop when idle in Sketch
    if Shared.target != scr
      Apps.leave(scr)
      scr = Shared.target
      Store.screen = scr
      frames = 0
      t = millis
      Shared.rendering = true
      enter_screen(scr, false)
      Shared.rendering = false
      colour_shown = false # any other screen's refresh replaced the colour image
      colour_due = millis &+ AUTO_COLOUR_MS
      last_total = millis &- t
      log2("main: screen / entry ms", scr, last_total)
    elsif scr == SCR_NAMETAG || scr == SCR_PORTRAIT
      # Colour on User A, or automatically after AUTO_COLOUR_MS without a
      # button press (any press restarts the wait). Not again while this
      # screen's colour image is still on the panel.
      colour_due = now &+ AUTO_COLOUR_MS if raw_held != 0_u32
      auto = !colour_shown && now &- colour_due >= 0
      if a_hold || auto
        log("main: colour refresh (1 = auto)", auto ? 1 : 0)
        if scr == SCR_NAMETAG
          draw_nametag_planes
        else
          draw_portrait_planes
        end
        colour_shown = colour_refresh
        colour_due = millis &+ AUTO_COLOUR_MS
      end
    elsif scr == SCR_HOME
      Home.tick(now, inp)
    elsif !Apps.builtin?(scr)
      Apps.tick(scr, now, inp)
    elsif scr == SCR_LINK || scr == SCR_PONG
      LinkUI.tick(scr, now, inp)
    elsif scr == SCR_DIAG
      if a_hold
        # Clean the panel: a full OTP (slow) refresh of a white screen with
        # an all-zero red plane, which also removes stray red pigment that
        # the fast tables cannot.
        log("diag: hold A, slow white clean", 0)
        EPD.fill(EPD::WHITE)
        colour_refresh
        SkState.red_frame = false
        show_diag
      elsif Games.pressed?(inp, Games::BTN_A)
        lut_timing
      elsif Games.pressed?(inp, Games::BTN_B)
        if Ota.b_held? # hold B: OTA update check (src/ota.cr)
          Ota.start(false)
        else
          ink_test
        end
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
      elsif Shared.upd(SCR_SKETCH) == UPD_INK && SkInk.ready?
        # Ink with incremental strength (SkInk): only the pixels the pen
        # covered get driven, each a step darker per pass.
        if SkState.after_colour?
          SkState.after_colour = false
          Sketch.render(EPD.black, EPD.red)
          fast_bw(2, EPD::LUT_BASE)
          SkState.mark_shown
        end
        SkState.hint = false # nothing to remove: the help strip stays
        if SkInk.take_touches
          t = millis
          Shared.led_mode = LED_CYAN
          SkTrack.reset
          EPD.hook = true
          SkInk.pull
          EPD.hook = false
          SkState.pen_seen(Sketch.x, Sketch.y)
          last_total = millis &- t
          SkState.last_lat = millis &- last_input
          log3("sketch: ink upload / panel / latency ms", EPD.upload_ms, EPD.panel_ms, SkState.last_lat)
        end
      else
        # Live ink: only where the pen moved since the planes were last
        # updated. Ink lies on the path from the old to the new pen position,
        # inside their bounding box grown by the brush (LINE_W / 2) + 1.
        nx = Sketch.x
        ny = Sketch.y
        ox = SkState.px
        oy = SkState.py
        moved = nx != ox || ny != oy
        if moved && ox < 0
          SkState.pen_seen(nx, ny)
          moved = false
        end
        pad = Sketch::HALF &+ 1
        bx0 = (nx < ox ? nx : ox) &- pad
        bx1 = (nx < ox ? ox : nx) &+ pad
        by0 = (ny < oy ? ny : oy) &- pad
        by1 = (ny < oy ? oy : ny) &+ pad
        bx0 = 0 if bx0 < 0
        by0 = 0 if by0 < 0
        bx1 = EPD::WIDTH &- 1 if bx1 > EPD::WIDTH &- 1
        by1 = EPD::HEIGHT &- 1 if by1 > EPD::HEIGHT &- 1
        changed = false
        hint_gone = false
        if moved && SkState.hint?
          hint_gone = true
          draw_sketch_hint(false) # drawing started: the full refresh below removes it
          SkState.hint = false
        end
        if moved
          SkState.pen_seen(nx, ny)
          w0 = bx0.unsafe_shr(5)
          w1 = bx1.unsafe_shr(5)
          SkState.render_box(by0, by1, w0 &* 4, w1 &* 4 &+ 3)
          changed = SkState.diff_words(by0, by1, w0, w1)
        end
        # SK_WIN: re-tracing existing ink (pen moved, no new pixels) still
        # refreshes those rows, so going over a line darkens it like a real
        # Etch-a-Sketch. The ink LUTs never drive black pixels white (table
        # 1 is black drive or ground only), so a pass can't lighten ink.
        retrace = moved && !changed && Shared.sk_win? && !hint_gone
        if retrace
          b = SkState.box
          b[0] = by0
          b[1] = by1
        end
        if changed || retrace
          b = SkState.box
          t = millis
          Shared.led_mode = LED_CYAN
          kind = SkState.colour? ? red_ink_kind : WIN_LUT
          # SK_INK_WFAST: window ink with the 20-frame WFAST table. OFF: on
          # this panel WFAST windows leave copies ~336 rows lower (photo on
          # 7dfbfae); WIN_LUT windows are clean.
          kind = EPD::LUT_WFAST if SK_INK_WFAST && !SkState.colour? && Shared.sk_win? && !hint_gone && !SkState.after_colour?
          EPD.fast_pulls = 1
          if SkState.after_colour?
            # First stroke after the colour show-off: one full B/W refresh
            # (2 pulls: the red frame turns black), then windows again.
            SkState.after_colour = false
            EPD.fast_pulls = 2
            EPD.raw = true
            EPD.refresh(true, WIN_LUT)
            EPD.raw = false
          elsif Shared.upd(SCR_SKETCH) == UPD_DIFF
            EPD.refresh_diff
          elsif Shared.upd(SCR_SKETCH) == UPD_DIFFWIN
            EPD.refresh_diff(b[1] &+ 1 &+ EPD::WIN_PAD_ROWS)
          elsif Shared.sk_win? && !hint_gone
            # Rows-only window (mode 8): full width x the changed rows.
            EPD.refresh_window2(b[0], b[1], 0, EPD::HALF_BYTES &- 1,
              b[0], b[1], 0, EPD::HALF_BYTES &- 1, kind, 8)
          elsif SK_WINDOWED
            EPD.refresh_window(b[2], b[3], b[0], b[1], kind)
          else
            EPD.raw = true
            EPD.refresh(true, kind)
            EPD.raw = false
          end
          last_total = millis &- t
          SkState.last_lat = millis &- last_input
          log2(retrace ? "sketch: retrace rows / latency ms" : "sketch: ink rows / latency ms", b[1] &- b[0] &+ 1, SkState.last_lat)
        end
      end
    elsif Menu.tick(now, inp)
      t = millis
      lw = last_wait
      # Sketch frames follow input; Life/Snake frames follow their own timer,
      # so for them "wait" is tick -> refresh start, not time since input.
      last_wait = scr == SCR_SKETCH ? millis &- last_input : millis &- now
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
        if clean
          # Clean frame: new label, full 3-pull refresh with the shaking LUT.
          draw_mode_label(Menu.mode, lw, EPD.upload_ms, EPD.panel_ms, last_total)
          EPD.fast_pulls = 3 # full drive with the shake (cleans residue)
          EPD.raw = true
          EPD.refresh(true, EPD::LUT_BASE)
          EPD.raw = false
          SkState.mark_shown
        else
          # Keep the shown label; refresh only the changed box.
          restore_label
          if SkState.diff
            b = SkState.box
            EPD.fast_pulls = GAME_PULLS
            gm = Shared.upd(scr)
            if gm == UPD_DIFF
              EPD.refresh_diff
            elsif gm == UPD_DIFFWIN
              EPD.refresh_diff(b[1] &+ 1 &+ EPD::WIN_PAD_ROWS)
            elsif GAME_WINDOWED || gm == UPD_WIN
              # One box per COG half keeps each window small.
              EPD.refresh_window2(b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], WIN_LUT)
            else
              EPD.raw = true
              EPD.refresh(true, WIN_LUT)
              EPD.raw = false
            end
            log2("game: changed rows / panel ms", b[1] &- b[0] &+ 1, EPD.panel_ms)
          end
        end
      end
      last_total = millis &- t
      log2("main: screen / frame ms", scr, last_total)
    end
    if scr == SCR_SKETCH
      Shared.led_mode = Sketch.dirty? ? LED_YELLOW : LED_GREEN
    else
      Shared.led_mode = 0
    end
    Store.sync_upd
    Shared.live = scr == SCR_SKETCH && !Shared.rendering? && Shared.target == scr
    LibIDF.cr_wait_notify(20_u32) # woken early by the knob task on input
  end
end
