# The SNAKES house snake: the built-in player, so the arena works with no
# bots at all and gives bots something to beat. Per turn it scores the
# four moves:
#   - out of bounds or into a body that will still be there: never;
#   - next to the head of a snake as long or longer (a lost or drawn
#     head-to-head): heavy penalty; next to a shorter one: small bonus;
#   - flood fill from the new head: room smaller than its own length is a
#     trap (heavy penalty, less heavy the more room there is);
#   - when hungry (health < 50, or not longer than the longest rival):
#     closer to the nearest food is better (BFS distance);
#   - a pinch of centre preference, then a random tie-break.
# Pure Crystal like rules.cr (host specs: test/snakes_spec.cr).

require "./snakes_rules"

module SnakeHouse
  N = SnakeRules::CELLS

  @@occ = Pointer(UInt8).null # 1 = blocked next turn
  @@seen = Pointer(UInt8).null
  @@q = Pointer(Int32).null

  def self.alloc : Bool
    return true unless @@occ.null?
    @@occ = game_alloc(N)
    @@seen = game_alloc(N)
    @@q = game_alloc(N &* 4).as(Int32*)
    !@@occ.null? && !@@seen.null? && !@@q.null?
  end

  # Cells that will be blocked after everyone moves: every body segment
  # but the tails that move away (a stacked tail, i.e. a snake that just
  # ate or is still at the start, stays).
  def self.mark : Nil
    k = 0
    while k < N
      @@occ[k] = 0_u8
      k = k &+ 1
    end
    i = 0
    n = SnakeRules.count
    while i < n
      if SnakeRules.alive?(i)
        l = SnakeRules.length(i)
        last = l &- 1
        tail_moves = l >= 2 && (SnakeRules.x(i, last) != SnakeRules.x(i, last &- 1) || SnakeRules.y(i, last) != SnakeRules.y(i, last &- 1))
        k = 0
        while k < l
          unless k == last && tail_moves
            x = SnakeRules.x(i, k)
            y = SnakeRules.y(i, k)
            @@occ[y &* SnakeRules::W &+ x] = 1_u8 if SnakeRules.in_bounds?(x, y)
          end
          k = k &+ 1
        end
      end
      i = i &+ 1
    end
  end

  # Free cells reachable from c (c itself counted), up to limit.
  def self.room(c : Int32, limit : Int32) : Int32
    k = 0
    while k < N
      @@seen[k] = @@occ[k]
      k = k &+ 1
    end
    @@seen[c] = 1_u8
    @@q[0] = c
    h = 0
    t = 1
    while h < t && t < limit
      v = @@q[h]
      h = h &+ 1
      d = 0
      while d < 4
        x = v.unsafe_mod(SnakeRules::W) &+ SnakeRules.dx(d)
        y = v.unsafe_div(SnakeRules::W) &+ SnakeRules.dy(d)
        if SnakeRules.in_bounds?(x, y)
          w = y &* SnakeRules::W &+ x
          if @@seen[w] == 0_u8
            @@seen[w] = 1_u8
            @@q[t] = w
            t = t &+ 1
          end
        end
        d = d &+ 1
      end
    end
    t
  end

  # BFS steps from c to the nearest food over free cells, or -1.
  def self.food_dist(c : Int32) : Int32
    return -1 if SnakeRules.food_count == 0
    k = 0
    while k < N
      @@seen[k] = @@occ[k]
      k = k &+ 1
    end
    @@seen[c] = 1_u8
    @@q[0] = c
    # distance packed into the queue entry: cell + N * dist
    h = 0
    t = 1
    while h < t
      e = @@q[h]
      h = h &+ 1
      v = e.unsafe_mod(N)
      dist = e.unsafe_div(N)
      return dist if SnakeRules.food_at?(v.unsafe_mod(SnakeRules::W), v.unsafe_div(SnakeRules::W))
      d = 0
      while d < 4
        x = v.unsafe_mod(SnakeRules::W) &+ SnakeRules.dx(d)
        y = v.unsafe_div(SnakeRules::W) &+ SnakeRules.dy(d)
        if SnakeRules.in_bounds?(x, y)
          w = y &* SnakeRules::W &+ x
          if @@seen[w] == 0_u8 && t < N
            @@seen[w] = 1_u8
            @@q[t] = w &+ N &* (dist &+ 1)
            t = t &+ 1
          end
        end
        d = d &+ 1
      end
    end
    -1
  end

  # A bot's missed move: its last direction when that is safe (on the
  # board, no body, room to fit), else the house snake's choice.
  def self.fallback(me : Int32) : Int32
    return SnakeRules.last_dir(me) unless alloc
    mark
    d = SnakeRules.last_dir(me)
    x = SnakeRules.x(me, 0) &+ SnakeRules.dx(d)
    y = SnakeRules.y(me, 0) &+ SnakeRules.dy(d)
    if SnakeRules.in_bounds?(x, y)
      c = y &* SnakeRules::W &+ x
      l = SnakeRules.length(me)
      return d if @@occ[c] == 0_u8 && room(c, l &+ 1) >= l
    end
    choose(me)
  end

  # The move for snake me (SnakeRules::UP..RIGHT).
  def self.choose(me : Int32) : Int32
    return SnakeRules::UP unless alloc
    mark
    hx = SnakeRules.x(me, 0)
    hy = SnakeRules.y(me, 0)
    mylen = SnakeRules.length(me)
    longest = 0
    i = 0
    while i < SnakeRules.count
      longest = SnakeRules.length(i) if i != me && SnakeRules.alive?(i) && SnakeRules.length(i) > longest
      i = i &+ 1
    end
    hungry = SnakeRules.health(me) < 50 || mylen <= longest &+ 1
    best = -1
    best_score = -2_000_000_000
    d = 0
    while d < 4
      x = hx &+ SnakeRules.dx(d)
      y = hy &+ SnakeRules.dy(d)
      if SnakeRules.in_bounds?(x, y) && @@occ[y &* SnakeRules::W &+ x] == 0_u8
        c = y &* SnakeRules::W &+ x
        s = 0
        # heads of rivals next to the target cell
        j = 0
        while j < SnakeRules.count
          if j != me && SnakeRules.alive?(j)
            ex = SnakeRules.x(j, 0) &- x
            ey = SnakeRules.y(j, 0) &- y
            ex = 0 &- ex if ex < 0
            ey = 0 &- ey if ey < 0
            if ex &+ ey == 1
              s = SnakeRules.length(j) >= mylen ? s &- 5000 : s &+ 50
            end
          end
          j = j &+ 1
        end
        r = room(c, mylen &* 2 &+ 2)
        s = r < mylen ? s &- 20_000 &+ r &* 100 : s &+ r &* 2
        if hungry
          fd = food_dist(c)
          s = s &+ (fd < 0 ? 0 : (40 &- fd) &* 20)
        end
        cx = x &- 5
        cy = y &- 5
        cx = 0 &- cx if cx < 0
        cy = 0 &- cy if cy < 0
        s = s &- cx &- cy
        s = s &+ Games.rand_below(3)
        if s > best_score
          best_score = s
          best = d
        end
      end
      d = d &+ 1
    end
    # no safe move: keep going (lose like a bot that times out)
    best < 0 ? SnakeRules.last_dir(me) : best
  end
end
