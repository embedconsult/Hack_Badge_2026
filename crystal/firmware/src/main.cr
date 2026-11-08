# Badge firmware in Crystal (--prelude=empty: compiler primitives, `lib`
# bindings and `fun` only; no stdlib, GC or exceptions).
#
# - crystal_knob_task (FreeRTOS task, started from main.c): blinks the status
#   LED at a rate set by the left knob and logs both knobs once a second.
# - crystal_app_main: draws a test pattern on the e-paper and refreshes it,
#   logging the time each phase takes (src/epd.cr).

require "./rt"
require "./dbg"

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

  # Press counts (Games.count_presses): written only by the knob task, one
  # word, so the main task never misses a press it was too busy to see.
  @@presses = 0_u32
  @@presses_seen = 0_u32 # main task: presses already delivered

  def self.count_presses(held : UInt32, prev_held : UInt32) : Nil
    @@presses = Games.count_presses(@@presses, held, prev_held)
  end

  # Main task: buttons with a press not yet delivered (one each per call).
  def self.next_presses : UInt32
    Games.next_presses(@@presses, pointerof(@@presses_seen))
  end

  # Main task: forget the presses not yet delivered.
  def self.drop_presses : Nil
    @@presses_seen = @@presses
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
  @@upd_sk = UPD_WIN # the user: "sketch with artifacts is better than sketch that is slow" (GOALS.md)
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
  REQ_WTEST     = 64_u32 # erase waveform test (WTest.codes)
  REQ_WBAR      = 128_u32 # window addressing test (wbar)

  @@fake = 0_u32 # buttons the shell holds down (until @@fake_until)
  @@fake_until = 0

  def self.fake_buttons : UInt32
    return 0_u32 if @@fake == 0_u32
    @@fake = 0_u32 if millis &- @@fake_until >= 0
    @@fake
  end

  def self.hold_fake(bits : UInt32, ms : Int32) : Nil
    @@fake_until = millis &+ ms
    @@fake = bits
  end

  @@idle_job = false # an idle-time slow refresh: any input aborts it
  @@idle_l = 0
  @@idle_r = 0

  def self.idle_job? : Bool
    @@idle_job
  end

  def self.idle_l : Int32
    @@idle_l
  end

  def self.idle_r : Int32
    @@idle_r
  end

  def self.idle_job=(v : Bool) : Nil
    @@idle_l = @@mv_l
    @@idle_r = @@mv_r
    @@idle_job = v
  end

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
  b | Shared.fake_buttons # shell `press menu`: held for real, through the same path
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
  # Every RMT channel shares one interrupt, which is wired to the core that
  # opened the channel. Open the knob pixel here too, on core 1 with the bar:
  # opened on core 0, a bar interrupt left core 0 re-entering its ISR during
  # an OTA flash erase while core 1 (masked) could not clear it: IWDT panic.
  led_test
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
    Shared.count_presses(btns, prev_btns) # before the wake-up below
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
    # A Menu press aborts a slow (colour) refresh in progress; during an
    # idle one (red residue clean, Sketch idle colour) any button or knob
    # turn does, so a visitor picking the badge up is never kept waiting.
    if (btns & (Games::BTN_PLUS | Games::BTN_MINUS)) != 0_u32 && EPD.abortable?
      EPD.request_abort
    end
    if Shared.idle_job? && EPD.abortable?
      il = mv_l &- Shared.idle_l
      ir = mv_r &- Shared.idle_r
      if btns != 0_u32 || il > 40 || il < -40 || ir > 40 || ir < -40
        EPD.request_abort
      end
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
    if now &- last_stack >= 10_000 && Dbg.on?(Dbg::KNOB) # shell `debug knob on`
      last_stack = now
      log2("stack: free bytes knob / main", LibIDF.cr_stack_free(false).to_i32!, LibIDF.cr_stack_free(true).to_i32!)
    end
    if now &- last_log >= 1000 && Dbg.on?(Dbg::KNOB)
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
  draw_sketch_hint(false) # the help strip (its own background redraw drops it)
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

# Erase waveform test (shell `wtest <A> <B> <C>`, 20 digits each: level
# per frame, 0 GND 1 VDH 2 VDL 3 VDHR). Three groups (a solid block, text
# and thin lines) are put up black with a normal clean refresh, then one
# ink pull erases group 1 with waveform A, group 2 with B, group 3 with C
# (ink commands 1, 2, 3); the labels stay. Photograph the result. Run a
# slow `clean` before each test: red residue survives fast refreshes.
module WTest
  @@codes = Pointer(UInt8).null

  @@pulls = 1

  def self.codes : UInt8*
    @@codes = game_alloc(64) if @@codes.null?
    @@codes
  end

  def self.pulls : Int32
    @@pulls
  end

  def self.pulls=(v : Int32) : Nil
    @@pulls = v < 0 ? 1 : (v > 9 ? 9 : v)
  end
end

def wt_group(p : UInt8*, y : Int32) : Nil
  Games.fill_rect(p, 120, y, 160, 60)
  k = 0
  while k < 6
    Games.fill_rect(p, 320 &+ k &* 14, y, 3, 60)
    k = k &+ 1
  end
end

# Window addressing test (shell `wbar <mode> [kind]`): a white base with a
# full refresh, then four bars (rows 100, 300, 400, 560, 16 rows each, at
# x 100 / 300 / 500 / 700, 120 px wide), each drawn into the black plane and
# put up with its own rows-only refresh_window2 (mode given, rows = bar +-
# 8). Photograph: each bar must land at its rows/x, nothing anywhere else.
module WBar
  @@mode = 8
  @@kind = 3

  def self.mode : Int32
    @@mode
  end

  def self.kind : Int32
    @@kind
  end

  @@y0 = -1
  @@step = 0

  def self.y0 : Int32
    @@y0
  end

  def self.step : Int32
    @@step
  end

  def self.set(m : Int32, k : Int32, y0 : Int32, step : Int32) : Nil
    @@mode = m
    @@kind = k
    @@y0 = y0
    @@step = step
  end
end

def wbar_test : Nil
  Shared.rendering = true
  EPD.fill(EPD::WHITE)
  fast_bw(3, EPD::LUT_BASE)
  i = 0
  n = WBar.y0 < 0 ? 4 : 6
  while i < n
    y = WBar.y0 < 0 ? (i == 0 ? 100 : (i == 1 ? 300 : (i == 2 ? 400 : 560))) : WBar.y0 &+ i &* WBar.step
    x = 60 &+ i &* 150
    EPD.fill_rect(x, y, 120, 16, EPD::BLACK)
    EPD.fast_pulls = 1
    rc = EPD.refresh_window2(y &- 8, y &+ 23, 0, EPD::HALF_BYTES &- 1, y &- 8, y &+ 23, 0, EPD::HALF_BYTES &- 1, WBar.kind, WBar.mode)
    log3("wbar: bar y / mode / panel ms", y, WBar.mode, rc)
    i = i &+ 1
  end
  Shared.rendering = false
end

def wtest : Nil
  Shared.rendering = true
  log("wtest: start", 0)
  EPD.fill(EPD::WHITE)
  i = 0
  while i < 3
    y = 130 &+ i &* 170
    draw_text(30, y &+ 10, i == 0 ? "A" : (i == 1 ? "B" : "C"), EPD::BLACK, 6)
    wt_group(EPD.black, y)
    draw_text(440, y &+ 10, "ERASE 123", EPD::BLACK, 5)
    i = i &+ 1
  end
  fast_bw(3, EPD::LUT_BASE)
  pn = LibIDF.heap_caps_malloc(EPD::PLANE.to_u32!, 0x404_u32).as(UInt8*)
  po = LibIDF.heap_caps_malloc(EPD::PLANE.to_u32!, 0x404_u32).as(UInt8*)
  return if pn.null? || po.null?
  Games.zero(pn, EPD::PLANE)
  Games.zero(po, EPD::PLANE)
  # group content = black pixels right of the labels
  i = 0
  while i < 3
    y0 = 130 &+ i &* 170
    r = y0
    while r < y0 &+ 60
      c = 110.unsafe_shr(3)
      while c < EPD::ROW_BYTES
        v = EPD.black[r &* EPD::ROW_BYTES &+ c]
        o = r &* EPD::ROW_BYTES &+ c
        pn[o] = v if i != 1  # commands 1 (A) and 3 (C)
        po[o] = v if i != 0  # commands 2 (B) and 3 (C)
        EPD.black[o] = 0_u8
        c = c &+ 1
      end
      r = r &+ 1
    end
    i = i &+ 1
  end
  if WTest.pulls == 0 # erase with a normal fast clean (base LUT, 3 pulls)
    fast_bw(3, EPD::LUT_BASE)
    LibIDF.heap_caps_free(pn.as(Void*))
    LibIDF.heap_caps_free(po.as(Void*))
    Shared.rendering = false
    log("wtest: fast clean done", 0)
    return
  end
  EPD.ink_custom = WTest.codes
  n = 0
  while n < WTest.pulls
    log("wtest: pull ms", EPD.refresh_ink(pn, po))
    n = n &+ 1
  end
  EPD.ink_custom = Pointer(UInt8).null
  EPD.cog_stop
  LibIDF.heap_caps_free(pn.as(Void*))
  LibIDF.heap_caps_free(po.as(Void*))
  Shared.rendering = false
  log("wtest: done", 0)
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
  @@saved_sk = UPD_WIN # values last stored in NVS
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

