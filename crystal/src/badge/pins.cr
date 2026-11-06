# ESP32-S3 GPIO assignments for the Billboard Badge, collected from the
# MicroPython sources (file named on each group).
module Badge::Pins
  # --- lib/board.py ---
  STATUS_LED =  1 # active low (MicroPython wraps it in an inverted Signal)
  BATT_V_SNS = 14 # 1/2 divider from the 3.3 V regulator input (USB or battery); ADC2_CH3
  TP8_GPIO9  =  9 # test point
  TP9_GPIO41 = 41 # test point
  # UART on the back test pads: TODO in board.py (UART1 disturbs the EPD).

  # --- lib/button.py --- (all active low, internal pull-ups)
  # NOTE: Menu +/- are swapped on the silkscreen. These names follow the
  # firmware (and how the app switcher uses them), not the printed labels.
  MENU_MINUS = 40 # SW5  BUTTON_2  IO40
  MENU_PLUS  = 15 # SW6  BUTTON_3  IO15
  USER_A     = 39 # SW4  BUTTON_1  IO39
  USER_B     = 16 # SW7  BUTTON_4  IO16
  BOOT       =  0 # strapping pin / BOOT button

  # --- lib/led_bar.py ---
  WS2812   = 38 # 8x WS2812 data in
  NUM_LEDS =  8

  # --- lib/epd.py --- (Pervasive Displays E2969JS0B1, two CoGs)
  EPD_CS1    = 13 # chip select, CoG 1 = left half (master)
  EPD_CS2    =  3 # chip select, CoG 2 = right half (slave)
  EPD_BUSY1  = 12 # input, low = busy
  EPD_BUSY2  =  8 # input, low = busy
  EPD_DC     = 10 # data high / command low
  EPD_RST    = 11 # reset, active low
  EPD_SCK    = 21 # SPI clock
  EPD_MOSI   = 47 # SPI data out
  EPD_MISO   = 45 # not connected; the SPI peripheral just wants a pin
  EPD_PWR_EN = 48 # declared in epd.py but never driven there

  # --- lib/sao.py --- (shared I2C bus on all three SAO headers)
  SAO_I2C_BUS  =       0
  SAO_I2C_SCL  =      18
  SAO_I2C_SDA  =      17
  SAO_I2C_FREQ = 400_000
  SAO1_GPIO1   =       2 # ADC1_CH1 - knob 1 (AS5600 OUT)
  SAO1_GPIO2   =      42
  SAO2_GPIO1   =       4 # ADC1_CH3
  SAO2_GPIO2   =       5 # ADC1_CH4
  SAO3_GPIO1   =       7 # ADC1_CH6 - knob 2 (AS5600 OUT)
  SAO3_GPIO2   =       6 # ADC1_CH5

  KNOB1_ADC = SAO1_GPIO1
  KNOB2_ADC = SAO3_GPIO1
end
