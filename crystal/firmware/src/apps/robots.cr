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
# Robots: the ones saved in the badge's slots (src/apps/robot_store.cr:
# shell `robot put`, the Settings page) and the ten that ship with
# crystal-robots (src/robots/roster.cr). Line-ups go through all of them;
# shell `robot run a b [c] [d] [@seed]` picks one, and
# `robot challenge <badge> a b [c] [d] [@seed]` plays one with another badge:
# both simulate the same battle (main/robonet.c) and compare results.
# A: next battle (next line-up, next seed). B: skip to the end of this one;
# once it is over, B: TOURNEY.
#
# Tournament (B: TOURNEY, shell `robot tourney [seed] [seeds]`): every
# robot here (slots, then built-ins) in a round robin of 4-robot battles,
# each line-up with several seeds (src/robots/tourney.cr), simulated at full
# speed without drawing (a progress screen with the standings so far), then
# the final of the top four. The standings (points, wins, average damage)
# are saved in NVS (main/robots.c; shell `robot standings`) and shown; A
# replays the final, the only battle drawn.

require "./robot_store"
require "../robots/tourney"

module RobotsApp
  include App
  ORDER = 320
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
  @@seed = 1_u32
  @@limit = 500000
  @@net_id = 0_u32  # badge-to-badge match being played (0: none)
  @@net_done = 0_u32 # its result was handed to robonet
  @@net = false      # show the badge link status line
  @@net_sig = 0_u32
  @@ended = false   # this battle's end was logged and reported
  @@line = Pointer(UInt8).null
  @@frames = 0
  @@n = 0
  @@pick = Pointer(Int32).null  # line-up code per robot (RobotStore)
  @@pool = Pointer(Int32).null  # line-up codes of every robot available
  @@pool_n = 0
  # a line-up asked for by the shell (another task): codes, then the flag
  @@req = Pointer(Int32).null
  @@req_n = 0
  @@req_seed = 0_u32
  @@req_ready = false
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
    @@pool = game_alloc((Roster::COUNT &+ 16) &* 4).as(Int32*)
    @@req = game_alloc(4 &* 4).as(Int32*) if @@req.null?
    @@trail = game_alloc(4 &* TRAIL &* 2 &* 4).as(Int32*)
    @@buf = game_alloc(64)
    @@ok = !@@pick.null? && !@@pool.null? && !@@req.null? && !@@trail.null? && !@@buf.null? && RB.setup
  end

  # The shell's `robot run` (shell task): robot r of the next battle.
  def self.request(r : Int32, code : Int32) : Nil
    @@req = game_alloc(4 &* 4).as(Int32*) if @@req.null?
    @@req[r] = code
  end

  def self.request_run(n : Int32, seed : Int32) : Nil
    @@req_n = n
    @@req_seed = seed.to_u32!
    @@req_limit = RB::CYCLE_LIMIT
    @@req_net = 0_u32
    @@req_ready = true
  end

  @@req_limit = 500000
  @@req_net = 0_u32
  @@mid = 0_u32
  @@mseed = 0_u32
  @@mlimit = 0_u32
  @@mn = 0
  @@midx = Pointer(Int32).null

  # A badge-to-badge match robonet has ready (both sides): play it now.
  def self.take_net_match : Bool
    @@midx = game_alloc(4 &* 4).as(Int32*) if @@midx.null?
    return false if LibIDF.cr_rn_take_match(pointerof(@@mid), pointerof(@@mseed), pointerof(@@mlimit), pointerof(@@mn), @@midx) == 0
    r = 0
    while r < @@mn
      request(r, RobotStore::CODE_NET &+ @@midx[r])
      r = r &+ 1
    end
    @@req_n = @@mn
    @@req_seed = @@mseed
    @@req_limit = @@mlimit.to_i32!
    @@req_net = @@mid
    @@req_ready = true
    true
  end

  # Hand a finished badge-to-badge battle's result to robonet (once).
  def self.report : Nil
    return if @@net_id == 0_u32 || @@net_done == @@net_id || !RB.over?
    @@net_done = @@net_id
    d = @@buf
    r = 0
    while r < @@n
      d[r] = RB.damage(r).to_u8!
      r = r &+ 1
    end
    LibIDF.cr_rn_result(@@net_id, RB.cycles.to_u32!, RB.winner, @@n, d, RB.result_hash)
  end

  # Badge link status line into @@line; its length.
  def self.net_status : Int32
    @@line = game_alloc(64) if @@line.null?
    LibIDF.cr_rn_status(@@line, 64)
    n = 0
    while n < 63 && @@line[n] != 0_u8
      n = n &+ 1
    end
    n
  end

  # Changes of the status line (so the screen follows a challenge).
  def self.net_sig : UInt32
    v = LibIDF.cr_rn_status(@@buf, 64).to_u32!
    h = v &* 31_u32
    i = 0
    while i < 63 && @@buf[i] != 0_u8
      h = (h ^ @@buf[i].to_u32!) &* 16777619_u32
      i = i &+ 1
    end
    h
  end

  # Every robot available: saved slots first, then the built-ins.
  def self.fill_pool : Nil
    @@pool_n = 0
    k = 0
    while k < LibIDF.cr_robot_slots && k < 16
      if LibIDF.cr_robot_len(k) >= 0
        @@pool[@@pool_n] = RobotStore::CODE_SLOT &+ k
        @@pool_n = @@pool_n &+ 1
      end
      k = k &+ 1
    end
    i = 0
    while i < Roster::COUNT
      @@pool[@@pool_n] = i
      @@pool_n = @@pool_n &+ 1
      i = i &+ 1
    end
  end

  # Line-up k: matches of four, then pairs, through the pool.
  def self.lineup(k : Int32) : Nil
    fill_pool
    c = @@pool_n
    if k.unsafe_mod(3) == 2
      @@n = 2
      a = k.unsafe_mod(c)
      b = (k &* 7 &+ 3).unsafe_mod(c)
      b = (b &+ 1).unsafe_mod(c) if b == a
      @@pick[0] = @@pool[a]
      @@pick[1] = @@pool[b]
    else
      @@n = 4
      i = 0
      while i < 4
        @@pick[i] = @@pool[(k &* 3 &+ i).unsafe_mod(c)]
        i = i &+ 1
      end
    end
  end

  def self.new_battle : Nil
    @@net_id = 0_u32
    @@limit = RB::CYCLE_LIMIT
    if @@req_ready
      @@req_ready = false
      @@n = @@req_n
      r = 0
      while r < @@n
        @@pick[r] = @@req[r]
        r = r &+ 1
      end
      @@seed = @@req_seed
      @@limit = @@req_limit
      @@net_id = @@req_net
      @@net = @@net_id != 0_u32
    else
      lineup(@@match)
      @@match = @@match &+ 1
      @@seed = 0_u32
      @@net = false
    end
    @@seed = (millis.to_u32! & 0xFFFF_u32) | 1_u32 if @@seed == 0_u32
    r = 0
    while r < @@n
      RobotStore.load(r, @@pick[r])
      r = r &+ 1
    end
    RB.start(@@n, @@seed.to_u64!, @@limit)
    if @@net_id != 0_u32
      # badge to badge: play it to the end at once and send the result, so
      # the peer is not kept waiting by our e-paper; then replay it to show
      # (the engine is deterministic: the same battle again)
      t0 = millis
      RB.run
      report
      log2("robots: link battle result sent: cycles / sim ms", RB.cycles, millis &- t0)
      RB.start(@@n, @@seed.to_u64!, @@limit)
    end
    @@ended = false
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
  # In the arena (clip = true) everything is clipped to its inside.
  def self.marker(r : Int32, x : Int32, y : Int32, s : Int32, clip : Bool = false) : Nil
    if r == 0
      disc(x, y, s, true, clip)
    elsif r == 1
      disc(x, y, s, true, clip)
      disc(x, y, s.unsafe_div(2), false, clip)
    elsif r == 2
      pbox(x &- s, y &- s, s &* 2 &+ 1, s &* 2 &+ 1, true, clip)
    else
      w = s &* 2 &+ 1
      pbox(x &- s, y &- s, w, 3, true, clip)
      pbox(x &- s, y &+ s &- 2, w, 3, true, clip)
      pbox(x &- s, y &- s, 3, w, true, clip)
      pbox(x &+ s &- 2, y &- s, 3, w, true, clip)
    end
  end

  def self.pbox(x : Int32, y : Int32, w : Int32, h : Int32, black : Bool, clip : Bool) : Nil
    clip ? abox(x, y, w, h, black) : Gfx.box(x, y, w, h, black)
  end

  # Filled disc (as Gfx.disc), optionally clipped to the arena.
  def self.disc(cx : Int32, cy : Int32, r : Int32, black : Bool, clip : Bool) : Nil
    dy = 0 &- r
    while dy <= r
      dx = 0
      while (dx &+ 1) &* (dx &+ 1) &+ dy &* dy <= r &* r
        dx = dx &+ 1
      end
      pbox(cx &- dx, cy &+ dy, dx &* 2 &+ 1, 1, black, clip)
      dy = dy &+ 1
    end
  end

  # A box clipped to the arena (inside its border).
  def self.abox(x : Int32, y : Int32, w : Int32, h : Int32, black : Bool) : Nil
    x1 = x &+ w
    y1 = y &+ h
    x = ARENA_X if x < ARENA_X
    y = ARENA_Y if y < ARENA_Y
    x1 = ARENA_X &+ ARENA if x1 > ARENA_X &+ ARENA
    y1 = ARENA_Y &+ ARENA if y1 > ARENA_Y &+ ARENA
    Gfx.box(x, y, x1 &- x, y1 &- y, black) if x1 > x && y1 > y
  end

  # A square outline s px wide, t px thick, clipped to the arena.
  def self.aframe(x : Int32, y : Int32, s : Int32, t : Int32) : Nil
    abox(x, y, s, t, true)
    abox(x, y &+ s &- t, s, t, true)
    abox(x, y, t, s, true)
    abox(x &+ s &- t, y, t, s, true)
  end

  # A thick line of dots from (x, y) in direction deg, len px.
  def self.ray(x : Int32, y : Int32, deg : Int32, len : Int32, t : Int32) : Nil
    k = 0
    while k <= len
      dx = (RB.lcos(deg).to_i64! &* k).unsafe_div(100000_i64).to_i32!
      dy = (RB.lsin(deg).to_i64! &* k).unsafe_div(100000_i64).to_i32!
      abox(x &+ dx &- t.unsafe_div(2), y &- dy &- t.unsafe_div(2), t, t, true)
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
        abox(@@trail[b] &- 1, @@trail[b &+ 1] &- 1, 3, 3, true) if (k & 1) == 0 || r == 0
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
            aframe(x &- 24, y &- 24, 49, 2) # 40 m damage radius
            abox(x &- 3, y &- 3, 7, 7, true)
          else
            disc(x, y, 4, true, true)
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
        marker(r, x, y, 10, true)
      elsif !RB.failed?(r)
        # wreck: an X
        k = -10
        while k <= 10
          abox(x &+ k &- 1, y &+ k &- 1, 3, 3, true)
          abox(x &+ k &- 1, y &- k &- 1, 3, 3, true)
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
      if nl == 0 && @@pick[r] >= RobotStore::CODE_SLOT
        x = Gfx.text(PANEL_X &+ 34, y, "SLOT ", 3)
        number(x, y, @@pick[r] &- RobotStore::CODE_SLOT, 3)
      elsif nl == 0
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
    # three lines fit under four robots (the panel ends at 672)
    y = ARENA_Y &+ 4 &* h &+ 4
    x = Gfx.text(PANEL_X, y, "CYCLE ", 2)
    number(x, y, RB.cycles, 2)
    x = Gfx.text(PANEL_X &+ 200, y &+ 4, "SEED ", 1)
    number(x, y &+ 4, (@@seed & 0x7FFFFFFF_u32).to_i32!, 1)
    if RB.over?
      Gfx.text(PANEL_X, y &+ 22, win >= 0 ? "BATTLE OVER" : "DRAW", 2)
    end
    if @@net # badge link: "<peer> got the same result", up to two lines
      n = net_status
      draw_bytes(PANEL_X, y &+ 44, @@line, n > 52 ? 52 : n, EPD::BLACK, 1)
      draw_bytes(PANEL_X, y &+ 54, @@line + 52_i64, n &- 52, EPD::BLACK, 1) if n > 52
    end
  end

  def self.draw : Nil
    EPD.fill(EPD::WHITE)
    if @@tmode == T_FINAL
      TopBar.draw("ROBOTS: FINAL", "", "", "A: TABLE", @@running ? "B: TO END" : "B: EXIT")
    else
      TopBar.draw("ROBOTS", "", "", "A: NEXT", @@running ? "B: TO END" : "B: TOURNEY")
    end
    draw_arena
    draw_panel
  end

  # ---- tournament ------------------------------------------------------------
  T_OFF   = 0
  T_SIM   = 1 # simulating the battles
  T_TABLE = 2 # standings on screen
  T_FINAL = 3 # the final, replayed
  T_SLICE = 1500 # ms of battles per main loop pass
  T_DRAW  = 6000 # ms between progress screens

  @@tmode = T_OFF
  @@treq = false
  @@treq_seed = 0_u32
  @@treq_seeds = 3
  @@tcodes = Pointer(Int32).null # line-up code of each tournament robot
  @@tidx = Pointer(Int32).null
  @@tdrawn = 0
  @@tt0 = 0
  @@tblob = Pointer(UInt8).null

  # Shell `robot tourney [seed] [seeds]` (shell task): start one when the app runs.
  def self.request_tourney(seed : UInt32, seeds : Int32) : Nil
    @@treq_seed = seed
    @@treq_seeds = seeds
    @@treq = true
  end

  def self.tourney_alloc : Bool
    @@tcodes = game_alloc(Tour::MAX &* 4).as(Int32*) if @@tcodes.null?
    @@tidx = game_alloc(4 &* 4).as(Int32*) if @@tidx.null?
    @@tblob = game_alloc(Tour.blob_size(Tour::MAX)) if @@tblob.null?
    !@@tcodes.null? && !@@tidx.null? && !@@tblob.null? && Tour.alloc
  end

  def self.tourney_start(seed : UInt32, seeds : Int32) : Nil
    return unless tourney_alloc
    fill_pool
    n = @@pool_n < Tour::MAX ? @@pool_n : Tour::MAX
    k = 0
    while k < n
      @@tcodes[k] = @@pool[k]
      k = k &+ 1
    end
    seed = ((millis.to_u32! &* 2654435761_u32) & 0x7FFFFFFF_u32) | 1_u32 if seed == 0_u32
    return unless Tour.setup(n, seed, seeds)
    @@running = false
    @@tmode = T_SIM
    @@tt0 = millis
    log2("robots: tournament: robots / battles", n, Tour.battles)
    draw_progress
    Apps.show_clean
    @@tdrawn = millis
  end

  # Load tournament robots idx[0, m] as battle robots; names on first sight.
  def self.tourney_load(m : Int32, idx : Int32*) : Nil
    r = 0
    while r < m
      i = idx[r]
      c = @@tcodes[i]
      RobotStore.load(r, c)
      @@pick[r] = c
      if Tour.name_len(i) == 0
        if RC.name_len(r) > 0
          Tour.set_name(i, RC.name(r), RC.name_len(r))
        elsif c >= RobotStore::CODE_SLOT && c < RobotStore::CODE_NET
          @@buf[0] = 0x53_u8; @@buf[1] = 0x4C_u8; @@buf[2] = 0x4F_u8; @@buf[3] = 0x54_u8; @@buf[4] = 0x20_u8 # "SLOT "
          Tour.set_name(i, @@buf, 5 &+ put_decimal(@@buf + 5_i64, c &- RobotStore::CODE_SLOT))
        elsif c < RobotStore::CODE_SLOT
          Tour.set_name(i, Roster.file(c))
        end
      end
      r = r &+ 1
    end
    @@n = m
  end

  # One battle (or the final) of the tournament; true when it is all done.
  def self.tourney_battle : Bool
    k = Tour.done
    if k < Tour.battles
      m = Tour.lineup(k, @@tidx)
      tourney_load(m, @@tidx)
      RB.start(m, Tour.seed_of(k).to_u64!, RB::CYCLE_LIMIT)
      RB.run
      Tour.record(m, @@tidx)
      return false
    end
    m = Tour.final_lineup(@@tidx)
    tourney_load(m, @@tidx)
    RB.start(m, Tour.final_seed.to_u64!, RB::CYCLE_LIMIT)
    RB.run
    Tour.record_final(m, @@tidx)
    log2("robots: tournament done: battles / s", Tour.done &+ 1, (millis &- @@tt0).unsafe_div(1000))
    n = Tour.save(@@tblob, 0)
    LibIDF.cr_robot_tbl_save(0, @@tblob, n)
    true
  end

  # Replay the final on screen (the engine is deterministic).
  def self.tourney_final : Nil
    m = Tour.finalists
    k = 0
    while k < m
      @@tidx[k] = Tour.finalist(k)
      k = k &+ 1
    end
    tourney_load(m, @@tidx)
    @@seed = Tour.final_seed
    @@limit = RB::CYCLE_LIMIT
    @@net_id = 0_u32
    @@net = false
    RB.start(m, @@seed.to_u64!, @@limit)
    @@ended = false
    @@trail_n = 0
    @@ms = 0
    @@running = true
    @@tmode = T_FINAL
    remember
  end

  def self.rnum(xr : Int32, y : Int32, v : Int32, scale : Int32) : Nil
    n = put_decimal(@@buf, v)
    draw_bytes(xr &- n &* 6 &* scale, y, @@buf, n, EPD::BLACK, scale)
  end

  # Standings from rank `from`, `rows` per column, two columns.
  def self.draw_table(y0 : Int32, rows : Int32) : Nil
    col = 0
    while col < 2 && col &* rows < Tour.robots
      x = 24 &+ col &* 472
      y = y0
      Gfx.text(x, y, "  # ROBOT", 2)
      Gfx.text(x &+ 228, y, "PTS   W   D   P DMG", 2)
      Gfx.box(x, y &+ 18, 456, 2, true)
      y = y &+ 26
      r = 0
      while r < rows
        k = col &* rows &+ r
        break if k >= Tour.robots
        i = Tour.at_rank(k)
        rnum(x &+ 36, y, k &+ 1, 2)
        nl = Tour.name_len(i)
        draw_bytes(x &+ 48, y, Tour.name(i), nl > 14 ? 14 : nl, EPD::BLACK, 2)
        Gfx.box(x &+ 40, y &+ 6, 4, 4, true) if i == Tour.champion && Tour.final_done?
        rnum(x &+ 264, y, Tour.points(i), 2)
        rnum(x &+ 312, y, Tour.wins(i), 2)
        rnum(x &+ 360, y, Tour.draws(i), 2)
        rnum(x &+ 408, y, Tour.played(i), 2)
        rnum(x &+ 456, y, Tour.avg_damage(i), 2)
        y = y &+ 22
        r = r &+ 1
      end
      col = col &+ 1
    end
  end

  def self.tourney_head(title : String) : Int32
    Gfx.text(24, 62, title, 3)
    y = 96
    x = number(24, y, Tour.robots, 2)
    x = Gfx.text(x, y, " ROBOTS, ", 2)
    x = number(x, y, Tour.battles, 2)
    x = Gfx.text(x, y, " BATTLES + FINAL, ", 2)
    x = number(x, y, Tour.seeds, 2)
    x = Gfx.text(x, y, " PER LINE-UP, SEED ", 2)
    number(x, y, (Tour.seed & 0x7FFFFFFF_u32).to_i32!, 2)
    y &+ 26
  end

  def self.draw_progress : Nil
    EPD.fill(EPD::WHITE)
    TopBar.draw("ROBOTS: TOURNAMENT", "", "", "", "B: STOP")
    y = tourney_head("TOURNAMENT RUNNING")
    x = Gfx.text(24, y, "BATTLE ", 2)
    x = number(x, y, Tour.done, 2)
    x = Gfx.text(x, y, " OF ", 2)
    number(x, y, Tour.battles, 2)
    Gfx.frame(300, y &- 2, 636, 20, 2)
    w = Tour.battles > 0 ? (630 &* Tour.done).unsafe_div(Tour.battles) : 0
    Gfx.box(303, y &+ 1, w, 14, true)
    draw_table(y &+ 34, 21)
  end

  def self.draw_standings : Nil
    EPD.fill(EPD::WHITE)
    TopBar.draw("ROBOTS: TOURNAMENT", "", "", "A: FINAL", "B: EXIT")
    y = tourney_head("TOURNAMENT STANDINGS")
    c = Tour.champion
    x = Gfx.text(24, y, "CHAMPION ", 2)
    if c >= 0
      nl = Tour.name_len(c)
      x = draw_bytes(x, y, Tour.name(c), nl, EPD::BLACK, 2)
      Gfx.text(x, y, Tour.final_winner >= 0 ? " (WON THE FINAL)" : " (FINAL DRAWN: TOP OF THE TABLE)", 2)
    end
    draw_table(y &+ 30, 21)
    Gfx.text(24, 650, "PTS: 3 A WIN (LAST ONE STANDING), 1 A DRAW (ALIVE AT THE CYCLE LIMIT). DMG: AVERAGE DAMAGE", 1)
  end

  # Tournament screens' tick (T_SIM, T_TABLE); T_FINAL runs as a battle.
  def self.tourney_tick(now : Int32, inp : LibGames::Input) : Nil
    if @@tmode == T_SIM
      if Games.pressed?(inp, Games::BTN_B)
        @@tmode = T_OFF
        new_battle
        draw
        Apps.show_clean
        return
      end
      t0 = millis
      while millis &- t0 < T_SLICE
        return if Apps.leaving?
        if tourney_battle
          @@tmode = T_TABLE
          draw_standings
          Apps.show_clean
          return
        end
      end
      if millis &- @@tdrawn >= T_DRAW
        draw_progress
        Apps.show
        @@tdrawn = millis
      end
    elsif Games.pressed?(inp, Games::BTN_A)
      tourney_final
      @@frames = 0
      draw
      Apps.show_clean
    elsif Games.pressed?(inp, Games::BTN_B)
      @@tmode = T_OFF
      new_battle
      draw
      Apps.show_clean
    end
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
    take_net_match
    if @@treq && !@@req_ready
      @@treq = false
      tourney_start(@@treq_seed, @@treq_seeds)
      return if @@tmode == T_SIM
    end
    if @@tmode == T_SIM || @@tmode == T_TABLE
      @@tmode = T_TABLE if @@tmode == T_SIM && Tour.final_done?
      @@tmode == T_SIM ? draw_progress : draw_standings
      Apps.show_clean
      @@tdrawn = millis
      return
    end
    @@tmode = T_OFF if @@req_ready
    new_battle if RB.robots == 0 || @@req_ready
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
    take_net_match
    @@tmode = T_OFF if @@req_ready # a requested battle (shell, badge link) comes first
    if @@treq
      @@treq = false
      tourney_start(@@treq_seed, @@treq_seeds)
      return
    end
    if @@tmode == T_SIM || @@tmode == T_TABLE
      tourney_tick(now, inp)
      return
    end
    if @@tmode == T_FINAL && (Games.pressed?(inp, Games::BTN_A) || (Games.pressed?(inp, Games::BTN_B) && !@@running))
      if Games.pressed?(inp, Games::BTN_A)
        @@tmode = T_TABLE
        draw_standings
      else
        @@tmode = T_OFF
        new_battle
        draw
      end
      Apps.show_clean
      return
    end
    if !@@running && @@tmode == T_OFF && Games.pressed?(inp, Games::BTN_B)
      tourney_start(0_u32, 3)
      return
    end
    if @@net && !@@running # follow the badge link status (challenge, result check)
      s = net_sig
      if s != @@net_sig
        @@net_sig = s
        changed = true
      end
    end
    if Games.pressed?(inp, Games::BTN_A) || @@req_ready
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
    if RB.over? && !@@ended
      @@ended = true
      log2("robots: battle over: cycles / sim ms", RB.cycles, @@ms)
      report
      @@net_sig = net_sig
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