# Red on the panel. Fast tables can't remove red pigment (EPD_NOTES), so
# a screen that replaces a colour image leaves a red ghost. on_panel: a
# colour image is up on purpose; residue: a fast refresh replaced it (or an
# OTA status screen ran). The main loop then redraws the current screen
# with one slow (OTP) refresh once the badge has been idle RES_IDLE_MS.
module RedRes
  @@on_panel = false
  @@residue = false

  def self.on_panel? : Bool
    @@on_panel
  end

  def self.on_panel=(v : Bool) : Nil
    @@on_panel = v
  end

  def self.residue? : Bool
    @@residue
  end

  def self.residue=(v : Bool) : Nil
    @@residue = v
  end

  # A fast refresh is about to replace what is on the panel.
  def self.replaced : Nil
    @@residue = true if @@on_panel
    @@on_panel = false
  end
end

RES_IDLE_MS = 60_000
SK_IDLE_COLOUR_MS = 60_000 # Sketch: idle this long -> the red frame (colour render) # idle time before the automatic slow clean of red residue (any input aborts it)

# Slow full-colour refresh that a Menu press can abort.
def colour_refresh : Bool
  Shared.rendering = true
  EPD.abortable = true
  ok = EPD.refresh(false)
  aborted = EPD.aborted?
  EPD.abortable = false
  Shared.rendering = false
  log2("main: colour refresh ok / aborted", ok ? 1 : 0, aborted ? 1 : 0)
  if ok || aborted # an aborted wait still runs the waveform to its end
    RedRes.residue = false # a full OTP refresh cleans the whole panel
    RedRes.on_panel = EPD.has_red?
  else
    RedRes.residue = true
  end
  ok
end

