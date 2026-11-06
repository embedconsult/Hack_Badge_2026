module Badge
  # E-paper driver: Pervasive Displays E2969JS0B1, 9.69" 960x672
  # black/white/red, two CoGs (CoG 1 = left half, CoG 2 = right half) on one
  # SPI bus with separate chip selects.
  #
  # Port of lib/epd.py, following upstream/claude_development where it
  # differs: fast waveform tables (register 0xB0), multi-pass fast updates,
  # black/white flash before fast updates, a black/white-only LUT for frames
  # without red, periodic full refreshes, 10 ms BUSY polling with a timeout,
  # chunked image upload that yields between chunks, and update requests that
  # arrive during a refresh are not lost.
  #
  # All waits go through `HAL::Clock#sleep_ms` (FreeRTOS delay on the badge).
  # `update` only records a request; the display task calls `service`, which
  # performs the (blocking, ~4-35 s) refresh.
  class EPD
    WIDTH            = 960
    HEIGHT           = 672
    WIDTH_BYTES      = WIDTH // 8                # 120
    HALF_WIDTH_BYTES = WIDTH_BYTES // 2          #  60
    PLANE_SIZE       = WIDTH_BYTES * HEIGHT      # 80640 bytes, one color, whole panel
    HALF_PLANE_SIZE  = HALF_WIDTH_BYTES * HEIGHT # 40320 bytes, one color, one CoG

    SPI_BAUD        = 8_000_000
    SPI_CHUNK       =      4096 # bytes per SPI write before yielding
    BUSY_POLL_MS    =        10
    BUSY_TIMEOUT_MS =   120_000

    # Upstream tunables (defaults).
    FAST_BY_DEFAULT    = true
    FULL_REFRESH_EVERY = 10 # after this many fast updates, one full refresh
    FAST_PASSES        =  3 # fast waveform runs per update (1 leaves ghosting)
    FLASH_BEFORE_FAST  = true
    FLASH_PASSES       = 1
    BW_FAST_LUT        = true

    # Panel part number from /data/hwconf "display_pn" (default B1).
    enum Panel
      B1  # CoG driver B, framebuffer bits reversed
      P84 # CoG driver 8, bits as-is

      def reverse_bits? : Bool
        !p84?
      end

      def driver_b? : Bool
        !p84?
      end
    end

    enum Target
      Both
      Left
      Right
    end

    enum Ink
      White
      Black
      Red
    end

    # Whole-panel, MONO_HLSB planes (1 = ink), 120 bytes per row.
    getter black : Bytes
    getter red : Bytes
    getter panel : Panel

    property fast_by_default : Bool = FAST_BY_DEFAULT
    property full_refresh_every : Int32 = FULL_REFRESH_EVERY
    property fast_passes : Int32 = FAST_PASSES
    property flash_before_fast : Bool = FLASH_BEFORE_FAST
    property flash_sequence : Array(Ink) = [Ink::Black, Ink::White]
    property flash_passes : Int32 = FLASH_PASSES
    property bw_fast_lut : Bool = BW_FAST_LUT

    getter last_update_ms = 0
    getter fast_count = 0
    getter busy_timeouts = 0
    # nil = unknown; whether the CoG runs a second 0x15 without a re-init.
    getter repeat_refresh_ok : Bool? = nil

    REVERSE = StaticArray(UInt8, 256).new { |i| EPD.reverse_byte(i.to_u8) }

    def self.reverse_byte(b : UInt8) : UInt8
      b = (b & 0xF0) >> 4 | (b & 0x0F) << 4
      b = (b & 0xCC) >> 2 | (b & 0x33) << 2
      (b & 0xAA) >> 1 | (b & 0x55) << 1
    end

    @ready = false
    @updated = true
    @req_fast : Bool = FAST_BY_DEFAULT
    @req_flash : Bool? = nil
    @req_passes : Int32? = nil
    @req_bw = false
    @req_auto_full = true
    @fill = StaticArray(UInt8, 256).new(0_u8)

    def initialize(@hal : HAL::Board, @panel : Panel = Panel::B1)
      @hal.gpio_output(Pins::EPD_DC, true)
      @hal.gpio_output(Pins::EPD_RST, true)
      @hal.gpio_output(Pins::EPD_CS1, true)
      @hal.gpio_output(Pins::EPD_CS2, true)
      @hal.gpio_input(Pins::EPD_BUSY1, HAL::Pull::None)
      @hal.gpio_input(Pins::EPD_BUSY2, HAL::Pull::None)
      @hal.spi_init(Pins::EPD_SCK, Pins::EPD_MOSI, Pins::EPD_MISO, SPI_BAUD)

      @black = Bytes.new(PLANE_SIZE)
      @red = Bytes.new(PLANE_SIZE)
      @black_left = Bytes.new(HALF_PLANE_SIZE)
      @black_right = Bytes.new(HALF_PLANE_SIZE)
      @red_left = Bytes.new(HALF_PLANE_SIZE)
      @red_right = Bytes.new(HALF_PLANE_SIZE)

      # Driver B black/white table: table 2 (red) idled after group 4.
      @bw_lut_b = Bytes.new(LUTs::LUTB_BASE.size)
      @bw_lut_b.copy_from(LUTs::LUTB_BASE)
      (5...10).each do |g|
        o = 2 * 80 + g * 8
        @bw_lut_b[o] = 0x00
        (1...8).each { |k| @bw_lut_b[o + k] = 0x01 }
      end
    end

    def bw_lut_b : Bytes
      @bw_lut_b
    end

    # ---------------------------------------------------------------- drawing

    def clear : Nil
      @black.fill(0_u8)
      @red.fill(0_u8)
    end

    def set_pixel(x : Int32, y : Int32, ink : Ink) : Nil
      return unless 0 <= x < WIDTH && 0 <= y < HEIGHT
      i = y * WIDTH_BYTES + (x >> 3)
      mask = 0x80_u8 >> (x & 7)
      case ink
      when .black?
        @black[i] |= mask
        @red[i] &= ~mask
      when .red?
        @red[i] |= mask
        @black[i] &= ~mask
      else
        @black[i] &= ~mask
        @red[i] &= ~mask
      end
    end

    def pixel(x : Int32, y : Int32) : Ink
      i = y * WIDTH_BYTES + (x >> 3)
      mask = 0x80_u8 >> (x & 7)
      return Ink::Red if @red[i] & mask != 0
      return Ink::Black if @black[i] & mask != 0
      Ink::White
    end

    # LVGL flush: RGB565 (little-endian) area -> planes. Pure red-ish is red,
    # dark is black, everything else white (upstream _rgb565_to_planes).
    def blit_rgb565(src : Bytes, stride : Int32, w : Int32, h : Int32, x1 : Int32, y1 : Int32) : Nil
      h.times do |row|
        base = (y1 + row) * WIDTH + x1
        ro = row * stride
        w.times do |col|
          i = ro + col * 2
          c = src[i].to_i32 | (src[i + 1].to_i32 << 8)
          idx = base + col
          byte = idx >> 3
          mask = 0x80_u8 >> (idx & 7)
          r_hi = c & 0x8000
          g_hi = c & 0x0400
          b_hi = c & 0x0010
          if r_hi != 0 && g_hi == 0 && b_hi == 0
            @red[byte] |= mask
            @black[byte] &= ~mask
          elsif r_hi == 0 && g_hi == 0 && b_hi == 0
            @black[byte] |= mask
            @red[byte] &= ~mask
          else
            @black[byte] &= ~mask
            @red[byte] &= ~mask
          end
        end
      end
    end

    # Split a 120-byte-wide plane into two 60-byte-wide halves, mapping each
    # byte through the bit-reversal table when `reverse`.
    def self.split_halves(src : Bytes, left : Bytes, right : Bytes, reverse : Bool) : Nil
      HEIGHT.times do |row|
        sb = row * WIDTH_BYTES
        db = row * HALF_WIDTH_BYTES
        HALF_WIDTH_BYTES.times do |c|
          l = src[sb + c]
          r = src[sb + HALF_WIDTH_BYTES + c]
          if reverse
            l = REVERSE[l]
            r = REVERSE[r]
          end
          left[db + c] = l
          right[db + c] = r
        end
      end
    end

    def self.any_set?(buf : Bytes) : Bool
      buf.each { |b| return true if b != 0 }
      false
    end

    def halves : {Bytes, Bytes, Bytes, Bytes}
      {@black_left, @red_left, @black_right, @red_right}
    end

    # ---------------------------------------------------------------- requests

    # Done drawing: request a refresh. `fast` nil = `fast_by_default`;
    # `flash` nil = `flash_before_fast`; `passes` nil = `fast_passes`;
    # `bw` forces the black/white waveform; `auto_full` false keeps this
    # update out of the periodic full-refresh count.
    def update(fast : Bool? = nil, flash : Bool? = nil, passes : Int32? = nil,
               bw : Bool = false, auto_full : Bool = true) : Nil
      @req_fast = fast.is_a?(Bool) ? fast : @fast_by_default
      @req_flash = flash
      @req_passes = passes
      @req_bw = bw
      @req_auto_full = auto_full
      @updated = false
      @ready = true
    end

    def full_update : Nil
      update(fast: false)
    end

    # Redraw the framebuffer with a flash to clear ghosting.
    def clean : Nil
      update(fast: true, flash: true)
    end

    def done_updating? : Bool
      @updated
    end

    def update_pending? : Bool
      @ready
    end

    # Display task body: if an update was requested, push the framebuffers
    # to the panel (blocking). Returns true if a refresh ran.
    def service : Bool
      return false unless @ready
      # Clear before copying, so an update() during the refresh isn't lost.
      @ready = false
      fast = @req_fast
      req_flash = @req_flash
      flash = req_flash.is_a?(Bool) ? req_flash : @flash_before_fast
      auto_full = @req_auto_full
      fast = false if fast && auto_full && @fast_count >= @full_refresh_every

      EPD.split_halves(@black, @black_left, @black_right, @panel.reverse_bits?)
      EPD.split_halves(@red, @red_left, @red_right, @panel.reverse_bits?)
      has_red = EPD.any_set?(@red)

      global_update(fast, has_red, flash, @req_passes, @req_bw)

      if !fast
        @fast_count = 0
      elsif auto_full
        @fast_count += 1
      end
      @updated = true unless @ready
      true
    end

    # One complete update of the panel from the split half planes.
    def global_update(fast : Bool, has_red : Bool, flash : Bool, passes : Int32?, bw : Bool) : Nil
      t_start = @hal.millis
      lut = fast ? fast_lut(has_red && !bw) : nil
      n = fast ? Math.max(1, passes || @fast_passes) : 1

      if fast && flash
        @flash_sequence.each do |ink|
          run_frame(ink, fast_lut(ink.red?), Math.max(1, @flash_passes))
        end
      end
      run_frame(nil, lut, n)
      @last_update_ms = HAL.ticks_diff(@hal.millis, t_start)
    end

    # Short waveform table for the panel's CoG revision.
    def fast_lut(has_red : Bool) : Bytes
      if @panel.driver_b?
        (!has_red && @bw_fast_lut) ? @bw_lut_b : LUTs::LUTB_BASE
      else
        has_red ? LUTs::LUT8_RED_CLEAR : LUTs::LUT8_NORED_CLEAR
      end
    end

    # Upload one frame (`solid` nil = the split framebuffers, else a solid
    # flash color) and run the waveform `passes` times.
    private def run_frame(solid : Ink?, lut : Bytes?, passes : Int32) : Nil
      if passes > 1 && @repeat_refresh_ok == false
        # This CoG ignores back-to-back refreshes: redo everything per pass.
        passes.times do
          prepare(solid, lut)
          refresh_once
          dcdc_soft_shutdown
        end
        return
      end

      prepare(solid, lut)
      p = 0
      while p < passes
        dt = refresh_once
        if p == 1 && @repeat_refresh_ok.nil?
          # A real pass takes seconds; a few ms means it was ignored.
          ok = dt > 500
          @repeat_refresh_ok = ok
          unless ok
            dcdc_soft_shutdown
            (p...passes).each do
              prepare(solid, lut)
              refresh_once
              dcdc_soft_shutdown
            end
            return
          end
        end
        p += 1
      end
      dcdc_soft_shutdown
    end

    # Reset, upload the image, init the CoG, load the LUT, power up DC/DC.
    private def prepare(solid : Ink?, lut : Bytes?) : Nil
      reset
      send_images(solid)
      cog_initial
      send(Target::Both, 0xB0_u8, lut) if lut
      dcdc_soft_start
    end

    # Trigger one waveform run and wait for it; returns ms the panel was busy.
    private def refresh_once : Int32
      display_refresh
      t = @hal.millis
      wait_not_busy
      HAL.ticks_diff(@hal.millis, t) + 5
    end

    # ---------------------------------------------------------------- BUSY

    # True while either CoG is busy (BUSY is active low).
    def busy? : Bool
      !@hal.gpio_read(Pins::EPD_BUSY1) || !@hal.gpio_read(Pins::EPD_BUSY2)
    end

    # Poll BUSY every `poll_ms`; false on timeout.
    def wait_not_busy(poll_ms : Int32 = BUSY_POLL_MS, timeout_ms : Int32 = BUSY_TIMEOUT_MS) : Bool
      t0 = @hal.millis
      while busy?
        if HAL.ticks_diff(@hal.millis, t0) > timeout_ms
          @busy_timeouts += 1
          return false
        end
        @hal.sleep_ms(poll_ms)
      end
      true
    end

    # ---------------------------------------------------------------- CoG sequences
    # (timings from the PDi reference driver, as in lib/epd.py)

    def cog_initial : Nil
      cmd(Target::Both, 0x05, 0x7D)
      @hal.sleep_ms(200)
      cmd(Target::Both, 0x05, 0x00)
      @hal.sleep_ms(10)
      cmd(Target::Both, 0xD8, 0x80) # MS_SYNC
      cmd(Target::Both, 0xD6, 0x00) # BVSS
      cmd(Target::Both, 0xA7, 0x10)
      @hal.sleep_ms(100)
      cmd(Target::Both, 0xA7, 0x00)
      @hal.sleep_ms(100)
      cmd(Target::Both, 0x03, 0x00, 0x11) # OSC

      {Target::Left, Target::Right}.each do |t|
        cmd(t, 0x44, 0x00)
        cmd(t, 0x45, 0x80)
        cmd(t, 0xA7, 0x10)
        @hal.sleep_ms(100)
        cmd(t, 0xA7, 0x00)
        @hal.sleep_ms(100)
        cmd(t, 0x44, 0x06)
        cmd(t, 0x45, 0x82) # temperature 0x82 @ 25 C
        cmd(t, 0xA7, 0x10)
        @hal.sleep_ms(100)
        cmd(t, 0xA7, 0x00)
        @hal.sleep_ms(100)
      end

      cmd(Target::Both, 0x60, 0x25) # TCON
      cmd(Target::Left, 0x61, 0x01) # STV_DIR for display 1
      cmd(Target::Both, 0x02, 0x00) # VCOM
    end

    # CoG shutdown (never called by the Python either; the update path ends
    # with dcdc_soft_shutdown).
    def cog_poweroff : Nil
      cmd(Target::Both, 0x09, 0x7F, 0x7D, 0x00)
      @hal.sleep_ms(200)
      wait_not_busy(1)
      pin(Pins::EPD_DC, false)
      pin(Pins::EPD_CS1, false)
      @hal.sleep_ms(150)
      pin(Pins::EPD_RST, false)
    end

    # CoG power-on hard reset.
    def reset : Nil
      @hal.sleep_ms(200)
      pin(Pins::EPD_RST, true)
      @hal.sleep_ms(20)
      pin(Pins::EPD_RST, false)
      @hal.sleep_ms(200)
      pin(Pins::EPD_RST, true)
      @hal.sleep_ms(200)
      pin(Pins::EPD_CS1, true)
      pin(Pins::EPD_CS2, true)
      @hal.sleep_ms(5)
    end

    private def send_images(solid : Ink?) : Nil
      cmd(Target::Both, 0x13, 0x00, 0x3B, 0x00, 0x00, 0x9F, 0x02) # DUW, both halves
      cmd(Target::Both, 0x90, 0x00, 0x3B, 0x00, 0xA9)             # DRFW, both halves
      {Target::Left, Target::Right}.each do |t|
        bk = t.left? ? @black_left : @black_right
        rd = t.left? ? @red_left : @red_right
        cmd(t, 0x12, 0x3B, 0x00, 0x14) # RAM_RW
        if solid
          send_fill(t, 0x10, solid.black? ? 0xFF_u8 : 0x00_u8)
        else
          send_big(t, 0x10, bk)
        end
        cmd(t, 0x12, 0x3B, 0x00, 0x14)
        if solid
          send_fill(t, 0x11, solid.red? ? 0xFF_u8 : 0x00_u8)
        else
          send_big(t, 0x11, rd)
        end
      end
    end

    def dcdc_soft_start : Nil
      cmd(Target::Both, 0x51, 0x50, 0x01)
      (1...5).each do |v|
        cmd(Target::Both, 0x09, 0x1F)
        cmd(Target::Both, 0x51, 0x50, v)
        cmd(Target::Both, 0x09, 0x9F)
        @hal.sleep_ms(2)
      end
      (1...11).each do |v|
        cmd(Target::Both, 0x09, 0x1F)
        cmd(Target::Both, 0x51, 0x0A, v)
        cmd(Target::Both, 0x09, 0x9F)
        @hal.sleep_ms(2)
      end
      (3...11).each do |v|
        cmd(Target::Both, 0x09, 0x7F)
        cmd(Target::Both, 0x51, 0x0A, v)
        cmd(Target::Both, 0x09, 0xFF)
        @hal.sleep_ms(2)
      end
      9.downto(2) do |v|
        cmd(Target::Both, 0x09, 0x7F)
        cmd(Target::Both, 0x51, v, 0x0A)
        cmd(Target::Both, 0x09, 0xFF)
        @hal.sleep_ms(2)
      end
      cmd(Target::Both, 0x09, 0xFF)
      @hal.sleep_ms(10)
    end

    def dcdc_soft_shutdown : Nil
      wait_not_busy
      cmd(Target::Both, 0x09, 0x7F)
      cmd(Target::Both, 0x05, 0x7D)
      cmd(Target::Both, 0x09, 0x00)
      @hal.sleep_ms(200)
      wait_not_busy
      pin(Pins::EPD_DC, false)
      pin(Pins::EPD_CS1, false)
      pin(Pins::EPD_RST, false)
      pin(Pins::EPD_CS1, true)
    end

    private def display_refresh : Nil
      wait_not_busy
      cmd(Target::Both, 0x15, 0x3C)
      @hal.sleep_ms(5)
    end

    # ---------------------------------------------------------------- SPI framing

    private def pin(p : Int32, level : Bool) : Nil
      @hal.gpio_write(p, level)
    end

    # Command with up to 8 literal data bytes, built on the stack.
    private def cmd(t : Target, index : Int, *data : Int) : Nil
      buf = StaticArray(UInt8, 8).new(0_u8)
      data.each_with_index { |d, i| buf[i] = d.to_u8 }
      send(t, index.to_u8, buf.to_slice[0, data.size])
    end

    # Index (DC low) then data (DC high), CS framing exactly as lib/epd.py:
    # _send_index_data for Both, upstream _send_one for Left/Right.
    def send(t : Target, index : UInt8, data : Bytes) : Nil
      send_index(t, index)
      @hal.spi_write(data)
      end_data(t)
    end

    private def send_index(t : Target, index : UInt8) : Nil
      idx = index
      one = Slice.new(pointerof(idx), 1)
      if t.both?
        pin(Pins::EPD_DC, false)
        pin(Pins::EPD_CS1, false)
        pin(Pins::EPD_CS2, false)
        @hal.spi_write(one)
        pin(Pins::EPD_CS1, true)
        pin(Pins::EPD_CS2, true)
        pin(Pins::EPD_DC, true)
        pin(Pins::EPD_CS1, false)
        pin(Pins::EPD_CS2, false)
      else
        cs, other = t.left? ? {Pins::EPD_CS1, Pins::EPD_CS2} : {Pins::EPD_CS2, Pins::EPD_CS1}
        pin(Pins::EPD_DC, false)
        pin(cs, false)
        pin(other, true)
        @hal.spi_write(one)
        pin(cs, true)
        pin(Pins::EPD_DC, true)
        pin(cs, false)
      end
    end

    private def end_data(t : Target) : Nil
      case t
      when .both?
        pin(Pins::EPD_CS1, true)
        pin(Pins::EPD_CS2, true)
      when .left?
        pin(Pins::EPD_CS1, true)
      else
        pin(Pins::EPD_CS2, true)
      end
    end

    # Large buffer, streamed in SPI_CHUNK pieces with a yield after each
    # (upstream _send_big). CS stays low throughout.
    private def send_big(t : Target, index : UInt8, buf : Bytes) : Nil
      send_index(t, index)
      i = 0
      while i < buf.size
        n = Math.min(SPI_CHUNK, buf.size - i)
        @hal.spi_write(buf[i, n])
        i += SPI_CHUNK
        @hal.yield_now
      end
      end_data(t)
    end

    # A half plane of one repeated byte (flash frames) without a 40 kB
    # buffer; same bytes on the wire as upstream's solid planes.
    private def send_fill(t : Target, index : UInt8, value : UInt8) : Nil
      send_index(t, index)
      @fill.fill(value)
      fill = @fill.to_slice
      sent = 0
      since_yield = 0
      while sent < HALF_PLANE_SIZE
        n = Math.min(fill.size, HALF_PLANE_SIZE - sent)
        @hal.spi_write(fill[0, n])
        sent += n
        since_yield += n
        if since_yield >= SPI_CHUNK || sent == HALF_PLANE_SIZE
          @hal.yield_now
          since_yield = 0
        end
      end
      end_data(t)
    end
  end
end
