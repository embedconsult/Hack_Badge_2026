# Host specs for the SNAKES arena rules engine and the house snake
# (src/games/snakes_rules.cr, snakes_house.cr).
#   crystal spec test/snakes_spec.cr
require "spec"
require "./shim"
require "../src/games/snakes_house"

private alias R = SnakeRules

private def mv(*ds)
  p = Pointer(Int32).malloc(R::MAX)
  R::MAX.times { |i| p[i] = -1 }
  ds.each_with_index { |d, i| p[i] = d }
  p
end

# Snake i from a list of {x, y}, head first.
private def snake(i, cells)
  cells.each_with_index { |(x, y), k| R.set_segment(i, k, x, y) }
end

private def body(i)
  (0...R.length(i)).map { |k| {R.x(i, k), R.y(i, k)} }
end

private def board(n)
  R.clear(n).should be_true
  R.food_on = false
end

describe "SnakeRules" do
  it "starts a standard game: stacked snakes on corners, food by each and in the centre" do
    R.food_on = true
    R.new_game(4, 1234_u32).should be_true
    R.count.should eq 4
    corners = [{1, 1}, {9, 9}, {1, 9}, {9, 1}]
    starts = (0...4).map { |i| {R.x(i, 0), R.y(i, 0)} }
    starts.sort.should eq corners.sort
    4.times do |i|
      R.length(i).should eq 3
      R.health(i).should eq 100
      body(i).uniq.size.should eq 1
    end
    R.food_count.should eq 5
    R.food_at?(5, 5).should be_true
    4.times do |i|
      sx, sy = starts[i]
      (0...R.food_count).any? { |k| (R.food_x(k) - sx).abs == 1 && (R.food_y(k) - sy).abs == 1 }.should be_true
    end
  end

  it "moves up as y + 1 and keeps going on a missing move" do
    board(1)
    snake(0, [{5, 5}, {5, 4}, {5, 3}])
    R.step(mv(R::UP)).should be_false
    body(0).should eq [{5, 6}, {5, 5}, {5, 4}]
    R.step(mv(R::RIGHT))
    body(0).should eq [{6, 6}, {5, 6}, {5, 5}]
    R.step(mv(-1)) # timeout: the last move again
    body(0).should eq [{7, 6}, {6, 6}, {5, 6}]
    R.health(0).should eq 97
    R.turn.should eq 3
  end

  it "unstacks the start body" do
    board(1)
    R.place(0, 1, 1, 3)
    R.step(mv(R::DOWN))
    body(0).should eq [{1, 0}, {1, 1}, {1, 1}]
    R.alive?(0).should be_true
    R.step(mv(R::RIGHT))
    body(0).should eq [{2, 0}, {1, 0}, {1, 1}]
  end

  it "eats: health back to 100, grows by the tail, food gone" do
    board(1)
    snake(0, [{5, 5}, {5, 4}, {5, 3}])
    R.set_health(0, 10)
    R.add_food(5, 6)
    R.step(mv(R::UP))
    R.health(0).should eq 100
    body(0).should eq [{5, 6}, {5, 5}, {5, 4}, {5, 4}]
    R.food_count.should eq 0
    R.step(mv(R::UP))
    body(0).should eq [{5, 7}, {5, 6}, {5, 5}, {5, 4}]
  end

  it "keeps at least one food on the board" do
    R.clear(1)
    R.food_on = true
    snake(0, [{5, 5}, {5, 4}, {5, 3}])
    R.step(mv(R::UP))
    R.food_count.should be >= 1
    R.snake_at?(R.food_x(0), R.food_y(0)).should be_false
  end

  it "eliminates on the wall" do
    board(1)
    snake(0, [{0, 5}, {1, 5}, {2, 5}])
    R.step(mv(R::LEFT)).should be_true
    R.cause(0).should eq R::WALL
    R.out_turn(0).should eq 1
  end

  it "starves at health 0, unless it eats on that turn" do
    board(2)
    snake(0, [{2, 5}, {2, 4}, {2, 3}])
    snake(1, [{8, 5}, {8, 4}, {8, 3}])
    R.set_health(0, 1)
    R.set_health(1, 1)
    R.add_food(8, 6)
    R.step(mv(R::UP, R::UP)).should be_true
    R.cause(0).should eq R::STARVED
    R.alive?(1).should be_true
    R.health(1).should eq 100
    R.winner.should eq 1
  end

  it "eliminates running into itself, but not into the tail that moves away" do
    board(1)
    snake(0, [{5, 5}, {5, 4}, {4, 4}, {4, 5}]) # tail at (4,5), head turns left onto it
    R.step(mv(R::LEFT))
    R.alive?(0).should be_true
    board(1)
    snake(0, [{5, 5}, {5, 4}, {4, 4}, {4, 5}, {4, 6}])
    R.step(mv(R::LEFT))
    R.cause(0).should eq R::SELF
    board(1)
    snake(0, [{5, 5}, {5, 4}, {5, 3}])
    R.step(mv(R::DOWN)) # back onto the neck
    R.cause(0).should eq R::SELF
  end

  it "eliminates running into another body and credits the owner" do
    board(2)
    snake(0, [{3, 5}, {2, 5}, {1, 5}])
    snake(1, [{4, 6}, {4, 5}, {4, 4}, {4, 3}])
    R.step(mv(R::RIGHT, R::UP)).should be_true
    R.cause(0).should eq R::BODY
    R.killer(0).should eq 1
    R.alive?(1).should be_true
    R.winner.should eq 1
  end

  it "head-to-head: the longer survives, equal both die" do
    board(2)
    snake(0, [{4, 5}, {3, 5}, {2, 5}, {1, 5}])
    snake(1, [{6, 5}, {7, 5}, {8, 5}])
    R.step(mv(R::RIGHT, R::LEFT)).should be_true
    R.alive?(0).should be_true
    R.cause(1).should eq R::HEAD
    R.killer(1).should eq 0
    board(2)
    snake(0, [{4, 5}, {3, 5}, {2, 5}])
    snake(1, [{6, 5}, {7, 5}, {8, 5}])
    R.step(mv(R::RIGHT, R::LEFT)).should be_true
    R.cause(0).should eq R::HEAD
    R.cause(1).should eq R::HEAD
    R.winner.should eq -1
  end

  it "a snake out of bounds is no obstacle in the same turn" do
    board(3)
    snake(0, [{0, 5}, {1, 5}, {2, 5}])          # leaves the board
    snake(1, [{1, 3}, {1, 2}, {1, 1}])          # moves up to (1,4): empty
    snake(2, [{9, 9}, {9, 8}, {9, 7}])
    R.step(mv(R::LEFT, R::UP, R::UP)).should be_false
    R.cause(0).should eq R::WALL
    R.alive?(1).should be_true
  end

  it "ends a multi-snake game with one left, a solo game with none" do
    board(2)
    snake(0, [{0, 0}, {0, 1}, {0, 2}])
    snake(1, [{5, 5}, {5, 4}, {5, 3}])
    R.step(mv(R::DOWN, R::UP)).should be_true
    R.winner.should eq 1
    board(1)
    snake(0, [{5, 5}, {5, 4}, {5, 3}])
    R.step(mv(R::UP)).should be_false
    R.over?.should be_false
  end

  it "snapshots the board for the bot API" do
    board(2)
    snake(0, [{1, 2}, {1, 1}, {1, 0}])
    snake(1, [{8, 8}, {8, 9}, {8, 10}])
    R.add_food(5, 5)
    buf = Pointer(Int32).malloc(64)
    n = R.snapshot(buf, 64)
    n.should eq 3 + 2 + 2 * (3 + 6)
    (0...n).map { |i| buf[i] }.should eq [0, 2, 1, 5, 5,
                                           1, 100, 3, 1, 2, 1, 1, 1, 0,
                                           1, 100, 3, 8, 8, 8, 9, 8, 10]
    R.snapshot(buf, 10).should eq 0
  end