# Automatic slow clean (RedRes): the current planes again, with the OTP
# waveform, which removes red residue (the image itself doesn't change).
def red_residue_clean(scr : Int32) : Nil
  log("main: slow clean of red residue, screen", scr)
  # Any input aborts the wait (Shared.idle_job): the main loop is free at
  # once, but the OTP waveform itself can't be cut short; it runs to its end
  # (same image, red removed) and the next refresh waits for it
  # (EPD.finish_aborted). Knob motion keeps being tracked meanwhile.
  Shared.idle_job = true
  colour_refresh
  Shared.idle_job = false
  RedRes.residue = false # aborted or not, the waveform completes
  SkState.mark_shown
  Sketch.forget_knobs if scr == SCR_SKETCH
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
  @@prev = Pointer(UInt8).null # pixels the previous pull touched (one pass per visit)
  @@cold = Pointer(UInt8).null
  @@lo = 0 # byte range of the command planes in use (to clear after)
  @@hi = -1


  def self.ready? : Bool
    if @@pass.null?
      @@pass = LibIDF.heap_caps_malloc((EPD::PLANE &* 8).to_u32!, 0x404_u32).as(UInt8*)
      @@cnew = LibIDF.heap_caps_malloc(EPD::PLANE.to_u32!, 0x404_u32).as(UInt8*)
      @@cold = LibIDF.heap_caps_malloc(EPD::PLANE.to_u32!, 0x404_u32).as(UInt8*)
      @@prev = LibIDF.heap_caps_malloc(EPD::PLANE.to_u32!, 0x404_u32).as(UInt8*)
      return false if @@pass.null? || @@cnew.null? || @@cold.null? || @@prev.null?
      Games.zero(@@prev, EPD::PLANE)
      Games.zero(@@cnew, EPD::PLANE)
      Games.zero(@@cold, EPD::PLANE)
      @@hi = -1
    end
    !@@pass.null? && !@@cnew.null? && !@@cold.null? && !@@prev.null?
  end

  # ---- shake to erase ----------------------------------------------------------
  # Like shaking an Etch-a-Sketch: the lines dissolve before the screen is
  # clean. One session with a shake table (three lighten strengths, VDL 4 /
  # 8 / 19 frames): pull 1 lightens each inked pixel by a random strength
  # (speckled fade), pull 2 drives them all strongly. The erase clean that
  # follows (3 full-drive pulls) removes what is left, pink included.
  SHAKE_CODES = "222200000000000000002222222222222222222022222222000000000000" # tables 1, 2, 3

  def self.shake : Nil
    return unless ready?
    codes = WTest.codes
    k = 0
    while k < 60
      codes[k] = SHAKE_CODES.to_unsafe[k] &- 48_u8
      k = k &+ 1
    end
    Shared.rendering = true
    t0 = millis
    seed = (millis | 1).to_u32!
    step = 0
    while step < 2
      Games.zero(@@cnew, EPD::PLANE)
      Games.zero(@@cold, EPD::PLANE)
      any = false
      i = 0
      while i < EPD::PLANE
        q = @@pass + (i &* 8).to_i64!
        n = 0_u8
        o = 0_u8
        b = 0
        while b < 8
          if q[b] != 0_u8
            m = 0x80_u8.unsafe_shr(b)
            r = 2_u32
            if step == 0
              seed = seed &* 1103515245_u32 &+ 12345_u32
              r = seed.unsafe_shr(16).unsafe_mod(3_u32)
            end
            # r 0: cmd 1 (VDL 4), 1: cmd 3 (VDL 8), 2: cmd 2 (VDL 19)
            n = n | m if r != 2_u32
            o = o | m if r != 0_u32
            any = true
          end
          b = b &+ 1
        end
        @@cnew[i] = n
        @@cold[i] = o
        i = i &+ 1
      end
      break unless any
      Shared.led_mode = step == 0 ? LED_YELLOW : LED_CYAN
      EPD.ink_custom = codes if step == 0 # a new table: one new session for both pulls
      EPD.refresh_ink(@@cnew, @@cold)
      step = step &+ 1
    end
    EPD.ink_custom = Pointer(UInt8).null # (stops the shake session; power stays on)
    Games.zero(@@cnew, EPD::PLANE)
    Games.zero(@@cold, EPD::PLANE)
    @@hi = -1
    Shared.rendering = false
    log2("sketch: shake pulls / ms", step, millis &- t0)
  end

  # ---- pen point ---------------------------------------------------------------
  # No separate cursor (crosshair ticks left marks): the pen point is the
  # cursor. A resting pen re-inks its 3x3 dot one light pass every
  # DWELL_MS, up to DWELL_CAP passes, so it shows where the pen is without
  # blotting; moving on lays the normal passes.
  DWELL_MS  = 3000 # rest this long before the pen dot gets its one extra pass
  DWELL_CAP = 2    # ...and only if it has fewer passes than this

  def self.dwell_ink(x : Int32, y : Int32) : Bool
    return false unless ready?
    q = @@pass + (y &* EPD::WIDTH &+ x).to_i64!
    return false if q.value >= DWELL_CAP.to_u8!
    Games.fill_rect(Sketch.touch, x &- Sketch::HALF, y &- Sketch::HALF, Sketch::LINE_W, Sketch::LINE_W)
    # a new visit: forget that the last pull touched the dot
    yy = y &- Sketch::HALF
    while yy <= y &+ Sketch::HALF
      xx = x &- Sketch::HALF
      while xx <= x &+ Sketch::HALF
        i = yy &* EPD::ROW_BYTES &+ xx.unsafe_shr(3)
        @@prev[i] = @@prev[i] & (0x80_u8.unsafe_shr(xx & 7) ^ 0xFF_u8)
        xx = xx &+ 1
      end
      yy = yy &+ 1
    end
    true
  end

  # After a full refresh: what the canvas shows is solid black (full
  # passes), the rest has none; pending touches are dropped.
  def self.sync_from_canvas : Nil
    return unless ready?
    @@pw0 = -1
    Games.zero(@@prev, EPD::PLANE)
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
    pv = @@prev
    i = 0
    while i < EPD::PLANE
      t0 = tc[i]
      # One pass per visit: a pixel the previous pull also touched is the
      # same pass of the pen (a slow stroke covers each pixel of its 3 px
      # line in 2-3 pulls), not a retrace.
      t = t0 & (pv[i] ^ 0xFF_u8)
      pv[i] = t0
      if t0 != 0_u8
        tc[i] = 0_u8
        bk[i] = bk[i] | t0
        rd[i] = rd[i] & (t0 ^ 0xFF_u8)
      end
      if t != 0_u8
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
QD_PTS = "1DF1361D81361D51371C81371C51381C21381BF1391BD13A1BC13C1BB13D1B91411B81421B71441B61451B51471B31481B314C1B214D1B214F1B11511B11521B01541B01561AF1571AF1591AC15F1AA1601A81601A71611A51621A41631A21631A016419F16519D16619A16619816719616719416819116818F16918C16918A16A18716A18416C18216D18116E17F16F17D17317C17417C17617B17817B17D17A17F17A18817918917918B17818D17718E17619017419217219317019516E19616D19716919916719916519A14E19A14819714719514519414419314319114219014118E13F18C13E18A13D18913C18713818313618213518113318113118012C18012A18112818112718212518212318312218412018511F18611D18711C18911A18B11818C11718E11618F11519111319311319511219711219A11119C11119E1101A01101A210F1A310F1B81101BA1101BB1111BD1111C01121C21121C31131C51131C81141CA1141CD1151CF1151D11161D21161D41151D71141D81101DA10A1DA1091DB1031DB1011DC0D51DC0D41DB0CB1DB0C91DA0C21DA0BF1D90BE1D80BC1D70BC1D10BD1CF0BD1CD0BE1CC0BF1CA0BF1C80C01C70C01C50C11C40C21C20C21C10C31BF0C31BD0C41BC0C51BA0C51B90C61B70C61B50C71B40C81B20C81B10CA1AD0CA1AC0CB1AA0CB1A90CC1A70CD1A60CD1A40CE1A20CE1A10CF19F0D019E0D019C0D119A0D11990D21970D31960D31940D41930D51910D518F0D618E0D718C0D718B0D81890D91880D91860DA1850DB1830DB1810DC1800DD17E0DE17D0DE17B0E01790E11770E21760E31740E41730E51710E716F0E816D0EA16B0EC16A0ED1680EF1660F01640F21630F41610F61600F715F0F915E0FA15D0FB15B0FD15A0FE15910015810215810315710715510815510C15310D15211115211315111615111815011A15011B14F11F14F12114E12414B12614A12714812914612B14512D14312F14213014113214013213B13113913113613013413012812F12612F12512511B12411912311812111412011311F11111F11011D10F11C10D11910A11710911610711810511B10411D10511F10512210612410712510912710A12910C12B10D12C10F12E11012F11013311213911213A11113C11113E11014010E14210D14310C14510B14610A14810914910814B10714D10715110515D10515F10417510417610518810518A1041AC1041AE1051B01051B11061B31061B51071B71071B91081BA1091BC10A1BF10B1C610B1CA10C24010C24310B2DF10B2E110A2E21092E31072E31052E41032E41012E50FF2E60FE2E80FD2ED0FD2EF0FE2F20FE2F51012F71022F81042FC1082FD10A2FF10A30110B30210B30410C30610C30710D30910E30911030A11230B11330B11E30A11F30A1233091253071273051273031282F71282F51292EE1292ED12A2EB12B2EB12D2EA12EFFFFFF2E91302E81312E81332E41352561352531361D81361D71371C81371C71381C21381C01391BF1391BD13A1BC13C1BB13D1B91411B81421B71441B61451B51471B41481B214C1B214F1B11501B11521B01541B01551AF1571AF1591AC15F1AA1601A81601A71611A51621A41631A21631A016419F16519D16619B16619916719616719416819116818F16918C16918A16A18716A18416C18216D17E17117D17317C17417C17617B17815D17116917117117417617A17817E17818317718817318E16C19415E19715419714F19614819114418A14318514417D14917714917D14B18715119015519215619114F18314F17815217415D17115E17115F17216317216417316717316817416C17416D17516F17517117617517617617717817717A17817B17817C17617C17417D17317E17118216D18416C18716A18A16A18C16918F16919116819416819616719916719B16619D16619F1651A01641A21631A41631A51621A71611A81601AA1601AC15F1AF1591AF1571B01551B01541B11521B11501B214F1B214C1B41481B51471B61451B71441B81421B91411BB13D1BC13C1BD13A1BF1391C01391C21381BD1262EA1262EE1292F71292F912830512830712730912530A12330A12030B11E30B11330A11230911030910F30810D30610C30410C30210B30110B2FD1092FC1082FA1072F91052F81042F71022F51012F20FE2EF0FE2ED0FD2EA0FD2E80FE2E60FE2E50FF2E41012E41032E31052E31072E21092E010A2DF10B28810BFFFFFF28610B27810B27710C1CA10C1C810B1BD10B1BC10A1BA1091BB1261BB1121BA1111BA1091B91081B71071B51071B31061B11061B01051AE1051AC10418810418610517810517610415D10415B10515810515910F15B10F15F10E16410E16910D18D10D19210E19710E19B10F19D10F19F1101A01121A11151A311F1A41251A41411A214D1A11511A015419F15619D15719B15719715819215818D15918315917E15A17815A17315916915916415815F15815B15715915715815615715415615115514D15414715411F15611515711215811015910F15810E15810515110514D10714B10714910814810914610A14510B14310C14210D14010E13F10F13C10A13B10D13611713411C13312113212713213713413C13514113814513B14A14115014515314A15515215715515815415815215715015714E15614D15614B15514A15514815414715414515314415214215113B14A13A14813914813814713814613714413714313514113513F13413E13413C13313B13313713213613212413312313311F13411D13411C13511B13511913611813611713711513711413811313711213311212F11012E11012C10F12B10D12910C12810B12B10712C10A13211613411913611D13912013C12913C12D13C12913B12813B12513A12313A12213912013711E13711D13611C13411C13411D13311F13312313212413213613313713313A13213B13214013014112E14312C14412B14512914612714812614A12514B12314C12114E11F14F11B14F11A15011815011615111315111115210F15210D15310C1531081551071551031571021581001580FE1590FD15A0FB15B0FA15C0F915E0F715F0F61600F41610F31620F11630F01640EF1660E816D0E716F0E51710E41730E31740E21760E11770E01790DF17A0DF17C0DD17E0DC1800DB1810DB1830DA1850D91860D91880D81890D718B0D718C0D618E0D518F0D41910D41930D31940D31960D21970D21990D119A0D019C0D019E0CF19F0CE1A10CE1A20CD1A40CD1A60CC1A70CB1A90CB1AA0CA1AC0CA1AD0C81B10C81B20C71B40C61B50C61B70C51B90C51BA0C41BC0C31BD0C31BF0C21C10C21C20C11C40C01C50C01C70BF1C80BE1CA0BE1CC0BD1CD0BD1CF0BC1D10BC1D70BE1D80C01DA0C91DA0CB1DB0D41DB0D51DC0FF1DCFFFFFF1011DB1091DB10A1DA1101DA1121D91131D81151D71161D51161D21151D11151CD1141CC1141CA1131C81131C71121C51121C21111C01111BD1101BB1101BA10F1B810F1A31101A21101A011119E11119C11219A11219711319511319311519111618F11C18911D18711F18612018512218412318312518212718212818112A18112C18012F18012F17E13217D13C17914817514D17315317115816F16416B16B16A17916617F16418616318C16219316119F15F1A415F1A815E1B315E1AE15B1AD15D1AC15E1A815E1A715F19E15F19C16019516019416118F16118E16218A16218816318516318316417F16417E16517B16517A16617716617616717316717216816F16816E16916B16916A16A16816A16716B16416B16316C16116C16016D15E16D15D16E15A16E15816F15717015417015317115117115017214F17214D17314C17314B17414917414817514617514517614417614217714117713F17813E17813C17913B17913A17A13817A13717B13617B13417C13317C13217D13017D12F17E12F17F12E18012C18012A18112818112718212518212318312218412018511F18611D18711C18911618F11519111319311319511219711219A11119C11119E1101A01101A210F1A310F1B81101BA1101BB1111BD1111C01121C21121C51131C71131C81141CA1141CC1151CD1151D11161D21161D51151D71131D81121D91101DA10A1DA1091DB1011DB0FF1DC0D51DC0D41DB0CB1DB0C91DA0C01DA0BE1D80BC1D70BC1D10BD1CF0BD1CD0BE1CC0BE1CA0BF1C80C01C70C01C50C11C40C21C20C21C10C31BF0C31BD0C41BC0C51BA0C51B90C61B70C61B50C71B40C81B20C81B10CA1AD0CA1AC0CB1AA0CB1A90CC1A70CD1A60CD1A40CE1A20CE1A10CF19F0D019E0D019C0D119A0D21990D21970D31960D31940D41930D41910D518F0D618E0D718C0D718B0D81890D91880D91860DA1850DB1830DB1810DC1800DD17E0DF17C0DF17A0E01790E11770E21760E31740E41730E51710E716F0E816D0EF1660F01640F11630F31620F41610F61600F715F0F915E0FA15C0FB15B0FD15A0FE15910015810215810315710715512B15B12114E11F14F11B14F11A15011815011615111315111115210F15210D15310C15310A15410915610A15610A15710415910015D0F61650F216A0EF16F0EB1740E517E0E31840DD18E0DC1940DA1990D819F0D61A40D31AA0D11B00CE1B50CC1BB0C91C00C51CC0C71D20CC1D30D21D40D71D50DD1D50E91D70EF1D70F51D80FB1D81011D90FC1DA0F61DA0F11DB0E51DB0DE1DC1091DA10E1D81101D51101C910E1C110C1BD1091B11081AC1081A41091A010919C10D19411019011818C11D18B12518712A18612218411F18311F18212418112618012317F12317512417112416C12516712616312615E12715AFFFFFF12715C12615D12616312516412516A12416C12417412317512317F12417F12618012718212818112A18112C18012E18012F17F12F17E13017D13217D13317C13417C13617B13717B13817A13A17A13B17913C17913E17813F17814117714217714417614517614617514817514917414B17414C17314D17314F17215017215117115317115417015717015816F15A16E15D16E15E16D16016D16116C16316C16416B16716B16816A16A16A16B16916E16916F16817216817316717616717716617A16617B16517E16517F16418316418516318816318A16218E16218F16119416119516019C16019E15F1A715F1A815E1AC15E1AD15D1AF1591AF1571B01551B01541B11521B11501B214F1B214C1B41481B51471B61451B71441B81421B91411BB13D1BC13C1BD13A1BF1391C01391C21381C71381C81371D71371D81361DF1361DF1341DC1341D81351CB1351C81361C11361BE1371B913C1B913E1B81401B71411B61431B41441B31461B21471B11491B114B1B014D1B014E1AF1501AF1521AE1531AE1551AD1571AD15A1A815F1A615F1A41601A316119F16319E16319C16419B16419916519616519416619116618F16718B16718A16818816818416A18116B18016D17E16E17B17417A17517917717917F17818017818917718B17718C17319017319117119216F19416D19516C19516619814F19814919514819414619314519114318F14318D14118B14018913F18813E18613D18513C18313918213718013518013117E12C17E12A17F12817F12218212118311F18411E18511C18611718B11618D11418E11319011219311119511119611019811019A10F19C10F19D10E19F10E1A110D1A310D1B810E1BA10E1BC10F1BD10F1C11101C21101C41111C61111C91121CA1121CC1131CE1131D11141D31141D61131D71111D710F1D810C1D810A1D91031D91011DA0D41DA0D21D90C91D90C71D80C21D80C01D70BF1D70BE1D60BE1D50BD1D40BE1D20BE1CF0BF1CE0C01CC0C01CB0C11C90C21C80C21C60C31C40C31C30C41C10C51C00C51BE0C61BC0C61BB0C71B90C81B80C81B60C91B50C91B30CA1B10CB1B00CB1AE0CC1AD0CD1AB0CD1A90CE1A80CE1A60CF1A50D01A30D01A10D11A00D119E0D219D0D319B0D319A0D41980D41960D51950D61930D61920D71900D818F0D818D0D918C0DA18A0DA1880DB1870DC1850DC1840DD1820DE1810DE17F0DF17E0E017C0E117B0E21790E41770E41750E61730E71710E81700EA16F0EB16D0ED16B0EE1690F11660F31650F41640F51620F71610F81600FA15F0FB15E0FD15D0FF15B10115A10215910415910615810715710915610B15610C15510E15411115411315311515311715211A15211C15111E15111F15012215012314E12514D12914912A14712C14712D14612F14513114313414113413B13313913313713213513212812F12212E12112C12012B11E12A11D12811C12611A12511812411712411512311412111012010F11F10D11E10C11C10B11B10A11A10811910711810711910711B10611D10612310912510B12710C12810E12A10F12B11012F11213011313211313511413711413911313C11314211014310F14510E14710C14910B14A10A14E10814F10815110715B10715D1061761061781071831071851061AC1061AE1071AF1071B11081B41081BE10D2DF10D2E110C2E410A2E51072E51052E61032E61012E80FF2E71002E90FF2EF0FF2F01002F21002F41022F61032F71052F81062F91082FC10B2FE10C30010C30410E30510E30811130811230911430911E30811F3081223071243051262F91262F71272ED1272EA12A2E912C2E812D2E712F2E71312E61322E51322E41332E21332E01341DC1341DA1351CB1351CA1361C11361C01371BE1371BA13B1B913D1B913E1B81401B41441B31461B21471B11491B114B1B014D1B014E1AF1501AF1521AE1531AE1551AD1571AD15A1A915E1A815E1A715F19E15F19C16019516019416118F16118E16218A16218816318516318316417F16417E16517B16517A16617716617616717316717216816F16816E16916B16916A16A16816A16716B16416B16316C16116C16016D15E16D15D16E15A16E15816F15717015417015317115117115017214F17214D17314C17314B17414917414817514617514517614417614217714117713F17813E17813C17913B17913A17A13817A13717B13617B13417C13317C13217D13017D12F17E12B17E12A17F12817F12618012417F12317F12317512417412416C12516A12516412616312615D12715C12615A12515A12415911D15911C15811615811515710F15710A15A10615E1031620FF1660F317A0F217F0EF1830EC1880E918C0E619B0D41B90D11BF0CF1C40D11CA0D51CC0EE1D10F41D21031D51001D60FB1D8FFFFFF0F71D90F21DA0EC1DB0E61DB0F01DB0F21DA1011DA1031D910A1D910C1D810E1D81101D61101C41121C31121C21111C01111BD1101BB1101BA10F1B810F1A31101A21101A011119E11119C11219A11219711319511319311519111618F11C18911D18711F18612018512218412318312518212718212818112A18112C18012E18012F17F12F17E13017D13217D13317C13417C13617B13717B13817A13A17A13B17913C17913E17813F17814117714217714417614517614617514817514917414B17414C17314D17314F17215017215117115317115417015717015816F15A16E15D16E15E16D16016D16116C16316C16416B16716B16816A16A16A16B16916E16916F16817216817316717616717716617A16617B16517E16517F16418316418516318816318A16218E16218F16119416119516019C16019E15F1A715F1A815E1AC15E1AD15D1AF1591AF1571B01551B01541B11521B11501B214F1B214C1B41481B51471B61451B71441B81421B91411BB13D1BC13C1BD13A1BF1391C01391C21381C71381C81371D71371D81361DF1361D81361D71371C81371C71381C21381C01391BF1391BD13A1BC13C1BB13D1B91411B81421B71441B61451B51471B41481B214C1B214F1B11501B11521B01541B01551AF1571AF1591AD15D1AC15E1A815E1A715F19E15F19C16019516019416118F16118E16218A16218816318516318316417F16417E16517B16517A16617716617616717316717216816F16816E16916B16916A16A16816A16716B16416B16316C16116C16016D15E16D15D16E15A16E15816F15717015417015317115117115017214F17214D17314C17314B17414917414817514617514517614417614217714117713F17813E17813C17913B17913A17A13817A13717B13617B13417C13317C13217D13017D12F17E12F17F12E18012C18012A18112818112718212518212318312218412018511F18611D18711C18911618F11519111319311319511219711219A11119C11119E1101A01101A210F1A310F1B81101BA1101BB1111BD1111C01121C21121C31101C41101D610E1D810C1D810A1D91031D91011DA0F21DA0F01DB0EC1DB0ED1DB0F21DA0FA1D81021D41051D31011D10FC1CF0E81C50E51C30E11C20DE1BF0DD1BA0E11B00E71A80E91A30F21970F218B0F41870FA17F0FB17B0FD17610616710A16311015B11315811515711615811C15811D15912415912515A12615A12715C12615D12616312516412516A12416C12417412317512317F12417F12618012817F12A17F12B17E13117E13317F13517F13718013918213B18213C18313D18513E18613F18814018914118B14118C14318D14318F14719314819114919214B19314D19514F19615119615219716019716219616619616719516A19516B19416C19416E19216F19217418D17518B17518A17718817718517818417818217918017917717A17817B17817C17617B17615D16F16917317017617417B17617F17618217518717218D16C19215D19515419514F19414A19014518A14517E14917914717E14918714F19115419415719215718E15118215117815317515D17315D16E15A16E15816F15717015417015317115117115017214F17214D17314C17314B17414917414817514617514517614417614217714117713F17813E17813C17913B17913A17A13817A13717B13617B13417C13317C13217D13017D12F17E12B17E12A17F12817F12618012417F12317F12317512417412416C12516A12516412616312615D12715C12615A12515A12415911D15911C15811815811615C10D16810917210617710417C10517F0FE1860FD1890FF18F1001930FD1960FA19A0F719D0F31A00F01A40EE1A80EB1AC0E91B10E91B60F11BE0F41C00F71C30FA1C50FD1C81001CA1041CD1081CF1031D40FD1D80F81DA0F41DB0F51DB0F71DA1011DA1031D910A1D910C1D810E1D81101D61101C41121C31121C21111C01111BD1101BB1101BA10F1B810F1A31101A21101A011119E11119C11219A11219711319511319311519111618F11C18911D18711F18612018512218412318312518212718212818112A18112C18012E18012F17F12F17E13017D13217D13317C13417C13617B13717B13817A13A17A13B17913C17913E17813F17814117714217714417614517614617514817514917414B17414C17314D17314F17215017215117115317115417015717015816F15A16E15D16E15E16D16016D16116C16316C16416B16716B16816A16A16A16B16916E16916F16817216817316717616717716617A16617B16517E16517F16418316418516318816318A16218E16218F16119416119516019C16019E15F1A715F1A815E1AC15E1AD15D1AF1591AF1571B01551B01541B11521B11501B214F1B214C1B41481B51471B61451B71441B81421B91411BB13D1BC13C1BD13A1BF1391C01391C21381C31381C41371BE1282EA1282ED12A2EB12B2EB12D2EA12E2E91302E81312E81332E41352CE135FFFFFF2CC1352861352851361D81361D71371C81371C71381C21381C01391BF1391BD13A1BC13C1BB13D1B91411B81421B71441B61451B51471B41481B214C1B214F1B11501B11521B01541B01551AF1571AF1591AD15D1AC15E1A815E1A715F19E15F19C16019516019416118F16118E16218A16218816318516318316417F16417E16517B16517A16617716617616717316717216816F16816E16916B16916A16A16816A16716B16416B16316C16116C16016D15E16D15D16E15A16E15816F15717015417015317115117115017214F17214D17314C17314B17414917414817514617514517614417614217714117713F17813E17813C17913B17913A17A13817A13717B13617B13417C13317C13217D13017D12F17E12F17F12E18012C18012A18112818112718212518212318312218412018511F18611D18711C18911618F11519111319311319511219711219A11119C11119E1101A01101A210F1A310F1B81101BA1101BB1111BD1111C01121C21121C31101C41101D610E1D810C1D810A1D91031D91011DA0FB1DA0FA1DB0FB1DB1011D91041D71081D11091CE10B1CB1071C91011C30FF1C00FC1BD0F91BB0F51B50F31B30F11AF0F21AB0F41A60FA19E10219810519510919210D18E10C18C10A18910918710A18510E18211117F11017D11117811317311416E11616A11716511D15912415912515A12915A12A15812915712815712715512215012314E12514D12814A12914812A14712C14712D14612F14513214213213B13313A13313713213613212413312313311F13411D13411C13511B13511913611813611713711513711413911313C11314011114111014310F14410E14610D14710C14910B14A10A14E10814F10815110715B10715D10616B10616D10516F1061761061781071861071881061A71061A91051AA1061AC1061AE1071AF1071B11081B41081B61091B71071B91081B91261B910B1B810A1B41081B11081AF1071AE1071AC1061AA1061A91051A710618810618610717810717610616F10616D10516B10615D10615B10715110714F10814E10814A10A14910B14710C14610D14410E14310F14111014011113C11313911313711413711513611713611813511913511B13411C13411D13311F13312313212413213613313713313A13213B13214212F14512D14612C14712A14712914812814A12514D12314E12215012715512815712915712A15812915A12515A12415912115912215912015D11F16211D16611C16B11B16F11917411717E11918011718211318411218511418711718911918B11618D11218F10E19210619610319910019D0FE1A20FD1A60FE1A90FF1AD1011B31031B71041BA1061BE1081C110B1C510D1C810D1CC10B1D210A1D61071D91021DA1041DA1061D910A1D910C1D810E1D81101D61101C110F1BF10F1BD10E1BC10E1BA10D1B810D1A310E1A110E19F10F19E10F19C11019A11019811119611119511219311219111418F11418E11618D11718B11918911A18711E18511F18412118312218212418112417F12317F12317512417412416C12516A12516412616312615D12715C12715A12915A12A15812915712815712715512215012314E12514D12814A12914812A14712C14712D14612F14513214213213B13313A13313713213613212413312313311F13411D13411C13511B13511913611813611713711513711413811313811213A11113C11113D11013F10F14010E14210D14310C14510B14610A14810914910814B10714D10715110515610515711016411016910F17310F17810E17E10E18310F18D10F19211019A11019D11119E1121A011A1A111F1A21251A21411A114719F15119E15419D15519A15619715619215718815718315817315816E15716415715F15615C15615915515815415815115614715613A15513315612C15611F15811515811215A11015811015710E15610D15610715110714F10814E10814A10A14910B14710C14610D14410E14310F14111014011113C11313911313711413711513611713611813511913511B13411C13411D13311F13312313212413213613313713313A13213B13214013014112E14312C14412B14512914612714812614A12514B12314C12114E11F14F11B14F11A15011815011615111715211515311315311115410E15410C15510E15711315711215910E15D10E15E10A16210A16310616710516910516A10216D10216E1011701001711001720FF1730FE1750FD1760FD1770FC1780FC17A0FB17B0FB17C0FA17E0FA17F0F81810F71830F41860F41870F31880F218A0F21970F01990F019A0EF19B0EE19D0EC19F0EB1A10E91A30E81A50E81A60E71A80E51AA0E41AC0E31AD0E31AE0E11B00E11B10E01B30E01B40DF1B50DF1B60DE1B80DE1B90DD1BA0DD1BC0DE1BD0DE1BF0DC1C00E41C00E51BF0E71BE0EA1BE0EC1BF0EC1C10EB1C20E91C30E61C30E41C10E41C00DF1C00DE1BF0DE1BD0DD1BCFFFFFF0DD1BA0DE1B90DE1B80DF1B60DF1B50E01B40E01B30E11B10E11B00E31AE0E31AD0E41AC0E51AA0E71A80E81A60E81A50E91A30EB1A10EC19F0EE19D0EF19B0F019A0F01990F21970F218A0F31880F41870F41860F71830F81810FA17F0FA17E0FB17C0FB17B0FC17A0FC1780FD1770FD1760FE1750FF17310017210017110117010216E10216D10516A10516910616710A16310A16210E15E10E15D11215911315710E15710C15510E15411115411315311515311715211615111815011A15011B14F11F14F12114E12314C12514B12614A12714812914612B14512C14412E14313014113214013213B13313A13313713213613212413312313311F13411D13411C13511B13511913611813611713711513711413811313811213A11113C11113D11013F10F14010E14110E13D10813910C13711113411613211C13112113012713013213113813213D13414213614613914B13C14F14415514915714E15815215915515A15315915115914F15814E15814C15714915714715514415514315414115313F15113D15013C14F13C14E13814A13814913714713614613614513414313414213214212F14512D14612C14712A14712914812814A12514D12314E12215011F15011E15111C15111A15211715211515311315311115410E15410C15510E15711315711215910E15D10E15E10A16210A16310616710516910516A10216D10216E1011701001711001720FF1730FE1750FD1760FD1770FC1780FC17A0FB17B0FB17C0FA17E0FA17F0F81810F71830F41860F41870F31880F218A0F21970F01990F019A0EF19B0EE19D0EC19F0ED19F0F019C0F119A0F21990F41980F61990F719A0F819C0F719E0F619F0F41A00F219F0F119E0F019C0F01990F21970F218A0F31880F41870F41860F71830F81810FA17F0FA17E0FB17C0FB17B0FC17A0FC1780FD1770FD1760FE1750FF17310017210017110117010216E10216D10516A10516910616710A16310A16210E15E10E15D11215911315710E15710C15510E15411115411315311515311715211615111815011A15011B14F11F14F12114E12314C12514B12614A12714812914612B14512C14412E14313014113214013213B13113A13113813013613012413112213112013211E13211C13311A13311713211613111413111313011212F11012E11012C10F12B10D12910C12C10912B10B12C10E12E11313011713311A13511E13912413912713A12913A12D13A12613912513912413812213612013611F13511E13411C13511B13511913611813611713711513711413911313C11314011114111014310F14410E14610D14710C14910B14A10A14E10814F10815110715610715610D15710E15811015711215611315611515511615511E15411F15414715514815514E19414E19015018615218215217D15317415316F15216B15216115015D14E15514E15514815414715411F15511E15511615611515611315711215811015710E15610D15610715110714F10814E10814A10A14910B14710C14610D14410E14310F14111014011113C11313911313711413711513611713611813511913511B13411C13411D13311F13312313212413213513313713313913413B13414013314013214212F14512D14612C14712A14712914812814A12514D12314E12215012715512815712915712A15812915A12715A12715C12615D12616312516412516A12416C12417412317512317F12417F12618012718212818112A18112C18013118013017F13317E13717D13D17A14317814817614E17415317316B16B17216A18016618616518D16419316319A16219F1611A41611A91601B21601B515D1AF1591AD15D1AC15E1A815E1A715F19E15F19C16019516019416118F16118E16218A16218816318516318316417F16417E16517B16517A16617716617616717316717216816F16816E16916B16916A16A16816A16716B16416B16316C16116C16016D15E16D15D16E15A16E15816F15717015417015317115117115017214F17214D17314C17314B17414917414817514617514517614417614217714117713F17813E17813C17913B17913A17A13817A13717B13617B13417C13317C13217D13017D12F17E12B17E12A17F12817F12618012417F12317F12317512417412416C12516A12516412616312615D12715C12715A12915A12A15812915712815712715512215012314E12514D12814A12914812A14712C14712D14612F14513214213314013414013413B13313913313713213513212413312313311F13411D13411C13511B13511913611813611713711513711413911313C11314011114111014310F14410E14610D14710C14910B14A10A14E10814F10815110715610715610D15710E15811015711215611315611515511615511E15411F15414015D14016113F16B13D16F13C18213C18613D19013F19414019014118B14318614418214517D14517914617414516F14516B14416614316114115D14015414015411F15511E15511615611515611315711215811015710E15610D15610715110714F10814E10814A10A14910B14710C14610D14410E14310F14111014011113C11313911313711413711513611713611813511913511B13411C13411D13311F13312313212413213613313713313A13213B13214013014112E14312C14412B14512914612714812614A12514B12314C12114E11F14F11B14F11A15011815011615111315111115210F15210D15310C15310A15410915610715710615810615712C15C12214D12314C12514B12614A12714812914612B14512C14412E14313014113214013213B13313A13313713213613212413312313311F13411D13411C13511B13511913611813611713711513711413911313C11314011114111014310F14410E14610D14710C14910B14A10A14E10814F10815110715610715610D15710EFFFFFF15811015711215611315611515511615511E15411F15412715412615D12616112516612316B12216F12118212118612218B12319012519412619012718612918212A17D12A17912B17412A16F12A16B12916112715D12615412615411F15511E15511615611515611315711215811015710E15610D15610715110714F10814E10814A10A14910B14710C14610D14410E14310F14111014011113C11313911313711413711513611713611813511913511B13411C13411D13311F13312313212413213613313713313A13213B13214013014112E14312C14412B14512914612714812614A12514B12314C12114E11F14F11B14F11A15011815011615111315111115210F15210D15310C15310A1541091561091551041580FE15B0F51640E91730E61780E417D0E11830DE1880DC18E0DA1930D81990D719E0D41A40D21A90CF1AF0CC1B40CA1BA0C71C00C51C50C31CC0C51D30CC1D50D11D60D71D70DD1D70E31D80E91D80F51DA0FA1DA0FF1DB0FC1D80F61D80F01D90EB1D90E51DA0DE1DE1091DC10F1DA1121D51121C91111C410F1C010A1AC10A1A510B1A110B19D10C19910F19511518F11918E11D18C12218B12618912B18612718312318212018212018412418312817F12417E12517A12517612617112616C12716812716312815F12915A12715A12915A12A15812615412615312515212415012414F12314E12514D12814A12914812A14712C14712D14612F14513214213314013414013413B13313913313713213513212413312313311F13411D13411C13511B13511913611813611713711513711413911313C11314011114111014310F14410E14610D14710C14910B14A10A14E10814F10815110715610715610D15710E15811015711215611315611515511615511815D11816111616B11416F11417411317D11318211418611419011619411815511815511615611515611315711215811016411016610F19010F19211019B11019C11119D11119E11319F11419F1151A01171A11161A21181A21191A311B1A31251A21271A11281A012719F12519E1221A011E1A111D1A211E1A31201A31221A41241A41421A31441A31471A21491A014919F14719E14419F1411A013F1A113E1A213F1A31411A31441A41421A21411A21241A11221A111B1A011A1A011719F11519F11419E11319D11119C11119B11019211019010F16610F16411016011015E10E15D10F15A10F15810E15810715110714F10814E10814A10A14910B14710C14610D14410E14310F14111014011113C11313911313711413711513611713611813511913511B13411C13411D13311F13312313212413213513313713313913413B13414013314013214212F14512D14612C14712A14712914812814A12514D12314E12414F12415012515212615312615412A15812815C12816212716312716912616B12617412517612517D12417E12617F12A17F12B17E12F17E13017D13217D13317C13417C13617B13717B13817A13A17A13B17913C17913E17813F17814117714217714417614517614617514817514917414B17414C17314D17314F17215017215117115317115417015717015816F15A16E15D16E15E16D16016D16116C16316C16416B16716B16816A16A16A16B16916E16916F16817216817316717616717716617A16617B16517E16517F16418316418516318816318A16218E16218F16119416119516019C16019E15F1A715F1A815E1AC15E1AD15D1AF1591AF1571B01551B01541B11521B11501B214F1B214C1B41481B51471B61451B71441B81421B91411BB13D1BC13C1BD13A1BF1391C01391C21381C51381C412D2DD12D1C412D1C5138FFFFFF1C31371C31351C21341C21321C11311C11301C012F1BF12D1BF12C1BE12B1BE1281BF1261CA1261CD1201CA1261CD1261D01201CD1261D01261D41201D01261D41261D71201D41261D71261DB1201D71261DB1261DE1201DB1261DE1261E11201DE1261E11261E51201E11261E51261E81201E51261E81261EB1201E81261EB1261EF1201EB1261EF1261F21201EF1261F21261F51201F21261F51261F91201F51261F91261FC1201F91261FC1261FF1201FC1261FF1262031201FF12620312620612020312620612620A12020612620A12620D12020A12620D12621012020D12621012621412021012621412621712021412621712621A12021712621A12621E12021A12621E12622112021E12622112622412022112622412622812022412622812622B12022812622B12622F12022B12622F12623212022F12623212623512023212623512623912023512623912623C12023912623C12623F12023C12623F12624312023F12624312624612024312624612624912024612624912624D12024912624D12625012024D12625012625312025012625312625712025312625712625A12025712625A12625E12025A12625E12626112025E12626112626412026112626412626812026412626812626B12026812626B12626E12026B12626E12627212026E12627212627512027212627512627812027512627812627C12027812627C12627F12027C12627F12628312027F12628312628612028312628612628912028612628912628D12028912628D12629012028D12629012629312029012629312629712029312629712629A12029712629A12629D12029A12629D1262A112029D1262A11262A41202A11262A41262A71202A41262A71262AB1202A71262AB1262AE1202AB1262AE1262B21202AE1262B21262B51202B21262B51262B81202B51262B81262BC1202B81262BC1262BF1202BC1262BF1262C21202BF1262C21262C61202C21262C61262C91202C61262C91262CC1202C91262CC1262D01202CC1262D01262D31202D01262D31262D71202D31262D71262DA1202D71262DA1262DD1202DA1262DD1262E11202DD1262E11262E41202E11261C41261CB1261CC1231CB1261CE1261D01231CE1261D21261D31231D21261D51261D61231D51261D81261DA1231D81261DC1261DD1231DC1261DF1261E01231DF1261E31261E41231E31261E61261E71231E61261E91261EA1231E91261ED1261EE1231ED1261F01261F11231F01261F31261F51231F31261F71261F81231F71261FA1261FB1231FA1261FD1261FF1231FD12620112620212320112620412620512320412620712620912320712620B12620C12320B12620E12620F12320E12621212621312321212621512621612321512621812621A12321812621C12621D12321C12621F12622012321F12622212622412322212622612622712322612622912622A12322912622C12622E12322C12623012623112323012623312623412323312623712623812323712623A12623B12323A12623D12623E12323D12624112624212324112624412624512324412624712624912324712624B126FFFFFF24C12324B12624E12624F12324E12625112625312325112625512625612325512625812625912325812625B12625D12325B12625F12626012325F12626212626312326212626612626712326612626912626A12326912626C12626E12326C12627012627112327012627312627412327312627612627812327612627A12627B12327A12627D12627E12327D12628012628212328012628412628512328412628712628812328712628B12628C12328B12628E12628F12328E12629112629212329112629512629612329512629812629912329812629B12629D12329B12629F1262A012329F1262A21262A31232A21262A51262A71232A51262A91262AA1232A91262AC1262AD1232AC1262AF1262B11232AF1262B31262B41232B31262B61262B71232B61262BA1262BB1232BA1262BD1262BE1232BD1262C01262C21232C01262C41262C51232C41262C71262C81232C71262CA1262CC1232CA1262CE1262CF1232CE1262D11262D21232D11262D41262D61232D41262D81262D91232D81262DB1262DC1232DB1262DF1262E01232DF1262E21262E31232E21262EA1262EC1282EC1292EB12B2EB12D2EA12E2E91302E81312E81332E41352861352851361D81361D71371CB1371CA1331CD12E1CA1331CD1331D012E1CD1331D01331D312E1D01331D41331D712E1D41331D71331DA12E1D71331DB1331DD12E1DB1331DE1331E112E1DE1331E11331E412E1E11331E51331E812E1E51331E81331EB12E1E81331EB1331EE12E1EB1331EF1331F212E1EF1331F21331F512E1F21331F51331F812E1F51331F91331FC12E1F91331FC1331FF12E1FC1331FF13320212E1FF13320313320612E20313320613320912E20613320A13320D12E20A13320D13321012E20D13321013321312E21013321413321712E21413321713321A12E21713321A13321D12E21A13321E13322112E21E13322113322412E22113322413322712E22413322813322B12E22813322B13322E12E22B13322F13323112E22F13323213323512E23213323513323812E23513323913323C12E23913323C13323F12E23C13323F13324212E23F13324313324612E24313324613324912E24613324913324C12E24913324D13325012E24D13325013325312E25013325313325612E25313325713325A12E25713325A13325D12E25A13325E13326112E25E13326113326412E26113326413326712E26413326813326B12E26813326B13326E12E26B13326E13327112E26E13327213327512E27213327513327812E27513327813327B12E27813327C13327F12E27C13327F13328212E27F13328313328512E28313328613328912E28613328913328C12E28913328D13329012E28D13329013329312E29013329313329612E29313329713329A12E29713329A13329D12E29A13329D1332A012E29D1332A11332A412E2A11332A41332A712E2A41332A71332AA12E2A71332AB1332AE12E2AB1332AE1332B112E2AE1332B21332B512E2B21332B51332B812E2B51332B81332BB12E2B81332BC1332BF12E2BC1332BF1332C212E2BF1332C21332C512E2C21332C61332C912E2C61332C91332CC12E2C91332CC1332CF12E2CC1332D01332D312E2D01332D31332D612E2D31332D71332D912E2D71332E41332E51322E71312E712F2E812D2E912C2EA12A2ED1272F71272F912630512630712430812230812130911F30911430811230811130410D30210D30010C2FE10C2FC10B2F91082F81062F71052F61032F41022F31012F11002F01002EF0FF2E80FF2E61012E51032E41032E31052E31072E21092E010A2DF10B27810B27710C26110CFFFFFF25F10C1CA10C1C810B1BF10B1BD10C1BB10C1BA10B1B41081B11081AF1071AE1071AC1061AA1061A91051A710618810618610717810717610616F10616D10516B10615D10615B10715810715810E15A10F15D10F15E10E16410E16510D19110D19210E19810E19910F19D10F19F1101A01121A011119911019411018F10F16710F16211015D11015711115611315D11316711118F1111991131A11131A11161A211619911519411518F11416711416211515D11515511615511E15411F15414715514815515015615115615315715415715515D15616215716715716C15818A15818F1571941571991561A01551A115419915419415518F15518A15616C15616715516215515D15415615415615115615215D15216215316715316C15418A15418F1531941531991521A11521A11501A214E1A214F19914F19415018F15018A15116C15116715016215015D14F15514F15515015615115615315715415815715A15715B15816515816715116515816815816A15116815816B15816D15116B15816E15817015116E15817115817315117115817415817615117415817715817915117715817A15817B15117A15817D15817E15117D15818015818115118015818315818415118315818615818715118615818815818A15118815818B15818D15118B15818E15819015118E15818D15918C15718615718515817115817015716415716215615C15615915515815415815115714F15714B15614A15613B15513A15512C15612B15611E15511C15511615611515611315711215811015710E15610D15610715110714F10814E10814A10A14910B14710C14610D14410E14310F14111014011113C11313911313711413711513611713611813511913511B13411C13411D13311F13312313212413213513313713313913413B13414013314013214212F14512D14612C14712A14712914812814A12514D12314E12414F12415012515212615312615412A15812815C12816212716312716912616B12617412517612517D12417E12617F12A17F12B17E13417E13517D13717D13917C13A17C13C17B13D17A13E17A14017914117914317814417814617714717714817614A17614B17514E17514F17415217415317315617315717215A17215B17116217116017416217116717116517416717116C17216917416C17217017416D17617017417417717117917417717717C17317D17717C17818017518117818017718517418517718517518A17218917518A17318E17018D17318E16F19216C19016F19216B19416919216B19416619516419316619516119616019316119615C19715C19415C19715719715719415719715219615319315219614D19514F19214D19514919214C19014919214618E14918C14618E14318A14718914318A14318514618514318514318014718014318014517B14817C14517B14917714B17914917714917C14C17E14917C14918114D18214918114B18614E18614B18614D18A15018914D18A15018F15218C15018F15419215518F15419215518F15718C15518F15318A15518815318A15118615418515118614F18115218214F18114F17C15217E14F17C14F17715117A14F17715317315417715317315817215817615817215D17115E17116017016116E16216E16416D16616D16716C16A16C16B16B16E16B16F16A17116A17216917516917616817A16817C16717E16718016618216618416518816518916418D16418E16319416319616219B16219C1611A31611A41601A615F1A815F1AD15A1AD1571AE1551AE1531AF1521AF1501B014E1B014D1B114B1B11491B21471B31461B41441B81401B913E1B913D1BA13B1BE1371C01371C11351C11331C01321C01311BF12F1BF12B1BE12B1BE1281BF1261CD1261CA1201CD1261D01261CD1201D01261D41261D01201D41261D71261D41201D71261DB1261D7120FFFFFF1DB1261DE1261DB1201DE1261E11261DE1201E11261E51261E11201E51261E81261E51201E81261EB1261E81201EB1261EF1261EB1201EF1261F21261EF1201F21261F51261F21201F51261F91261F51201F91261FC1261F91201FC1261FF1261FC1201FF1262031261FF12020312620612620312020612620A12620612020A12620D12620A12020D12621012620D12021012621412621012021412621712621412021712621A12621712021A12621E12621A12021E12622112621E12022112622412622112022412622812622412022812622B12622812022B12622F12622B12022F12623212622F12023212623512623212023512623912623512023912623C12623912023C12623F12623C12023F12624312623F12024312624612624312024612624912624612024912624D12624912024D12625012624D12025012625312625012025312625712625312025712625A12625712025A12625E12625A12025E12626112625E12026112626412626112026412626812626412026812626B12626812026B12626E12626B12026E12627212626E12027212627512627212027512627812627512027812627C12627812027C12627F12627C12027F12628312627F12028312628612628312028612628912628612028912628D12628912028D12629012628D12029012629312629012029312629712629312029712629A12629712029A12629D12629A12029D1262A112629D1202A11262A41262A11202A41262A71262A41202A71262AB1262A71202AB1262AE1262AB1202AE1262B21262AE1202B21262B51262B21202B51262B81262B51202B81262BC1262B81202BC1262BF1262BC1202BF1262C21262BF1202C21262C61262C21202C61262C91262C61202C91262CC1262C91202CC1262D01262CC1202D01262D31262D01202D31262D71262D31202D71262DA1262D71202DA1262DD1262DA1202DD1262E11262DD1202E11262EA1262EC1282EC1292EB12B2EB12D2EA12E2E91302E81312E81332E41352861352851361D81361D71371CB1371CD1331CA12E1CD1331D01331CE12E1D01331D41331D112E1D41331D71331D412E1D71331DB1331D812E1DB1331DE1331DB12E1DE1331E11331DE12E1E11331E51331E212E1E51331E81331E512E1E81331EB1331E812E1EB1331EF1331EC12E1EF1331F21331EF12E1F21331F51331F212E1F51331F91331F612E1F91331FC1331F912E1FC1331FF1331FD12E1FF13320313320012E20313320613320312E20613320A13320712E20A13320D13320A12E20D13321013320D12E21013321413321112E21413321713321412E21713321A13321712E21A13321E13321B12E21E13322113321E12E22113322413322212E22413322813322512E22813322B13322812E22B13322F13322C12E22F13323213322F12E23213323513323212E23513323913323612E23913323C13323912EFFFFFF23C13323F13323C12E23F13324313324012E24313324613324312E24613324913324612E24913324D13324A12E24D13325013324D12E25013325313325112E25313325713325412E25713325A13325712E25A13325E13325B12E25E13326113325E12E26113326413326112E26413326813326512E26813326B13326812E26B13326E13326B12E26E13327213326F12E27213327513327212E27513327813327612E27813327C13327912E27C13327F13327C12E27F13328313328012E28313328613328312E28613328913328612E28913328D13328A12E28D13329013328D12E29013329313329012E29313329713329412E29713329A13329712E29A13329D13329A12E29D1332A113329E12E2A11332A41332A112E2A41332A71332A512E2A71332AB1332A812E2AB1332AE1332AB12E2AE1332B21332AF12E2B21332B51332B212E2B51332B81332B512E2B81332BC1332B912E2BC1332BF1332BC12E2BF1332C21332BF12E2C21332C61332C312E2C61332C91332C612E2C91332CC1332CA12E2CC1332D01332CD12E2D01332D31332D012E2D31332D71332D412E2D71332861332851341DC1341DA1351CB1351CA1361C31361C11371BE1371BA13B1B913D1B913E1B81401B41441B31461B21471B11491B114B1B014D1B014E1AF1501AF1521AE1531AE1551AD1571AD15A1A915E1A815E1A715F19E15F19C16019516019416118F16118E16218A16218816318516318316417F16417E16517B16517A16617716617616717316717216816F16816E16916B16916A16A16816A16716B16416B16316C16116C16016D15E16D15D16E15A16E15816F15717015417015317115117115017214F17214D17314C17314B17414917414817514617514517614417614217714117713F17813E17813C17913B17913A17A13817A13717B13617B13417C13317C13217D13017D12F17E12B17E12A17F12617F12417E12517D12517612617412616B12716912716312616112615D12415B11E15B11C15A11815A11715910F15910E1581091581071571061560FE15A10315B0FE15A0F715F0FC1600F715F0F11640F51650F11640EB16A0F016B0EB16A0E51710EA1720E51710E01780E51790E01780DC1800E11800DC1800D91870DE1870D91870D518F0DA18F0D518F0D21970D71970D21970CF19F0D419F0CF19F0CC1A70D11A60CC1A70C91AF0CE1AE0C91AF0C61B80CB1B60C61B80C31C00C71BE0C31C00BF1C80C41C60BF1C80BD1D00C11CE0BD1D00BE1D80C21D60BE1D80C61DA0CA1D80C61DA0CE1DA0D31D80CE1DA0D71DB0DC1D80D71DB0E01DB0E41D80E01DB0E81DB0ED1D80E81DB0F11DB0F51D90F11DB0FA1DC0FE1D90FA1DC0FB1DC1001D90FB1DC0F31DC0F71D90F31DC0EA1DC0EE1D90EA1DC0E21DC0E61D90E21DC0D91DC0E01DC0E21DB0F01DB0F21DA1011DA1031D910A1D910C1D810E1D81101D61101C41121C21111C01111BD1101BB1101BA10F1B810F1A31101A21101A011119E11119C11219A11219711319511319311519111618F11C18911D18711F18612018512218412418212518212718112817F12A17F12B17E12F17E13417C13617813417C13917A13B17613917A13F17814117413F17814417614617214417614917414B17014917414F17215016E14F17215417015616C15417015A16F15B16A15A16F15F16D16016915F16D16516B16516716516B16A16A16B16616A16A17016817016417016817516717516317516717B16517A16117B16518016418016018016418616318515F18616318C16218A15E18C16219116119015D19116119716019515D19716019D16019A15C19D1601A215F1A015B1A215F1A815E1A515B1A815E1AE15E1AB15B1AE15E1B315EFFFFFF"
QD_N     = 6180 # points (incl. pull breaks)

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

