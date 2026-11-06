# Hardware-abstraction layer for the badge drivers.
#
# Every driver in `Badge` talks to the hardware only through a
# `Badge::HAL::Board`. The interface is deliberately C-shaped (ints, bools and
# `Bytes`) so the ESP-IDF implementation can be a thin wrapper over `lib`
# bindings (gpio_set_level, spi_device_transmit, adc_oneshot_read +
# calibration, rmt/led_strip, i2c_master_*, esp_timer_get_time, vTaskDelay).
#
# `Badge::HAL::Mock` implements the same interface on the host and records
# what the drivers do, for specs.
module Badge::HAL
  enum Pull
    None
    Up
    Down
  end

  # Digital GPIO.
  module GPIO
    abstract def gpio_input(pin : Int32, pull : Pull) : Nil
    abstract def gpio_output(pin : Int32, level : Bool) : Nil
    abstract def gpio_write(pin : Int32, level : Bool) : Nil
    abstract def gpio_read(pin : Int32) : Bool
  end

  # Write-only SPI master on the given pins (mode 0, MSB first). Upstream
  # moved the e-paper from SoftSPI to hardware SPI at the same 8 MHz; either
  # is fine behind this call. Chip selects are plain GPIOs, driven by callers.
  module SPI
    abstract def spi_init(sck : Int32, mosi : Int32, miso : Int32, baud : Int32) : Nil
    abstract def spi_write(data : Bytes) : Nil
  end

  # One-shot ADC read, calibrated, in microvolts. `adc_init` configures the
  # pin for the full (11/12 dB attenuation) range.
  module ADC
    abstract def adc_init(pin : Int32) : Nil
    abstract def adc_read_uv(pin : Int32) : Int32
  end

  # WS2812 strip on one pin. `grb` is 3 bytes per LED, already in wire order.
  module WS2812
    abstract def ws2812_write(pin : Int32, grb : Bytes) : Nil
  end

  # I2C master. Return values follow MicroPython: bytes/ACKs transferred, or
  # a negative error code (e.g. -ENODEV) on NACK/timeout.
  module I2C
    abstract def i2c_init(bus : Int32, scl : Int32, sda : Int32, freq : Int32) : Nil
    abstract def i2c_write(bus : Int32, addr : Int32, data : Bytes, stop : Bool) : Int32
    abstract def i2c_read(bus : Int32, addr : Int32, buf : Bytes, stop : Bool) : Int32
  end

  # Time. `millis` wraps like MicroPython's ticks_ms; compare with
  # `HAL.ticks_diff`. `sleep_ms` blocks the calling task (vTaskDelay on the
  # badge); `yield_now` lets other tasks run (taskYIELD / vTaskDelay(0)).
  module Clock
    abstract def millis : UInt32
    abstract def sleep_ms(ms : Int32) : Nil
    abstract def yield_now : Nil
  end

  # Everything a badge driver may need.
  abstract class Board
    include GPIO
    include SPI
    include ADC
    include WS2812
    include I2C
    include Clock
  end

  # Signed difference `a - b` of two wrapping millisecond counters.
  def self.ticks_diff(a : UInt32, b : UInt32) : Int32
    (a &- b).to_i32!
  end

  ENODEV = -19

  # Host implementation that records driver activity.
  #
  # * Inputs read high (pull-ups) unless set with `set_input` or scripted
  #   with `script_input` (one value per read, the last one sticks).
  # * `sleep_ms` advances the fake clock and is logged in `sleeps`.
  # * Every `spi_write` is logged with the level of all output pins at the
  #   time, so specs can tell commands (DC low) from data and which CS was low.
  class Mock < Board
    NUM_PINS = 49

    record PinWrite, pin : Int32, level : Bool
    record SpiWrite, data : Bytes, levels : StaticArray(Bool, 49) do
      def level(pin : Int32) : Bool
        levels[pin]
      end
    end
    record I2CTransfer, bus : Int32, addr : Int32, data : Bytes, read : Bool, stop : Bool

    getter levels = StaticArray(Bool, 49).new(false)
    getter pin_writes = [] of PinWrite
    getter pulls = {} of Int32 => Pull
    getter outputs = [] of Int32
    getter spi_writes = [] of SpiWrite
    getter spi_config : {Int32, Int32, Int32, Int32}? = nil
    getter ws2812_frames = [] of {Int32, Bytes}
    getter i2c_config = {} of Int32 => {Int32, Int32, Int32}
    getter i2c_log = [] of I2CTransfer
    getter sleeps = [] of Int32
    getter adc_pins = [] of Int32
    property now : UInt32 = 0_u32
    property yields = 0
    # Advance the clock this much on every `yield_now` (default: not at all).
    property yield_ms = 0
    # Advance the clock this much on every `gpio_read` (simulates poll cost).
    property read_ms = 0
    # Called after each logged SPI write (e.g. to script BUSY after 0x15).
    property on_spi : Proc(SpiWrite, Nil)? = nil

    @inputs = {} of Int32 => Bool
    @scripts = {} of Int32 => Array(Bool)
    @adc = {} of Int32 => Int32
    @adc_scripts = {} of Int32 => Array(Int32)
    # Devices on the I2C bus: addr => bytes returned by reads.
    @i2c_devices = {} of Int32 => Bytes

    def set_input(pin : Int32, level : Bool) : Nil
      @scripts.delete(pin)
      @inputs[pin] = level
    end

    # Each read of `pin` consumes one value; the last one then sticks.
    def script_input(pin : Int32, values : Array(Bool)) : Nil
      @scripts[pin] = values.dup
    end

    def set_adc_uv(pin : Int32, uv : Int32) : Nil
      @adc_scripts.delete(pin)
      @adc[pin] = uv
    end

    def set_adc_mv(pin : Int32, mv : Int32) : Nil
      set_adc_uv(pin, mv * 1000)
    end

    def script_adc_uv(pin : Int32, values : Array(Int32)) : Nil
      @adc_scripts[pin] = values.dup
    end

    def add_i2c_device(addr : Int32, response : Bytes = Bytes.empty) : Nil
      @i2c_devices[addr] = response
    end

    def clear_log : Nil
      @pin_writes.clear
      @spi_writes.clear
      @ws2812_frames.clear
      @i2c_log.clear
      @sleeps.clear
      @yields = 0
    end

    # All SPI bytes sent, concatenated.
    def spi_bytes : Array(UInt8)
      out = [] of UInt8
      @spi_writes.each { |w| out.concat(w.data) }
      out
    end

    def total_sleep_ms : Int32
      @sleeps.sum
    end

    # --- GPIO ---
    def gpio_input(pin : Int32, pull : Pull) : Nil
      @pulls[pin] = pull
    end

    def gpio_output(pin : Int32, level : Bool) : Nil
      @outputs << pin unless @outputs.includes?(pin)
      gpio_write(pin, level)
    end

    def gpio_write(pin : Int32, level : Bool) : Nil
      @levels[pin] = level
      @pin_writes << PinWrite.new(pin, level)
    end

    def gpio_read(pin : Int32) : Bool
      @now = @now &+ @read_ms.to_u32
      if (s = @scripts[pin]?) && !s.empty?
        v = s.size > 1 ? s.shift : s[0]
        @inputs[pin] = v
        return v
      end
      if @outputs.includes?(pin)
        @levels[pin]
      else
        @inputs.fetch(pin) { @pulls[pin]? != Pull::Down }
      end
    end

    # --- SPI ---
    def spi_init(sck : Int32, mosi : Int32, miso : Int32, baud : Int32) : Nil
      @spi_config = {sck, mosi, miso, baud}
    end

    def spi_write(data : Bytes) : Nil
      w = SpiWrite.new(data.dup, @levels)
      @spi_writes << w
      @on_spi.try &.call(w)
    end

    # --- ADC ---
    def adc_init(pin : Int32) : Nil
      @adc_pins << pin unless @adc_pins.includes?(pin)
    end

    def adc_read_uv(pin : Int32) : Int32
      if (s = @adc_scripts[pin]?) && !s.empty?
        v = s.size > 1 ? s.shift : s[0]
        @adc[pin] = v
        return v
      end
      @adc.fetch(pin, 0)
    end

    # --- WS2812 ---
    def ws2812_write(pin : Int32, grb : Bytes) : Nil
      @ws2812_frames << {pin, grb.dup}
    end

    def last_ws2812 : Bytes
      @ws2812_frames.last[1]
    end

    # --- I2C ---
    def i2c_init(bus : Int32, scl : Int32, sda : Int32, freq : Int32) : Nil
      @i2c_config[bus] = {scl, sda, freq}
    end

    def i2c_write(bus : Int32, addr : Int32, data : Bytes, stop : Bool) : Int32
      @i2c_log << I2CTransfer.new(bus, addr, data.dup, false, stop)
      @i2c_devices.has_key?(addr) ? data.size : ENODEV
    end

    def i2c_read(bus : Int32, addr : Int32, buf : Bytes, stop : Bool) : Int32
      resp = @i2c_devices[addr]?
      unless resp
        @i2c_log << I2CTransfer.new(bus, addr, Bytes.empty, true, stop)
        return ENODEV
      end
      buf.size.times { |i| buf[i] = i < resp.size ? resp[i] : 0xFF_u8 }
      @i2c_log << I2CTransfer.new(bus, addr, buf.dup, true, stop)
      buf.size
    end

    # --- Clock ---
    def millis : UInt32
      @now
    end

    def sleep_ms(ms : Int32) : Nil
      @sleeps << ms
      @now = @now &+ ms.to_u32
    end

    def yield_now : Nil
      @yields += 1
      @now = @now &+ @yield_ms.to_u32
    end
  end
end
