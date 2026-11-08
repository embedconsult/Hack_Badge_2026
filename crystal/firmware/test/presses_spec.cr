require "spec"
require "./shim"

# Models the badge: the knob task polls the buttons every 15 ms (latching
# what it sees, as Shared.set_knobs does, and counting presses), and the main
# task ticks, then may block for a refresh. `timeline` is the + button level
# per 15 ms poll; `busy` is the number of polls a tick that sees a press
# blocks for (a Home selection move: ~0.65 s = about 43 polls).
private def run_badge(timeline : Array(Bool), busy : Int32, counted : Bool) : Int32
  presses = 0_u32
  seen = 0_u32
  latched = 0_u32
  prev_poll = 0_u32
  prev = 0_u32
  moves = 0
  blocked = 0
  timeline.each do |down|
    btns = down ? Games::BTN_PLUS : 0_u32
    presses = Games.count_presses(presses, btns, prev_poll)
    prev_poll = btns
    latched |= btns
    if blocked > 0
      blocked -= 1
      next
    end
    held = latched | btns # Shared.take_buttons
    latched = 0_u32
    inp = Games.input(0, 0, held, prev)
    inp.pressed = Games.next_presses(presses, pointerof(seen)) if counted
    prev = held
    if Games.pressed?(inp, Games::BTN_PLUS)
      moves += 1
      blocked = busy
    end
  end
  moves
end

# n quick clicks: 5 polls (75 ms) down, 5 up.
private def clicks(n : Int32, idle_after = 200) : Array(Bool)
  t = [] of Bool
  n.times { 5.times { t << true }; 5.times { t << false } }
  idle_after.times { t << false }
  t
end

describe "button presses during a refresh" do
  it "loses the second of two quick clicks with edge detection on the main task alone" do
    run_badge(clicks(2), 43, false).should eq 1
  end

  it "delivers every click when the knob task counts presses" do
    run_badge(clicks(2), 43, true).should eq 2
    run_badge(clicks(5), 43, true).should eq 5
  end

  it "counts a press held across a refresh once" do
    t = [true] * 100 + [false] * 100
    run_badge(t, 43, true).should eq 1
  end

  it "wraps each button's count inside its own byte" do
    c = 0xFF_u32 # A at 255
    c = Games.count_presses(c, Games::BTN_A, 0_u32)
    c.should eq 0_u32 # B's byte untouched
    seen = 0xFF_u32
    Games.next_presses(c, pointerof(seen)).should eq Games::BTN_A
    seen.should eq 0_u32
    Games.next_presses(c, pointerof(seen)).should eq 0_u32
  end

  it "hands out one press per button per tick, other buttons alongside" do
    c = 0_u32
    2.times { c = Games.count_presses(c, Games::BTN_MINUS | Games::BTN_B, 0_u32) }
    seen = 0_u32
    Games.next_presses(c, pointerof(seen)).should eq(Games::BTN_MINUS | Games::BTN_B)
    Games.next_presses(c, pointerof(seen)).should eq(Games::BTN_MINUS | Games::BTN_B)
    Games.next_presses(c, pointerof(seen)).should eq 0_u32
  end
end
