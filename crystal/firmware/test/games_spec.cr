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
    Games.knob(0, 694, 2963).should eq 0
    Games.knob(5000, 694, 2963).should eq 4096
    Games.knob(1828, 694, 2963).should eq 2047
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
    i0 = inp(0, 1200) # one generation per refresh
    t = 1000
    Life.tick(t, i0) # sync
    results = (1..Life::STABLE_RESEED + 1).map { t += Life::MAX_INTERVAL; Life.tick(t, i0) }
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

  it "reports exactly the flipped cells of a glider step as the dirty box" do
    life_clear
    glider = [{1, 0}, {2, 1}, {0, 2}, {1, 2}, {2, 2}]
    glider.each { |(x, y)| Life.set_cell(x + 20, y + 10, true) }
    Life.flush # panel now shows the seeded board (full refresh)
    x0 = y0 = x1 = y1 = 0
    Life.dirty_box(pointerof(x0), pointerof(y0), pointerof(x1), pointerof(y1)).should be_false
    before = life_cells
    Life.step
    Life.flush
    flipped = (before - life_cells) + (life_cells - before)
    flipped.size.should be > 0
    Life.dirty_box(pointerof(x0), pointerof(y0), pointerof(x1), pointerof(y1)).should be_true
    cx0, cx1 = flipped.min_of(&.[0]), flipped.max_of(&.[0])
    cy0, cy1 = flipped.min_of(&.[1]), flipped.max_of(&.[1])
    {x0, y0, x1, y1}.should eq({cx0 * 20, 6 + cy0 * 20, (cx1 + 1) * 20 - 1, 6 + (cy1 + 1) * 20 - 1})
    r = Pointer(Int32).malloc(16)
    Life.dirty_rects(r, 4).should eq 1 # all in band 1 (cols 12..23)
    {r[0], r[1], r[2], r[3]}.should eq({x0, y0, x1, y1})
  end

  it "splits flips into vertical bands and merges down to max" do
    life_clear
    Life.flush
    3.times { |i| Life.set_cell(2 + i, 5, true) }   # blinker, band 0
    3.times { |i| Life.set_cell(40 + i, 20, true) } # blinker, band 3
    Life.step
    Life.flush
    r = Pointer(Int32).malloc(16)
    Life.dirty_rects(r, 4).should eq 2
    {r[0], r[1], r[2], r[3]}.should eq({40, 6 + 4 * 20, 100 - 1, 6 + 7 * 20 - 1})
    {r[4], r[5], r[6], r[7]}.should eq({800, 6 + 19 * 20, 860 - 1, 6 + 22 * 20 - 1})
    Life.dirty_rects(r, 1).should eq 1
    {r[0], r[1], r[2], r[3]}.should eq({40, 6 + 4 * 20, 860 - 1, 6 + 22 * 20 - 1})
    # a blinker's two phases cancel: nothing to refresh after 2 generations
    Life.step; Life.step
    Life.pending?.should be_false
  end

  it "runs several generations per refresh at the fast end of the right knob" do
    Life.gens_for(0).should eq Life::MAX_GENS
    Life.gens_for(Life::FAST_ZONE - 1).should eq 1
    Life.gens_for(4096).should eq 1
    Life.interval_for(Life::FAST_ZONE).should eq Life::MIN_INTERVAL
    Life.interval_for(4096).should eq Life::MAX_INTERVAL
    life_clear
    glider = [{1, 0}, {2, 1}, {0, 2}, {1, 2}, {2, 2}]
    glider.each { |(x, y)| Life.set_cell(x + 20, y + 10, true) }
    Life.tick(0, inp(0, 0)) # sync
    Life.tick(Life::MIN_INTERVAL, inp(0, 0)).should be_true
    Life.gens_per_frame.should eq 4
    Life.gen.should eq 4
    life_cells.sort.should eq glider.map { |(x, y)| {x + 21, y + 11} }.sort
  end

  it "reseed forces a full refresh" do
    Life.init(20)
    Life.tick(0, press(Games::BTN_A)).should be_true
    x0 = y0 = x1 = y1 = 0
    Life.dirty_box(pointerof(x0), pointerof(y0), pointerof(x1), pointerof(y1)).should be_false
    Life.dirty_rects(Pointer(Int32).malloc(16), 4).should eq 0
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

  it "reports the new head and vacated tail cells per step" do
    Snake.init(true)
    Snake.resync
    Snake.set_food(0)
    Snake.tick(0, inp(1536, 0)) # sync (right knob 0 = slowest)
    tail = Snake.segment(Snake.length - 1)
    Snake.tick(Snake::MAX_INTERVAL, inp(1536, 0)).should be_true
    h = Snake.head
    x0 = y0 = x1 = y1 = 0
    Snake.dirty_box(pointerof(x0), pointerof(y0), pointerof(x1), pointerof(y1)).should be_true
    tx, ty, hx, hy = (tail % 40) * 24, (tail // 40) * 24, (h % 40) * 24, (h // 40) * 24
    {x0, y0, x1, y1}.should eq({tx, ty, hx + 23, hy + 23})
    r = Pointer(Int32).malloc(12)
    Snake.dirty_rects(r, 3).should eq 2
    rects = [{r[0], r[1], r[2], r[3]}, {r[4], r[5], r[6], r[7]}].sort
    rects.should eq [{tx, ty, tx + 23, ty + 23}, {hx, hy, hx + 23, hy + 23}].sort
  end

  it "reports head and new food after eating (tail stays)" do
    Snake.init(true)
    Snake.resync
    Snake.tick(0, inp(1536, 0))
    Snake.set_food(Snake.head + 1)
    Snake.tick(Snake::MAX_INTERVAL, inp(1536, 0)).should be_true
    f, h = Snake.food, Snake.head
    r = Pointer(Int32).malloc(12)
    Snake.dirty_rects(r, 3).should eq 2
    rects = [{r[0], r[1]}, {r[4], r[5]}].sort
    rects.should eq [{(h % 40) * 24, (h // 40) * 24}, {(f % 40) * 24, (f // 40) * 24}].sort
  end

  it "forces a full refresh on game over and restart" do
    Snake.init(false)
    Snake.resync
    Snake.set_food(-1)
    Snake.tick(0, inp(1536, 0))
    t = 0
    x0 = y0 = x1 = y1 = 0
    20.times do
      t += Snake::MAX_INTERVAL
      Snake.tick(t, inp(1536, 0)).should be_true
      Snake.dirty_box(pointerof(x0), pointerof(y0), pointerof(x1), pointerof(y1)).should be_true
    end
    t += Snake::MAX_INTERVAL
    Snake.tick(t, inp(1536, 0)).should be_true # hits the wall
    Snake.over?.should be_true
    Snake.dirty_box(pointerof(x0), pointerof(y0), pointerof(x1), pointerof(y1)).should be_false
    Snake.dirty_rects(Pointer(Int32).malloc(12), 3).should eq 0
    Snake.tick(t + 10, press(Games::BTN_A, 1536)).should be_true # restart
    Snake.dirty_box(pointerof(x0), pointerof(y0), pointerof(x1), pointerof(y1)).should be_false
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

module SkT
  class_property l = -1
  class_property r = -1
end

def sk_wrap(d)
  ((d + 2048) & 4095) - 2048
end

# Big knob moves arrive as hand turns do: in steps below Sketch::JUMP (a
# bigger step between two samples is taken as a source switch, not a turn).
def sk_tick(t, cl, cr, pressed = 0_u32)
  if SkT.l >= 0
    dl = sk_wrap(cl - SkT.l)
    dr = sk_wrap(cr - SkT.r)
    n = {dl.abs, dr.abs}.max // 400
    (1..n).each do |k|
      Sketch.tick_counts(t, (SkT.l + dl * k // (n + 1)) & 4095, (SkT.r + dr * k // (n + 1)) & 4095, 0_u32)
    end
  end
  SkT.l = cl
  SkT.r = cr
  Sketch.tick_counts(t, cl, cr, pressed)
end

# Fresh two-knob sketch, launch refresh consumed, knob refs at (cl, cr),
# the backlash filter taken up in the + direction (turns up count 1:1).
def sk_fresh(cl = 1000, cr = 1000, knobs = 2)
  Sketch.init(knobs).should be_true
  SkT.l = -1
  sk_tick(0, cl - Sketch::HYST, cr - Sketch::HYST).should be_true # launch: cleaning flash
  sk_tick(0, cl, cr)
  Sketch.want_clean?.should be_true
  Sketch.render(plane, plane)
end

describe Sketch do
  it "maps millivolts onto 0..4095 counts" do
    Sketch.counts(0, 694, 2963).should eq 0
    Sketch.counts(694, 694, 2963).should eq 0
    Sketch.counts(2963, 694, 2963).should eq 4095
    Sketch.counts(9999, 70, 2703).should eq 4095
    Sketch.counts(1387, 70, 2703).should eq 2048
  end

  it "uses upstream's delta: first read 0, deadband 12 keeps the reference, wraps" do
    last = -1
    Sketch.delta(1000, pointerof(last)).should eq 0
    Sketch.delta(1012, pointerof(last)).should eq 0
    Sketch.delta(1013, pointerof(last)).should eq 13
  end

  it "filters knob noise with a backlash: no wobble, even speed, wraps" do
    pos = -1
    Sketch.follow(1000, pointerof(pos)).should eq 0
    Sketch.follow(1000 + Sketch::HYST, pointerof(pos)).should eq 0
    Sketch.follow(1000 - Sketch::HYST, pointerof(pos)).should eq 0
    pos.should eq 1000
    Sketch.follow(1000 + Sketch::HYST + 3, pointerof(pos)).should eq 3
    Sketch.follow(1000 + Sketch::HYST + 4, pointerof(pos)).should eq 1 # count by count
    Sketch.follow(1000 + Sketch::HYST - 5, pointerof(pos)).should eq 0 # reversal inside the band
    pos = 4090
    Sketch.follow(20 + Sketch::HYST, pointerof(pos)).should eq 26
  end

  it "draws 3 px Bresenham lines including both endpoints" do
    p = plane
    Sketch.line(p, 300, 300, 300, 290)
    count_bits(p).should eq 3 * 13
    Games.get(p, 299, 289).should be_true
    Games.get(p, 301, 301).should be_true
    Games.get(p, 302, 300).should be_false
    p = plane
    Sketch.line(p, 210, 220, 250, 235)
    Games.get(p, 209, 219).should be_true
    Games.get(p, 251, 236).should be_true
    Games.get(p, 252, 235).should be_false
  end

  it "starts mid-screen with a pen dot, needing the frame and a clean flash" do
    Sketch.init.should be_true
    Sketch.x.should eq 479
    Sketch.y.should eq 310
    Sketch.needs_background?.should be_true
    count_bits(Sketch.canvas).should eq 9
    Sketch.status_text.should eq ""
  end

  it "preps the background: white, rows 668..671 red" do
    b, r = plane, plane
    b[0] = 0xFF_u8
    Sketch.prep_background(b, r)
    count_bits(b).should eq 0
    count_bits(r).should eq 960 * 4
    Games.get(r, 0, 667).should be_false
    Games.get(r, 959, 668).should be_true
  end

  it "moves 240 px per revolution, clockwise = right / up" do
    sk_fresh
    sk_tick(10, 2024, 1000).should be_false
    Sketch.x.should eq 539 # 1024 counts * 240 / 4096
    sk_tick(20, 2024, 2024).should be_false
    Sketch.y.should eq 250
    sk_tick(30, 2041, 2024) # 17 counts = 0.996 px: remainder kept
    Sketch.x.should eq 539
    sk_tick(40, 2059, 2024) # +18 -> 35 counts = 2.05 px
    Sketch.x.should eq 541
    Games.get(Sketch.canvas, 479, 310).should be_true
    Games.get(Sketch.canvas, 539, 278).should be_true
  end

  it "keeps the pen inside the Etch screen and drops turns banked at a wall" do
    sk_fresh
    c = 1000
    6.times { |i| c = (c + 2000) & 4095; sk_tick(10 + i, c, 1000) } # wraps past 4095
    Sketch.x.should eq Sketch::X_MAX
    sk_tick(20, (c + 30) & 4095, 1000) # 1.76 px further: clamped, remainder dropped
    sk_tick(30, (c + 30 - 52 - 2 * Sketch::HYST) & 4095, 1000) # reversal takes up the backlash, then back 3.05 px
    Sketch.x.should eq Sketch::X_MAX - 3
    d = 1000
    6.times { |i| d = (d + 2000) & 4095; sk_tick(40 + i, (c + 30 - 52 - 2 * Sketch::HYST) & 4095, d) }
    Sketch.y.should eq Sketch::PEN_Y_MIN
    d2 = 1000
    6.times { |i| d2 = (d2 - 2000) & 4095; sk_tick(60 + i, 0, 0) } # re-reference
    Sketch.y.should be >= Sketch::PEN_Y_MIN
    Sketch.y.should be <= Sketch::PEN_Y_MAX
    Games.get(Sketch.canvas, Sketch::X_MAX + 2, 322).should be_false
  end

  it "refreshes IDLE_REFRESH_MS after motion stops, or MAX_WAIT_MS while drawing" do
    sk_fresh
    sk_tick(100, 1100, 1000).should be_false
    Sketch.dirty?.should be_true
    Sketch.last_motion_ms.should eq 100
    sk_tick(799, 1100, 1000).should be_false
    sk_tick(800, 1100, 1000).should be_true
    Sketch.want_clean?.should be_false
    Sketch.refresh_reason.should eq Sketch::R_IDLE
    Sketch.refresh_ms.should eq 800
    sk_tick(5000, 1100, 1000).should be_false

    pos = 1100
    t = 10_000
    hits = [] of Int32
    60.times do
      t += 100
      pos += 40
      hits << t if sk_tick(t, pos, 1000)
    end
    hits.first.should eq 14_100 # first change at 10_100 + 4000
    Sketch.first_change_ms.should be > 14_100
    Sketch.refresh_reason.should eq Sketch::R_MAX
  end

  it "reports the bounding box of ink added since the last refresh" do
    sk_fresh
    x0 = y0 = x1 = y1 = 0
    Sketch.dirty_box(pointerof(x0), pointerof(y0), pointerof(x1), pointerof(y1)).should be_false # clean
    sk_tick(10, 2024, 1000)  # 479 -> 539 at y 310
    sk_tick(20, 2024, 2024)  # 310 -> 250 at x 539
    sk_tick(800, 2024, 2024).should be_true
    Sketch.dirty_box(pointerof(x0), pointerof(y0), pointerof(x1), pointerof(y1)).should be_true
    {x0, y0, x1, y1}.should eq({478, 249, 540, 311})
    sk_tick(900, 1000 - 2 * Sketch::HYST, 2024) # back left 60 px (after the backlash): new box only
    sk_tick(1600, 1000 - 2 * Sketch::HYST, 2024).should be_true
    Sketch.dirty_box(pointerof(x0), pointerof(y0), pointerof(x1), pointerof(y1)).should be_true
    {x0, y0, x1, y1}.should eq({478, 249, 540, 251})
    sk_tick(1700, 1000, 2024, Games::BTN_B).should be_true # clean: no window
    Sketch.dirty_box(pointerof(x0), pointerof(y0), pointerof(x1), pointerof(y1)).should be_false
  end

  it "erases on User A with a cleaning flash; User B re-flashes the drawing" do
    sk_fresh
    sk_tick(10, 2000, 1000)
    sk_tick(20, 2000, 1000, Games::BTN_A).should be_true
    Sketch.want_clean?.should be_true
    Sketch.needs_background?.should be_true
    Sketch.refresh_reason.should eq Sketch::R_CLEAN
    count_bits(Sketch.canvas).should eq 9 # just the pen dot, where the pen is
    Games.get(Sketch.canvas, Sketch.x, Sketch.y).should be_true
    Sketch.render(plane, plane)
    sk_tick(30, 2000, 1000).should be_false
    sk_tick(40, 2000, 1000, Games::BTN_B).should be_true
    Sketch.want_clean?.should be_true
    Sketch.needs_background?.should be_false
  end

  it "single-knob mode: User B switches the axis" do
    sk_fresh(1000, 1000, 1)
    Sketch.status_text.should eq "1 knob (SAO1/GPIO2) - B switches X/Y"
    sk_tick(10, 2024, 3000).should be_false
    Sketch.x.should eq 539
    Sketch.y.should eq 310
    sk_tick(20, 2024, 3000, Games::BTN_B).should be_false
    Sketch.single_axis_y?.should be_true
    Sketch.blink_request.should eq 2
    Sketch.blink_request.should eq 0
    sk_tick(30, 3048, 0)
    Sketch.x.should eq 539
    Sketch.y.should eq 250
  end

  it "animates the LEDs: spinning dot, red at walls, status colors when idle" do
    sk_fresh
    leds = Pointer(UInt32).malloc(8)
    Sketch.led_frame(0, true, leds).should be_true
    8.times { |i| leds[i].should eq Sketch::C_CYAN }
    Sketch.led_frame(1, true, leds).should be_false # unchanged
    sk_tick(100, 1300, 1000)                         # +300 counts = 1.17 steps
    Sketch.led_frame(100, false, leds).should be_true
    (0...8).map { |i| leds[i] }.should eq [0_u32, Sketch::C_CYAN, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32]
    sk_tick(150, 1300, 700) # Y turned back 300: phase -1.17 -> int -1 -> pos 3
    Sketch.led_frame(150, false, leds)
    (4...8).map { |i| leds[i] }.should eq [0_u32, 0_u32, 0_u32, Sketch::C_MAGENTA]
    Sketch.led_frame(600, false, leds) # X done (>400 ms), Y done too
    8.times { |i| leds[i].should eq Sketch::C_YELLOW } # dirty, waiting
    c = 1300
    5.times { |i| c = (c + 2000) & 4095; sk_tick(700 + i, c, 700) }
    Sketch.led_frame(705, false, leds)
    4.times { |i| leds[i].should eq Sketch::C_RED }
  end

  it "takes knob millivolts through tick()" do
    sk_fresh
    Sketch.tick(10, inp(1000, 1000)) # re-reference at the mV mapping
    Sketch.tick(20, inp(1512, 1000)) # turns arrive in steps below JUMP
    Sketch.tick(30, inp(2024, 1000))
    (Sketch.x - 479).should be_close(59, 1) # 60 px less the backlash
  end

  it "overlays the trace on the frame: black set, red cleared" do
    sk_fresh
    b, r = plane, plane
    Games::PLANE.times { |i| r[i] = 0xFF_u8 }
    b[0] = 0x80_u8
    Sketch.render(b, r)
    Games.get(b, 479, 309).should be_true
    Games.get(r, 479, 309).should be_false
    Games.get(r, 10, 10).should be_true
    Games.get(b, 0, 0).should be_true
    count_bits(b).should eq 1 + 9
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
    Menu.needs_background?.should be_true
    Menu.render(b, r).should be_true
    Menu.want_clean?.should be_true
    Menu.needs_background?.should be_false
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

  it "passes dirty boxes through, full after a mode switch" do
    Menu.init(Menu::NAMETAG)
    Menu.tick(0, press(Games::BTN_MINUS)).should be_true # -> Snake
    x0 = y0 = x1 = y1 = 0
    rr = Pointer(Int32).malloc(16)
    Menu.dirty_box(pointerof(x0), pointerof(y0), pointerof(x1), pointerof(y1)).should be_false
    Menu.dirty_rects(rr, 4).should eq 0
    Snake.set_food(-1)
    Menu.tick(1, inp(1536, 0))
    Menu.tick(1 + Snake::MAX_INTERVAL, inp(1536, 0)).should be_true
    Menu.dirty_box(pointerof(x0), pointerof(y0), pointerof(x1), pointerof(y1)).should be_true
    Menu.dirty_rects(rr, 3).should eq 2
  end
end

require "./arcade_spec"