end

describe "SnakeHouse" do
  it "never steps off the board or into a body when it has a way out" do
    board(1)
    snake(0, [{0, 10}, {1, 10}, {2, 10}]) # top-left corner, heading left
    R.food_on = false
    m = SnakeHouse.choose(0)
    m.should eq R::DOWN
  end

  it "avoids the dead end" do
    board(2)
    # snake 0 at (5,5) heading up; going left leads into a 1-cell pocket
    snake(0, [{5, 5}, {5, 4}, {5, 3}, {5, 2}])
    snake(1, [{4, 6}, {3, 6}, {3, 5}, {3, 4}, {4, 4}, {4, 3}, {9, 0}])
    m = SnakeHouse.choose(0)
    m.should_not eq R::LEFT
  end

  it "goes for food when hungry" do
    board(1)
    snake(0, [{5, 5}, {5, 4}, {5, 3}])
    R.set_health(0, 20)
    R.add_food(8, 5)
    SnakeHouse.choose(0).should eq R::RIGHT
  end

  it "steers away from a longer head" do
    board(2)
    snake(0, [{5, 5}, {5, 4}, {5, 3}])
    snake(1, [{6, 6}, {7, 6}, {8, 6}, {9, 6}, {10, 6}]) # (5,6) and (6,5) are next to its head
    20.times do
      m = SnakeHouse.choose(0)
      [R::UP, R::RIGHT].should_not contain m
    end
  end

  it "makes a missed bot move safe: last direction if clear, else no wall or body" do
    board(2)
    snake(0, [{5, 5}, {4, 5}, {3, 5}]) # heading right, clear ahead
    snake(1, [{9, 9}, {9, 8}, {9, 7}])
    R.step(mv(R::RIGHT, R::LEFT))
    SnakeHouse.fallback(0).should eq R::RIGHT
    # the --delay 800 case: start in a corner, first moves missed
    board(2)
    R.place(0, 1, 1, 3)
    snake(1, [{9, 9}, {9, 8}, {9, 7}])
    R.step(mv(R::DOWN, R::LEFT)) # (1,0), heading down at the wall
    m = SnakeHouse.fallback(0)
    [R::LEFT, R::RIGHT].should contain m
    R.step(mv(m, R::LEFT))
    R.alive?(0).should be_true
    # into a body: not the last direction
    board(2)
    snake(0, [{5, 5}, {4, 5}, {3, 5}])
    snake(1, [{8, 9}, {7, 9}, {7, 8}, {7, 7}, {7, 6}, {7, 5}, {7, 4}, {7, 3}])
    R.step(mv(R::RIGHT, R::RIGHT)) # 0 at (6,5), heading right; (7,5) is 1's body
    R.alive?(0).should be_true
    m = SnakeHouse.fallback(0)
    m.should_not eq R::RIGHT
    [R::UP, R::DOWN].should contain m
  end

  it "plays whole house games to the end, all rules holding" do
    R.food_on = true
    10.times do |g|
      R.new_game(4, (g + 1).to_u32).should be_true
      moves = Pointer(Int32).malloc(R::MAX)
      turns = 0
      until R.over? || turns > 2000
        R.count.times { |i| moves[i] = R.alive?(i) ? SnakeHouse.choose(i) : -1 }
        R.step(moves)
        turns += 1
        R.count.times do |i|
          next unless R.alive?(i)
          R.in_bounds?(R.x(i, 0), R.y(i, 0)).should be_true
          R.health(i).should be > 0
        end
      end
      R.over?.should be_true
      turns.should be > 10 # the house snake should not die at once
    end
  end
end
