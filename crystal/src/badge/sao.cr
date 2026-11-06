module Badge
  # SAO header helper (port of lib/sao.py as fixed in fdd3541): a port's two
  # GPIOs plus a 7-bit I2C target address on the shared SAO I2C bus.
  #
  # The bus is a plain I2C *controller*; there is no I2CTarget (the original
  # set_address() created one and ignored its argument).
  #
  # Errors are return codes, not exceptions: a negative value is an error
  # (`NO_ADDRESS`, `BAD_ADDRESS` or the HAL's -errno).
  class Sao
    NO_ADDRESS  = -1000
    BAD_ADDRESS = -1001

    getter gpio1 : Int32
    getter gpio2 : Int32
    getter address : Int32? = nil

    def self.init_bus(hal : HAL::Board) : Nil
      hal.i2c_init(Pins::SAO_I2C_BUS, Pins::SAO_I2C_SCL, Pins::SAO_I2C_SDA, Pins::SAO_I2C_FREQ)
    end

    def initialize(@hal : HAL::Board, @gpio1 : Int32, @gpio2 : Int32)
    end

    def self.sao1(hal) : Sao
      new(hal, Pins::SAO1_GPIO1, Pins::SAO1_GPIO2)
    end

    def self.sao2(hal) : Sao
      new(hal, Pins::SAO2_GPIO1, Pins::SAO2_GPIO2)
    end

    def self.sao3(hal) : Sao
      new(hal, Pins::SAO3_GPIO1, Pins::SAO3_GPIO2)
    end

    # Set the 7-bit I2C address of the device on this port. Returns false
    # (and leaves the address unchanged) if it is outside 0x00..0x7F.
    def address=(addr : Int32) : Bool
      return false unless 0 <= addr <= 0x7F
      @address = addr
      true
    end

    def clear_address : Nil
      @address = nil
    end

    # Read `buf.size` bytes from the target. Returns bytes read or < 0.
    def read(buf : Bytes, stop : Bool = true) : Int32
      addr = @address
      return NO_ADDRESS unless addr
      @hal.i2c_read(Pins::SAO_I2C_BUS, addr, buf, stop)
    end

    # Write `data` to the target. Returns bytes written or < 0.
    def write(data : Bytes, stop : Bool = true) : Int32
      addr = @address
      return NO_ADDRESS unless addr
      @hal.i2c_write(Pins::SAO_I2C_BUS, addr, data, stop)
    end

    # Register read: write `reg` without STOP, then read with a repeated start.
    def read_reg(reg : UInt8, buf : Bytes) : Int32
      addr = @address
      return NO_ADDRESS unless addr
      r = reg
      n = @hal.i2c_write(Pins::SAO_I2C_BUS, addr, Slice.new(pointerof(r), 1), false)
      return n if n < 0
      @hal.i2c_read(Pins::SAO_I2C_BUS, addr, buf, true)
    end
  end
end
