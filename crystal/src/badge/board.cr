module Badge
  # Miscellaneous hardware from lib/board.py: the status LED and the
  # regulator-input voltage sense.
  class BoardIO
    def initialize(@hal : HAL::Board)
      # board.py: Pin(OUT, value=True) behind an inverted Signal -> LED off.
      @hal.gpio_output(Pins::STATUS_LED, true)
      @hal.adc_init(Pins::BATT_V_SNS)
    end

    # Status LED, active low.
    def status_led=(on : Bool) : Nil
      @hal.gpio_write(Pins::STATUS_LED, !on)
    end

    # Regulator input (USB or battery) in millivolts; the sense pin sits
    # behind a 1/2 divider. Note GPIO14 is on ADC2, which the ESP32-S3 shares
    # with Wi-Fi.
    def regulator_input_mv : Int32
      @hal.adc_read_uv(Pins::BATT_V_SNS) // 500
    end
  end
end
