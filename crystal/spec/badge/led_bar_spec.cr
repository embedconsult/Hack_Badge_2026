require "../spec_helper"

private alias C = Badge::Color

private def bar
  mock = Badge::HAL::Mock.new
  {mock, Badge::LedBar.new(mock)}
end

# Decode the last GRB frame into scaled RGB tuples.
private def frame(mock) : Array({Int32, Int32, Int32})
  f = mock.last_ws2812
  (0...8).map { |i| {f[3 * i + 1].to_i, f[3 * i].to_i, f[3 * i + 2].to_i} }
end

describe Badge::Color do
  it "has the upstream named colors" do
    C.named?("white").should eq C.new(255, 200, 150)
    C.named?("orange").should eq C.new(255, 70, 0)
    C.named?("off").should eq C::OFF
    C.named?("nope").should be_nil
    C.hex(0xFF8800).should eq C.new(255, 136, 0)
  end

  it "computes the rainbow wheel" do
    C.wheel(0).should eq C.new(255, 0, 0)
    C.wheel(85).should eq C.new(0, 255, 0)
    C.wheel(170).should eq C.new(0, 0, 255)
    C.wheel(256).should eq C.wheel(0)
  end
end

describe Badge::LedBar do
  it "writes GRB bytes on GPIO38, scaled by brightness" do
    mock, leds = bar
    leds.brightness = 255
    leds[0] = C.new(1, 2, 3)
    leds.write
    mock.ws2812_frames.last[0].should eq 38
    mock.last_ws2812.size.should eq 24
    mock.last_ws2812[0, 3].should eq Bytes[2, 1, 3]
  end

  it "scales so non-zero channels never vanish" do
    _mock, leds = bar
    leds.brightness = 24
    leds.scale(C.new(255, 1, 0)).should eq C.new(24, 1, 0)
    leds.scale(C.new(0, 1, 1)).should eq C.new(0, 1, 1) # old tiny colors still light
    leds.scale(C.new(128, 0, 0)).should eq C.new(12, 0, 0)
  end

  it "fills and clears" do
    mock, leds = bar
    leds.brightness = 255
    leds.fill(C::GREEN)
    frame(mock).should eq [{0, 255, 0}] * 8
    leds.clear
    frame(mock).should eq [{0, 0, 0}] * 8
  end

  it "shows the menu: page color for apps on the page, selected white" do
    mock, leds = bar
    leds.brightness = 255
    leds.menu_display(2, 5)
    leds.paused?.should be_true
    (0...8).map { |i| leds[i] }.should eq [
      C::ORANGE, C::ORANGE, C::WHITE, C::ORANGE, C::ORANGE, C::OFF, C::OFF, C::OFF,
    ]
    frame(mock)[2].should eq({255, 200, 150})
  end

  it "fills a full page and uses the next page color" do
    _mock, leds = bar
    leds.menu_display(9, 20) # page 1, slot 1; page full
    (0...8).map { |i| leds[i] }.should eq [C::CYAN, C::WHITE] + [C::CYAN] * 6
    leds.menu_display(17, 20) # page 2 holds apps 16..19
    (0...8).map { |i| leds[i] }.should eq [C::MAGENTA, C::WHITE, C::MAGENTA, C::MAGENTA] + [C::OFF] * 4
  end

  it "wraps menu page colors instead of overflowing (original had 6 colors)" do
    _mock, leds = bar
    leds.menu_display(70, 72) # page 8 -> color 0
    leds[0].should eq C::ORANGE
  end

  it "shows a single submenu LED colored by page" do
    _mock, leds = bar
    leds.submenu_display(11)
    (0...8).map { |i| leds[i] }.should eq [C::OFF] * 3 + [C::CYAN] + [C::OFF] * 4
  end

  it "shows bits MSB first and progress bars" do
    _mock, leds = bar
    leds.bits(0b10110010, C::RED)
    (0...8).map { |i| leds[i] == C::RED }.should eq [true, false, true, true, false, false, true, false]
    leds.progress(6, 10)
    (0...8).count { |i| leds[i] == C::GREEN }.should eq 5 # 0.6 * 8 = 4.8 -> 5
  end

  it "runs a blink sequence through tick and then stops" do
    mock, leds = bar
    leds.blink(C::RED, times: 2, on_ms: 100, off_ms: 50)
    seen = [] of Badge::Color
    80.times do
      before = mock.ws2812_frames.size
      leds.tick
      seen << leds[0] if mock.ws2812_frames.size > before
      mock.sleep_ms(Badge::LedBar::TICK_MS)
    end
    seen.should eq [C::RED, C::OFF, C::RED, C::OFF]
    leds.effect.none?.should be_true
  end

  it "re-sends the frame every 500 ms when idle" do
    mock, leds = bar
    leds.fill(C::BLUE)
    n = mock.ws2812_frames.size
    leds.tick
    mock.ws2812_frames.size.should eq n
    mock.sleep_ms(501)
    leds.tick
    mock.ws2812_frames.size.should eq n + 1
  end

  it "does not advance a paused effect, and clear_sequence unpauses" do
    mock, leds = bar
    leds.chase(C::ORANGE, ms: 10, tail: 3)
    leds.tick
    leds[0].should eq C::ORANGE
    leds[7].should eq C.new(170, 46, 0) # 2/3 tail, wrapped
    leds.pause
    mock.sleep_ms(20)
    leds.tick
    leds[1].should eq C::OFF
    leds.clear_sequence
    leds.paused?.should be_false
  end

  it "runs custom sequences" do
    mock, leds = bar
    leds.set_sequence(->(step : Int32, buf : Slice(Badge::Color)) do
      return -1 if step >= 2
      buf[step] = C::PINK
      20
    end)
    3.times do
      leds.tick
      mock.sleep_ms(20)
    end
    leds[0].should eq C::PINK
    leds[1].should eq C::PINK
    leds.effect.none?.should be_true
  end

  it "pulses with a squared ramp" do
    _mock, leds = bar
    leds.pulse(C.new(200, 0, 0), period_ms: 600, steps: 10)
    leds.tick
    leds[0].should eq C::OFF # k = 0
  end
end
