# Classic snake on a 40x28 grid of 24 px cells. Walls kill unless `wrap`.
# Body is a ring buffer of cell indices (head at @@head) plus an occupancy
# map for O(1) self-hit checks.
#
# Controls: User A = turn left, User B = turn right (relative), or the left
# knob's quadrant as an absolute direction (up/right/down/left clockwise),
# applied when the quadrant changes. Right knob = speed. After game over,
# User A or B restarts.
#
# Rendering is black-only (fast refresh): body cells filled, food a hollow
# square, game over = thick frame around the panel and an X on the head.

require "./common"

module Snake
  CELL  = 24
  COLS  = 40
  ROWS  = 28
  MAX   = 1120 # COLS * ROWS
  START =    4

  RIGHT = 0
  DOWN  = 1
  LEFT  = 2
  UP    = 3

  MIN_INTERVAL = 300  # ms per step, right knob at 1
  MAX_INTERVAL = 1500 # right knob at 0
  KNOB_HYST    =  128 # Q12 margin into a quadrant before it counts

  @@body = Pointer(UInt16).null
  @@occ = Pointer(UInt8).null
  @@head = 0 # ring index of the head
  @@len = 0
  @@dir = RIGHT
  @@food = 0
  @@over = false
  @@won = false
  @@score = 0
  @@wrap = true
  @@last = 0
  @@started = false
  @@quad = -1

  def self.score : Int32
    @@score
  end

  def self.over? : Bool
    @@over
  end

  def self.won? : Bool
    @@won
  end

  def self.length : Int32
    @@len
  end

  def self.dir : Int32
    @@dir
  end

  def self.food : Int32
    @@food
  end

  def self.wrap? : Bool
    @@wrap
  end

  # Cell index of the i-th segment (0 = head).
  def self.segment(i : Int32) : Int32
    j = @@head &- i
    j = j &+ MAX if j < 0
    @@body[j].to_i32!
  end

  def self.head : Int32
    segment(0)
  end

  def self.occupied?(c : Int32) : Bool
    @@occ[c] != 0_u8
  end

  def self.init(wrap : Bool = true) : Bool
    @@wrap = wrap
    if @@body.null?
      @@body = game_alloc(MAX &* 2).as(UInt16*)
      @@occ = game_alloc(MAX)
      return false if @@body.null? || @@occ.null?
    end
    restart
    true
  end

  def self.resync : Nil
    @@started = false
    @@quad = -1
  end

  def self.restart : Nil
    Games.zero(@@occ, MAX)
    @@len = 0
    @@head = MAX &- 1
    @@dir = RIGHT
    @@over = false
    @@won = false
    @@score = 0
    y = ROWS.unsafe_div(2)
    x = COLS.unsafe_div(2) &- START
    i = 0
    while i < START
      push(y &* COLS &+ x &+ i)
      i = i &+ 1
    end
    place_food
  end

  def self.push(c : Int32) : Nil
    @@head = @@head &+ 1
    @@head = 0 if @@head == MAX
    @@body[@@head] = c.to_u16!
    @@occ[c] = 1_u8
    @@len = @@len &+ 1
  end

  # Put food on a random free cell (test hook: set_food).
  def self.place_food : Nil
    if @@len >= MAX
      @@food = -1
      return
    end
    c = Games.rand_below(MAX)
    while @@occ[c] != 0_u8
      c = c &+ 1
      c = 0 if c == MAX
    end
    @@food = c
  end

  def self.set_food(c : Int32) : Nil
    @@food = c
  end

  # Change direction unless it would reverse onto the neck.
  def self.set_dir(d : Int32) : Nil
    d = d & 3
    return if d == ((@@dir &+ 2) & 3)
    @@dir = d
  end

  def self.turn_left : Nil
    @@dir = (@@dir &+ 3) & 3
  end

  def self.turn_right : Nil
    @@dir = (@@dir &+ 1) & 3
  end

  # One move. Returns false once the game is over.
  def self.step : Bool
    return false if @@over
    h = head
    x = h.unsafe_mod(COLS)
    y = h.unsafe_div(COLS)
    if @@dir == RIGHT
      x = x &+ 1
    elsif @@dir == DOWN
      y = y &+ 1
    elsif @@dir == LEFT
      x = x &- 1
    else
      y = y &- 1
    end
    if x < 0 || y < 0 || x >= COLS || y >= ROWS
      unless @@wrap
        @@over = true
        return false
      end
      x = COLS &- 1 if x < 0
      x = 0 if x >= COLS
      y = ROWS &- 1 if y < 0
      y = 0 if y >= ROWS
    end
    n = y &* COLS &+ x
    grow = n == @@food
    tail = segment(@@len &- 1)
    # Moving into the tail's cell is fine unless growing (it moves away).
    if @@occ[n] != 0_u8 && (grow || n != tail)
      @@over = true
      return false
    end
    unless grow
      @@occ[tail] = 0_u8
      @@len = @@len &- 1
    end
    push(n)
    if grow
      @@score = @@score &+ 1
      place_food
      if @@food < 0
        @@won = true
        @@over = true
        return false
      end
    end
    true
  end

  # true = something changed on screen.
  def self.tick(now : Int32, inp : LibGames::Input) : Bool
    unless @@started
      @@started = true
      @@last = now
      @@quad = -1
    end
    if @@over
      if Games.pressed?(inp, Games::BTN_A | Games::BTN_B)
        restart
        @@last = now
        return true
      end
      return false
    end
    turn_left if Games.pressed?(inp, Games::BTN_A)
    turn_right if Games.pressed?(inp, Games::BTN_B)

    # Absolute direction from the left knob quadrant, with hysteresis.
    k = Games.knob_left(inp)
    q = (k &* 4).unsafe_div(Games::KNOB_ONE &+ 1)
    off = k &- q &* Games::KNOB_ONE.unsafe_div(4)
    inside = off >= KNOB_HYST && off <= Games::KNOB_ONE.unsafe_div(4) &- KNOB_HYST
    if @@quad < 0
      @@quad = q
    elsif q != @@quad && inside
      @@quad = q
      set_dir((q &+ 3) & 3) # quadrants clockwise: up, right, down, left
    end

    interval = MAX_INTERVAL &- ((MAX_INTERVAL &- MIN_INTERVAL) &* Games.knob_right(inp)).unsafe_div(Games::KNOB_ONE)
    return false if now &- @@last < interval
    @@last = now
    step
    true
  end

  def self.render(black : UInt8*, red : UInt8*) : Nil
    Games.clear(black, red)
    i = 0
    while i < @@len
      c = segment(i)
      Games.fill_rect(black, c.unsafe_mod(COLS) &* CELL &+ 1, c.unsafe_div(COLS) &* CELL &+ 1, CELL &- 2, CELL &- 2)
      i = i &+ 1
    end
    if @@food >= 0
      Games.rect_outline(black, @@food.unsafe_mod(COLS) &* CELL &+ 3, @@food.unsafe_div(COLS) &* CELL &+ 3, CELL &- 6, CELL &- 6, 3)
    end
    if @@over
      Games.rect_outline(black, 0, 0, Games::W, Games::H, 8)
      h = head
      hx = h.unsafe_mod(COLS) &* CELL
      hy = h.unsafe_div(COLS) &* CELL
      # Clear the head cell and draw an X in it.
      j = 0
      while j < CELL
        k = 0
        while k < CELL
          on = (j &- k <= 1 && k &- j <= 1) || (j &+ k >= CELL &- 2 && j &+ k <= CELL)
          idx = (hy &+ j) &* Games::ROW_BYTES &+ (hx &+ k).unsafe_shr(3)
          m = 0x80_u8.unsafe_shr((hx &+ k) & 7)
          black[idx] = on ? (black[idx] | m) : (black[idx] & (m ^ 0xFF_u8))
          k = k &+ 1
        end
        j = j &+ 1
      end
    end
  end
end
