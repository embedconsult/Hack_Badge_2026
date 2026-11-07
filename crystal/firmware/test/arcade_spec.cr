# Host specs for the arcade games (blocks, aliens, rocks) and their helpers.
# Run with the others: crystal spec test/games_spec.cr (it requires this).
require "spec"
require "./shim"
require "../src/games/blocks"
require "../src/games/aliens"
require "../src/games/rocks"

private def ainp(left = 0, right = 0, held = 0_u32, prev = 0_u32)
  Games.input(Games.mv_for(left, Games::LEFT_MV_LO, Games::LEFT_MV_HI),
    Games.mv_for(right, Games::RIGHT_MV_LO, Games::RIGHT_MV_HI), held, prev)
end

private def aplane
  Pointer(UInt8).malloc(Games::PLANE)
end

private def abits(p, rows = Games::H)
  n = 0
  (rows * Games::ROW_BYTES).times { |i| n += p[i].popcount }
  n
end

describe "Arcade helpers" do
  it "draws digits from the 3x5 font" do
    p = aplane
    Arcade.draw_number(p, 0, 0, 8, 1)
    abits(p).should eq 13 # 8 = 111 101 111 101 111
    p2 = aplane
    Arcade.draw_number(p2, 0, 0, 7, 2, 3).should eq 3 * 8 # "007"
  end

  it "has a 32-step sine" do
    Arcade.sin32(0).should eq 0
    Arcade.sin32(8).should eq 1024
    Arcade.sin32(16).should eq 0
    Arcade.sin32(24).should eq -1024
    Arcade.cos32(0).should eq 1024
    Arcade.cos32(16).should eq -1024
    Arcade.sin32(3).should eq Arcade.sin32(13)
  end

  it "draws thick lines end to end" do
    p = aplane
    Arcade.line(p, 10, 10, 50, 30, 3)
    Games.get(p, 10, 10).should be_true
    Games.get(p, 50, 30).should be_true
    Games.get(p, 30, 20).should be_true
    Games.get(p, 10, 30).should be_false
  end

  it "buckets knobs with hysteresis" do
    Arcade.bucket(0, 4, -1, 100).should eq 0
    Arcade.bucket(4096, 4, -1, 100).should eq 3
    b = Arcade.bucket(1030, 4, 0, 100) # just past the 0/1 boundary
    b.should eq 0
    Arcade.bucket(1300, 4, 0, 100).should eq 1
  end
end

