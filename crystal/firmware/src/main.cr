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

  @@cur = Pointer(UInt8).null # pixels showing the pen cursor (1-pass grey)
  @@cx = -1                    # cursor position on the panel, -1 = none
  @@cy = -1

  def self.ready? : Bool
    if @@pass.null?
      @@pass = LibIDF.heap_caps_malloc((EPD::PLANE &* 8).to_u32!, 0x404_u32).as(UInt8*)
      @@cnew = LibIDF.heap_caps_malloc(EPD::PLANE.to_u32!, 0x404_u32).as(UInt8*)
      @@cold = LibIDF.heap_caps_malloc(EPD::PLANE.to_u32!, 0x404_u32).as(UInt8*)
      @@cur = LibIDF.heap_caps_malloc(EPD::PLANE.to_u32!, 0x404_u32).as(UInt8*)
      return false if @@pass.null? || @@cnew.null? || @@cold.null? || @@cur.null?
      Games.zero(@@cnew, EPD::PLANE)
      Games.zero(@@cold, EPD::PLANE)
      Games.zero(@@cur, EPD::PLANE)
      @@hi = -1
    end
    !@@pass.null? && !@@cnew.null? && !@@cold.null? && !@@cur.null?
  end

  # ---- pen cursor ------------------------------------------------------------
  # Four short ticks around the pen (CUR_IN..CUR_OUT px from its centre,
  # CUR_W px wide), drawn as a first-pass grey (ink command 1) on pixels the
  # pen never inked, and taken away again with the short lighten command
  # (2, EPD ink_fe frames = the same drive as one pass, reversed) when the
  # pen moves. Pixels with ink are never touched by the cursor, so it can't
  # lighten a line; a full refresh (sync_from_canvas) drops it.
  CUR_IN  = 6
  CUR_OUT = 10
  CUR_W   = 2

  def self.cursor_shown? : Bool
    @@cx >= 0
  end

  def self.cur_tick(x0 : Int32, y0 : Int32, w : Int32, h : Int32, on : Bool) : Nil
    y = y0
    while y < y0 &+ h
      x = x0
      while x < x0 &+ w
        if x >= Sketch::X_MIN &- Sketch::HALF && x <= Sketch::X_MAX &+ Sketch::HALF &&
           y >= Sketch::PEN_Y_MIN &- Sketch::HALF && y <= Sketch::PEN_Y_MAX &+ Sketch::HALF
          i = y &* EPD::ROW_BYTES &+ x.unsafe_shr(3)
          m = 0x80_u8.unsafe_shr(x & 7)
          if (@@pass + (y &* EPD::WIDTH &+ x).to_i64!).value == 0_u8 # never over ink
            if on
              if (@@cur[i] & m) == 0_u8
                @@cur[i] = @@cur[i] | m
                @@cnew[i] = @@cnew[i] | m # command 1: a light grey step
                @@cold[i] = @@cold[i] & (m ^ 0xFF_u8)
                use(i)
              end
            elsif (@@cur[i] & m) != 0_u8 && (@@cnew[i] & m) == 0_u8
              @@cur[i] = @@cur[i] & (m ^ 0xFF_u8)
              @@cold[i] = @@cold[i] | m # command 2: back to white
              use(i)
            end
          else
            @@cur[i] = @@cur[i] & (m ^ 0xFF_u8) # inked over: it is a line now
          end
        end
        x = x &+ 1
      end
      y = y &+ 1
    end
  end

  def self.cur_shape(x : Int32, y : Int32, on : Bool) : Nil
    l = CUR_OUT &- CUR_IN &+ 1
    h = CUR_W.unsafe_div(2)
    cur_tick(x &+ CUR_IN, y &- h, l, CUR_W, on)
    cur_tick(x &- CUR_OUT, y &- h, l, CUR_W, on)
    cur_tick(x &- h, y &+ CUR_IN, CUR_W, l, on)
    cur_tick(x &- h, y &- CUR_OUT, CUR_W, l, on)
  end

  # Moves the cursor to (x, y): new ticks first (so pixels both shapes
  # share stay), then the old ones go. Call after take_touches. True if
  # anything changed (an ink pull is needed).
  def self.cursor_to(x : Int32, y : Int32) : Bool
    return false unless ready?
    return false if x == @@cx && y == @@cy
    cur_shape(x, y, true)
    cur_shape(@@cx, @@cy, false) if @@cx >= 0
    @@cx = x
    @@cy = y
    true
  end

  # After a full refresh: what the canvas shows is solid black (full
  # passes), the rest has none; pending touches are dropped.
  def self.sync_from_canvas : Nil
    return unless ready?
    @@pw0 = -1
    Games.zero(@@cur, EPD::PLANE) # a full refresh showed no cursor
    @@cx = -1
    @@cy = -1
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

