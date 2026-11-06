require "spec"
require "./shim"

def inp(left_pos = 0, right_pos = 0, held = 0_u32, prev = 0_u32)
  Games.input(Games.mv_for(left_pos, Games::LEFT_MV_LO, Games::LEFT_MV_HI),
    Games.mv_for(right_pos, Games::RIGHT_MV_LO, Games::RIGHT_MV_HI), held, prev)
end

def press(btn, left_pos = 0, right_pos = 0)
  inp(left_pos, right_pos, btn, 0_u32)
end

def plane
  Pointer(UInt8).malloc(Games::PLANE)
end

def count_bits(p)
  n = 0
  Games::PLANE.times { |i| n += p[i].popcount }
  n
end

def life_clear
  Life.init(20)
  Life.clear
end

def life_cells
  cells = [] of {Int32, Int32}
  Life.rows.times { |y| Life.cols.times { |x| cells << {x, y} if Life.alive?(x, y) } }
  cells
end

describe "Games helpers" do
  it "clamps knobs to 0..4096" do
    Games.knob(0, 769, 2963).should eq 0
    Games.knob(5000, 769, 2963).should eq 4096
    Games.knob(1866, 769, 2963).should eq 2048
  end

  it "computes pressed edges" do
    i = Games.input(1000, 1000, 0b0101_u32, 0b0001_u32)
    i.pressed.should eq 0b0100_u32
  end

  it "fill_rect sets exactly the rect" do
    p = plane
    Games.fill_rect(p, 5, 7, 11, 3)
    count_bits(p).should eq 33
    Games.get(p, 5, 7).should be_true
    Games.get(p, 15, 9).should be_true
    Games.get(p, 4, 7).should be_false
    Games.get(p, 16, 7).should be_false
    Games.get(p, 5, 10).should be_false
    p[7 * 120].should eq 0b0000_0111_u8 # x = 5..7, MSB first
    p[7 * 120 + 1].should eq 0xFF_u8    # x = 8..15
  end

  it "clips at the edges" do
    p = plane
    Games.fill_rect(p, 955, 668, 20, 20)
    count_bits(p).should eq 5 * 4
  end
end

describe Life do
  it "uses a 48x33 grid at 20 px" do
    Life.init(20).should be_true
    Life.cols.should eq 48
    Life.rows.should eq 33
  end

  it "moves a glider by (1,1) in 4 generations, wrapping the torus" do
    life_clear
    glider = [{1, 0}, {2, 1}, {0, 2}, {1, 2}, {2, 2}]
    ox, oy = 46, 31 # straddles the right/bottom edges
    glider.each { |(x, y)| Life.set_cell((x + ox) % 48, (y + oy) % 33, true) }
    4.times do
      Life.step
      Life.changed?.should be_true
      Life.population.should eq 5
    end
    expected = glider.map { |(x, y)| {(x + ox + 1) % 48, (y + oy + 1) % 33} }.sort
    life_cells.sort.should eq expected
  end

  it "detects a blinker as period 2 and a block as static" do
    life_clear
    3.times { |i| Life.set_cell(10 + i, 10, true) }
    Life.step
    Life.changed?.should be_true
    life_cells.sort.should eq [{11, 9}, {11, 10}, {11, 11}]
    Life.step
    Life.period2?.should be_true
    Life.static?.should be_false
    Life.changed?.should be_false
    Life.stable_count.should eq 1

    life_clear
    [{3, 3}, {4, 3}, {3, 4}, {4, 4}].each { |(x, y)| Life.set_cell(x, y, true) }
    Life.step
    Life.static?.should be_true
    Life.changed?.should be_false
  end

  it "reseeds after STABLE_RESEED stable generations" do
    life_clear
    3.times { |i| Life.set_cell(10 + i, 10, true) }
    i0 = inp
    t = 1000
    Life.tick(t, i0) # sync
    results = (1..Life::STABLE_RESEED + 1).map { t += 250; Life.tick(t, i0) }
    results[0].should be_true                    # first step changes
    results[1...Life::STABLE_RESEED].all? { |r| !r }.should be_true
    results.last.should be_true                  # reseeded
    Life.gen.should eq 0
    Life.population.should be > 50
  end

  it "seeds with density from the left knob" do
    Life.init(20)
    Life.tick(0, press(Games::BTN_A, 0))
    lo = Life.population
    Life.tick(10, press(Games::BTN_A, 4096))
    hi = Life.population
    hi.should be > lo * 4
  end

  it "renders cells as squares with a 2 px gap" do
    life_clear
    Life.set_cell(0, 0, true)
    b, r = plane, plane
    r[0] = 0xFF_u8
    Life.render(b, r)
    count_bits(r).should eq 0
    count_bits(b).should eq 18 * 18
    y0 = 6 # (672 - 33*20) / 2
    Games.get(b, 1, y0 + 1).should be_true
    Games.get(b, 18, y0 + 18).should be_true
    Games.get(b, 0, y0 + 1).should be_false
    Games.get(b, 19, y0 + 18).should be_false
    Games.get(b, 1, y0).should be_false
  end