describe "Blocks" do
  it "spawns a piece and falls with gravity" do
    Games.seed(1_u32)
    Blocks.init.should be_true
    Blocks.over?.should be_false
    y = Blocks.py
    Blocks.step
    Blocks.py.should eq y + 1
  end

  it "has 4 cells in every shape" do
    7.times do |k|
      4.times { |r| Blocks.shape(k, r).popcount.should eq 4 }
    end
  end

  it "clears a full line and scores" do
    Blocks.init
    9.times { |c| Blocks.set_cell(c, 19, true) }
    # vertical I in the last column: rot 1 = column 2 of the box
    Blocks.set_piece(0, 1, 7, 10)
    Blocks.hard_drop
    Blocks.cleared.should eq 1
    Blocks.lines.should eq 1
    Blocks.cell?(0, 19).should be_false
    Blocks.cell?(9, 19).should be_true # rest of the I moved down
    Blocks.score.should be >= 100
  end

  it "levels up every 10 lines" do
    Blocks.init
    10.times do
      9.times { |c| Blocks.set_cell(c + 1, 19, true) }
      Blocks.set_piece(0, 1, -2, 0) # vertical I in column 0
      Blocks.hard_drop
      # three I cells remain stacked in column 0; clear them for the next round
      18.downto(16) { |r| Blocks.set_cell(0, r, false) }
    end
    Blocks.lines.should eq 10
    Blocks.level.should eq 2
  end

  it "moves to the knob column, stopping at walls and blocks" do
    Blocks.init
    Blocks.set_piece(3, 0, 3, 5) # O piece, cells at box cols 1..2
    Blocks.move_to(0).should be_true
    (Blocks.px + 1).should eq 0
    Blocks.move_to(8)
    (Blocks.px + 1).should eq 8
    Blocks.set_piece(3, 0, 3, 5)
    Blocks.set_cell(7, 6, true)
    Blocks.move_to(8)
    (Blocks.px + 1).should eq 5 # O occupies 5..6, blocked at 7
  end

  it "rotates with wall kicks" do
    Blocks.init
    Blocks.set_piece(0, 1, -2, 5) # vertical I against the left wall
    Blocks.rotate(1).should be_true
    Blocks.rot.should eq 2
    Blocks.px.should be >= 0
  end

  it "follows the knobs and buttons in tick" do
    Games.seed(7_u32)
    Blocks.init
    Blocks.resync
    Blocks.tick(0, ainp(0, 0)).should be_false # reference only
    Blocks.tick(10, ainp(4096, 0)).should be_true # slide right
    m = Blocks.shape(Blocks.kind, Blocks.rot)
    (Blocks.px + Blocks.max_col(m)).should eq 9
    r = Blocks.rot
    Blocks.tick(20, ainp(4096, 0, Games::BTN_A)) # A = rotate
    Blocks.rot.should_not eq r if Blocks.kind != 3
    Blocks.tick(30, ainp(4096, 1300)) # right knob a quarter = rotate once more
    k = Blocks.kind
    Blocks.tick(40, ainp(4096, 1300, Games::BTN_B)).should be_true # hard drop
    Blocks.lines.should eq 0
    Blocks.tick(2000, ainp(4096, 1300)).should be_true # gravity
  end

  # Hardware report (b3bc247): in 45 s only one piece fell and none spawned.
  # Badge timing model: a frame (tick -> true) costs a ~0.7 s diff pull, a
  # clean every 20 frames ~7 s, a pause >= 400 ms an erase-settle pull, and
  # idle loop passes 20 ms. With no input, pieces must keep spawning and
  # locking at a playable rate.
  it "spawns and locks several pieces in 45 s of badge time with no input" do
    Games.seed(99_u32)
    Blocks.init
    Blocks.resync
    t = 0
    frames = 0
    last_frame = 0
    settled = true
    idle = ainp(2048, 2048)
    while t < 45_000
      if Blocks.tick(t, idle)
        frames += 1
        t += frames % 20 == 0 ? 7000 : 700
        last_frame = t
        settled = false
      elsif !settled && t - last_frame >= 400
        t += 650 # erase settle pull
        settled = true
      else
        t += 20
      end
    end
    Blocks.over?.should be_false
    Blocks.pieces.should be >= 4
    # every spawned piece but the falling one is locked in the well
    cells = 0
    20.times { |r| 10.times { |c| cells += 1 if Blocks.cell?(c, r) } }
    cells.should eq (Blocks.pieces - 1) * 4 - Blocks.lines * 10
  end

  it "rests one frame on landing, then locks and spawns the next" do
    Blocks.init
    Blocks.set_piece(3, 0, 3, 17) # O piece, cells on rows 17..18
    n = Blocks.pieces
    Blocks.fall # one row down to 18..19, then blocked: rests (still movable)
    Blocks.resting?.should be_true
    Blocks.py.should eq 18
    Blocks.pieces.should eq n
    Blocks.fall # locks, next piece
    Blocks.pieces.should eq n + 1
    Blocks.cell?(4, 19).should be_true
  end

  it "ends when the well overflows and restarts on A" do
    Blocks.init
    20.times { |r| 9.times { |c| Blocks.set_cell(c, r, true) if r >= 1 } }
    Blocks.set_piece(3, 0, 3, -1)
    Blocks.hard_drop
    Blocks.over?.should be_true
    Blocks.resync
    Blocks.tick(0, ainp).should be_false
    Blocks.tick(10, ainp(0, 0, Games::BTN_A)).should be_true
    Blocks.over?.should be_false
  end

  it "renders without touching the label band" do
    Blocks.init
    b = aplane
    r = aplane
    Blocks.render(b, r)
    abits(b).should be > 0
    abits(b, Arcade::LABEL_H).should eq 0
    abits(r).should eq 0
  end
end

