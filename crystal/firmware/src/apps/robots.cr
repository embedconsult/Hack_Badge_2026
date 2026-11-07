# ROBOTS: CROBOTS-style robot battles in the crystal-robots language
# (https://jkridner.beagleboard.io/crystal-robots/). The engine is
# src/robots/ (parser, checker, bytecode VM, battlefield), host-tested to
# play every match exactly like upstream crystal-robots, so a robot written
# on the website fights the same way here, and a battle with the same robots
# in the same order and the same seed is the same battle everywhere.
#
# The battle runs at full speed in the main task and the panel shows it
# every FRAME_UPDATES motion updates (one differential refresh, ~0.65 s;
# a clean refresh every CLEAN_EVERY frames). Trails show where each robot
# has been since the last few frames.
#
# Robots: the ten that ship with crystal-robots (src/robots/roster.cr).
# A: next battle (next line-up, next seed). B: skip to the end of this one.

require "../robots/battle"
require "../robots/roster"

module RobotsApp
  include App
  ORDER = 310
  NAME  = "ROBOTS"
  COLOR = 0xFF2020_u32

  CLEAN_EVERY   = 12
  FRAME_UPDATES = 40  # motion updates (600 CROBOTS cycles) per frame
  ARENA_X       = 16  # 600 x 600 px arena = 1000 x 1000 m
  ARENA_Y       = 60
  ARENA         = 600
  PANEL_X       = 640
  TRAIL         = 24  # positions kept per robot

  @@ok = false
  @@tried = false
  @@running = false
  @@match = 0 # line-ups played
  @@seed = 1
  @@frames = 0
  @@n = 0
  @@pick = Pointer(Int32).null  # roster index per slot
  @@trail = Pointer(Int32).null # per robot TRAIL (x, y) pairs, px
  @@trail_n = 0
  @@ms = 0 # simulation time of this battle, ms
  @@buf = Pointer(UInt8).null

  # Two robots facing off, a missile between them.
  def self.icon(x : Int32, y : Int32) : Nil
    Gfx.tile(x, y)
    Gfx.disc(x &+ 44, y &+ 110, 18, false)
    Gfx.box(x &+ 40, y &+ 70, 8, 26, false) # turret up
    Gfx.box(x &+ 98, y &+ 34, 34, 34, false)
    Gfx.box(x &+ 106, y &+ 42, 18, 18, true)
    Gfx.disc(x &+ 80, y &+ 72, 6, false)
    Gfx.frame(x &+ 60, y &+ 52, 40, 40, 3, false) # blast ring
  end

  def self.setup : Bool
    return @@ok if @@tried
    @@tried = true
    @@pick = game_alloc(4 &* 4).as(Int32*)
    @@trail = game_alloc(4 &* TRAIL &* 2 &* 4).as(Int32*)
    @@buf = game_alloc(64)
    @@ok = !@@pick.null? && !@@trail.null? && !@@buf.null? && RB.setup
  end

  # Line-up k: matches of four, then pairs, through the roster.
  def self.lineup(k : Int32) : Nil
    c = Roster::COUNT
    if k.unsafe_mod(3) == 2
      @@n = 2
      @@pick[0] = k.unsafe_mod(c)
      @@pick[1] = (k &* 7 &+ 3).unsafe_mod(c)
      @@pick[1] = (@@pick[1] &+ 1).unsafe_mod(c) if @@pick[1] == @@pick[0]
    else
      @@n = 4
      i = 0
      while i < 4
        @@pick[i] = (k &* 3 &+ i).unsafe_mod(c)
        i = i &+ 1
      end
    end
  end

  def self.new_battle : Nil
    lineup(@@match)
    @@match = @@match &+ 1
    @@seed = (millis.to_u32! & 0xFFFF_u32).to_i32! | 1
    r = 0
    while r < @@n
      s = Roster.source(@@pick[r])
      RB.load(r, s.to_unsafe, s.bytesize)
      r = r &+ 1
    end
    RB.start(@@n, @@seed.to_u64!, RB::CYCLE_LIMIT)
    @@trail_n = 0
    @@ms = 0
    @@running = true
    remember
  end

  # ---- coordinates -----------------------------------------------------------
  def self.px(x_click : Int32) : Int32
    ARENA_X &+ (x_click.to_i64! &* ARENA).unsafe_div(10000_i64).to_i32!
  end

  def self.py(y_click : Int32) : Int32
    ARENA_Y &+ ARENA &- (y_click.to_i64! &* ARENA).unsafe_div(10000_i64).to_i32!
  end

  def self.remember : Nil
    if @@trail_n == TRAIL # drop the oldest
      r = 0
      while r < 4
        k = 0
        while k < TRAIL &- 1
          b = (r &* TRAIL &+ k) &* 2
          @@trail[b] = @@trail[b &+ 2]
          @@trail[b &+ 1] = @@trail[b &+ 3]
          k = k &+ 1
        end
        r = r &+ 1
      end
      @@trail_n = TRAIL &- 1
    end
    r = 0
    while r < @@n
      b = (r &* TRAIL &+ @@trail_n) &* 2
      @@trail[b] = px(RB.x(r))
      @@trail[b &+ 1] = py(RB.y(r))
      r = r &+ 1
    end
    @@trail_n = @@trail_n &+ 1
  end

  # ---- drawing -------------------------------------------------------------
  # Robot marker r (0 disc, 1 ring, 2 square, 3 hollow square) at (x, y).
  def self.marker(r : Int32, x : Int32, y : Int32, s : Int32) : Nil
    if r == 0
      Gfx.disc(x, y, s, true)
    elsif r == 1
      Gfx.disc(x, y, s, true)
      Gfx.disc(x, y, s.unsafe_div(2), false)
    elsif r == 2
      Gfx.box(x &- s, y &- s, s &* 2 &+ 1, s &* 2 &+ 1, true)
    else
      Gfx.frame(x &- s, y &- s, s &* 2 &+ 1, s &* 2 &+ 1, 3)
    end
  end

  # A thick line of dots from (x, y) in direction deg, len px.
  def self.ray(x : Int32, y : Int32, deg : Int32, len : Int32, t : Int32) : Nil
    k = 0
    while k <= len
      dx = (RB.lcos(deg).to_i64! &* k).unsafe_div(100000_i64).to_i32!
      dy = (RB.lsin(deg).to_i64! &* k).unsafe_div(100000_i64).to_i32!
      Gfx.box(x &+ dx &- t.unsafe_div(2), y &- dy &- t.unsafe_div(2), t, t, true)
      k = k &+ 2
    end
  end

  def self.draw_arena : Nil
    Gfx.frame(ARENA_X &- 4, ARENA_Y &- 4, ARENA &+ 9, ARENA &+ 9, 3)
    # trails
    r = 0
    while r < @@n
      k = 0
      while k < @@trail_n &- 1
        b = (r &* TRAIL &+ k) &* 2
        Gfx.box(@@trail[b] &- 1, @@trail[b &+ 1] &- 1, 3, 3, true) if (k & 1) == 0 || r == 0
        k = k &+ 1
      end
      r = r &+ 1
    end
    # missiles and blasts
    r = 0
    while r < @@n
      k = 0
      while k < RB::MIS_ROBOT
        st = RB.missile_state(r, k)
        if st != RB::AVAIL
          x = px(RB.missile_x(r, k))
          y = py(RB.missile_y(r, k))
          if st == RB::EXPLODING
            Gfx.frame(x &- 24, y &- 24, 49, 49, 2) # 40 m damage radius
            Gfx.box(x &- 3, y &- 3, 7, 7, true)
          else
            Gfx.disc(x, y, 4, true)
          end
        end
        k = k &+ 1
      end
      r = r &+ 1
    end
    # robots: marker, heading, last scan direction
    r = 0
    while r < @@n
      x = px(RB.x(r))
      y = py(RB.y(r))
      if RB.active?(r)
        ray(x, y, RB.scan_dir(r), 30, 1)
        ray(x, y, RB.heading(r), 18, 4)
        marker(r, x, y, 10)
      elsif !RB.failed?(r)
        # wreck: an X
        k = -10
        while k <= 10
          Gfx.box(x &+ k &- 1, y &+ k &- 1, 3, 3, true)
          Gfx.box(x &+ k &- 1, y &- k &- 1, 3, 3, true)
          k = k &+ 1
        end
      end
      r = r &+ 1
    end
  end

  def self.number(x : Int32, y : Int32, v : Int32, scale : Int32) : Int32
    n = put_decimal(@@buf, v)
    draw_bytes(x, y, @@buf, n, EPD::BLACK, scale)
  end

  def self.draw_panel : Nil
    h = 132
    win = RB.over? ? RB.winner : -1
    r = 0
    while r < @@n
      y = ARENA_Y &+ r &* h
      marker(r, PANEL_X &+ 12, y &+ 12, 10)
      nm = RC.name(r)
      nl = RC.name_len(r)
      if nl == 0
        Gfx.text(PANEL_X &+ 34, y, Roster.file(@@pick[r]), 3)
      else
        draw_bytes(PANEL_X &+ 34, y, nm, nl > 12 ? 12 : nl, EPD::BLACK, 3)
      end
      # damage bar
      Gfx.frame(PANEL_X, y &+ 32, 200, 18, 2)
      d = RB.damage(r)
      Gfx.box(PANEL_X &+ 3, y &+ 35, (194 &* d).unsafe_div(100), 12, true)
      x = number(PANEL_X &+ 210, y &+ 34, d, 2)
      Gfx.text(x, y &+ 34, "%", 2)
      # state
      st = RB.failed?(r) ? "FAILED" : (r == win ? "WINNER" : (RB.active?(r) ? "" : "DESTROYED"))
      Gfx.text(PANEL_X, y &+ 58, st, 2)
      if RB.failed?(r) && RB.msg_len(r) > 0
        m = RB.msg(r)
        n = RB.msg_len(r)
        draw_bytes(PANEL_X, y &+ 80, m, n > 50 ? 50 : n, EPD::BLACK, 1)
        draw_bytes(PANEL_X, y &+ 90, m + 50_i64, n > 100 ? 50 : n &- 50, EPD::BLACK, 1) if n > 50
      elsif RB.out_len(r) > 0
        Gfx.text(PANEL_X, y &+ 82, "puts", 1)
        n = RB.out_len(r)
        draw_bytes(PANEL_X &+ 30, y &+ 82, RB.out(r), n > 44 ? 44 : n, EPD::BLACK, 1)
      end
      r = r &+ 1
    end
    y = ARENA_Y &+ 4 &* h &+ 8
    x = Gfx.text(PANEL_X, y, "CYCLE ", 2)
    number(x, y, RB.cycles, 2)
    x = Gfx.text(PANEL_X, y &+ 24, "SEED ", 2)
    number(x, y &+ 24, @@seed, 2)
    if RB.over?
      Gfx.text(PANEL_X, y &+ 48, win >= 0 ? "BATTLE OVER" : "DRAW", 2)
    end
  end

  def self.draw : Nil
    EPD.fill(EPD::WHITE)
    TopBar.draw("ROBOTS", "", "", "A: NEXT", @@running ? "B: TO END" : "")
    draw_arena
    draw_panel
  end

  # ---- app -------------------------------------------------------------------
  def self.enter : Nil
    unless setup
      EPD.fill(EPD::WHITE)
      TopBar.draw("ROBOTS", "", "", "", "")
      Gfx.text_c(EPD::WIDTH.unsafe_div(2), 300, "OUT OF MEMORY", 4)
      Apps.show_clean
      return
    end
    new_battle unless RB.robots > 0
    @@frames = 0
    draw
    Apps.show_clean
  end

  # Run the battle up to the next frame; true when there is something new.
  def self.advance(updates : Int32) : Bool
    return false unless @@running
    t0 = millis
    k = 0
    while k < updates && RB.update
      k = k &+ 1
    end
    @@ms = @@ms &+ (millis &- t0)
    @@running = false if RB.over?
    remember
    true
  end

  def self.tick(now : Int32, inp : LibGames::Input) : Nil
    return unless @@ok
    changed = false
    if Games.pressed?(inp, Games::BTN_A)
      new_battle
      @@frames = CLEAN_EVERY # new scene: clean refresh
      changed = true
    elsif Games.pressed?(inp, Games::BTN_B) && @@running
      while RB.update
        return if Apps.leaving?
      end
      @@running = false
      remember
      changed = true
    elsif @@running
      changed = advance(FRAME_UPDATES)
    end
    return unless changed
    if RB.over?
      log2("robots: battle over: cycles / sim ms", RB.cycles, @@ms)
    end
    draw
    @@frames = @@frames &+ 1
    if @@frames >= CLEAN_EVERY
      @@frames = 0
      Apps.show_clean
    else
      Apps.show
    end
  end
end