end

describe Snake do
  it "grows on food and dies on self-hit" do
    Snake.init(true).should be_true
    Snake.length.should eq 4
    h = Snake.head
    (h % 40).should eq 19
    Snake.set_food(h + 1)
    Snake.step.should be_true
    Snake.length.should eq 5
    Snake.score.should eq 1
    Snake.food.should_not eq h + 1
    Snake.occupied?(Snake.food).should be_false
    Snake.set_food(0)
    Snake.turn_right # down
    Snake.step.should be_true
    Snake.turn_right # left
    Snake.step.should be_true
    Snake.turn_right # up, into its own body
    Snake.step.should be_false
    Snake.over?.should be_true
    Snake.length.should eq 5
  end

  it "may chase its own tail" do
    Snake.init(true)
    Snake.set_food(0)
    Snake.turn_right; Snake.step.should be_true # 4 segments in a 2x2 loop
    Snake.turn_right; Snake.step.should be_true
    Snake.turn_right; Snake.step.should be_true
    Snake.over?.should be_false
  end

  it "wraps or hits walls" do
    Snake.init(false)
    Snake.set_food(-1)
    20.times { Snake.step.should be_true }
    Snake.step.should be_false
    Snake.over?.should be_true

    Snake.init(true)
    Snake.set_food(-1)
    21.times { Snake.step.should be_true }
    Snake.head.should eq 14 * 40
  end

  it "rejects reversing and restarts after game over via a button" do
    Snake.init(false)
    Snake.set_dir(Snake::LEFT)
    Snake.dir.should eq Snake::RIGHT
    Snake.set_dir(Snake::UP)
    Snake.dir.should eq Snake::UP
    Snake.set_food(-1)
    20.times { Snake.step }
    Snake.over?.should be_true
    Snake.tick(0, inp).should be_false
    Snake.tick(10, press(Games::BTN_A)).should be_true
    Snake.over?.should be_false
    Snake.score.should eq 0
  end

  it "takes an absolute direction from the knob quadrant" do
    Snake.init(true)
    Snake.tick(0, inp(1536))    # quadrant 1 (right), just records
    Snake.dir.should eq Snake::RIGHT
    Snake.tick(10, inp(2560))   # quadrant 2 -> down
    Snake.dir.should eq Snake::DOWN
    Snake.tick(20, inp(3080))   # barely into quadrant 3: hysteresis
    Snake.dir.should eq Snake::DOWN
    Snake.tick(30, inp(3600))   # left
    Snake.dir.should eq Snake::LEFT
  end

  it "renders body filled and food hollow" do
    Snake.init(true)
    Snake.set_food(0)
    b, r = plane, plane
    Snake.render(b, r)
    h = Snake.head
    hx, hy = (h % 40) * 24, (h // 40) * 24
    Games.get(b, hx + 12, hy + 12).should be_true
    Games.get(b, hx, hy).should be_false
    Games.get(b, 3, 3).should be_true    # food outline
    Games.get(b, 12, 12).should be_false # hollow
    count_bits(b).should eq 4 * 22 * 22 + (18 * 18 - 12 * 12)
    count_bits(r).should eq 0
  end
end

describe Sketch do
  it "applies deadband and wrap to knob deltas" do
    Sketch.knob_delta(1000, 1010).should eq 0
    Sketch.knob_delta(1000, 981).should eq 0
    Sketch.knob_delta(1000, 1030).should eq 30
    Sketch.knob_delta(4000, 50).should eq 146
    Sketch.knob_delta(50, 4000).should eq -146
  end

  it "draws Bresenham lines including both endpoints" do
    p = plane
    Sketch.line(p, 10, 20, 50, 35, 1)
    Games.get(p, 10, 20).should be_true
    Games.get(p, 50, 35).should be_true
    count_bits(p).should eq 41 # one pixel per x step
    Games.get(p, 9, 20).should be_false
    Games.get(p, 51, 35).should be_false

    p = plane
    Sketch.line(p, 100, 100, 100, 90, 3)
    count_bits(p).should eq 3 * 13
    Games.get(p, 99, 89).should be_true
    Games.get(p, 101, 101).should be_true
    Games.get(p, 102, 100).should be_false
  end

  it "moves the pen from knob deltas and refreshes after a pause" do
    Sketch.init.should be_true
    Sketch.tick(0, inp(1000, 2000)).should be_false # sync
    Sketch.tick(400, inp(1000, 2000)).should be_true # initial show
    Sketch.tick(500, inp(2024, 2000)).should be_false
    (Sketch.x - 480).should be_close(60, 1)
    Sketch.y.should eq 336
    Sketch.tick(600, inp(2024, 3024)).should be_false # clockwise = up
    (336 - Sketch.y).should be_close(60, 1)
    Sketch.tick(800, inp(2024, 3024)).should be_false # < 300 ms pause
    Sketch.tick(950, inp(2024, 3024)).should be_true
    Sketch.tick(2000, inp(2024, 3024)).should be_false # nothing new
    x = Sketch.x
    Sketch.tick(2010, inp(2034, 3024)).should be_false # within deadband
    Sketch.x.should eq x
    Games.get(Sketch.canvas, 480, 336).should be_true
    Games.get(Sketch.canvas, Sketch.x, Sketch.y).should be_true
  end

  it "refreshes at most every MAX_MS while drawing, erases on User A" do
    Sketch.init
    t = 0
    Sketch.tick(t, inp(0, 2000))
    pos = 0
    refreshes = 0
    40.times do
      t += 100
      pos += 40
      refreshes += 1 if Sketch.tick(t, inp(pos, 2000))
    end
    refreshes.should eq 1 # at t = 3000
    Sketch.tick(t + 10, press(Games::BTN_A, pos, 2000)).should be_true
    count_bits(Sketch.canvas).should eq 0
  end

  it "renders canvas plus cursor into black, clears red" do
    Sketch.init
    Games.set(Sketch.canvas, 5, 5)
    b, r = plane, plane
    r[100] = 1_u8
    Sketch.render(b, r)
    Games.get(b, 5, 5).should be_true
    count_bits(r).should eq 0
    count_bits(b).should eq 1 + 48 # 13x13 one-pixel outline
  end
end

describe Menu do
  it "cycles modes with Menu +/- and dispatches" do
    Menu.init
    Menu.mode.should eq Menu::NAMETAG
    Menu.full_color?.should be_true
    b, r = plane, plane
    Menu.render(b, r).should be_false
    Menu.tick(0, press(Games::BTN_PLUS)).should be_true
    Menu.mode.should eq Menu::SKETCH
    Menu.tick(0, press(Games::BTN_PLUS))
    Menu.mode.should eq Menu::LIFE
    Menu.render(b, r).should be_true
    Menu.tick(0, press(Games::BTN_PLUS))
    Menu.mode.should eq Menu::SNAKE
    Menu.tick(0, press(Games::BTN_PLUS))
    Menu.mode.should eq Menu::NAMETAG
    Menu.tick(0, press(Games::BTN_MINUS))
    Menu.mode.should eq Menu::SNAKE
    Menu.ok?.should be_true
    Menu.full_color?.should be_false
  end
end