describe "Aliens" do
  it "starts a full wave" do
    Games.seed(3_u32)
    Aliens.init.should be_true
    Aliens.alive_count.should eq 32
    Aliens.lives.should eq 3
    Aliens.shield_cells.should eq 4 * (32 - 2)
  end

  it "marches sideways and steps down at the edge" do
    Aliens.init
    x = Aliens.origin_x
    Aliens.step
    Aliens.origin_x.should eq x + Aliens.step_x
    y = Aliens.origin_y
    40.times { Aliens.step if Aliens.dir == 1 && Aliens.origin_y == y }
    Aliens.origin_y.should eq y + 24
    Aliens.dir.should eq -1
  end

  it "shoots the lowest alien in the column" do
    Aliens.init
    Aliens.resync
    # put the cannon under column 0
    k = 0
    target = Aliens.alien_x(0) + Aliens::AW // 2
    while Aliens.knob_cannon(k) < target - 4 && k < 4096
      k += 8
    end
    Aliens.tick(0, ainp(k))
    Aliens.fire.should be_true
    # the shot passes no shield at this x? shields are at 64..176; column 0 is ~56..100
    10.times { Aliens.move_shots }
    n = Aliens.alive_count
    (n < 32 || Aliens.shield_cells < 120).should be_true
  end

  it "loses a life to a bomb on the cannon" do
    Aliens.init
    Aliens.set_bomb(0, Aliens.cannon_x - 4, Aliens::CANNON_Y - 30)
    Aliens.move_bombs
    Aliens.lives.should eq 2
  end

  it "shields stop bombs" do
    Aliens.init
    c = Aliens.shield_cells
    Aliens.set_bomb(0, Aliens.shield_x(1) + 20, Aliens::SHIELD_Y - 30)
    Aliens.move_bombs
    Aliens.bomb_y(0).should eq -1
    Aliens.shield_cells.should eq c - 1
  end

  it "starts a new wave when all are gone and ends on landing" do
    Aliens.init
    32.times { |i| Aliens.kill(i) }
    Aliens.step
    Aliens.wave.should eq 2
    Aliens.alive_count.should eq 32
    200.times { Aliens.step unless Aliens.over? }
    Aliens.over?.should be_true
  end

  it "moves the cannon with the knob and renders" do
    Aliens.init
    Aliens.resync
    Aliens.tick(0, ainp(0))
    l = Aliens.cannon_x
    Aliens.tick(10, ainp(4096)).should be_true
    Aliens.cannon_x.should be > l + 800
    b = aplane
    Aliens.render(b, aplane)
    abits(b).should be > 0
    abits(b, Arcade::LABEL_H).should eq 0
  end
end

describe "Rocks" do
  it "starts with big rocks away from the ship" do
    Games.seed(5_u32)
    Rocks.init.should be_true
    Rocks.rock_count.should eq 4
    Rocks.lives.should eq 3
  end

  it "wraps the ship around the edges" do
    Rocks.init
    Rocks.clear_rocks
    Rocks.add_rock(100, 100, 0, 0, 1)
    Rocks.place_ship(950, 300, 30 * 16, 0)
    Rocks.step(false)
    Rocks.ship_x.should be < 40
    Rocks.place_ship(500, 2, 0, -10 * 16)
    Rocks.step(false)
    Rocks.ship_y.should be > Rocks::FH - 20
  end

  it "thrusts along the heading and drags without" do
    Rocks.init
    Rocks.clear_rocks
    Rocks.add_rock(100, 100, 0, 0, 1)
    Rocks.place_ship(480, 300, 0, 0)
    Rocks.set_dir(0) # right
    Rocks.step(true)
    Rocks.ship_vx.should be > 0
    Rocks.ship_vy.should eq 0
    v = Rocks.ship_vx
    Rocks.step(false)
    Rocks.ship_vx.should be < v
  end

  it "splits a big rock into two medium ones when shot" do
    Rocks.init
    Rocks.clear_rocks
    Rocks.place_ship(200, 300, 0, 0)
    Rocks.set_dir(0)
    Rocks.add_rock(320, 300, 0, 0, 3)
    Rocks.add_rock(800, 100, 0, 0, 1) # keeps the wave going
    Rocks.fire.should be_true
    Rocks.step(false)
    Rocks.rock_count.should eq 3
    Rocks.score.should eq 20
    Rocks.bullet_count.should eq 0
  end

  it "loses a life on collision and respawns invulnerable" do
    Rocks.init
    Rocks.clear_rocks
    Rocks.add_rock(800, 100, 0, 0, 1)
    Rocks.set_invuln(0)
    Rocks.place_ship(300, 300, 0, 0)
    Rocks.add_rock(310, 300, 0, 0, 2)
    Rocks.step(false)
    Rocks.lives.should eq 2
    Rocks.invulnerable?.should be_true
  end

  it "next wave after the last rock; game over after three hits" do
    Rocks.init
    Rocks.clear_rocks
    Rocks.step(false)
    Rocks.wave.should eq 2
    Rocks.rock_count.should eq 5
    3.times do
      Rocks.set_invuln(0)
      Rocks.add_rock(Rocks.ship_x, Rocks.ship_y, 0, 0, 1)
      Rocks.step(false)
    end
    Rocks.over?.should be_true
  end

  it "turns with the right knob, fires on A, and renders" do
    Rocks.init
    Rocks.resync
    Rocks.tick(0, ainp(0, 0))
    Rocks.dir.should eq 24 # up
    Rocks.tick(10, ainp(0, 1100)).should be_true
    Rocks.dir.should eq 0 # a quarter turn = right
    Rocks.tick(20, ainp(0, 1100, Games::BTN_A)).should be_true
    Rocks.bullet_count.should eq 1
    b = aplane
    Rocks.render(b, aplane)
    abits(b).should be > 0
    abits(b, Arcade::LABEL_H).should eq 0
  end
end
