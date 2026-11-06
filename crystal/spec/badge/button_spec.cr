require "../spec_helper"

private def setup
  mock = Badge::HAL::Mock.new
  mock.now = 1000_u32
  btn = Badge::Button.new(mock, Badge::Pins::USER_A, "User A")
  {mock, btn}
end

private def press(mock, btn, down : Bool, after_ms = 5)
  mock.sleep_ms(after_ms)
  mock.set_input(btn.pin, !down) # active low
  btn.scan
end

describe Badge::Button do
  it "configures an input with pull-up" do
    mock, _btn = setup
    mock.pulls[Badge::Pins::USER_A].should eq Badge::HAL::Pull::Up
  end

  it "reports a press exactly once" do
    mock, btn = setup
    press(mock, btn, true, 50)
    btn.pressed?.should be_true
    btn.pressed?.should be_false
    press(mock, btn, true)
    btn.pressed?.should be_false # still the same press
    btn.down?.should be_true
  end

  it "keeps a press that was released before it was read" do
    mock, btn = setup
    press(mock, btn, true, 50)
    press(mock, btn, false)
    press(mock, btn, false)
    btn.state.pressed_unread?.should be_true
    btn.pressed?.should be_true
    press(mock, btn, false)
    btn.state.unpressed?.should be_true
  end

  it "debounces bounces after a release" do
    mock, btn = setup
    press(mock, btn, true, 50)
    btn.pressed?.should be_true
    press(mock, btn, false, 5) # released (edge at t)
    press(mock, btn, true, 5)  # bounce 5 ms later
    press(mock, btn, false, 5)
    press(mock, btn, true, 10) # 20 ms after release
    btn.pressed?.should be_false
    press(mock, btn, true, 15) # 35 ms after release, still held -> new press
    btn.pressed?.should be_true
  end

  it "ignores a press within DEBOUNCE_MS of boot" do
    mock, btn = setup
    press(mock, btn, true, 10)
    btn.pressed?.should be_false
  end

  it "tracks held time" do
    mock, btn = setup
    btn.held_ms.should eq 0
    press(mock, btn, true, 50)
    mock.sleep_ms(400)
    btn.held_ms.should eq 400
    btn.pressed?
    press(mock, btn, false)
    btn.held_ms.should eq 0
  end

  it "latches from the edge interrupt hook between scans" do
    mock, btn = setup
    mock.sleep_ms(100)
    btn.on_falling_edge # tap shorter than a scan period
    btn.scan            # pin already back up
    btn.pressed?.should be_true
  end

  it "handles the millisecond counter wrapping" do
    mock = Badge::HAL::Mock.new
    mock.now = UInt32::MAX - 10
    btn = Badge::Button.new(mock, 39, "x")
    press(mock, btn, true, 40)
    mock.now.should be < 100
    btn.pressed?.should be_true
    mock.sleep_ms(20)
    btn.held_ms.should eq 20
  end
end

describe Badge::Buttons do
  it "maps the five buttons (menu +/- per firmware, not silkscreen)" do
    mock = Badge::HAL::Mock.new
    b = Badge::Buttons.new(mock)
    b.menu_minus.pin.should eq 40
    b.menu_plus.pin.should eq 15
    b.user_a.pin.should eq 39
    b.user_b.pin.should eq 16
    b.boot.pin.should eq 0
    mock.sleep_ms(100)
    mock.set_input(15, false)
    b.scan
    b.menu_plus.pressed?.should be_true
    b.menu_minus.pressed?.should be_false
  end
end