# Quick draw on the window path (upd sketch win): the rows the pen touched
# since the last pull, full width, one WIN_LUT pull (as the live UPD_WIN path).
def qd_window_pull : Nil
  tc = Sketch.touch
  y0 = -1
  y1 = -1
  r = 0
  while r < EPD::HEIGHT
    i = r &* EPD::ROW_BYTES
    e = i &+ EPD::ROW_BYTES
    hit = false
    while i < e
      if tc[i] != 0_u8
        hit = true
        tc[i] = 0_u8
      end
      i = i &+ 1
    end
    if hit
      y0 = r if y0 < 0
      y1 = r
    end
    r = r &+ 1
  end
  return if y0 < 0
  Sketch.render(EPD.black, EPD.red)
  red_to_black
  Shared.led_mode = LED_CYAN
  EPD.fast_pulls = 1
  EPD.refresh_window2(y0, y1, 0, EPD::HALF_BYTES &- 1, y0, y1, 0, EPD::HALF_BYTES &- 1, WIN_LUT, 8)
  log2(EPD.panel_ms > 250 ? "sketch: qd pull panel / upload ms (OVER 250)" : "sketch: qd pull panel / upload ms",
    EPD.panel_ms, EPD.upload_ms)
end

def quick_draw : Nil
  return unless SkInk.ready?
  log("sketch: quick draw", 0)
  t0 = millis
  base = QD_PTS.to_unsafe
  win = Shared.upd(SCR_SKETCH) == UPD_WIN # test the rows-only window path with quick draw
  pulls = 0
  k = 0
  while k < QD_N
    p = base + (k &* 6).to_i64!
    x = qd_hex3(p)
    if win && x != 0xFFF && (k & 7) == 7
      qd_window_pull # window test path: a rows-only pull every 8 points, like live drawing
      pulls = pulls &+ 1
    end
    if x == 0xFFF && win
      qd_window_pull
      pulls = pulls &+ 1
    elsif x == 0xFFF
      Shared.led_mode = pulls & 1 == 0 ? LED_YELLOW : LED_CYAN
      SkInk.take_touches
      SkInk.pull
      log2(EPD.panel_ms > 250 ? "sketch: qd pull panel / upload ms (OVER 250)" : "sketch: qd pull panel / upload ms",
        EPD.panel_ms, EPD.upload_ms)
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
  @@dwell_at = 0 # last resting-pen re-ink (SkInk.dwell_ink)

  def self.dwell_at : Int32
    @@dwell_at
  end

  def self.dwell_at=(v : Int32) : Nil
    @@dwell_at = v
  end

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
  # The red frame stays: ink pulls only drive the pixels the pen touches,
  # and erase / clean flash only the white screen with the keep-red LUT,
  # so drawing simply continues on the colour frame.
  SkState.colour = true
  SkState.red_frame = true
  SkState.after_colour = false
  SkState.hint = false
  SkState.mark_shown
  Sketch.forget_knobs
