# Robot battle: the resumable bytecode VM (one CROBOTS cycle per step) and
# the CROBOTS battlefield of crystal-robots (Jason Kridner, GPL-2.0;
# src/battle/field.cr and src/battle/step_robot.cr there, after Tom
# Poindexter's CROBOTS, 1985). Prelude-free: fixed arrays from game_alloc,
# module state, no exceptions.
#
# Field rules (CROBOTS units): 1000 x 1000 m, positions in clicks (10/m),
# 0 deg east, 90 north, (0,0) lower left. Robots run one charged cycle each
# in turn; every MOTION_CYCLES rounds robots and missiles move. A match ends
# with one robot left or at the cycle limit (then missiles still in flight
# land). Everything is deterministic for a given seed and robot order: the
# same robots and seed give the same match as upstream's Field#run_stepwise
# (checked by test/robots_spec.cr), so two badges that exchange sources and
# a seed see the same battle.

require "./compile"
require "./trig"

lib LibRM
  fun atan(x : Float64) : Float64
  fun sin(x : Float64) : Float64
  fun cos(x : Float64) : Float64
  fun tan(x : Float64) : Float64
  fun sqrt(x : Float64) : Float64
end

module RB
  MAX_ROBOTS    = RC::MAX_ROBOTS
  CLICK         = 10
  MAX_X         = 1000
  MAX_Y         = 1000
  MOTION_CYCLES = 15
  CYCLE_LIMIT   = 500000
  ROBOT_SPEED   = 7
  TURN_SPEED    = 50
  ACCEL         = 10
  MIS_SPEED     = 500
  MIS_RANGE     = 700
  MIS_ROBOT     = 2
  RELOAD        = 15
  EXP_COUNT     = 5
  COLLISION     = 2
  RES_LIMIT     = 10
  RAD_DEG       = 57.29578
  PI            = 3.141592653589793
  MAX_ERRORS    = 10
  MAX_CALL_DEPTH = 200

  STACK_MAX = 4096
  FRAME_MAX = MAX_CALL_DEPTH + 8
  SLOT_MAX  = 8192
  MSG_MAX   = 96

  STR_TAG = 1_i64.unsafe_shl(40)
  UNDEF   = -9223372036854775807_i64 &- 1

  # missile states
  AVAIL     = 0
  FLYING    = 1
  EXPLODING = 2

  # step outcomes
  CHARGED   = 0
  COMPLETED = 1
  FAILED    = 2

  @@ready = false
  @@n = 0 # robots in the match

  # ---- VM state, per robot ---------------------------------------------------
  @@loaded = Pointer(Int32).null # 1 = program compiled
  @@pc = Pointer(Int32).null
  @@sp = Pointer(Int32).null
  @@fd = Pointer(Int32).null
  @@slot_top = Pointer(Int32).null
  @@pending = Pointer(Int32).null
  @@defer = Pointer(Int32).null
  @@need_start = Pointer(Int32).null
  @@inited = Pointer(Int32).null
  @@errors = Pointer(Int32).null
  @@restarts = Pointer(Int32).null
  @@cycles = Pointer(Int32).null
  @@stack = Pointer(Int64).null
  @@fr_ret = Pointer(Int32).null
  @@fr_sp = Pointer(Int32).null
  @@fr_slot = Pointer(Int32).null
  @@fr_sym = Pointer(Int32).null
  @@fr_last = Pointer(Int64).null
  @@slots = Pointer(Int64).null
  @@gval = Pointer(Int64).null # globals per sym, UNDEF = not declared
  @@cval = Pointer(Int64).null # constants per sym
  @@msg = Pointer(UInt8).null # last runtime error / load error
  @@msg_len = Pointer(Int32).null
  @@failed = Pointer(Int32).null # 1 = load error or too many runtime errors
  @@out = Pointer(UInt8).null # last puts line
  @@out_len = Pointer(Int32).null
  @@outs = Pointer(Int32).null # puts and notes so far

  # ---- field state, per robot ------------------------------------------------
  @@active = Pointer(Int32).null
  @@x = Pointer(Int32).null
  @@y = Pointer(Int32).null
  @@org_x = Pointer(Int32).null
  @@org_y = Pointer(Int32).null
  @@range = Pointer(Int32).null
  @@speed = Pointer(Int32).null
  @@accel = Pointer(Int32).null
  @@d_speed = Pointer(Int32).null
  @@heading = Pointer(Int32).null
  @@d_heading = Pointer(Int32).null
  @@damage = Pointer(Int32).null
  @@scan = Pointer(Int32).null
  @@reload = Pointer(Int32).null
  @@cannon_dir = Pointer(Int32).null
  @@fired = Pointer(Int32).null
  # missiles, per robot * MIS_ROBOT
  @@m_stat = Pointer(Int32).null
  @@m_beg_x = Pointer(Int32).null
  @@m_beg_y = Pointer(Int32).null
  @@m_cur_x = Pointer(Int32).null
  @@m_cur_y = Pointer(Int32).null
  @@m_head = Pointer(Int32).null
  @@m_count = Pointer(Int32).null
  @@m_rang = Pointer(Int32).null
  @@m_dist = Pointer(Int32).null

  # ---- match state ---------------------------------------------------------------
  @@rng_state = 0_u64
  @@rng_inc = 0_u64
  @@c = 0      # cycles so far (motion updates * MOTION_CYCLES)
  @@limit = CYCLE_LIMIT
  @@updates = 0
  @@guard = 0
  @@phase = 0 # 0 not started, 1 fighting, 2 missiles landing, 3 over
  @@event = false
  @@movement = MOTION_CYCLES

  def self.i32s(n : Int32) : Int32*
    game_alloc(n &* 4).as(Int32*)
  end

  def self.setup : Bool
    return true if @@ready
    return false unless RC.setup
    m = MAX_ROBOTS
    @@loaded = i32s(m); @@pc = i32s(m); @@sp = i32s(m); @@fd = i32s(m); @@slot_top = i32s(m)
    @@pending = i32s(m); @@defer = i32s(m); @@need_start = i32s(m); @@inited = i32s(m)
    @@errors = i32s(m); @@restarts = i32s(m); @@cycles = i32s(m)
    @@stack = game_alloc(m &* STACK_MAX &* 8).as(Int64*)
    @@fr_ret = i32s(m &* FRAME_MAX); @@fr_sp = i32s(m &* FRAME_MAX)
    @@fr_slot = i32s(m &* FRAME_MAX); @@fr_sym = i32s(m &* FRAME_MAX)
    @@fr_last = game_alloc(m &* FRAME_MAX &* 8).as(Int64*)
    @@slots = game_alloc(m &* SLOT_MAX &* 8).as(Int64*)
    @@gval = game_alloc(m &* RC::SYM_MAX &* 8).as(Int64*)
    @@cval = game_alloc(m &* RC::SYM_MAX &* 8).as(Int64*)
    @@msg = game_alloc(m &* (MSG_MAX &+ 1))
    @@msg_len = i32s(m); @@failed = i32s(m)
    @@out = game_alloc(m &* (MSG_MAX &+ 1))
    @@out_len = i32s(m); @@outs = i32s(m)
    @@active = i32s(m); @@x = i32s(m); @@y = i32s(m); @@org_x = i32s(m); @@org_y = i32s(m)
    @@range = i32s(m); @@speed = i32s(m); @@accel = i32s(m); @@d_speed = i32s(m)
    @@heading = i32s(m); @@d_heading = i32s(m); @@damage = i32s(m); @@scan = i32s(m)
    @@reload = i32s(m); @@cannon_dir = i32s(m); @@fired = i32s(m)
    k = m &* MIS_ROBOT
    @@m_stat = i32s(k); @@m_beg_x = i32s(k); @@m_beg_y = i32s(k); @@m_cur_x = i32s(k)
    @@m_cur_y = i32s(k); @@m_head = i32s(k); @@m_count = i32s(k); @@m_rang = i32s(k)
    @@m_dist = i32s(k)
    return false if @@stack.null? || @@slots.null? || @@fr_last.null? || @@gval.null? ||
                    @@cval.null? || @@msg.null? || @@out.null? || @@m_dist.null? ||
                    @@fr_sym.null? || @@fired.null?
    @@ready = true
  end

  # ---- accessors -----------------------------------------------------------------
  def self.robots : Int32
    @@n
  end

  def self.active?(r : Int32) : Bool
    @@active[r] != 0
  end

  def self.failed?(r : Int32) : Bool
    @@failed[r] != 0
  end

  def self.x(r : Int32) : Int32
    @@x[r]
  end

  def self.y(r : Int32) : Int32
    @@y[r]
  end

  def self.heading(r : Int32) : Int32
    @@heading[r]
  end

  def self.speed(r : Int32) : Int32
    @@speed[r]
  end

  def self.damage(r : Int32) : Int32
    @@damage[r]
  end

  def self.scan_dir(r : Int32) : Int32
    @@scan[r]
  end

  def self.cannon_dir(r : Int32) : Int32
    @@cannon_dir[r]
  end

  def self.fired?(r : Int32) : Bool
    @@fired[r] != 0
  end

  def self.restarts(r : Int32) : Int32
    @@restarts[r]
  end

  def self.robot_cycles(r : Int32) : Int32
    @@cycles[r]
  end

  def self.errors(r : Int32) : Int32
    @@errors[r]
  end

  def self.msg(r : Int32) : UInt8*
    @@msg + (r &* (MSG_MAX &+ 1)).to_i64!
  end

  def self.msg_len(r : Int32) : Int32
    @@msg_len[r]
  end

  def self.out(r : Int32) : UInt8*
    @@out + (r &* (MSG_MAX &+ 1)).to_i64!
  end

  def self.out_len(r : Int32) : Int32
    @@out_len[r]
  end

  def self.outs(r : Int32) : Int32
    @@outs[r]
  end

  def self.missile_state(r : Int32, k : Int32) : Int32
    @@m_stat[r &* MIS_ROBOT &+ k]
  end

  def self.missile_x(r : Int32, k : Int32) : Int32
    @@m_cur_x[r &* MIS_ROBOT &+ k]
  end

  def self.missile_y(r : Int32, k : Int32) : Int32
    @@m_cur_y[r &* MIS_ROBOT &+ k]
  end

  def self.cycles : Int32
    @@c
  end

  def self.updates : Int32
    @@updates
  end

  def self.over? : Bool
    @@phase == 3
  end

  def self.active_count : Int32
    k = 0
    r = 0
    while r < @@n
      k = k &+ 1 if @@active[r] != 0
      r = r &+ 1
    end
    k
  end

  # Index of the winner (the only robot left), or -1.
  # FNV-1a over the final state (cycles, then per robot x, y, damage,
  # restarts, cycles, active, failed): two badges that played the same
  # battle compare this (badge link Z message, main/robonet.c).
  def self.result_hash : UInt32
    h = 2166136261_u32
    h = fnv(h, @@c)
    h = fnv(h, @@n)
    r = 0
    while r < @@n
      h = fnv(h, @@x[r])
      h = fnv(h, @@y[r])
      h = fnv(h, @@damage[r])
      h = fnv(h, @@restarts[r])
      h = fnv(h, @@cycles[r])
      h = fnv(h, @@active[r])
      h = fnv(h, @@failed[r])
      r = r &+ 1
    end
    h
  end

  def self.fnv(h : UInt32, v : Int32) : UInt32
    u = v.to_u32!
    k = 0
    while k < 4
      h = (h ^ (u & 0xFF_u32)) &* 16777619_u32
      u = u.unsafe_shr(8)
      k = k &+ 1
    end
    h
  end

  def self.winner : Int32
    return -1 if active_count != 1
    r = 0
    while r < @@n
      return r if @@active[r] != 0
      r = r &+ 1
    end
    -1
  end

  # ---- random (Crystal's Random::PCG32 and Random#rand(Int32), bit exact) --------
  def self.rng_next : UInt32
    old = @@rng_state
    @@rng_state = old &* 6364136223846793005_u64 &+ @@rng_inc
    xs = ((old.unsafe_shr(18) ^ old).unsafe_shr(27)).to_u32!
    rot = old.unsafe_shr(59).to_u32!
    rot == 0_u32 ? xs : (xs.unsafe_shr(rot) | xs.unsafe_shl(32_u32 &- rot))
  end

  def self.seed(s : UInt64) : Nil
    @@rng_state = 0_u64
    @@rng_inc = 1_u64 # (initseq 0 << 1) | 1
    rng_next
    @@rng_state = @@rng_state &+ s
    rng_next
  end

  def self.rand(limit : Int32) : Int32
    return 0 if limit <= 0
    max = limit.to_u32!
    lim = 0_u32 &- (0_u32 &- max).unsafe_mod(max)
    while true
      v = rng_next
      return v.unsafe_mod(max).to_i32! if v < lim || lim == 0_u32
    end
    0
  end

  # ---- integer helpers (Crystal semantics) -------------------------------------
  # Floored division and modulo, as Crystal's // and % on integers.
  def self.fdiv(a : Int32, b : Int32) : Int32
    q = a.unsafe_div(b)
    q = q &- 1 if q &* b != a && ((a < 0) != (b < 0))
    q
  end

  def self.fmod(a : Int32, b : Int32) : Int32
    m = a.unsafe_mod(b)
    m = m &+ b if m != 0 && ((m < 0) != (b < 0))
    m
  end

  def self.fdiv64(a : Int64, b : Int64) : Int64
    q = a.unsafe_div(b)
    q = q &- 1 if q &* b != a && ((a < 0) != (b < 0))
    q
  end

  def self.normalize(deg : Int32) : Int32
    v = deg.to_i64!
    v = 0_i64 &- v if v < 0
    v.unsafe_mod(360_i64).to_i32!
  end

  # sin * 100000 for 0..90 degrees (CROBOTS trig table).
  def self.trig(d : Int32) : Int32
    t = trig_table
    k = d &* 3
    t[k].to_i32! | t[k &+ 1].to_i32!.unsafe_shl(8) | t[k &+ 2].to_i32!.unsafe_shl(16)
  end

  def self.lsin(deg : Int32) : Int32
    deg = fmod(deg, 360)
    deg = deg &+ 360 if deg < 0
    return trig(deg) if deg < 91
    return trig(90 &- (deg &- 90)) if deg < 181
    return 0 &- trig(deg &- 180) if deg < 271
    0 &- trig(90 &- (deg &- 270))
  end

  def self.lcos(deg : Int32) : Int32
    deg = fmod(deg, 360)
    deg = deg &+ 360 if deg < 0
    return trig(90 &- deg) if deg < 91
    return 0 &- trig(deg &- 90) if deg < 181
    return 0 &- trig(90 &- (deg &- 180)) if deg < 271
    trig(deg &- 270)
  end

  def self.abs(v : Int32) : Int32
    v < 0 ? 0 &- v : v
  end

  def self.clamp(v : Int32, lo : Int32, hi : Int32) : Int32
    v < lo ? lo : (v > hi ? hi : v)
  end

  # Float64 -> Int32 like Crystal's to_i32 (truncate). ok = false when out of
  # range, where upstream would raise.
  @@f_ok = true

  def self.f2i(f : Float64) : Int32
    if f >= 2147483648.0 || f <= -2147483649.0 || f != f
      @@f_ok = false
      return 0
    end
    f.to_i32!
  end

  # ---- loading ---------------------------------------------------------------------
  # Load robot r of a match of n robots. False when its source does not
  # parse or check: it then sits the match out (inactive), as upstream.
  def self.load(r : Int32, p : UInt8*, len : Int32) : Bool
    return false unless setup
    ok = RC.load(r, p, len)
    @@loaded[r] = ok ? 1 : 0
    @@failed[r] = ok ? 0 : 1
    m = msg(r)
    k = 0
    unless ok
      e = RL.error
      while k < RL.error_len && k < MSG_MAX
        m[k] = e[k]
        k = k &+ 1
      end
    end
    m[k] = 0_u8
    @@msg_len[r] = k
    ok
  end

  # A new match of n loaded robots (load them first).
  def self.start(n : Int32, seed_v : UInt64, limit : Int32) : Nil
    @@n = n
    @@limit = limit
    seed(seed_v)
    @@c = 0
    @@updates = 0
    @@guard = 0
    @@movement = MOTION_CYCLES
    @@event = false
    r = 0
    while r < n
      @@active[r] = @@loaded[r]
      @@pc[r] = 0; @@sp[r] = 0; @@fd[r] = 0; @@slot_top[r] = 0
      @@pending[r] = 0; @@defer[r] = -1; @@need_start[r] = 1; @@inited[r] = 0
      @@errors[r] = 0; @@restarts[r] = 0; @@cycles[r] = 0
      @@out_len[r] = 0; @@outs[r] = 0
      @@failed[r] = @@loaded[r] == 0 ? 1 : 0
      @@msg_len[r] = 0 if @@loaded[r] != 0
      @@x[r] = 0; @@y[r] = 0; @@org_x[r] = 0; @@org_y[r] = 0; @@range[r] = 0
      @@speed[r] = 0; @@accel[r] = 0; @@d_speed[r] = 0; @@heading[r] = 0; @@d_heading[r] = 0
      @@damage[r] = 0; @@scan[r] = 0; @@reload[r] = 0; @@cannon_dir[r] = 0; @@fired[r] = 0
      k = 0
      while k < MIS_ROBOT
        q = r &* MIS_ROBOT &+ k
        @@m_stat[q] = AVAIL; @@m_beg_x[q] = 0; @@m_beg_y[q] = 0; @@m_cur_x[q] = 0
        @@m_cur_y[q] = 0; @@m_head[q] = 0; @@m_count[q] = 0; @@m_rang[q] = 0; @@m_dist[q] = 0
        k = k &+ 1
      end
      s = 0
      b = r &* RC::SYM_MAX
      while s < RC::SYM_MAX
        @@gval[b &+ s] = UNDEF
        @@cval[b &+ s] = UNDEF
        s = s &+ 1
      end
      r = r &+ 1
    end
    rand_pos
    @@phase = 1
  end

  # Start position in meters instead of rand_pos (specs, demos).
  def self.place(r : Int32, x_m : Int32, y_m : Int32) : Nil
    @@org_x[r] = x_m &* CLICK
    @@x[r] = @@org_x[r]
    @@org_y[r] = y_m &* CLICK
    @@y[r] = @@org_y[r]
    @@range[r] = 0
  end

  # CROBOTS rand_pos: one robot per quadrant.
  def self.rand_pos : Nil
    used = 0
    r = 0
    while r < @@n
      k = rand(4)
      while (used & 1.unsafe_shl(k)) != 0
        k = (k &+ 1).unsafe_mod(4)
      end
      used = used | 1.unsafe_shl(k)
      half_x = (MAX_X * CLICK).unsafe_div(2)
      half_y = (MAX_Y * CLICK).unsafe_div(2)
      @@org_x[r] = rand(half_x) &+ half_x &* k.unsafe_mod(2)
      @@x[r] = @@org_x[r]
      @@org_y[r] = rand(half_y) &+ half_y &* (k < 2 ? 1 : 0)
      @@y[r] = @@org_y[r]
      r = r &+ 1
    end
  end

  # ---- the match loop -----------------------------------------------------------------
  # One motion update: MOTION_CYCLES rounds of one step per active robot,
  # then movement (or, once the fight is over, one landing update for
  # missiles still in flight). False when the match is over.
  #
  # As upstream, the fight condition (more than one robot active, cycle
  # limit not reached) is tested before every round, so a robot failing
  # mid-update can end the fight before that update's motion.
  def self.update : Bool
    if @@phase == 1
      while active_count > 1 && @@c < @@limit
        r = 0
        while r < @@n
          step(r) if @@active[r] != 0
          r = r &+ 1
        end
        @@movement = @@movement &- 1
        if @@movement == 0
          @@movement = MOTION_CYCLES
          @@c = @@c &+ MOTION_CYCLES
          move_robots
          move_missiles
          count_missiles
          @@updates = @@updates &+ 1
          return true
        end
      end
      @@phase = 2
    end
    if @@phase == 2
      if any_flying? && @@guard < 100
        @@c = @@c &+ MOTION_CYCLES
        move_robots
        move_missiles
        count_missiles
        @@guard = @@guard &+ 1
        return true
      end
      @@phase = 3
    end
    false
  end

  def self.run : Nil
    while update
    end
  end

  def self.any_flying? : Bool
    q = 0
    while q < @@n &* MIS_ROBOT
      return true if @@m_stat[q] == FLYING
      q = q &+ 1
    end
    false
  end

  # ---- motion (CROBOTS move_robots, move_miss, count_miss) ----------------------------
  def self.collide(r : Int32) : Nil
    @@speed[r] = 0
    @@d_speed[r] = 0
    @@damage[r] = @@damage[r] &+ COLLISION
    @@event = true
  end

  def self.move_robots : Nil
    i = 0
    while i < @@n
      if @@active[i] == 0
        i = i &+ 1
        next
      end
      if @@damage[i] >= 100
        @@damage[i] = 100
        @@active[i] = 0
        @@event = true
        i = i &+ 1
        next
      end
      @@reload[i] = @@reload[i] &- 1 if @@reload[i] > 0
      if @@speed[i] != @@d_speed[i]
        if @@speed[i] > @@d_speed[i]
          @@accel[i] = @@accel[i] &- ACCEL
          if @@accel[i] < @@d_speed[i]
            @@accel[i] = @@d_speed[i]
            @@speed[i] = @@accel[i]
          else
            @@speed[i] = @@accel[i]
          end
        else
          @@accel[i] = @@accel[i] &+ ACCEL
          if @@accel[i] > @@d_speed[i]
            @@accel[i] = @@d_speed[i]
            @@speed[i] = @@accel[i]
          else
            @@speed[i] = @@accel[i]
          end
        end
      end
      if @@heading[i] != @@d_heading[i]
        if @@speed[i] <= TURN_SPEED
          @@heading[i] = @@d_heading[i]
          @@range[i] = 0
          @@org_x[i] = @@x[i]
          @@org_y[i] = @@y[i]
        else
          @@d_speed[i] = 0
        end
      end
      if @@speed[i] > 0
        @@range[i] = @@range[i] &+ fdiv(@@speed[i], CLICK) &* ROBOT_SPEED
        rr = fdiv(@@range[i], CLICK).to_i64!
        @@x[i] = @@org_x[i] &+ fdiv64(lcos(@@heading[i]).to_i64! &* rr, 10000_i64).to_i32!
        @@y[i] = @@org_y[i] &+ fdiv64(lsin(@@heading[i]).to_i64! &* rr, 10000_i64).to_i32!
        n = 0
        while n < @@n
          if @@active[n] != 0 && n != i &&
             abs(@@x[i] &- @@x[n]) < CLICK && abs(@@y[i] &- @@y[n]) < CLICK
            collide(i)
            collide(n)
          end
          n = n &+ 1
        end
        if @@x[i] < 0
          @@x[i] = 0
          collide(i)
        elsif @@x[i] > MAX_X * CLICK
          @@x[i] = MAX_X * CLICK - 1
          collide(i)
        end
        if @@y[i] < 0
          @@y[i] = 0
          collide(i)
        elsif @@y[i] > MAX_Y * CLICK
          @@y[i] = MAX_Y * CLICK - 1
          collide(i)
        end
      end
      i = i &+ 1
    end
  end

  def self.move_missiles : Nil
    r = 0
    while r < @@n
      if @@damage[r] >= 100 && @@active[r] != 0
        @@damage[r] = 100
        @@active[r] = 0
        @@event = true
      end
      k = 0
      while k < MIS_ROBOT
        q = r &* MIS_ROBOT &+ k
        k = k &+ 1
        next unless @@m_stat[q] == FLYING
        d = @@m_dist[q] &+ MIS_SPEED
        d = @@m_rang[q] if d > @@m_rang[q]
        @@m_dist[q] = d
        dd = fdiv(d, CLICK).to_i64!
        x = @@m_beg_x[q] &+ fdiv64(lcos(@@m_head[q]).to_i64! &* dd, 10000_i64).to_i32!
        y = @@m_beg_y[q] &+ fdiv64(lsin(@@m_head[q]).to_i64! &* dd, 10000_i64).to_i32!
        @@m_cur_x[q] = x
        @@m_cur_y[q] = y
        @@m_stat[q] = EXPLODING if x < 0 || x >= MAX_X * CLICK || y < 0 || y > MAX_Y * CLICK
        @@m_stat[q] = EXPLODING if d == @@m_rang[q]
        next unless @@m_stat[q] == EXPLODING
        @@event = true
        t = 0
        while t < @@n
          if @@active[t] != 0
            dx = fdiv(@@x[t] &- x, CLICK)
            dy = fdiv(@@y[t] &- y, CLICK)
            dist = f2i(LibRM.sqrt(dx.to_f64 * dx.to_f64 + dy.to_f64 * dy.to_f64))
            if dist < 5
              @@damage[t] = @@damage[t] &+ 10
            elsif dist < 20
              @@damage[t] = @@damage[t] &+ 5
            elsif dist < 40
              @@damage[t] = @@damage[t] &+ 3
            end
            if @@damage[t] >= 100
              @@damage[t] = 100
              @@active[t] = 0
            end
          end
          t = t &+ 1
        end
      end
      r = r &+ 1
    end
  end

  def self.count_missiles : Nil
    q = 0
    while q < @@n &* MIS_ROBOT
      if @@m_stat[q] == EXPLODING
        @@m_count[q] = @@m_count[q] &- 1
        @@m_stat[q] = AVAIL if @@m_count[q] <= 0
      end
      q = q &+ 1
    end
  end

  # ---- robot builtins (CROBOTS c_scan, c_cannon, c_drive) -----------------------------
  def self.scan(r : Int32, degree : Int32, res : Int32) : Int32
    res = clamp(res, 0, RES_LIMIT)
    degree = normalize(degree)
    @@scan[r] = degree
    closest = 0
    o = 0
    while o < @@n
      if o != r && @@active[o] != 0
        x = (fdiv(@@x[r], CLICK) &- fdiv(@@x[o], CLICK)).to_f64
        y = (fdiv(@@y[r], CLICK) &- fdiv(@@y[o], CLICK)).to_f64
        d = 0
        if f2i(x + 0.5) == 0
          d = @@y[o] > @@y[r] ? 90 : 270
        elsif @@y[o] < @@y[r]
          d = @@x[o] > @@x[r] ? f2i(360.0 + RAD_DEG * LibRM.atan(y / x)) : f2i(180.0 + RAD_DEG * LibRM.atan(y / x))
        else
          d = @@x[o] > @@x[r] ? f2i(RAD_DEG * LibRM.atan(y / x)) : f2i(180.0 + RAD_DEG * LibRM.atan(y / x))
        end
        dd = 0
        d1 = 0
        d2 = 0
        if degree > res && degree < 360 &- res
          dd = degree
          d1 = d &- res
          d2 = d &+ res
        else
          dd = fmod(degree &+ 180, 360)
          center = fmod(d &+ 180, 360)
          d1 = center &- res
          d2 = center &+ res
        end
        if dd >= d1 && dd <= d2
          distance = f2i(LibRM.sqrt(x * x + y * y))
          closest = distance if distance < closest || closest == 0
        end
      end
      o = o &+ 1
    end
    @@event = true if closest != 0
    closest
  end

  def self.cannon(r : Int32, degree : Int32, distance : Int32) : Int32
    return 1 if distance < 0
    distance = MIS_RANGE if distance > MIS_RANGE
    degree = normalize(degree)
    return 0 if @@reload[r] > 0
    k = 0
    while k < MIS_ROBOT
      q = r &* MIS_ROBOT &+ k
      if @@m_stat[q] == AVAIL
        @@reload[r] = RELOAD
        @@cannon_dir[r] = degree
        @@fired[r] = 1
        @@m_stat[q] = FLYING
        @@m_cur_x[q] = @@x[r]
        @@m_beg_x[q] = @@m_cur_x[q]
        @@m_cur_y[q] = @@y[r]
        @@m_beg_y[q] = @@m_cur_y[q]
        @@m_head[q] = degree
        @@m_rang[q] = distance &* CLICK
        @@m_dist[q] = 0
        @@m_count[q] = EXP_COUNT
        @@event = true
        return 1
      end
      k = k &+ 1
    end
    0
  end

  def self.drive(r : Int32, degree : Int32, speed : Int32) : Int32
    @@d_heading[r] = normalize(degree)
    @@d_speed[r] = clamp(speed, 0, 100)
    1
  end

  # ---- VM ------------------------------------------------------------------------------
  @@r = 0 # robot being stepped
  @@code = Pointer(Int32).null
  @@sbase = 0 # r * STACK_MAX
  @@fbase = 0 # r * FRAME_MAX
  @@vbase = 0 # r * SYM_MAX
  @@lbase = 0 # r * SLOT_MAX

  def self.str?(v : Int64) : Bool
    v >= STR_TAG
  end

  def self.truthy?(v : Int64) : Bool
    str?(v) || v != 0_i64
  end

  # ---- messages -------------------------------------------------------------------
  def self.msg_clear : Nil
    @@msg_len[@@r] = 0
  end

  def self.msg_byte(c : UInt8) : Nil
    k = @@msg_len[@@r]
    if k < MSG_MAX
      m = msg(@@r)
      m[k] = c
      m[k &+ 1] = 0_u8
      @@msg_len[@@r] = k &+ 1
    end
  end

  def self.msg_s(s : String) : Nil
    msg_bytes(s.to_unsafe, s.bytesize)
  end

  def self.msg_bytes(p : UInt8*, n : Int32) : Nil
    i = 0
    while i < n
      msg_byte(p[i])
      i = i &+ 1
    end
  end

  def self.msg_int(v : Int32) : Nil
    if v < 0
      msg_byte(0x2D_u8)
      if v == -2147483647 &- 1
        msg_s("2147483648")
        return
      end
      v = 0 &- v
    end
    d = 1
    while v.unsafe_div(d) >= 10
      d = d &* 10
    end
    while d > 0
      msg_byte((0x30 &+ v.unsafe_div(d).unsafe_mod(10)).to_u8!)
      d = d.unsafe_div(10)
    end
  end

  def self.msg_sym(s : Int32) : Nil
    msg_bytes(RC.sym_ptr(@@r, s), RC.sym_len(@@r, s))
  end

  def self.str_ptr(v : Int64) : UInt8*
    RC.src(@@r) + v.unsafe_shr(16).to_i32!.&(0xFFFF).to_i64!
  end

  def self.str_len(v : Int64) : Int32
    (v & 0xFFFF_i64).to_i32!
  end

  # Crystal's String#inspect for the error message (printable ASCII kept).
  def self.msg_inspect(v : Int64) : Nil
    msg_byte(0x22_u8)
    p = str_ptr(v)
    n = str_len(v)
    i = 0
    while i < n
      c = p[i]
      if c == 0x22_u8 || c == 0x5C_u8
        msg_byte(0x5C_u8)
        msg_byte(c)
      elsif c == 0x0A_u8
        msg_byte(0x5C_u8)
        msg_byte(0x6E_u8)
      else
        msg_byte(c)
      end
      i = i &+ 1
    end
    msg_byte(0x22_u8)
  end

  # puts: keep the last line.
  def self.puts(v : Int64) : Nil
    r = @@r
    o = out(r)
    k = 0
    if str?(v)
      p = str_ptr(v)
      n = str_len(v)
      while k < n && k < MSG_MAX
        o[k] = p[k]
        k = k &+ 1
      end
    else
      i = v.to_i32!
      neg = i < 0
      u = neg ? 0_i64 &- i.to_i64! : i.to_i64!
      d = 1_i64
      while u.unsafe_div(d) >= 10_i64
        d = d &* 10_i64
      end
      if neg
        o[0] = 0x2D_u8
        k = 1
      end
      while d > 0_i64
        o[k] = (0x30_i64 &+ u.unsafe_div(d).unsafe_mod(10_i64)).to_u8!
        k = k &+ 1
        d = d.unsafe_div(10_i64)
      end
    end
    o[k] = 0_u8
    @@out_len[r] = k
    @@outs[r] = @@outs[r] &+ 1
  end

  # ---- stack and frames -----------------------------------------------------------
  def self.push(v : Int64) : Bool
    sp = @@sp[@@r]
    return false if sp >= STACK_MAX
    @@stack[@@sbase &+ sp] = v
    @@sp[@@r] = sp &+ 1
    true
  end

  def self.pop : Int64
    sp = @@sp[@@r] &- 1
    @@sp[@@r] = sp
    @@stack[@@sbase &+ sp]
  end

  def self.peek : Int64
    @@stack[@@sbase &+ @@sp[@@r] &- 1]
  end

  # Push a frame with `slots` locals (all undefined). False when out of room.
  def self.push_frame(sym : Int32, slots : Int32, ret : Int32) : Bool
    r = @@r
    fd = @@fd[r]
    top = @@slot_top[r]
    return false if fd >= FRAME_MAX || top &+ slots > SLOT_MAX
    f = @@fbase &+ fd
    @@fr_ret[f] = ret
    @@fr_sp[f] = @@sp[r]
    @@fr_slot[f] = top
    @@fr_sym[f] = sym
    @@fr_last[f] = 0_i64
    i = 0
    while i < slots
      @@slots[@@lbase &+ top &+ i] = UNDEF
      i = i &+ 1
    end
    @@slot_top[r] = top &+ slots
    @@fd[r] = fd &+ 1
    true
  end

  def self.pop_frame : Int32
    r = @@r
    fd = @@fd[r] &- 1
    @@fd[r] = fd
    f = @@fbase &+ fd
    @@sp[r] = @@fr_sp[f]
    @@slot_top[r] = @@fr_slot[f]
    @@fr_ret[f]
  end

  def self.top_frame : Int32
    @@fbase &+ @@fd[@@r] &- 1
  end

  def self.set_last(v : Int64) : Nil
    @@fr_last[top_frame] = v if @@fd[@@r] > 0
  end

  # ---- variables ------------------------------------------------------------------
  def self.local_at(slot : Int32) : Int32
    @@lbase &+ @@fr_slot[top_frame] &+ slot
  end

  def self.gdef?(s : Int32) : Bool
    @@gval[@@vbase &+ s] != UNDEF
  end

  def self.cdef?(s : Int32) : Bool
    @@cval[@@vbase &+ s] != UNDEF
  end

  # Value of a name if it is a variable, else UNDEF (upstream defined_var? +
  # lookup: the frame, then globals, then constants).
  def self.lookup(s : Int32, slot : Int32, mode : Int32) : Int64
    if mode == RC::MODE_FRAME && @@fd[@@r] > 0 && slot >= 0
      v = @@slots[local_at(slot)]
      return v if v != UNDEF
    elsif mode == RC::MODE_CONST && cdef?(s)
      return @@cval[@@vbase &+ s]
    end
    return @@gval[@@vbase &+ s] if gdef?(s)
    return @@cval[@@vbase &+ s] if cdef?(s)
    UNDEF
  end

  def self.store(s : Int32, slot : Int32, mode : Int32, v : Int64) : Nil
    if gdef?(s)
      @@gval[@@vbase &+ s] = v
    elsif mode == RC::MODE_FRAME && @@fd[@@r] > 0 && slot >= 0
      @@slots[local_at(slot)] = v
    else
      @@cval[@@vbase &+ s] = v
    end
  end

  # ---- errors ---------------------------------------------------------------------
  def self.expect_number(v : Int64) : Int32
    msg_clear
    msg_s("expected a number, got ")
    msg_inspect(v)
    FAILED
  end

  # Upstream binop: both operands numbers, CROBOTS division by 0 is 0.
  # Returns FAILED or CHARGED (0) with the result pushed.
  def self.binop(op : Int32, l : Int64, rv : Int64) : Int32
    return expect_number(l) if str?(l)
    return expect_number(rv) if str?(rv)
    a = l.to_i32!
    b = rv.to_i32!
    v = 0
    if op == RL::ADD
      v = a &+ b
    elsif op == RL::SUB
      v = a &- b
    elsif op == RL::MUL
      v = a &* b
    elsif op == RL::FDIV || op == RL::DIV
      v = b == 0 ? 0 : (b == -1 ? 0 &- a : fdiv(a, b))
    elsif op == RL::MOD
      v = b == 0 || b == -1 ? 0 : fmod(a, b)
    elsif op == RL::EQ
      v = a == b ? 1 : 0
    elsif op == RL::NE
      v = a != b ? 1 : 0
    elsif op == RL::LT
      v = a < b ? 1 : 0
    elsif op == RL::GT
      v = a > b ? 1 : 0
    elsif op == RL::LE
      v = a <= b ? 1 : 0
    elsif op == RL::GE
      v = a >= b ? 1 : 0
    elsif op == RL::AND
      v = a != 0 && b != 0 ? 1 : 0
    elsif op == RL::OR
      v = a != 0 || b != 0 ? 1 : 0
    elsif op == RL::XOR
      v = a ^ b
    end
    return stack_full unless push(v.to_i64!)
    CHARGED
  end

  def self.stack_full : Int32
    msg_clear
    msg_s("stack overflow")
    FAILED
  end

  def self.values_equal?(a : Int64, b : Int64) : Bool
    if str?(a) && str?(b)
      n = str_len(a)
      return false if n != str_len(b)
      p = str_ptr(a)
      q = str_ptr(b)
      i = 0
      while i < n
        return false if p[i] != q[i]
        i = i &+ 1
      end
      return true
    end
    a == b
  end

  # Call user function s with argc arguments on the stack (upstream
  # call_user). CHARGED (0) on success.
  def self.call(s : Int32, argc : Int32, ret : Int32) : Int32
    r = @@r
    entry = RC.fn_entry(r, s)
    if entry < 0
      msg_clear
      msg_s("undefined function ")
      msg_sym(s)
      return FAILED
    end
    if @@fd[r] > MAX_CALL_DEPTH
      msg_clear
      msg_s("call depth exceeded ")
      msg_int(MAX_CALL_DEPTH)
      msg_s(" in ")
      msg_sym(s)
      return FAILED
    end
    ar = RC.fn_arity(r, s)
    if ar != argc
      msg_clear
      msg_sym(s)
      msg_s(" expects ")
      msg_int(ar)
      msg_s(" arguments, got ")
      msg_int(argc)
      return FAILED
    end
    @@sp[r] = @@sp[r] &- argc # arguments become the first slots
    base = @@sp[r]
    return stack_full unless push_frame(s, RC.fn_slots(r, s), ret)
    i = 0
    while i < argc
      @@slots[local_at(i)] = @@stack[@@sbase &+ base &+ i]
      i = i &+ 1
    end
    @@pc[r] = entry
    CHARGED
  end

  # Builtin b (upstream Interpreter builtins against the battlefield host).
  def self.builtin(b : Int32) : Int32
    r = @@r
    if b == RC::B_PUTS
      puts(pop)
      return push(0_i64) ? CHARGED : stack_full
    end
    v = 0
    if b >= RC::B_DAMAGE
      v = b == RC::B_DAMAGE ? @@damage[r] : (b == RC::B_SPEED ? @@speed[r] :
          (b == RC::B_LOC_X ? fdiv(@@x[r], CLICK) : (b == RC::B_LOC_Y ? fdiv(@@y[r], CLICK) : 0)))
    elsif b >= RC::B_SCAN
      a2 = pop
      a1 = pop
      return expect_number(a1) if str?(a1)
      return expect_number(a2) if str?(a2)
      x = a1.to_i32!
      y = a2.to_i32!
      v = b == RC::B_SCAN ? scan(r, x, y) : (b == RC::B_CANNON ? cannon(r, x, y) : drive(r, x, y))
    else
      a = pop
      return expect_number(a) if str?(a)
      x = a.to_i32!
      @@f_ok = true
      if b == RC::B_RAND
        v = rand(x)
      elsif b == RC::B_SQRT
        v = isqrt(x)
      elsif b == RC::B_ATAN
        v = f2i(LibRM.atan(x.to_f64 / 100000.0) * 180.0 / PI)
      else
        rad = x.to_f64 * PI / 180.0
        f = b == RC::B_SIN ? LibRM.sin(rad) : (b == RC::B_COS ? LibRM.cos(rad) : LibRM.tan(rad))
        v = f2i(f * 100000.0)
      end
      unless @@f_ok # upstream raises OverflowError here
        msg_clear
        msg_s("arithmetic overflow")
        return FAILED
      end
    end
    push(v.to_i64!) ? CHARGED : stack_full
  end

  # Math.isqrt(n.to_i64.abs).
  def self.isqrt(n : Int32) : Int32
    v = n.to_i64!
    v = 0_i64 &- v if v < 0
    return v.to_i32! if v < 2
    x = v
    y = (x &+ 1).unsafe_div(2)
    while y < x
      x = y
      y = (x &+ v.unsafe_div(x)).unsafe_div(2)
    end
    x.to_i32!
  end

  # ---- stepping ---------------------------------------------------------------------
  def self.use_robot(r : Int32) : Nil
    @@r = r
    @@code = RC.code(r)
    @@sbase = r &* STACK_MAX
    @@fbase = r &* FRAME_MAX
    @@vbase = r &* RC::SYM_MAX
    @@lbase = r &* SLOT_MAX
  end

  # upstream run_main
  def self.run_main : Bool
    r = @@r
    @@fd[r] = 0
    @@sp[r] = 0
    @@slot_top[r] = 0
    @@pc[r] = RC.main_entry(r)
    push_frame(-1, RC.main_slots(r), 0)
  end

  # Advance robot r by one charged cycle (upstream Robot#step!).
  def self.step(r : Int32) : Nil
    return if @@active[r] == 0
    if @@pending[r] > 0
      @@pending[r] = @@pending[r] &- 1
      @@cycles[r] = @@cycles[r] &+ 1
      return
    end
    use_robot(r)
    st = CHARGED
    if @@need_start[r] != 0
      @@need_start[r] = 0
      if @@inited[r] == 0
        @@inited[r] = 1
        @@fd[r] = 0
        @@sp[r] = 0
        @@slot_top[r] = 0
        @@pc[r] = RC.init_entry(r)
      else
        run_main
      end
    elsif (s = @@defer[r]) >= 0
      @@defer[r] = -1
      st = call(s, 0, @@pc[r])
    end
    st = exec if st == CHARGED
    if st == FAILED
      note_error
      @@errors[r] = @@errors[r] &+ 1
      if @@errors[r] >= MAX_ERRORS
        @@failed[r] = 1
        @@active[r] = 0
      else
        @@restarts[r] = @@restarts[r] &+ 1
        @@cycles[r] = @@cycles[r] &+ 1
        @@need_start[r] = 1
      end
    elsif st == COMPLETED
      @@restarts[r] = @@restarts[r] &+ 1
      @@cycles[r] = @@cycles[r] &+ 1
      @@need_start[r] = 1
    end
  end

  # upstream note("runtime error: ...")
  def self.note_error : Nil
    @@outs[@@r] = @@outs[@@r] &+ 1
  end

  # Run until the next charged cycle (CHARGED), the end of main
  # (COMPLETED) or a runtime error (FAILED).
  def self.exec : Int32
    r = @@r
    c = @@code
    pc = @@pc[r]
    while true
      op = c[pc]
      if op == RC::OP_TICK
        @@cycles[r] = @@cycles[r] &+ 1
        @@pending[r] = c[pc &+ 1] &- 1
        @@pc[r] = pc &+ 2
        return CHARGED
      elsif op == RC::OP_PUSH
        return stack_full unless push(c[pc &+ 1].to_i64!)
        pc = pc &+ 2
      elsif op == RC::OP_PUSHS
        return stack_full unless push(STR_TAG | c[pc &+ 1].to_i64!.unsafe_shl(16) | c[pc &+ 2].to_i64!)
        pc = pc &+ 3
      elsif op == RC::OP_LOAD
        s = c[pc &+ 1]
        v = lookup(s, c[pc &+ 2], c[pc &+ 3])
        pc = pc &+ 4
        if v != UNDEF
          return stack_full unless push(v)
          @@cycles[r] = @@cycles[r] &+ 1 # fetch: 1 cycle
          @@pc[r] = pc
          return CHARGED
        end
        if RC.fn_entry(r, s) >= 0
          # a bare name that is a function: a call (3 cycles, then the call)
          @@defer[r] = s
          @@cycles[r] = @@cycles[r] &+ 1
          @@pending[r] = 2
          @@pc[r] = pc
          return CHARGED
        end
        msg_clear
        msg_s("undefined variable or function ")
        msg_sym(s)
        return FAILED
      elsif op == RC::OP_STORE
        store(c[pc &+ 1], c[pc &+ 2], c[pc &+ 3], peek)
        pc = pc &+ 4
      elsif op == RC::OP_OPASSIGN
        s = c[pc &+ 2]
        slot = c[pc &+ 3]
        mode = c[pc &+ 4]
        rv = pop
        l = lookup(s, slot, mode)
        l = 0_i64 if l == UNDEF
        return FAILED if binop(c[pc &+ 1], l, rv) == FAILED
        store(s, slot, mode, peek)
        pc = pc &+ 5
      elsif op == RC::OP_BINOP
        b = pop
        a = pop
        return FAILED if binop(c[pc &+ 1], a, b) == FAILED
        pc = pc &+ 2
      elsif op == RC::OP_NEG
        a = pop
        return expect_number(a) if str?(a)
        push((0 &- a.to_i32!).to_i64!)
        pc = pc &+ 1
      elsif op == RC::OP_POPN
        @@sp[r] = @@sp[r] &- c[pc &+ 1]
        pc = pc &+ 2
      elsif op == RC::OP_SETLAST
        set_last(pop)
        pc = pc &+ 1
      elsif op == RC::OP_LAST0
        set_last(0_i64)
        pc = pc &+ 1
      elsif op == RC::OP_JMP
        pc = c[pc &+ 1]
      elsif op == RC::OP_JF
        pc = truthy?(pop) ? pc &+ 2 : c[pc &+ 1]
      elsif op == RC::OP_JT
        pc = truthy?(pop) ? c[pc &+ 1] : pc &+ 2
      elsif op == RC::OP_CASEEQ
        w = pop
        push(values_equal?(peek, w) ? 1_i64 : 0_i64)
        pc = pc &+ 1
      elsif op == RC::OP_CALL
        st = call(c[pc &+ 1], c[pc &+ 2], pc &+ 3)
        return st if st != CHARGED
        pc = @@pc[r]
      elsif op == RC::OP_BUILTIN
        st = builtin(c[pc &+ 1])
        return st if st != CHARGED
        pc = pc &+ 2
      elsif op == RC::OP_RET || op == RC::OP_RETLAST
        v = op == RC::OP_RET ? pop : @@fr_last[top_frame]
        pc = pop_frame
        return stack_full unless push(v)
      elsif op == RC::OP_SETGLOBAL
        @@gval[@@vbase &+ c[pc &+ 1]] = pop
        pc = pc &+ 2
      elsif op == RC::OP_SETCONST
        @@cval[@@vbase &+ c[pc &+ 1]] = pop
        pc = pc &+ 2
      elsif op == RC::OP_CFRAME
        return stack_full unless push_frame(-2, 0, 0)
        pc = pc &+ 1
      elsif op == RC::OP_CFRAME_END
        pop_frame
        pc = pc &+ 1
      elsif op == RC::OP_ENDINIT
        return stack_full unless run_main
        pc = @@pc[r]
      elsif op == RC::OP_END
        return COMPLETED
      else # OP_FAIL
        msg_clear
        msg_s("cannot execute main")
        return FAILED
      end
    end
    FAILED
  end
end
