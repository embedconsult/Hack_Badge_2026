# Blink the status LED (GPIO1, active low) every 250 ms.
# Compiled with --prelude=empty: only compiler primitives are available
# (no stdlib, no GC, no exceptions), so wrapping arithmetic (&*) and
# unsafe_div are used.

lib LibIDF
  # driver/gpio.h (gpio_num_t / gpio_mode_t are C enums -> int)
  fun gpio_reset_pin(gpio_num : Int32) : Int32
  fun gpio_set_direction(gpio_num : Int32, mode : Int32) : Int32
  fun gpio_set_level(gpio_num : Int32, level : UInt32) : Int32

  # freertos/task.h: a real function (not a macro); TickType_t is uint32_t
  fun vTaskDelay(ticks : UInt32) : Void

  # main/main.c: configTICK_RATE_HZ
  $crystal_tick_rate_hz : UInt32
end

STATUS_LED       = 1
GPIO_MODE_OUTPUT = 2 # GPIO_MODE_DEF_OUTPUT (BIT1)
BLINK_MS         = 250_u32

fun crystal_app_main : Void
  LibIDF.gpio_reset_pin(STATUS_LED)
  LibIDF.gpio_set_direction(STATUS_LED, GPIO_MODE_OUTPUT)

  ticks = (BLINK_MS &* LibIDF.crystal_tick_rate_hz).unsafe_div(1000_u32)
  ticks = 1_u32 if ticks == 0_u32

  on = false
  while true
    on = !on
    LibIDF.gpio_set_level(STATUS_LED, on ? 0_u32 : 1_u32) # active low
    LibIDF.vTaskDelay(ticks)
  end
end
