module Badge
  # An unscaled RGB color, 0..255 per channel.
  record Color, r : UInt8, g : UInt8, b : UInt8 do
    def self.rgb(r : Int, g : Int, b : Int) : Color
      new(r.clamp(0, 255).to_u8, g.clamp(0, 255).to_u8, b.clamp(0, 255).to_u8)
    end

    # 0xRRGGBB
    def self.hex(c : Int) : Color
      new(((c >> 16) & 0xFF).to_u8, ((c >> 8) & 0xFF).to_u8, (c & 0xFF).to_u8)
    end

    # Each channel times num/den (num <= den), truncated like Python's int().
    def scale(num : Int32, den : Int32) : Color
      Color.new((r.to_i32 * num // den).to_u8, (g.to_i32 * num // den).to_u8, (b.to_i32 * num // den).to_u8)
    end

    def off? : Bool
      r == 0 && g == 0 && b == 0
    end

    # Named colors from upstream lib/led_bar.py COLORS.
    OFF     = new(0, 0, 0)
    BLACK   = OFF
    WHITE   = new(255, 200, 150) # warm white looks more neutral on WS2812
    RED     = new(255, 0, 0)
    GREEN   = new(0, 255, 0)
    BLUE    = new(0, 0, 255)
    YELLOW  = new(255, 160, 0)
    ORANGE  = new(255, 70, 0)
    CYAN    = new(0, 255, 255)
    MAGENTA = new(255, 0, 255)
    PURPLE  = new(140, 0, 255)
    PINK    = new(255, 40, 90)

    # Name lookup (case-sensitive lower case, as stored in upstream COLORS).
    def self.named?(name : String) : Color?
      case name
      when "off", "black" then OFF
      when "white"        then WHITE
      when "red"          then RED
      when "green"        then GREEN
      when "blue"         then BLUE
      when "yellow"       then YELLOW
      when "orange"       then ORANGE
      when "cyan"         then CYAN
      when "magenta"      then MAGENTA
      when "purple"       then PURPLE
      when "pink"         then PINK
      end
    end

    # 0..255 -> rainbow color (upstream wheel()).
    def self.wheel(pos : Int32) : Color
      pos &= 0xFF
      if pos < 85
        rgb(255 - pos * 3, pos * 3, 0)
      elsif pos < 170
        pos -= 85
        rgb(0, 255 - pos * 3, pos * 3)
      else
        pos -= 170
        rgb(pos * 3, 0, 255 - pos * 3)
      end
    end
  end

  # 8x WS2812 bar on GPIO38 (port of upstream lib/led_bar.py).
  #
  # Colors are buffered unscaled and scaled by `brightness` on write; a
  # non-zero channel never scales below 1, so old tiny values like
  # (0, 1, 1) still light up. Built-in effects and custom sequences are
  # advanced by `tick`, which also re-sends the frame every REFRESH_MS to heal
  # a glitched LED (upstream's reliability fix).
  class LedBar
    N                  = Pins::NUM_LEDS
    DEFAULT_BRIGHTNESS =  24 # out of 255; the LEDs are very bright
    REFRESH_MS         = 500
    TICK_MS            =   5

    MENU_BACKGROUND_COLORS = StaticArray[Color::ORANGE, Color::CYAN, Color::MAGENTA, Color::RED,
      Color::GREEN, Color::BLUE, Color::PURPLE, Color::YELLOW]
    MENU_SELECTED_COLOR     = Color::WHITE
    SUBMENU_SELECTED_COLORS = MENU_BACKGROUND_COLORS

    enum Effect
      None
      Blink
      Pulse
      Chase
      Rainbow
      Custom
    end

    # Custom sequence: called with the step number and the 8-LED buffer to
    # fill; returns the delay in ms before the next step, or < 0 to stop.
    alias Sequence = Proc(Int32, Slice(Color), Int32)

    property brightness : Int32 = DEFAULT_BRIGHTNESS
    getter effect = Effect::None
    getter? paused = false

    @buf = StaticArray(Color, 8).new(Color::OFF)
    @grb = StaticArray(UInt8, 24).new(0_u8)
    @last_write_ms : UInt32 = 0_u32
    @next_ms : UInt32 = 0_u32
    @step : Int32 = 0
    @fx_color : Color = Color::OFF
    @fx_a : Int32 = 0 # times / period / tail
    @fx_b : Int32 = 0 # on_ms / steps / ms
    @fx_c : Int32 = 0 # off_ms
    @custom : Sequence? = nil

    def initialize(@hal : HAL::Board, @pin : Int32 = Pins::WS2812)
    end

    def size : Int32
      N
    end

    def [](i : Int) : Color
      @buf[i]
    end

    # Buffer one LED (does not write).
    def []=(i : Int, c : Color) : Color
      @buf[i] = c
    end

    def colors : Slice(Color)
      @buf.to_slice
    end

    # Scale for the current brightness.
    def scale(c : Color) : Color
      Color.new(scale_channel(c.r), scale_channel(c.g), scale_channel(c.b))
    end

    private def scale_channel(v : UInt8) : UInt8
      return 0_u8 if v == 0
      s = (v.to_i32 * @brightness + 127) // 255
      s > 0 ? s.to_u8 : 1_u8
    end

    # Send the buffered colors to the LEDs (GRB wire order).
    def write : Nil
      N.times do |i|
        c = scale(@buf[i])
        @grb[3 * i] = c.g
        @grb[3 * i + 1] = c.r
        @grb[3 * i + 2] = c.b
      end
      @hal.ws2812_write(@pin, @grb.to_slice)
      @last_write_ms = @hal.millis
    end

    # Buffer a list of colors (extra entries ignored); does not write.
    def set(values : Indexable(Color)) : Nil
      values.each_with_index do |c, i|
        break if i >= N
        @buf[i] = c
      end
    end

    def show(values : Indexable(Color)) : Nil
      set(values)
      write
    end

    def fill(c : Color) : Nil
      N.times { |i| @buf[i] = c }
      write
    end

    def clear : Nil
      fill(Color::OFF)
    end

    def off : Nil
      fill(Color::OFF)
    end

    def set_pixel(i : Int32, c : Color, write now : Bool = true) : Nil
      @buf[i % N] = c
      write if now
    end

    # Bar graph: `num`/`den` of the bar lit (rounded). Stops any effect.
    def progress(num : Int32, den : Int32, color : Color = Color::GREEN, background : Color = Color::OFF) : Nil
      clear_sequence
      lit = den <= 0 ? 0 : ((num.clamp(0, den) * N * 2 + den) // (2 * den))
      N.times { |i| @buf[i] = i < lit ? color : background }
      write
    end

    # Show an 8-bit number, MSB on LED 0. Stops any effect.
    def bits(x : Int32, color : Color = Color::WHITE) : Nil
      clear_sequence
      N.times { |i| @buf[i] = ((x >> (N - 1 - i)) & 1) == 1 ? color : Color::OFF }
      write
    end

    # ---------------- menu helpers (used by the app switcher) ------------

    # One LED per app on the current page in the page color, the selected
    # app in white. Pages wrap through the 8 page colors.
    def menu_display(app_index : Int32, total_apps : Int32) : Nil
      pause
      page = app_index // N
      sel = app_index % N
      bg = MENU_BACKGROUND_COLORS[page % MENU_BACKGROUND_COLORS.size]
      on_page = Math.min(N, total_apps - page * N)
      N.times { |i| @buf[i] = i < on_page ? bg : Color::OFF }
      @buf[sel] = MENU_SELECTED_COLOR
      write
    end

    # A single LED in submenus, colored by page.
    def submenu_display(item_index : Int32) : Nil
      pause
      N.times { |i| @buf[i] = Color::OFF }
      @buf[item_index % N] = SUBMENU_SELECTED_COLORS[(item_index // N) % SUBMENU_SELECTED_COLORS.size]
      write
    end

    # ---------------- sequencer ----------------

    def pause : Nil
      @paused = true
    end

    def unpause : Nil
      @paused = false
    end

    def toggle_pause : Nil
      @paused = !@paused
    end

    def clear_sequence : Nil
      @effect = Effect::None
      @custom = nil
      @paused = false
    end

    def stop : Nil
      clear_sequence
    end

    def set_sequence(seq : Sequence) : Nil
      @custom = seq
      start(Effect::Custom)
    end

    def blink(color : Color = Color::WHITE, times : Int32 = 3, on_ms : Int32 = 150, off_ms : Int32 = 150) : Nil
      @fx_color = color
      @fx_a = times
      @fx_b = on_ms
      @fx_c = off_ms
      start(Effect::Blink)
    end

    def pulse(color : Color = Color::CYAN, period_ms : Int32 = 1500, steps : Int32 = 30) : Nil
      @fx_color = color
      @fx_a = period_ms
      @fx_b = steps
      start(Effect::Pulse)
    end

    def chase(color : Color = Color::ORANGE, ms : Int32 = 80, tail : Int32 = 3) : Nil
      @fx_color = color
      @fx_a = tail
      @fx_b = ms
      start(Effect::Chase)
    end

    def rainbow(ms : Int32 = 40) : Nil
      @fx_b = ms
      start(Effect::Rainbow)
    end

    private def start(e : Effect) : Nil
      @effect = e
      @step = 0
      @paused = false
      @next_ms = @hal.millis
    end

    # Advance the running effect if it is due, otherwise re-send the frame
    # every REFRESH_MS. Call every TICK_MS from the LED task.
    def tick : Nil
      now = @hal.millis
      if !@effect.none? && !@paused && HAL.ticks_diff(now, @next_ms) >= 0
        delay = render_step(@step)
        if delay < 0
          @effect = Effect::None
          @custom = nil
        else
          @step += 1
          write
          @next_ms = now &+ Math.max(1, delay).to_u32
        end
      elsif HAL.ticks_diff(now, @last_write_ms) > REFRESH_MS
        write
      end
    end

    # Fill @buf for step `i` of the current effect; returns delay or -1 = done.
    private def render_step(i : Int32) : Int32
      case @effect
      when .blink?
        return -1 if i >= 2 * @fx_a
        on = i.even?
        N.times { |k| @buf[k] = on ? @fx_color : Color::OFF }
        on ? @fx_b : @fx_c
      when .pulse?
        steps = Math.max(1, @fx_b)
        j = i % (2 * steps)
        k = j < steps ? j : 2 * steps - j
        c = @fx_color.scale(k * k, steps * steps) # f = (k/steps)^2
        N.times { |n| @buf[n] = c }
        Math.max(10, @fx_a // (2 * steps))
      when .chase?
        tail = Math.max(1, @fx_a)
        N.times { |n| @buf[n] = Color::OFF }
        tail.times { |t| @buf[(i - t) % N] = @fx_color.scale(tail - t, tail) }
        @fx_b
      when .rainbow?
        base = (i * 3) & 0xFF
        N.times { |n| @buf[n] = Color.wheel(base + n * 256 // N) }
        @fx_b
      when .custom?
        if seq = @custom
          seq.call(i, @buf.to_slice)
        else
          -1
        end
      else
        -1
      end
    end
  end
end
