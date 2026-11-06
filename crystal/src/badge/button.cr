module Badge
  # Push button with latched, debounced presses (port of upstream
  # lib/button.py on claude_development).
  #
  # * `pressed?` is true once per press, even if the press was released
  #   before anyone looked (the original lib/button.py dropped such presses).
  # * `down?` is the live state, `held_ms` how long it has been held.
  # * Press edges closer than DEBOUNCE_MS to the last edge are ignored.
  # * `on_falling_edge` is the ISR hook: the real HAL can call it from a GPIO
  #   interrupt so a tap shorter than the scan period still latches.
  #
  # Buttons are active low with internal pull-ups.
  class Button
    DEBOUNCE_MS = 30

    enum State
      Unpressed
      PressedUnread
      PressedRead
    end

    getter pin : Int32
    getter name : String
    getter state = State::Unpressed
    # Debounced-ish level from the last scan (true = pressed).
    getter value = false

    @press_onset_ms : UInt32? = nil
    @last_edge_ms : UInt32

    def initialize(@hal : HAL::Board, @pin : Int32, @name : String)
      @hal.gpio_input(@pin, HAL::Pull::Up)
      @last_edge_ms = @hal.millis
    end

    # Interrupt handler for the falling (press) edge.
    def on_falling_edge : Nil
      latch(@hal.millis)
    end

    # Poll the pin; call every few ms (upstream scans every 5 ms).
    def scan : Nil
      @value = !@hal.gpio_read(@pin)
      now = @hal.millis
      if @value
        latch(now)
      elsif @state.pressed_read?
        # Released after the app saw it. An unread press stays latched.
        @state = State::Unpressed
        @press_onset_ms = nil
        @last_edge_ms = now
      end
    end

    private def latch(now : UInt32) : Nil
      if @state.unpressed? && HAL.ticks_diff(now, @last_edge_ms) > DEBOUNCE_MS
        @state = State::PressedUnread
        @press_onset_ms = now
        @last_edge_ms = now
      end
    end

    # Was the button pressed? True only once per press.
    def pressed? : Bool
      if @state.pressed_unread?
        @state = State::PressedRead
        true
      else
        false
      end
    end

    # Live pin state (true = held down).
    def down? : Bool
      !@hal.gpio_read(@pin)
    end

    # How long the button has been held, 0 when up (as of the last scan).
    def held_ms : Int32
      onset = @press_onset_ms
      return 0 unless @value && onset
      HAL.ticks_diff(@hal.millis, onset)
    end
  end

  # The badge's five buttons. Names follow the firmware; Menu +/- are
  # printed the other way round on the silkscreen.
  class Buttons
    getter menu_minus : Button
    getter menu_plus : Button
    getter user_a : Button
    getter user_b : Button
    getter boot : Button

    SCAN_PERIOD_MS = 5

    def initialize(hal : HAL::Board)
      @menu_minus = Button.new(hal, Pins::MENU_MINUS, "Menu -")
      @menu_plus = Button.new(hal, Pins::MENU_PLUS, "Menu +")
      @user_a = Button.new(hal, Pins::USER_A, "User A")
      @user_b = Button.new(hal, Pins::USER_B, "User B")
      @boot = Button.new(hal, Pins::BOOT, "Boot")
    end

    def each(& : Button ->) : Nil
      yield @menu_minus
      yield @menu_plus
      yield @user_a
      yield @user_b
      yield @boot
    end

    def scan : Nil
      each(&.scan)
    end
  end
end
