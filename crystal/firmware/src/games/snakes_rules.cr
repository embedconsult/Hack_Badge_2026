# SNAKES arena rules engine: the standard multiplayer snake rules that the
# open snake-bot move API (POST /start, /move, /end) is built around, so
# any bot written for that API plays here by URL. 11x11 board, health 100,
# one food at least and a 15 % chance of one more per turn, body and head
# collisions, the longer snake wins a head-to-head (equal: both die).
#
# Coordinates are the API's: x = 0 left, y = 0 at the BOTTOM, "up" = y + 1.
# Body index 0 is the head. A new snake is 3 segments stacked on one cell.
#
# Turn order (as in the standard ruleset): move every snake, health - 1,
# feed (head on food: health 100, grow by repeating the tail), spawn food,
# then eliminate: first out of bounds and starved, then, among the rest at
# once, self / body collisions and lost head-to-heads.
#
# Pure Crystal for --prelude=empty and free of ESP-IDF calls, so the host
# specs (test/snakes_spec.cr) run it with the standard prelude.

require "./common"

module SnakeRules
  W     = 11
  H     = 11
  CELLS = 121
  MAX   =   4 # snakes per game
  CAP   = 128 # segments per snake (a snake cannot outgrow the board)
  START =   3 # starting length
  HEALTH = 100

  MIN_FOOD   =  1
  FOOD_CHANCE = 15 # percent per turn once MIN_FOOD is there

  UP    = 0
  DOWN  = 1
  LEFT  = 2
  RIGHT = 3

  # Elimination causes (0 = alive).
  ALIVE   = 0
  WALL    = 1 # moved out of bounds
  STARVED = 2 # health reached 0
  SELF    = 3 # ran into itself
  BODY    = 4 # ran into another snake's body
  HEAD    = 5 # lost a head-to-head

  # Start cells of the standard 11x11 map: corners, then edge middles.
  def self.start_x(k : Int32) : Int32
    k == 0 || k == 2 || k == 5 ? 1 : (k == 1 || k == 3 || k == 6 ? 9 : 5)
  end

  def self.start_y(k : Int32) : Int32
    k == 0 || k == 3 || k == 4 ? 1 : (k == 1 || k == 2 || k == 7 ? 9 : 5)
  end

  @@bx = Pointer(Int32).null # MAX * CAP
  @@by = Pointer(Int32).null
  @@len = Pointer(Int32).null
  @@hp = Pointer(Int32).null
  @@dir = Pointer(Int32).null  # last move
  @@out = Pointer(Int32).null  # elimination cause
  @@outt = Pointer(Int32).null # turn of elimination
  @@by_ = Pointer(Int32).null  # who eliminated it (-1)
  @@ate = Pointer(Int32).null  # 1 if it ate this turn
  @@cause = Pointer(Int32).null # scratch: collisions of this turn
  @@who = Pointer(Int32).null
  @@order = Pointer(Int32).null # scratch: start cell shuffle (8)
  @@fx = Pointer(Int32).null   # food, CELLS
  @@fy = Pointer(Int32).null
  @@nf = 0
  @@n = 0
  @@turn = 0
  @@food_on = true # false: no random food (specs place it by hand)

  def self.alloc : Bool
    return true unless @@bx.null?
    @@bx = game_alloc(MAX &* CAP &* 4).as(Int32*)
    @@by = game_alloc(MAX &* CAP &* 4).as(Int32*)
    @@len = game_alloc((MAX &* 9 &+ 8) &* 4).as(Int32*) # 9 arrays of MAX + 8
    @@fx = game_alloc(CELLS &* 4).as(Int32*)
    @@fy = game_alloc(CELLS &* 4).as(Int32*)
    return false if @@bx.null? || @@by.null? || @@len.null? || @@fx.null? || @@fy.null?
    @@hp = @@len + MAX.to_i64!
    @@dir = @@hp + MAX.to_i64!
    @@out = @@dir + MAX.to_i64!
    @@outt = @@out + MAX.to_i64!
    @@by_ = @@outt + MAX.to_i64!
    @@ate = @@by_ + MAX.to_i64!
    @@cause = @@ate + MAX.to_i64!
    @@who = @@cause + MAX.to_i64!
    @@order = @@who + MAX.to_i64!
    true
  end

  # ---- accessors ------------------------------------------------------------

  def self.count : Int32
    @@n
  end

  def self.turn : Int32
    @@turn
  end

  def self.length(i : Int32) : Int32
    @@len[i]
  end

  def self.health(i : Int32) : Int32
    @@hp[i]
  end

  def self.alive?(i : Int32) : Bool
    @@out[i] == ALIVE
  end

  def self.cause(i : Int32) : Int32
    @@out[i]
  end

  def self.out_turn(i : Int32) : Int32
    @@outt[i]
  end

  def self.killer(i : Int32) : Int32
    @@by_[i]
  end

  def self.last_dir(i : Int32) : Int32
    @@dir[i]
  end

  def self.x(i : Int32, k : Int32) : Int32
    @@bx[i &* CAP &+ k]
  end

  def self.y(i : Int32, k : Int32) : Int32
    @@by[i &* CAP &+ k]
  end

  def self.food_count : Int32
    @@nf
  end

  def self.food_x(k : Int32) : Int32
    @@fx[k]
  end

  def self.food_y(k : Int32) : Int32
    @@fy[k]
  end

  def self.food_on=(on : Bool) : Nil
    @@food_on = on
  end

  def self.alive_count : Int32
    c = 0
    i = 0
    while i < @@n
      c = c &+ 1 if @@out[i] == ALIVE
      i = i &+ 1
    end
    c
  end

  # Multi-snake games end when one snake (or none) is left, a solo game
  # when its snake dies.
  def self.over? : Bool
    a = alive_count
    @@n > 1 ? a <= 1 : a == 0
  end

  # The last snake standing, or -1 (draw, or still running).
  def self.winner : Int32
    return -1 unless over?
    i = 0
    while i < @@n
      return i if @@out[i] == ALIVE
      i = i &+ 1
    end
    -1
  end

  def self.dx(d : Int32) : Int32
    d == LEFT ? -1 : (d == RIGHT ? 1 : 0)
  end

  def self.dy(d : Int32) : Int32
    d == UP ? 1 : (d == DOWN ? -1 : 0)
  end

  def self.in_bounds?(x : Int32, y : Int32) : Bool
    x >= 0 && x < W && y >= 0 && y < H
  end

  # ---- setup ----------------------------------------------------------------

  # Empty board with n snakes (no snakes, no food yet): the specs build
  # positions with place / add_food; new_game uses the standard map.
  def self.clear(n : Int32) : Bool
    return false unless alloc
    n = MAX if n > MAX
    @@n = n
    @@nf = 0
    @@turn = 0
    i = 0
    while i < MAX
      @@len[i] = 0
      @@hp[i] = HEALTH
      @@dir[i] = UP
      @@out[i] = i < n ? ALIVE : WALL
      @@outt[i] = 0
      @@by_[i] = -1
      @@ate[i] = 0
      i = i &+ 1
    end
    true
  end

  # Snake i: len segments, all at (x, y).
  def self.place(i : Int32, x : Int32, y : Int32, len : Int32) : Nil
    k = 0
    while k < len
      @@bx[i &* CAP &+ k] = x
      @@by[i &* CAP &+ k] = y
      k = k &+ 1
    end
    @@len[i] = len
  end

  # Sets segment k of snake i (growing the length to k + 1 if needed).
  def self.set_segment(i : Int32, k : Int32, x : Int32, y : Int32) : Nil
    @@bx[i &* CAP &+ k] = x
    @@by[i &* CAP &+ k] = y
    @@len[i] = k &+ 1 if @@len[i] < k &+ 1
  end

  def self.set_health(i : Int32, hp : Int32) : Nil
    @@hp[i] = hp
  end

  def self.add_food(x : Int32, y : Int32) : Nil
    return if @@nf >= CELLS || food_at?(x, y)
    @@fx[@@nf] = x
    @@fy[@@nf] = y
    @@nf = @@nf &+ 1
  end

  def self.food_at?(x : Int32, y : Int32) : Bool
    k = 0
    while k < @@nf
      return true if @@fx[k] == x && @@fy[k] == y
      k = k &+ 1
    end
    false
  end

  # Is (x, y) under any segment of a living snake?
  def self.snake_at?(x : Int32, y : Int32) : Bool
    i = 0
    while i < @@n
      if @@out[i] == ALIVE
        k = 0
        l = @@len[i]
        while k < l
          return true if @@bx[i &* CAP &+ k] == x && @@by[i &* CAP &+ k] == y
          k = k &+ 1
        end
      end
      i = i &+ 1
    end
    false
  end

  # Standard start: n snakes on shuffled start cells (corners first for up
  # to 4), one food diagonally next to each snake on its side towards the
  # centre, one food in the centre.
  def self.new_game(n : Int32, seed : UInt32) : Bool
    return false unless clear(n)
    Games.seed(seed)
    # shuffle the 4 corners (and the 4 edge middles behind them)
    order = @@order
    k = 0
    while k < 8
      order[k] = k
      k = k &+ 1
    end
    k = 3
    while k > 0
      j = Games.rand_below(k &+ 1)
      t = order[k]
      order[k] = order[j]
      order[j] = t
      k = k &- 1
    end
    i = 0
    c = W.unsafe_div(2)
    while i < @@n
      sx = start_x(order[i])
      sy = start_y(order[i])
      place(i, sx, sy, START)
      @@dir[i] = UP
      # food on the diagonal towards the centre, keeping it off the centre
      fx = sx &+ (sx < c ? 1 : (sx > c ? -1 : (Games.rand_below(2) == 0 ? -1 : 1)))
      fy = sy &+ (sy < c ? 1 : (sy > c ? -1 : (Games.rand_below(2) == 0 ? -1 : 1)))
      add_food(fx, fy)
      i = i &+ 1
    end
    add_food(c, c)
    true
  end

  # ---- one turn ---------------------------------------------------------------

  # moves[i] = UP/DOWN/LEFT/RIGHT, or < 0 = keep going (the last move).
  # Returns true when the game is over.
  def self.step(moves : Int32*) : Bool
    return true if over?
    @@turn = @@turn &+ 1
    # 1. move: every living snake gets a new head, the tail goes
    i = 0
    while i < @@n
      @@ate[i] = 0
      if @@out[i] == ALIVE
        d = moves[i]
        d = @@dir[i] if d < 0 || d > 3
        @@dir[i] = d
        b = i &* CAP
        k = @@len[i] &- 1
        while k > 0
          @@bx[b &+ k] = @@bx[b &+ k &- 1]
          @@by[b &+ k] = @@by[b &+ k &- 1]
          k = k &- 1
        end
        @@bx[b] = @@bx[b] &+ dx(d)
        @@by[b] = @@by[b] &+ dy(d)
        # 2. health
        @@hp[i] = @@hp[i] &- 1
      end
      i = i &+ 1
    end
    # 3. feed
    i = 0
    while i < @@n
      if @@out[i] == ALIVE
        hx = @@bx[i &* CAP]
        hy = @@by[i &* CAP]
        if in_bounds?(hx, hy) && food_at?(hx, hy)
          @@ate[i] = 1
          @@hp[i] = HEALTH
          l = @@len[i]
          if l < CAP
            @@bx[i &* CAP &+ l] = @@bx[i &* CAP &+ l &- 1]
            @@by[i &* CAP &+ l] = @@by[i &* CAP &+ l &- 1]
            @@len[i] = l &+ 1
          end
        end
      end
      i = i &+ 1
    end
    i = 0
    while i < @@n
      remove_food(@@bx[i &* CAP], @@by[i &* CAP]) if @@ate[i] != 0
      i = i &+ 1
    end
    # 4. spawn food
    spawn_food if @@food_on
    # 5. eliminate: out of bounds and starved first
    i = 0
    while i < @@n
      if @@out[i] == ALIVE
        if !in_bounds?(@@bx[i &* CAP], @@by[i &* CAP])
          kill(i, WALL, -1)
        elsif @@hp[i] <= 0
          kill(i, STARVED, -1)
        end
      end
      i = i &+ 1
    end
    # then collisions among the survivors, all decided before any is applied
    cause = @@cause
    who = @@who
    i = 0
    while i < MAX
      cause[i] = 0
      who[i] = -1
      i = i &+ 1
    end
    i = 0
    while i < @@n
      if @@out[i] == ALIVE
        hx = @@bx[i &* CAP]
        hy = @@by[i &* CAP]
        if body_hit?(i, hx, hy)
          cause[i] = SELF
          who[i] = i
        else
          j = 0
          while j < @@n && cause[i] == 0
            if j != i && @@out[j] == ALIVE
              if body_hit?(j, hx, hy)
                cause[i] = BODY
                who[i] = j
              elsif @@bx[j &* CAP] == hx && @@by[j &* CAP] == hy && @@len[i] <= @@len[j]
                cause[i] = HEAD
                who[i] = j
              end
            end
            j = j &+ 1
          end
        end
      end
      i = i &+ 1
    end
    i = 0
    while i < @@n
      kill(i, cause[i], who[i]) if cause[i] != 0
      i = i &+ 1
    end
    over?
  end

  # Does (x, y) hit snake j's body (segments 1.., after this turn's move)?
  def self.body_hit?(j : Int32, x : Int32, y : Int32) : Bool
    b = j &* CAP
    l = @@len[j]
    k = 1
    while k < l
      return true if @@bx[b &+ k] == x && @@by[b &+ k] == y
      k = k &+ 1
    end
    false
  end

  def self.kill(i : Int32, why : Int32, by : Int32) : Nil
    @@out[i] = why
    @@outt[i] = @@turn
    @@by_[i] = by
  end

  def self.remove_food(x : Int32, y : Int32) : Nil
    k = 0
    while k < @@nf
      if @@fx[k] == x && @@fy[k] == y
        @@nf = @@nf &- 1
        @@fx[k] = @@fx[@@nf]
        @@fy[k] = @@fy[@@nf]
        return
      end
      k = k &+ 1
    end
  end

  def self.spawn_food : Nil
    if @@nf < MIN_FOOD
      need = MIN_FOOD &- @@nf
      while need > 0
        break unless place_random_food
        need = need &- 1
      end
    elsif Games.rand_below(100) < FOOD_CHANCE
      place_random_food
    end
  end

  # One food on a random free cell; false if the board is full.
  def self.place_random_food : Bool
    free = 0
    c = 0
    while c < CELLS
      free = free &+ 1 if cell_free?(c)
      c = c &+ 1
    end
    return false if free == 0
    pick = Games.rand_below(free)
    c = 0
    while c < CELLS
      if cell_free?(c)
        if pick == 0
          add_food(c.unsafe_mod(W), c.unsafe_div(W))
          return true
        end
        pick = pick &- 1
      end
      c = c &+ 1
    end
    false
  end

  def self.cell_free?(c : Int32) : Bool
    x = c.unsafe_mod(W)
    y = c.unsafe_div(W)
    !food_at?(x, y) && !snake_at?(x, y)
  end

  # ---- snapshot for the bot API (main/snakes.c turns it into JSON) ---------

  # [turn, n, nfood, (fx, fy) * nfood, then per snake: alive, health, len,
  #  (x, y) * len]. Returns the Int32 count written (at most max).
  def self.snapshot(buf : Int32*, max : Int32) : Int32
    need = 3 &+ @@nf &* 2
    i = 0
    while i < @@n
      need = need &+ 3 &+ @@len[i] &* 2
      i = i &+ 1
    end
    return 0 if need > max
    buf[0] = @@turn
    buf[1] = @@n
    buf[2] = @@nf
    p = 3
    k = 0
    while k < @@nf
      buf[p] = @@fx[k]
      buf[p &+ 1] = @@fy[k]
      p = p &+ 2
      k = k &+ 1
    end
    i = 0
    while i < @@n
      buf[p] = @@out[i] == ALIVE ? 1 : 0
      buf[p &+ 1] = @@hp[i]
      buf[p &+ 2] = @@len[i]
      p = p &+ 3
      k = 0
      while k < @@len[i]
        buf[p] = @@bx[i &* CAP &+ k]
        buf[p &+ 1] = @@by[i &* CAP &+ k]
        p = p &+ 2
        k = k &+ 1
      end
      i = i &+ 1
    end
    p
  end
end
