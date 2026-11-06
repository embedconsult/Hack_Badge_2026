# Blink the status LED (GPIO1, active low) at a rate set by the left knob.
#
# The left knob is an AS5600 on SAO1 whose analog output is on GPIO2
# (ADC1 channel 1). Turning it sweeps the half-period from 50 to ~1000 ms.
# Compiled with --prelude=empty: only compiler primitives are available
# (no stdlib, no GC, no exceptions), so wrapping arithmetic (&*, &+) and
# unsafe_div are used.

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

  alias AdcHandle = Void*
  fun adc_oneshot_new_unit(cfg : AdcOneshotUnitInitCfg*, handle : AdcHandle*) : Int32
  fun adc_oneshot_config_channel(handle : AdcHandle, channel : Int32, cfg : AdcOneshotChanCfg*) : Int32
  fun adc_oneshot_read(handle : AdcHandle, channel : Int32, out_raw : Int32*) : Int32

  # main/main.c: configTICK_RATE_HZ
  $crystal_tick_rate_hz : UInt32
end

STATUS_LED       = 1
GPIO_MODE_OUTPUT = 2 # GPIO_MODE_DEF_OUTPUT (BIT1)
ADC_UNIT_1       = 0
ADC_ATTEN_DB_12  = 3
KNOB_LEFT_CH     = 1 # GPIO2 = ADC1_CH1 (SAO1 GPIO1)
MIN_MS           = 50_u32

def ms_to_ticks(ms : UInt32) : UInt32
  ticks = (ms &* LibIDF.crystal_tick_rate_hz).unsafe_div(1000_u32)
  ticks == 0_u32 ? 1_u32 : ticks
end

fun crystal_app_main : Void
  LibIDF.gpio_reset_pin(STATUS_LED)
  LibIDF.gpio_set_direction(STATUS_LED, GPIO_MODE_OUTPUT)

  unit_cfg = LibIDF::AdcOneshotUnitInitCfg.new
  unit_cfg.unit_id = ADC_UNIT_1
  adc = uninitialized Void*
  LibIDF.adc_oneshot_new_unit(pointerof(unit_cfg), pointerof(adc))
  chan_cfg = LibIDF::AdcOneshotChanCfg.new
  chan_cfg.atten = ADC_ATTEN_DB_12
  LibIDF.adc_oneshot_config_channel(adc, KNOB_LEFT_CH, pointerof(chan_cfg))

  on = false
  raw = 0
  while true
    on = !on
    LibIDF.gpio_set_level(STATUS_LED, on ? 0_u32 : 1_u32) # active low
    LibIDF.adc_oneshot_read(adc, KNOB_LEFT_CH, pointerof(raw))
    raw = 0 if raw < 0
    half_period = MIN_MS &+ (raw.to_u32! &* 950_u32).unsafe_div(4095_u32)
    LibIDF.vTaskDelay(ms_to_ticks(half_period))
  end
end
