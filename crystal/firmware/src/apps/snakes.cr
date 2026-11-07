# SNAKES: a bot arena. Snake bots written by anyone, in any language, play
# each other (and the built-in house snake) on an 11x11 board, refereed
# by the badge. Bots are HTTP servers speaking the open snake-bot move
# API (GET /, POST /start, /move, /end), so existing bots work by URL;
# see crystal/net/snakes/README.md and the example bot there.
#
#   shell: snakes add <name> <url> | snakes list | snakes rm <name|#> | snakes play
#
# Lobby: the saved bots (checked with GET / on entry), A: play, B: how
# many house snakes join (0..4). Up to 4 snakes play: the house snakes,
# then the saved bots in list order. In a game, every turn the badge asks
# all living bots at once (500 ms deadline; no answer = keep going), moves
# the house snakes, applies the standard rules (src/games/snakes_rules.cr)
# and redraws the board with one differential update. A: pause, B: stop.
#
# Black only (red needs the ~33 s slow waveform). The network side is C:
# main/snakes_net.c (worker task, NVS) and main/snakes.c (JSON, HTTP).

require "../games/snakes_house"

lib LibIDF
  fun cr_snk_cmd(line : UInt8*, n : Int32) : Int32
  fun cr_snk_bots : Int32
  fun cr_snk_bot_name(i : Int32) : UInt8*
  fun cr_snk_bot_url(i : Int32) : UInt8*
  fun cr_snk_bot_state(i : Int32) : Int32 # 0 unknown, 1 checking, 2 online, 3 offline
  fun cr_snk_bot_ms(i : Int32) : Int32
  fun cr_snk_bot_author(i : Int32) : UInt8*
  fun cr_snk_sig : UInt32
  fun cr_snk_net : Int32 # 0 ok, 1 joining the Wi-Fi, 2 no Wi-Fi
  fun cr_snk_busy : Int32
  fun cr_snk_ping : Void
  fun cr_snk_begin(n : Int32, who : Int32*, seed : UInt32, snap : Int32*, nsnap : Int32) : Void
  fun cr_snk_turn(snap : Int32*, nsnap : Int32) : Void
  fun cr_snk_end(snap : Int32*, nsnap : Int32) : Void
  fun cr_snk_move(i : Int32) : Int32
  fun cr_snk_err(i : Int32) : Int32
  fun cr_snk_ms(i : Int32) : Int32
  fun cr_snk_misses(i : Int32) : Int32
  fun cr_snk_name(i : Int32) : UInt8*
  fun cr_snk_shout(i : Int32) : UInt8*
  fun cr_snk_err_name(e : Int32) : UInt8*
  fun esp_random : UInt32
end