end

# Shows a screen on entry: always a fast black/white frame.
def enter_screen(scr : Int32, boot : Bool) : Nil
  prev = Shared.screen
  fast_prev_ok = prev == SCR_HOME || (prev >= 0 && prev < Apps.count && !Apps.builtin?(prev))
  red_before = RedRes.on_panel? || RedRes.residue?
  Shared.screen = scr
  LibIDF.cr_net_screen(scr)
  LibIDF.cr_tn_where(scr == SCR_HOME || scr == Apps.find("ROBOTS".to_unsafe, 6) ? 1 : 0)
  SkState.red_frame = false unless scr == SCR_SKETCH # another screen replaces it
  RedRes.replaced unless scr == SCR_SKETCH && SkState.red_frame?
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
  if scr == SCR_HOME || !Apps.builtin?(scr)
    # FAST_ENTRY: only from another registry app / Home, never after red.
    Apps.begin_entry(!boot && fast_prev_ok && !red_before)
  end
  if scr == SCR_HOME
    Home.enter
    Apps.end_entry
  elsif !Apps.builtin?(scr)
    Apps.enter(scr) # registry app (src/apps/)
    Apps.end_entry
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
  RedRes.residue = true if Ota.boot_ok # display works: keep this image (OTA rollback); the update screen left a ghost

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
    Ota.ui(scr) if Ota.ui_now? # OTA (shell, DIAG, or an automatic one installing): no other e-paper work meanwhile
    held = Shared.take_buttons
    presses = Shared.next_presses # every press, even one made during a refresh
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
    wtest if (reqs & Shared::REQ_WTEST) != 0_u32
    wbar_test if (reqs & Shared::REQ_WBAR) != 0_u32
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
    # Presses come from the knob task's counts, not from held vs prev (which
    # loses a press made while a refresh started by the last one runs). A,
    # and B in Sketch, stay taps on release (above).
    taps = scr == SCR_SKETCH ? (Games::BTN_A | Games::BTN_B) : Games::BTN_A
    presses = presses & (taps ^ 0xFFFFFFFF_u32)
    presses = presses & ((Games::BTN_PLUS | Games::BTN_MINUS) ^ 0xFFFFFFFF_u32) unless Apps.owns_menu?(scr)
    inp.pressed = (inp.pressed & taps) | presses
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
      last_input = millis # idle timers (Sketch colour, red residue) start now
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
        # A (erase) shakes the drawing away first: two ink pulls dissolve
        # the lines (speckled, then gone), then the clean below.
        SkInk.shake if Menu.needs_background? && Shared.upd(SCR_SKETCH) == UPD_INK && SkInk.ready?
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
        # pen resting: re-ink its dot now and then (the pen point is the cursor)
        if now &- Sketch.last_motion_ms >= SkInk::DWELL_MS && SkState.dwell_at != Sketch.last_motion_ms
          SkState.dwell_at = Sketch.last_motion_ms # once per resting place
          SkInk.dwell_ink(Sketch.x, Sketch.y)
        end
        inked = SkInk.take_touches
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
          log3("sketch: ink upload / panel / latency ms", EPD.upload_ms, EPD.panel_ms, SkState.last_lat) if Dbg.on?(Dbg::FRAME)
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
          log2(retrace ? "sketch: retrace rows / latency ms" : "sketch: ink rows / latency ms", b[1] &- b[0] &+ 1, SkState.last_lat) if Dbg.on?(Dbg::FRAME)
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
            log2("game: changed rows / panel ms", b[1] &- b[0] &+ 1, EPD.panel_ms) if Dbg.on?(Dbg::FRAME)
          end
        end
      end
      last_total = millis &- t
      log2("main: screen / frame ms", scr, last_total) if Dbg.on?(Dbg::FRAME)
    end
    if scr == SCR_SKETCH
      Shared.led_mode = Sketch.dirty? ? LED_YELLOW : LED_GREEN
    else
      Shared.led_mode = 0
    end
    Store.sync_upd
    # Sketch left alone: put the red Etch-a-Sketch frame up (slow colour
    # render, ~33 s); drawing then goes on over it (ink pulls never touch it).
    if scr == SCR_SKETCH && !SkState.colour? && Shared.target == scr && !Shared.rendering? &&
       raw_held == 0_u32 && millis &- last_input >= SK_IDLE_COLOUR_MS && !Ota.running?
      log("sketch: idle, colour frame", 0)
      Shared.idle_job = true # input frees the main loop (the waveform completes)
      sketch_colour
      Shared.idle_job = false
      last_input = millis
    end
    if RedRes.residue? && Shared.target == scr && !Shared.rendering? && raw_held == 0_u32 &&
       millis &- last_input >= RES_IDLE_MS && !Ota.running?
      red_residue_clean(scr)
      last_input = millis
    end
    Ota.auto_tick(scr, millis &- last_input)
    # Erase settling (EPD.diff_settle): when an app's diff updates pause,
    # the pixels they erased get their remaining VDL pulls (no pink).
    if EPD.settle_pending? && Shared.target == scr && raw_held == 0_u32 && millis &- EPD.diff_last_ms >= 400
      Shared.rendering = true
      EPD.diff_settle
      Shared.rendering = false
    end
    Shared.live = scr == SCR_SKETCH && !Shared.rendering? && Shared.target == scr
    LibIDF.cr_wait_notify(20_u32) # woken early by the knob task on input
  end
end
