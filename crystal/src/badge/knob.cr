module Badge
  # AS5600 magnetic encoder read through its ANALOG output pin.
  #
  # The AS5600 OUT pin defaults to a ratiometric 10%..90% of VDD across one
  # turn, so with VDD = 3.3 V the angle spans 330..2970 mV. Knob 1 sits on
  # SAO1 GPIO1 (GPIO2, ADC1_CH1), knob 2 on SAO3 GPIO1 (GPIO7, ADC1_CH6).
  # (Upstream's Sketch app reads the same chips over I2C instead; its
  # wraparound/deadband delta logic is reused here.)
  #
  # Angles are in counts, 0..4095 for 0..360 degrees, like the AS5600's own
  # ANGLE register. `update` reads the ADC once and runs an exponential
  # moving average that is wrap-aware, so 4095 -> 0 doesn't swing through
  # the middle.
  class Knob
    COUNTS     = 4096
    HALF       = 2048
    MASK       = 4095
    VDD_MV     = 3300
    DEFAULT_LO = VDD_MV // 10     # 330 mV at 0 degrees
    DEFAULT_HI = VDD_MV * 9 // 10 # 2970 mV at 360 degrees
    # Internal fixed point: 1 count = 16 units.
    FRAC      = 4
    FULL_FRAC = COUNTS << FRAC

    getter pin : Int32
    # Output voltage at 0 degrees and at 360 degrees. Swap them to reverse
    # the direction (or use the AS5600 DIR pin).
    getter lo_mv : Int32
    getter hi_mv : Int32
    # EMA weight is 1 / 2**smoothing; 0 disables smoothing.
    property smoothing : Int32 = 2
    # Counts of jitter ignored by `delta`.
    property deadband : Int32 = 3
    getter raw_mv = 0
    getter raw_counts = 0

    @acc = -1 # smoothed angle in 1/16 counts; -1 = no reading yet
    @last : Int32? = nil

    def initialize(@hal : HAL::Board, @pin : Int32, @lo_mv : Int32 = DEFAULT_LO, @hi_mv : Int32 = DEFAULT_HI)
      @hal.adc_init(@pin)
    end

    def self.knob1(hal) : Knob
      new(hal, Pins::KNOB1_ADC)
    end

    def self.knob2(hal) : Knob
      new(hal, Pins::KNOB2_ADC)
    end

    # Set both endpoints (mV at 0 and 360 degrees). Ignored if they're equal.
    def set_endpoints(lo_mv : Int32, hi_mv : Int32) : Nil
      return if lo_mv == hi_mv
      @lo_mv = lo_mv
      @hi_mv = hi_mv
    end

    # mV -> counts 0..4095, clamped outside the endpoints.
    def self.counts_from_mv(mv : Int32, lo_mv : Int32 = DEFAULT_LO, hi_mv : Int32 = DEFAULT_HI) : Int32
      span = hi_mv - lo_mv
      return 0 if span == 0
      c = ((mv - lo_mv).to_i64 * COUNTS // span).to_i32
      c.clamp(0, MASK)
    end

    # Signed shortest difference a - b in counts, -2048..2047.
    def self.wrap_delta(a : Int32, b : Int32) : Int32
      ((a - b + HALF) & MASK) - HALF
    end

    def self.counts_to_degrees(counts : Int32) : Float32
      counts.to_f32 * 360_f32 / COUNTS
    end

    # Tenths of a degree, rounded (integer-only callers).
    def self.counts_to_decidegrees(counts : Int32) : Int32
      (counts * 3600 + HALF) // COUNTS
    end

    # Read the ADC once and update the smoothed angle. Returns `angle`.
    def update : Int32
      @raw_mv = @hal.adc_read_uv(@pin) // 1000
      @raw_counts = Knob.counts_from_mv(@raw_mv, @lo_mv, @hi_mv)
      feed(@raw_counts)
    end

    # Feed one raw reading in counts (exposed for specs / other sources).
    def feed(counts : Int32) : Int32
      target = (counts & MASK) << FRAC
      if @acc < 0 || @smoothing <= 0
        @acc = target
      else
        d = ((target - @acc + FULL_FRAC // 2) & (FULL_FRAC - 1)) - FULL_FRAC // 2
        # Round the step away from zero so a steady input converges exactly.
        k = 1 << @smoothing
        step = d >= 0 ? (d + k - 1) // k : -((k - 1 - d) // k)
        @acc = (@acc + step) & (FULL_FRAC - 1)
      end
      angle
    end

    # Smoothed angle in counts, 0..4095 (0 before the first reading).
    def angle : Int32
      return 0 if @acc < 0
      ((@acc + (1 << (FRAC - 1))) >> FRAC) & MASK
    end

    def degrees : Float32
      Knob.counts_to_degrees(angle)
    end

    def decidegrees : Int32
      Knob.counts_to_decidegrees(angle) % 3600
    end

    # Signed counts turned since the last accepted reading, wrapping at
    # 0/4095. Changes within the deadband return 0 and are NOT consumed, so
    # slow turns still accumulate. The first call establishes the reference
    # and returns 0. Uses the current smoothed angle; call `update` first.
    def delta : Int32
      a = angle
      last = @last
      if last.nil?
        @last = a
        return 0
      end
      d = Knob.wrap_delta(a, last)
      return 0 if -@deadband <= d <= @deadband
      @last = a
      d
    end

    # Forget the delta reference (next `delta` returns 0).
    def reset_delta : Nil
      @last = nil
    end
  end
end