# "Quick draw" (hold B 2 s in Sketch, shell `sketch quickdraw`): our own
# six-shooter (muzzle right, grip lower left) drawn as one continuous
# Etch-a-Sketch path, generated by crystal/tools/gen_quickdraw.py (edit
# that, then `gen_quickdraw.py --write`). Every ink pull adds new line
# work, so it is seen being drawn: outlines, then details and a second
# hand-inked edge on every outline, then hatching / cross-hatching. Tone
# comes from line density and from crossings (a pixel touched in two pulls
# is a step darker). Table: 6 hex digits per point (x, y screen pixels,
# 3 digits each); FFFFFF = run an ink pull here. Starts at the pen's home.
QD_PTS = "1DF1361891361DF1361DE1311DE12A1DD1221DC1191DB1111D91031D80FB1D80E81D90E31DB0DE1DC0D91DD0D617D0DA17D0D817C0D417B0D117A0CD1760C71730C51710C216E0C016A0BE1670BC1610BA15C0BA15B0BB1590BC1580BD1580BF15A0C115D0C315F0C41620C61670CB16B0D116D0D516E0DA1700DE1710E11700DE16E0DA16D0D516B0D11690CE1660CA1620C615F0C415C0C315A0C21590C01580BF1590BD15C0BA1610BA16A0BD16D0C01710C21760C717A0CD17B0D017D0D817D0DA18E0DA1910D91A50D91A80D81BE0D81C10D71D50D71D80D61E50D61E50D82970D82A20CC2AF0CC2B30D82B80D82B80E11DD0E11DD0D61DD0E12180E1FFFFFF21A0E12B80E12B80F92B80E12BA0E22BB0E52BC0E92BC0F22BB0F62BA0F82B80F92B70F82B60F62B50F22B40ED2B60E52B70E22B80E12B80F91E80F91E810E25C10E25F10D26410C26710A26910726A10426B10226B0F926B0FF2760FF27A10327910527610826910826A10426B10226B0F91E80F92B50F92B70F82B50F62B50F22B40ED2B50E92B50E52B70E22B50E12300E1FFFFFF22E0E11DD0E11D80E01D00E01D60E01D80E11D80ED1D90F61D911A1D81231D812F1D61301D01301C313119F13119213018C13018A12F18A12D18912918912318811A1881111891081880FF1880F61890ED1890E718A0E318A0E118C0E01920E019F0DF1C30DF1D00E01D60E01D80E11D80EA1D90ED1D91021DA1061DA10A1DB10E1DB1111DC1151DC11C1DD11F1DD1251DE1271DE12D1DF1311DF1361C51361C613A1C81461C714C1C51521BF15E1B51661A716A19A16A19416818F16618A16218715E18415818215218114C18114618214018213A18313618313A18213D18214018114318114C18315218315518415818615B18715E18916018A16218D16418F16519216719416819A16A1A716A1AB1691B11671B71641BA1621BC1601BF15E1C115B1C21581C41551C81491C81461C71431C713D1C613A1C51361BC1361BC1391BD13E1BD1481B91521B61571B315B1AF15E1AA1601A516119C16119715F19315D19015B18C15318B14F18A14A18A13F18B13A18B1361AA1361AB1391AD1431AD1481AB1521A81551A51591A215B19F15B19D15A19B15A19D15A19F15B1A215B1A51591A81551AB1521AD1481AD1431AB1391AA1361DF1361DF1311DE12D1DE1271DD1251DD11F1DC11C1DC1151DB1111DB10E1DA10A1DA1061D91021D90ED1D80EA1D80E81D90E6FFFFFF1D90E31DB0DE1DD0D61D80D61D50D71C10D71BE0D81A80D81A50D91910D918E0DA17D0DA1710E116F0E416E0E91690F31670F916110515D10B15A11215611915212114E12814913014513814014013B14913715113215912E16112916912417211C18211818911519011119610E19C10C1A21091A71081AC1061B41061BA1091C310C1C510F1C81151CC1161CD1301D114C1C914D1C714E1C41501C01521BB1531B71551B21561AD1581A81591A315B19D15C19816018C16318616518016817916A17316D16D16F16717216117515C17715617A15117C14C17D14817F14318113B18213818313617D0DA17D0DD17E0E017E0EB17F0EE17F0FA17F0F91740F91730FD16D10916411E15C12C15813415413B15014314C14A14016213C16913817112C18612918D12519312219912019F11E1A411C1AE11B1B211B1B611A1B91441BE1461BB1471B814B1AE14E1A914F1A41511A015319B15519515918B15B18515D18016716216A15C17014A17214517413F17613A17713417912E17A12917B12517C1221740F9FFFFFF1770F917F0F917F0FA17F0EE17E0EB17E0E017D0DD17D0DA18E0DA1910D91A50D91A80D81BE0D81C10D71D50D71D80D61DD0D61DB0DE1D90E31D90E61D80E81D80EA1D90ED1D91021DA1061DA10A1DB10E1DB1111DC1151DC11C1DD11F1DD1251DE1271DE12D1DF1311DF1361DF1341891361DF1381DF1311DE12D1DE1271DD1251DD11F1DC11C1DC1151DB1111DB10E1DA10A1DA1061D91021D90ED1D80EA1D80E81D90E61D90E31DA0E01DD0E12B50E12B70E22B50E52B50E92B40ED2B50F22B50F62B70F82B50F92730F92760F42730F92790F927B0F42790F927E0F92810F427E0F92840F92860F42840F92890F928C0F42890F928F0F92910F428F0F92940F92970F42940F929A0F929D0F429A0F929F0F92A20F429F0F92A50F92A80F42A50F92AA0F92AD0F42AA0F92B00F92B30F42B00F92B50F92B70F82B50F62B50F22B40ED2B50E92B50E52B70E22B50E11DD0E11DA0E01D90E31D90E61D80E81D80EA1D90ED1D91021DA1061DA10A1DB10E1DB1111DC1151DC11C1DD11F1DD1251DE1271DE12D1DF1311DF1361E11361E01311E012A1DF1211DD1111DC10A1DB1021DA0FB1DA0F41D90EE1DA0E91DB0E31DD0DE1DE0DA1DF0D71DE0DA1DD0DC1DD0E12B50E12B70E22B50E52B50E92B40ED2B50F22B50F62B70F82B50F926D0F926B0FC26B10226A10426910826710A26310C25F10D25C10E25810E25C10E26710A26B10226B0F91E80F91E81032601031E81031E80F92B50F92B70F82B50F62B50F22B40ED2B50E92B50E52B70E22B50E11DD0E11DD0D417D0D817B0D017A0CD1760C71710C216D0C01690CD16D0C016A0BE1660CA16A0BE1660BC1630C71660BC1630BA1600C41630BA15F0BA15C0C215F0BA1610BA16A0BD16D0C01710C21760C717A0CD17B0D017D0D817D0DA1800DA17F0DA17F0D717E0D417D0D017B0CC1750C31720C116F0BE16B0BC1680BA1640B91610B815C0B815A0B91580BB1560BF1570C11590C315C0C415E0C61610C71630C91650CC1680CF1690D216D0DA16E0DF16F0E21730E01760DF1780DD17B0DB17D0DA18E0DA1910D91A50D91A80D81BE0D81C10D71D50D71D80D61DD0D61DD0DE1DA0E01CD0E01CA0DF1980DF1950E018C0E018A0E118A0E31890E71890EA1C60EA1C80EC1CA0F01C90F31C80F51C60F61C30F71890F7FFFFFF1890EA1890E718A0E318A0E118C0E01950E01980DF1CA0DF1CD0E01DA0E01DD0DE1DD0D81E40D81E50DA2970DA2A30CE2AE0CE2B10D92B70D92B60E11DD0E11DA0E01CD0E01CA0DF1980DF1950E018C0E018A0E118A0E31890E71891021C61021C81031C91061CA1081C910A1C810D1C610E18910E1890E718A0E318A0E118C0E01950E01980DF1CA0DF1CD0E01DA0E01DD0E12B80E12B80DE2B80E01DD0E01DD0DE1DA0E01CD0E01CA0DF1980DF1950E018C0E018A0E118A0E31890E718911A1891191C31191C611A1C811B1C911D1CA1201C81241C61261891261890E718A0E318A0E118C0E01950E01980DF1CA0DF1CD0E01DA0E01DD0E11E00E11DF0E11DF0D61DF0D71DE0DA1DD0DE1DB0E31DB0E61DA0E91DA0EB1D90EE1D91231D81261D812F1D61301CD1301CA13119813119513019413019412D19413019713019812D19713019B13019C12D19B13019F1301A012D19F1301A21301A312D1A21301A61301A712D1A61301AA1301AB12D1AA1301AD1301AE12D1AD1301B11301B212D1B11301B51301B612D1B51301B81301B912D1B81301BC1301BD12D1BC1301C01301C112D1C01301C31301C412D1C31301C71301C812D1C71301CB1301CC12D1CB1301D61301D812F1D81261D91231D90EE1DA0EB1DA0E91DB0E61DB0E31DD0E12B60E12B60F92B60E42B70E22B50E11DD0E11DB0E31D90E31D80E11D90E11DA0E21DC0E51DD0E81DD0F11DC0F41DA0F71D90F71D90EE1DA0EB1DA0E91DB0E61DB0E31DD0E12B50E12B70E22B70E32B80E32B90E52BA0E92BA0F22B90F52B80F72B70F52B70F22B60ED2B70E92B70E52B80E32B90E32B50E11DD0E11DB0E31DB0E61DA0E91DA0EB1D90EE1D90FD1DC1001DD1041DD10C1DC1101D91131D9111FFFFFF1D910E1D90EE1DA0EB1DA0E91DB0E61DB0E31DD0E12B50E12B70E22B60E42B60ED2B70F12B70F52B80F71E80F72B50F72B50F62B60F32B60E42B70E22B50E11DD0E11DB0E31DB0E61DA0E91DA0EB1D90EE1D91191DA1191DC11C1DD11F1DD1281DC12B1DA12E1D912F1D812D1D81261D91231D90EE1DA0EB1DA0E91DB0E61DB0E31DD0E12B50E12B70E22B60E42B60F32B50F62B50F720C0F720A0F91E60F91E810F26010F26810B26B10826D10226D0F72B50F72B50F62B60F32B60E12B50E01E00E01DF0DF1DF0DC1DD0D81DD0D61D80D61D50D71C10D71BE0D81A80D81A50D91910D918E0DA17D0DA17D0DD17E0E017E0EB17F0EE17F0FA17F0F91740F91750FC1750FF17610217610117410717210C17111116D11B16912316612716412B16112F15F13315C13815913C15714014916314716714516C14317014017513E17913518513218A13018E12D19312B19712919C1261AB1261B01251B51231BA1251B51261B01261AB1271A61271A112919C12B19812F18E13518613818113E17914017514317014516C14816714A16314B15E15514515714115A13C15C13715F13316113016412B16612716912316D11B17111117210C1731091741071751041761021750FF1750FC1740F917F0F917F0FA17F0EE17E0EB17E0E017D0DD17D0DA18E0DA1910D91A50D91A80D81BE0D81C10D71D50D71D80D61DD0D61DD0D81DF0DC1DF0DF1E00E02B50E02B60E12B60F32B50F62B50F726D0F726D0F926B0FC26B10226B10127610127710327810327710427610626B10626C10526D10226D0F72B50F72B50F62B60F32B60E12B50E01F90E0FFFFFF1F60E01E00E01DF0DF1DF0DC1DD0D81DD0D61D80D61D50D71C10D71BE0D81A80D81A50D91910D918E0DA17D0DA17D0DD17E0E017E0EB17F0EE17F0FA17F0F91740F91750FC1750FF17610217510417410717310917210C17111116D11B16912316612716412B16113015F13315C13715A13C15714115514514B15E14A16314816714516C14317014017513E17913818113518612F18E12B19812919C1271A11271A61261AB1261B01251B51221BA1281BA12B1BB12A1BB12A1B612D1A712F1A313219F13519A13819613A19213D18E13F18A14118514218114417C14617214816E14A16914C16514F16115115D15715515B14D15D14815F14416313A16413516812B17610F1771091771051750FF1750FC1740F917F0F917F0FA17F0EE17E0EB17E0E017D0DD17D0DA18E0DA1910D91A50D91A80D81BE0D81C10D71D50D71D80D61DD0D61DD0D81DF0DC1DF0DF1E00E02B50E02B60E12B60F32B50F62B50F726A0F726B0F71E80F72B50F72B50F62B60F32B60E12B50E01E00E01DF0DF1DF0DC1DD0D81DD0D61D80D61D50D71C10D71BE0D81A80D81A50D91910D918E0DA17D0DA17D0DD17E0E017E0EB17F0EE17F0FA17F0F91740F91750FC1750FF17710517710817810B17811017711617611917212117112516B13116A13616614016514416314916214E15A15E15716215516615216915016D14E17214A17A14917F14718314518D14419114219514119A13F19E13C1A213A1A61371AA1351AE1331B31311B71321BC1311B71331B31351AE1381AA13E19E14119A14319514419114518C14618814818314917F14A17A14C17614E17115016D15216A15516515716215A15E16015216114E16514416614016A13616B13117112517212117611917811317810B1771081771051750FF1750FC1740F917F0F917F0FA17F0EE17E0EB17E0E017D0DD17D0DA18E0DA1910D91A50D91A80D81BE0D81C10D71D50D71D80D61DD0D61DD0E01DE0E01D80DE1CF0DE1D60E21D60E71D70ED1D71231D61291D612E1D012F1C312F1B113019F12F19212F18C12E18B12E18C12D18B12918A12318A0ED18B0E718C0E318B0E218C0E21920E119F0E11B10E01C30E11D00E11D30E01D50DE1D80DE1DB0DF1DB0DE1DD0D61D80D61D50D71C10D71BE0D81A80D81A50D91910D918E0DA17D0DA17D0DD17E0E017E0EB17F0EE17F0FA17F0F91740F91750FC1750FF17710517710817810B17811317611917212117112516B13116A13616614016514416114E16015215A15E15716215516515216A15016D14E17114C17614A17A14917F14818314618814518C14419114319514119A13E19E1381AA1351AE1331B31311B71321BC1361BC1391BD13C1B913C1B413E1AC13F1A71411A314219F14819314B18F15118315318015717815817415A16F15B16B15D16715E16215F15E16115916215516415016514C16B14016D13D17113517213217412E17512A17712617812217911D17A11717911617911417811017810B1771081771051750FF1750FC1740F917F0F917F0FA17F0EE17E0EB17E0E017D0DD17D0DA18E0DA1910D91A50D91A80D81BE0D81C10D71D50D71D80D6FFFFFF1DA0D61DD0D61DD0DE1DB0E31DB0E61DA0E91DA0EB1D90EE1D91021DA1061DA10A1DB10E1DB1111DC1151DC11C1DD11F1DD1251DE1271DE12D1DF1311DF1361DF1341C51341C31361C413A1C61461C514C1C31511C11571B91611B41641AD1661A71681A016919B16819516619016418C16118815D18415118314C18314018413A18513618313618312D18212A18211C18111918110E18010B1800FF17F0FC17F0F91740F91750FC1750FF17710517710817810B17811017911417911617B11C17B11D17912517712817513017313417113C16F14016E14416C14916B14D16915116815616715A16515E16416216316716116B16016F15E17315D17715B17B15A17E15218E15019114A19D1491A11451A91441AD1421B113F1BD1401BA1411B51421B11441AD1451A91491A114A19D14E19515019215218D15418A15818215A17F15B17B15F17316116B16316716416316515E16615A16815616915116B14D16C14916D14417113C17313417513017612C17812917812517A12117B11D17B11C17911617911417811017810B1771081771051750FF1750FC1740F917F0F917F0FC1800FF18010B18110E18111918211C18212A18312D18313A18213D18214018114318114C18315218315518615718715A18915D18C16119016419316519516619B16819E1681A01691A41681A61681AA1671AD1661B11651B41641B71621B91611BB15E1BD15D1C11571C414E1C514C1C61491C61461C51431C513D1C413A1C31361BA1361BB13A1BB13E1BC1431BA14D1B71511B51561B21591AE15C1A915E1A515F19C15F19815E19415C19115A18F15718D14F18C14A18C13F18D13A18D1361C31361C413A1C513D1C51431C61461C61491C514C1C414E1C11571BD15D1BB15E1B91611B71621B41641B11651AD1661AA1671A61681A41681A016919E16819B16819516619316519016418C16118915D18715A18615718315518315218114C18114318214018213D18313A18312D18212A18211C18111918110E18010B1800FF17F0FC17F0F91740F91750FC1750FF17710517710C17610F17411417211717111B16E11F16812B16613016513515F14415D14815B14D15715515115D14F16115016114816B14C16915216915416A15516C15516E15117014E17014B16F14916E14816D14816B14A16914C16514F16115115D15715515B14D15D14815F14416513516613016812B16E11F17111B17211717411417610F17710C1771051750FF1750FC1740F917F0F917F0FC1800FF18010B18110E18111918211C18212A18312D18313A18213D18214018114318114C18315218315518615718715A18915D18C16119016419316519516619B16819E1681A01691A41681A61681AA1671AD1661B11651B41641B71621B91611BB15E1BD15D1C11571C414E1C514C1C61491C61461C51431C513D1C413A1C313618B13618B1381AA1381A81371A913A1AB13E1AB1481AA14D1A91511A71541A215919D15919B15819A15C19C15C19F15D1A315C1A615A1AA1571AE14D1AF1481AF1431AD1391AB1351AD1361DF1361DF1311DE12D1DE1271DD1251DD11F1DC11C1DC1151DB1111DB10E1DA10A1DA1061D91021D90EE1DA0EB1DA0E91DB0E61DB0E31DD0DE1DD0D61D80D61D50D71C10D71BE0D81A80D81A50D91910D918E0DA17F0DA17D0D81700E016F0E116E0E416C0E816A0ED1670F21650F815F10415C10B15811115411914C12714812F13E13F13A14813015812C16012716912317111E17911A18111718811318F10A1A11061AB1051B01041B41041BB1061C11081C410B1C71141CD1161CF1301D214C1CB14D1CA1521C01531BC1551B71571B31581AE15A1A915B1A315C19E15E19816019316418716718016A17A16C17416F16E17116817416217615C17915717F14818114418313C18413918513718513617F0DA17F0DD1800E01800E617E0E617E0EB17F0EE17F0F71740F71730F91710FC16F10216C10816910F16511615F12415B12B15713315213A14E14214A14913A16913217712F17E12718C12419212019811C1A411A1AE1191B21191B611A1BA1441C01461BF1471BC14B1B415719615819115A18B15C18616017A16317516B15D16E15717414517614017813A17913417B12F17D12517D1211760F9FFFFFF1770F71810F71810EE1800EB1800E017F0DD17F0DA18E0DA1910D91A50D91A80D81BE0D81C10D71D50D71D80D61DD0D61DD0D81DF0DC1DF0DF1E00E02B50E02B60E12B60F32B50F62B50F92700F92770EE2700F92760F927C0EE2760F927B0F92820EE27B0F92810F92870EE2810F92860F928D0EE2860F928C0F92920EE28C0F92910F92980EE2910F92970F929D0EE2970F929D0F92A30EE29D0F92A20F92A80EE2A20F92A80F92AE0EE2A80F92AD0F92B40EE2AD0F92B30F92B90EE2B30F926D0F926B0FC26B10226A10426910826710A26310C25F10D25C10E1F110E1F71051F110E1F710E1FC1051F710E1FC10E2021051FC10E20210E20710520210E20710E20D10520710E20D10E21310520D10E21310E21810521310E21810E21E10521810E21E10E22310521E10E22310E22910522310E22910E22E10522910E22E10E23410522E10EFFFFFF23410E23910523410E23910E23F10523910E23F10E24410523F10E24410E24A10524410E24A10E24F10524A10E24F10E25510524F10E25510E25A10525510E25C10E25F10D26310C26710A26910826A10426B10226B0FC26D0F926D0F72B50F72B50F62B60F32B60E42B70E22B50E11DD0E11DB0E31DB0E61DA0E91DA0EB1D90EE1D90F31D80F51D70F61D71231D61261D612E1D312E1D012F1C712F1C313019F13019C12F19B13119813119513019213019412819213019513019812819513019913019C12819913019D1301A012819D1301A01301A31281A01301A41301A71281A41301A81301AB1281A81301AB1301AE1281AB1301AF1301B21281AF1301B31301B61281B31301B71301B91281B71301BA1301BD1281BA1301BE1301C11281BE1301C21301C41281C21301C51301C81281C51301C91301CC1281C91301CD1301CF1281CD1301D61301D612E1D812D1D81261D91231D910E1DB10E1DB1111DC1151DC11C1DD11F1DD1251DE1271DE12D1DF1311DF1361BC1361BC1391B713C1BC1391BD13E1B713F1BD13E1BD1431B71431BD1431BD1481B71471BD1481BB14D1B514B1BB14D1B91521B414F1B91521B61571B21521B61571B315B1AF1551B315B1AF15E1AC1581AF15E1AA1601A91591AA1601A51611A515AFFFFFF1A51611A01611A115B1A016119C16119E15B19C16119715F19A15A19715F19315D19715819315D19015B19415619015B18E15719215318E15718C15319115018C15318B14F19114C18B14F18A14A19114918A14A18A14519114518A14518A13F19114018A13F18B13A19113C18B13A18B1361DF1361DF1311DE12D1DE1271DD1251DD11F1DC11C1DC1151DB1111DB10E1DA10A1DA1061D91021D90EE1DA0EB1DA0E91DB0E61DB0E31DD0E12B50E12B70E22B60E42B60F32B50F62B50F92750F92760F926F0EE2760F927B0F92750EE27B0F92810F927A0EE2810F92860F92800EE2860F928C0F92860EE28C0F92910F928B0EE2910F92970F92910EE2970F929D0F92960EE29D0F92A20F929C0EE2A20F92A80F92A10EE2A80F92AD0F92A70EE2AD0F92B30F92AC0EE2B30F926D0F926B0FC26B10226A10426910826710A26310C25F10D25C10E1F710E1F11051F710E1FC10E1F71051FC10E20210E1FC10520210E20710E202105FFFFFF20710E20D10E20710520D10E21310E20D10521310E21810E21310521810E21E10E21810521E10E22310E21E10522310E22910E22310522910E22E10E22910522E10E23410E22E10523410E23910E23410523910E23F10E23910523F10E24410E23F10524410E24A10E24410524A10E24F10E24A10524F10E25510E24F10525510E25C10E25F10D26310C26710A26910826A10426B10226B0FC26D0F926D0F72B50F72B50F62B60F32B60E42B70E22B50E11DD0E11DB0E31DB0E61DA0E91DA0EB1D90EE1D90F31D80F51D70F61D71231D61261D612E1D312E1D313019713019212719713019D13019712719D1301A213019D1271A21301A81301A21271A81301AD1301A81271AD1301B31301AD1271B31301B81301B31271B81301BE1301B81271BE1301C31301BE1271C31301C91301C31271C91301D61301D612E1D812D1D81261D91231D910E1DB10E1DB1111DC1151DC11C1DD11F1DD1251DE1271DE12D1DF1311DF13618B13618B13A18A13F19414318A13F18A14A19414AFFFFFF18A14A18B14F18C15319515018C15319015B19815419015B19315D19715F19D15719715F19C1611A01611A21571A01611A51611AA1601A71561AA1601AF15E1B315B1AC1531B315B1B61571B91521B014F1B91521BD1481B31491BD1481BD13E1B41421BD13E1BC1391BC1361DF1361DF1311DE12D1DE1271DD1251DD11F1DC11C1DC1151DB1111DB10E1DA10A1DA1061D91021D90EE1DA0EB1DA0E91DB0E61DB0E31DD0DE1DD0D61D80D61D50D71C10D71BE0D81A80D81A50D91910D918E0DA17D0DA17B0DB1780DD1760DF1730E01710E116E0E91710F016E0E916A0F016E0F716A0F01670F716B0FF1670F71640FE1681061640FE16010516510C16010515D10C16211315D10C15911315E11A15911315511A15B12015511A15112115712715112114E12815412E14E12814A12F15013414A12F14613614D13A14613614213D14914114213D13E14414614713E14413A14B14214E13A14B13615113E15413615113215813A15A13215812F15F13716112F15F12B16613316712B16612716D12F16E12716D12317412C17412317412017B12817B12017B11C18212418111C18211818912018811818911519011D18F11519011119711919511119710D19E11519C10D19E10A1A51121A310A1A51071AD10F1AA1071AD1061B410E1B11061B41061BC10E1B91061BC10A1C31111C010A1C31101C81171C41101C81161CDFFFFFF"
QD_N     = 2709 # points (incl. pull breaks)