module SnakesApp
  include App
  ORDER = 310
  NAME  = "SNAKES"
  COLOR = 0x40FF40_u32

  alias R = SnakeRules

  # board: 11 x 52 px cells, below the top bar; side panel on the right
  CELL  =  52
  BX    =  24
  BY    =  80
  SIDE  = 632
  CLEAN_EVERY = 60 # turns between clean refreshes (ghosting)
  SNAP_MAX = 1024

  ST_LOBBY = 0
  ST_START = 1 # waiting for /start
  ST_TURN  = 2 # waiting for the bots' moves
  ST_OVER  = 3

  @@state = ST_LOBBY
  @@houses = -1 # -1: not chosen yet (2 with no bots saved, else 1)
  @@who = Pointer(Int32).null  # entry -> -1 house, else saved bot index
  @@moves = Pointer(Int32).null
  @@snap = Pointer(Int32).null
  @@nsnap = 0
  @@n = 0
  @@bots_in = false # any bot in this game
  @@paused = false
  @@stopped = false
  @@since_clean = 0
  @@sig = 0_u32
  @@drawn = 0
  @@msg = 0 # lobby message: 0 none, 1 no Wi-Fi, 2 no entrants
  @@play_req = false
  @@buf = Pointer(UInt8).null

  # Shell `snakes play` (shell task): start a game as soon as the app runs.
  def self.request_play : Nil
    @@play_req = true
  end

  def self.alloc : Bool
    if @@who.null?
      @@who = game_alloc(R::MAX &* 4).as(Int32*)
      @@moves = game_alloc(R::MAX &* 4).as(Int32*)
      @@snap = game_alloc(SNAP_MAX &* 4).as(Int32*)
      @@buf = game_alloc(64)
    end
    !@@who.null? && !@@moves.null? && !@@snap.null? && !@@buf.null?
  end

  # ---- drawing helpers --------------------------------------------------

  def self.cstr_len(p : UInt8*) : Int32
    n = 0
    while p[n] != 0_u8
      n = n &+ 1
    end
    n
  end

  def self.cstr(x : Int32, y : Int32, p : UInt8*, max : Int32, scale : Int32) : Int32
    n = cstr_len(p)
    n = max if n > max
    Gfx.bytes(x, y, p, n, scale)
  end

  def self.num(x : Int32, y : Int32, v : Int32, scale : Int32) : Int32
    n = put_decimal(@@buf, v < 0 ? 0 : v)
    Gfx.bytes(x, y, @@buf, n, scale)
  end

  # Pattern fill: 0 solid, 1 checker, 2 diagonal stripes, 3 dots.
  def self.pat(x0 : Int32, y0 : Int32, w : Int32, h : Int32, style : Int32) : Nil
    if style == 0
      Gfx.box(x0, y0, w, h, true)
      return
    end
    p = EPD.black
    y = y0
    while y < y0 &+ h
      x = x0
      while x < x0 &+ w
        on = if style == 1
               ((x.unsafe_shr(2) ^ y.unsafe_shr(2)) & 1) == 0
             elsif style == 2
               (x &+ y).unsafe_mod(10) < 5
             else
               x.unsafe_mod(6) < 3 && y.unsafe_mod(6) < 3
             end
        if on
          i = y &* EPD::ROW_BYTES &+ x.unsafe_shr(3)
          p[i] = p[i] | (0x80_u8.unsafe_shr(x & 7))
        end
        x = x &+ 1
      end
      y = y &+ 1
    end
  end

  def self.cx(x : Int32) : Int32
    BX &+ x &* CELL
  end

  # API y is up; screen rows go down
  def self.cy(y : Int32) : Int32
    BY &+ (R::H &- 1 &- y) &* CELL
  end

  def self.draw_board : Nil
    w = R::W &* CELL
    Gfx.frame(BX &- 6, BY &- 6, w &+ 12, w &+ 12, 4)
    # grid dots at the cell corners
    y = 1
    while y < R::H
      x = 1
      while x < R::W
        Gfx.box(BX &+ x &* CELL &- 1, BY &+ y &* CELL &- 1, 3, 3, true)
        x = x &+ 1
      end
      y = y &+ 1
    end
    k = 0
    while k < R.food_count
      fx = cx(R.food_x(k)) &+ CELL.unsafe_div(2)
      fy = cy(R.food_y(k)) &+ CELL.unsafe_div(2)
      Gfx.disc(fx, fy, 12, true)
      Gfx.disc(fx, fy, 5, false)
      Gfx.box(fx &- 1, fy &- 20, 3, 8, true) # stalk
      k = k &+ 1
    end
    i = 0
    while i < R.count
      draw_snake(i) if R.alive?(i)
      i = i &+ 1
    end
  end

  def self.draw_snake(i : Int32) : Nil
    l = R.length(i)
    ins = 7
    k = l &- 1
    while k >= 1
      x = R.x(i, k)
      y = R.y(i, k)
      if R.in_bounds?(x, y)
        pat(cx(x) &+ ins, cy(y) &+ ins, CELL &- 2 &* ins, CELL &- 2 &* ins, i)
        # bridge towards the previous segment
        px = R.x(i, k &- 1)
        py = R.y(i, k &- 1)
        if R.in_bounds?(px, py) && (px != x || py != y)
          bx = px > x ? cx(x) &+ CELL &- ins : (px < x ? cx(x) &- ins : cx(x) &+ ins)
          byy = py > y ? cy(y) &- ins : (py < y ? cy(y) &+ CELL &- ins : cy(y) &+ ins)
          bw = px != x ? 2 &* ins : CELL &- 2 &* ins
          bh = py != y ? 2 &* ins : CELL &- 2 &* ins
          pat(bx, byy, bw, bh, i)
        end
      end
      k = k &- 1
    end
    hx = R.x(i, 0)
    hy = R.y(i, 0)
    return unless R.in_bounds?(hx, hy)
    Gfx.box(cx(hx) &+ 3, cy(hy) &+ 3, CELL &- 6, CELL &- 6, true)
    @@buf[0] = (0x31 &+ i).to_u8!
    Gfx.bytes(cx(hx) &+ (CELL &- 19).unsafe_div(2), cy(hy) &+ (CELL &- 28).unsafe_div(2), @@buf, 1, 4, false)
  end

  def self.title_bar : Nil
    if @@state == ST_LOBBY
      b = @@houses == 0 ? "B: NO HOUSE" : (@@houses == 1 ? "B: 1 HOUSE" : (@@houses == 2 ? "B: 2 HOUSES" : (@@houses == 3 ? "B: 3 HOUSES" : "B: 4 HOUSES")))
      TopBar.draw(NAME, "", "", "A: PLAY", b)
    elsif @@state == ST_OVER
      TopBar.draw(NAME, "", "", "A: AGAIN", "B: LOBBY")
    else
      TopBar.draw(NAME, "", "", @@paused ? "A: GO ON" : "A: PAUSE", "B: STOP")
    end
  end

  def self.cause_word(c : Int32) : String
    c == R::WALL ? "WALL" : (c == R::STARVED ? "STARVED" : (c == R::SELF ? "BIT ITSELF" : (c == R::BODY ? "HIT A BODY" : "HEAD-ON")))
  end

  # One snake's card in the side panel (rows y .. y+128).
  def self.card(i : Int32, y : Int32) : Nil
    x = SIDE
    if R.alive?(i)
      pat(x, y &+ 4, 40, 40, i)
    else
      Gfx.frame(x, y &+ 4, 40, 40, 3)
    end
    Gfx.box(x &+ 8, y &+ 12, 24, 24, false)
    @@buf[0] = (0x31 &+ i).to_u8!
    Gfx.bytes(x &+ 12, y &+ 14, @@buf, 1, 3)
    cstr(x &+ 52, y &+ 6, LibIDF.cr_snk_name(i), 15, cstr_len(LibIDF.cr_snk_name(i)) > 12 ? 2 : 3)
    house = @@who[i] < 0
    yy = y &+ 50
    if R.alive?(i)
      xx = Gfx.text(x, yy, "LEN ", 2)
      xx = num(xx, yy, R.length(i), 2)
      Gfx.text(xx &+ 12, yy, "HP", 2)
      Gfx.frame(x &+ 168, yy &- 1, 140, 16, 2)
      Gfx.box(x &+ 171, yy &+ 2, (134 &* R.health(i)).unsafe_div(100), 10, true)
    else
      xx = Gfx.text(x, yy, "OUT T", 2)
      xx = num(xx, yy, R.out_turn(i), 2)
      Gfx.text(xx &+ 12, yy, cause_word(R.cause(i)), 2)
    end
    yy = yy &+ 24
    if house
      Gfx.text(x, yy, "HOUSE SNAKE", 2)
    else
      e = LibIDF.cr_snk_err(i)
      if e == 0
        xx = num(x, yy, LibIDF.cr_snk_ms(i), 2)
        xx = Gfx.text(xx, yy, " MS", 2)
      else
        xx = cstr(x, yy, LibIDF.cr_snk_err_name(e), 14, 2)
      end
      m = LibIDF.cr_snk_misses(i)
      if m > 0
        xx = Gfx.text(xx &+ 12, yy, "MISSED ", 2)
        num(xx, yy, m, 2)
      end
      cstr(x, yy &+ 22, LibIDF.cr_snk_shout(i), 26, 2)
    end
  end

  def self.draw_game : Nil
    EPD.fill(EPD::WHITE)
    title_bar
    draw_board
    xx = Gfx.text(SIDE, 64, "TURN ", 3)
    num(xx, 64, R.turn, 3)
    if @@state == ST_START
      Gfx.text(SIDE, 100, LibIDF.cr_snk_net == 1 ? "JOINING WI-FI..." : "STARTING...", 2)
    elsif @@paused
      Gfx.text(SIDE, 100, "PAUSED", 2)
    end
    if @@state == ST_OVER
      draw_result
      return
    end
    i = 0
    while i < @@n
      card(i, 128 &+ i &* 134)
      i = i &+ 1
    end
  end

  def self.draw_result : Nil
    w = R.winner
    y = 110
    if @@stopped
      Gfx.text(SIDE, y, "STOPPED", 4)
    elsif w < 0
      Gfx.text(SIDE, y, "DRAW", 4)
    else
      Gfx.text(SIDE, y, "WINNER", 4)
      y = y &+ 40
      cstr(SIDE, y, LibIDF.cr_snk_name(w), 15, 3)
    end
    y = y &+ 50
    # everyone, longest-lasting first: alive (longest first), then by turn out
    mask = 0
    place = 1
    while place <= @@n
      best = 0
      bt = -1
      i = 0
      while i < @@n
        if (mask & 1.unsafe_shl(i)) == 0
          t = R.alive?(i) ? 100_000 &+ R.length(i) : R.out_turn(i)
          if t > bt
            bt = t
            best = i
          end
        end
        i = i &+ 1
      end
      mask = mask | 1.unsafe_shl(best)
      result_row(place, best, y)
      y = y &+ 96
      place = place &+ 1
    end
  end

  # "1. NAME" then "LEN 7, OUT T45 WALL" / "LEN 7, ALIVE", and misses
  def self.result_row(place : Int32, i : Int32, y : Int32) : Nil
    xx = num(SIDE, y, place, 3)
    xx = Gfx.text(xx, y, ".", 3)
    if R.alive?(i)
      pat(xx &+ 8, y &- 2, 26, 26, i)
    else
      Gfx.frame(xx &+ 8, y &- 2, 26, 26, 3)
    end
    cstr(xx &+ 46, y, LibIDF.cr_snk_name(i), 15, cstr_len(LibIDF.cr_snk_name(i)) > 10 ? 2 : 3)
    yy = y &+ 32
    xx = Gfx.text(SIDE, yy, "LEN ", 2)
    xx = num(xx, yy, R.length(i), 2)
    if R.alive?(i)
      Gfx.text(xx &+ 12, yy, "ALIVE", 2)
    else
      xx = Gfx.text(xx &+ 12, yy, "OUT T", 2)
      xx = num(xx, yy, R.out_turn(i), 2)
      Gfx.text(xx &+ 12, yy, cause_word(R.cause(i)), 2)
    end
    yy = yy &+ 22
    if @@who[i] < 0
      Gfx.text(SIDE, yy, "HOUSE SNAKE", 2)
    else
      xx = Gfx.text(SIDE, yy, "MISSED MOVES ", 2)
      num(xx, yy, LibIDF.cr_snk_misses(i), 2)
    end
  end

  def self.draw_lobby : Nil
    EPD.fill(EPD::WHITE)
    title_bar
    Gfx.text(40, 70, "BOT ARENA", 5)
    Gfx.text(40, 116, "SNAKE BOTS OVER HTTP, 11X11, LAST ONE STANDING WINS", 2)
    nb = LibIDF.cr_snk_bots
    y = 160
    xx = Gfx.text(40, y, "PLAYERS: ", 3)
    xx = num(xx, y, entrants, 3)
    Gfx.text(xx, y, " OF 4", 3)
    y = y &+ 44
    i = 0
    while i < nb
      s = LibIDF.cr_snk_bot_state(i)
      playing = i < 4 &- @@houses
      Gfx.frame(40, y, 24, 24, 3)
      Gfx.box(46, y &+ 6, 12, 12, true) if playing
      cstr(80, y, LibIDF.cr_snk_bot_name(i), 15, 3)
      xx = 380
      if s == 1
        Gfx.text(xx, y &+ 4, "CHECKING...", 2)
      elsif s == 2
        xx = Gfx.text(xx, y &+ 4, "ONLINE ", 2)
        xx = num(xx, y &+ 4, LibIDF.cr_snk_bot_ms(i), 2)
        xx = Gfx.text(xx, y &+ 4, " MS ", 2)
        cstr(xx &+ 12, y &+ 4, LibIDF.cr_snk_bot_author(i), 20, 2)
      elsif s == 3
        Gfx.text(xx, y &+ 4, "NO ANSWER", 2)
      end
      cstr(80, y &+ 28, LibIDF.cr_snk_bot_url(i), 60, 1)
      y = y &+ 48
      i = i &+ 1
    end
    if @@houses > 0
      Gfx.frame(40, y, 24, 24, 3)
      Gfx.box(46, y &+ 6, 12, 12, true)
      xx = Gfx.text(80, y, "HOUSE SNAKE X", 3)
      num(xx, y, @@houses, 3)
      Gfx.text(380, y &+ 4, "BUILT IN", 2)
      y = y &+ 48
    end
    if nb == 0
      Gfx.text(40, y &+ 10, "NO BOTS SAVED YET: HOUSE SNAKES PLAY EACH OTHER.", 2)
    end
    net = LibIDF.cr_snk_net
    if @@msg == 1 || net == 2
      Gfx.text(40, 520, "COULD NOT JOIN THE WI-FI (SHELL: WIFI <SSID> <PASSWORD>)", 2)
    elsif @@msg == 2
      Gfx.text(40, 520, "NOBODY TO PLAY: B ADDS HOUSE SNAKES", 2)
    elsif net == 1
      Gfx.text(40, 520, "JOINING THE WI-FI...", 2)
    end
    Gfx.box(40, 552, 880, 2, true)
    Gfx.text(40, 566, "ADD A BOT (USB SHELL): SNAKES ADD <NAME> HTTP://<IP>:<PORT>", 2)
    Gfx.text(40, 592, "BOT API: GET /  POST /START /MOVE /END (THE OPEN SNAKE BOT API)", 2)
    Gfx.text(40, 618, "EXAMPLE BOT + HOW-TO: CRYSTAL/NET/SNAKES/ IN THE BADGE REPO", 2)
    @@sig = LibIDF.cr_snk_sig
    @@drawn = millis
  end

  # ---- game flow ----------------------------------------------------------

  def self.entrants : Int32
    nb = LibIDF.cr_snk_bots
    b = 4 &- @@houses
    b = nb if b > nb
    @@houses &+ b
  end

  def self.start : Nil
    return unless alloc
    @@houses = LibIDF.cr_snk_bots == 0 ? 2 : 1 if @@houses < 0
    nb = LibIDF.cr_snk_bots
    @@n = 0
    @@bots_in = false
    h = 0
    while h < @@houses && @@n < R::MAX
      @@who[@@n] = -1
      @@n = @@n &+ 1
      h = h &+ 1
    end
    b = 0
    while b < nb && @@n < R::MAX
      @@who[@@n] = b
      @@n = @@n &+ 1
      @@bots_in = true
      b = b &+ 1
    end
    if @@n == 0
      @@msg = 2
      draw_lobby
      Apps.show
      return
    end
    seed = LibIDF.esp_random
    R.food_on = true
    R.new_game(@@n, seed)
    @@nsnap = R.snapshot(@@snap, SNAP_MAX)
    LibIDF.cr_snk_begin(@@n, @@who, seed, @@snap, @@nsnap)
    @@state = ST_START
    @@paused = false
    @@stopped = false
    @@msg = 0
    @@since_clean = 0
    draw_game
    Apps.show_clean
  end

  # Moves are in (or no bots): apply them, ask for the next turn, redraw.
  def self.advance : Nil
    i = 0
    while i < @@n
      @@moves[i] = R.alive?(i) ? (@@who[i] < 0 ? SnakeHouse.choose(i) : LibIDF.cr_snk_move(i)) : -1
      i = i &+ 1
    end
    R.step(@@moves)
    @@nsnap = R.snapshot(@@snap, SNAP_MAX)
    if R.over? || R.turn >= 2000
      finish
      return
    end
    LibIDF.cr_snk_turn(@@snap, @@nsnap) # the bots think while the panel updates
    draw_game
    @@since_clean = @@since_clean &+ 1
    if @@since_clean >= CLEAN_EVERY
      @@since_clean = 0
      Apps.show_clean
    else
      Apps.show
    end
  end

  def self.finish : Nil
    LibIDF.cr_snk_end(@@snap, @@nsnap)
    @@state = ST_OVER
    draw_game
    Apps.show
  end

  def self.lobby : Nil
    @@state = ST_LOBBY
    LibIDF.cr_snk_ping
    draw_lobby
    Apps.show_clean
  end

  # ---- App ----------------------------------------------------------------

  # A snake chasing an apple on the tile.
  def self.icon(x : Int32, y : Int32) : Nil
    Gfx.tile(x, y)
    k = 0
    while k < 5
      Gfx.box(x &+ 24 &+ k &* 22, y &+ 96, 18, 18, false)
      k = k &+ 1
    end
    Gfx.box(x &+ 24, y &+ 74, 18, 22, false)
    Gfx.box(x &+ 24, y &+ 52, 18, 18, false)
    Gfx.box(x &+ 46, y &+ 52, 22, 18, false)
    Gfx.box(x &+ 68, y &+ 44, 26, 26, false) # head
    Gfx.box(x &+ 84, y &+ 50, 5, 5, true)    # eye
    Gfx.disc(x &+ 122, y &+ 56, 13, false)   # apple
    Gfx.box(x &+ 121, y &+ 36, 3, 8, false)
  end

  def self.enter : Nil
    alloc
    @@houses = LibIDF.cr_snk_bots == 0 ? 2 : 1 if @@houses < 0
    if @@play_req
      @@play_req = false
      @@state = ST_LOBBY
      start
      return
    end
    lobby
  end

  def self.leave : Nil
    LibIDF.cr_snk_end(@@snap, @@nsnap) if @@state == ST_START || @@state == ST_TURN
    @@state = ST_LOBBY
  end

  def self.tick(now : Int32, inp : LibGames::Input) : Nil
    a = Games.pressed?(inp, Games::BTN_A)
    b = Games.pressed?(inp, Games::BTN_B)
    if @@play_req
      @@play_req = false
      if @@state == ST_START || @@state == ST_TURN
        LibIDF.cr_snk_end(@@snap, @@nsnap)
      end
      start
      return
    end
    busy = LibIDF.cr_snk_busy != 0
    if @@state == ST_LOBBY
      if a && !busy
        start
      elsif b
        @@houses = @@houses >= 4 ? 0 : @@houses &+ 1
        @@msg = 0
        draw_lobby
        Apps.show
      elsif LibIDF.cr_snk_sig != @@sig && now &- @@drawn >= 1000
        draw_lobby
        Apps.show
      end
    elsif @@state == ST_START
      if b
        stop
      elsif !busy
        if @@bots_in && LibIDF.cr_snk_net == 2
          @@msg = 1
          LibIDF.cr_snk_end(@@snap, @@nsnap)
          @@state = ST_LOBBY
          draw_lobby
          Apps.show
        else
          @@state = ST_TURN
          LibIDF.cr_snk_turn(@@snap, @@nsnap)
        end
      end
    elsif @@state == ST_TURN
      if b
        stop
      elsif a
        @@paused = !@@paused
        draw_game
        Apps.show
      elsif !busy && !@@paused
        advance
      end
    elsif @@state == ST_OVER
      if a
        start
      elsif b
        lobby
      end
    end
  end

  def self.stop : Nil
    @@stopped = true
    finish
  end
end