def qd_hex3(p : UInt8*) : Int32
  v = 0
  k = 0
  while k < 3
    c = p[k].to_i32!
    v = v &* 16 &+ (c >= 65 ? c &- 55 : c &- 48)
    k = k &+ 1
  end
  v
end

def quick_draw : Nil
  return unless SkInk.ready?
  log("sketch: quick draw", 0)
  t0 = millis
  base = QD_PTS.to_unsafe
  pulls = 0
  k = 0
  while k < QD_N
    p = base + (k &* 6).to_i64!
    x = qd_hex3(p)
    if x == 0xFFF
      Shared.led_mode = pulls & 1 == 0 ? LED_YELLOW : LED_CYAN
      SkInk.take_touches
      SkInk.cursor_to(Sketch.x, Sketch.y) # the cursor rides along with the pen
      SkInk.pull
      pulls = pulls &+ 1
    else
      Sketch.pen_to(x, qd_hex3(p + 3_i64))
    end
    k = k &+ 1
  end
  Sketch.forget_knobs
  SkState.pen_seen(Sketch.x, Sketch.y)
  log2("sketch: quick draw pulls / ms", pulls, millis &- t0)
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
        inked = SkInk.take_touches
        inked = true if SkInk.cursor_to(Sketch.x, Sketch.y)
        if inked
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
