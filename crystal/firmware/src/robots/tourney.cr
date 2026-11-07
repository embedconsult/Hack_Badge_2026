# Robot tournaments: a round robin of robots in 4-robot battles, several
# seeds per line-up, standings, and a final of the top four. Prelude-free
# (the badge, test/robots/empty_prelude.cr's `rb tourney`, host specs).
#
# The whole tournament follows from (robot count, seed, seeds per line-up):
# every badge that has the same robots in the same order plays the same
# tournament (main/tourney_net.c cross-checks with `hash`). Robots are
# indices 0..n-1; the caller loads robot idx[r] as battle robot r before
# each battle (Tour doesn't know where sources come from).
#
#   Tour.setup(n, seed, seeds)
#   k = 0
#   while k < Tour.battles
#     m = Tour.lineup(k, idx)       # robots of battle k, in battle order
#     ...RB.load(r, source of idx[r]) for r < m...
#     RB.start(m, Tour.seed_of(k).to_u64!, RB::CYCLE_LIMIT); RB.run
#     Tour.record(m, idx)
#     k += 1
#   end
#   m = Tour.final_lineup(idx)      # the top four by the standings
#   ...load, RB.start(m, Tour.final_seed.to_u64!, ...); RB.run
#   Tour.record_final(m, idx)
#
# Schedule: rounds of groups (sizes as even as possible, 2..4), built
# greedily so robots that have met least meet next (a shuffled order breaks
# ties); rounds are added until every pair has met, at most MAX_ROUNDS.
# Each group plays `seeds` battles, the robot order rotated each time.
# Scoring per battle: sole survivor 3 points (a win), every robot still
# alive at the cycle limit 1 point (a draw). Damage: what the robot took,
# 100 when destroyed or when it failed to load. Ranking: points, then
# wins, then lower average damage, then robot index.

module Tour
  MAX        = 48 # robots
  GROUP      =  4
  MAX_ROUNDS = 24
  MAX_SEEDS  =  4
  MAX_GROUPS = MAX_ROUNDS * 12
  NAME       = 16

  @@ok = false
  @@n = 0
  @@seed = 1_u32
  @@seeds = 3
  @@rounds = 0
  @@groups = 0
  @@done = 0      # battles recorded
  @@hash = 2166136261_u32
  @@rng = 1_u32
  @@grp = Pointer(Int8).null   # MAX_GROUPS x GROUP robots, -1 = none
  @@met = Pointer(UInt8).null  # MAX x MAX meetings
  @@wins = Pointer(Int32).null
  @@draws = Pointer(Int32).null
  @@played = Pointer(Int32).null
  @@points = Pointer(Int32).null
  @@dmg = Pointer(Int32).null
  @@rank = Pointer(Int32).null # rank -> robot
  @@names = Pointer(UInt8).null
  @@nlen = Pointer(Int32).null
  @@tmp = Pointer(Int32).null
  @@try = Pointer(Int8).null  # a candidate round
  @@unmet = Pointer(Int32).null
  @@best = Pointer(Int8).null
  @@fn = 0
  @@fidx = Pointer(Int32).null # finalists (robots) in battle order
  @@fdmg = Pointer(Int32).null
  @@fwin = -1                  # final winner (robot), -1 draw / not played
  @@fdone = false

  def self.i32s(n : Int32) : Int32*
    game_alloc(n &* 4).as(Int32*)
  end

  def self.alloc : Bool
    return @@ok if @@ok
    @@grp = game_alloc(MAX_GROUPS &* GROUP).as(Int8*)
    @@met = game_alloc(MAX &* MAX)
    @@wins = i32s(MAX)
    @@draws = i32s(MAX)
    @@played = i32s(MAX)
    @@points = i32s(MAX)
    @@dmg = i32s(MAX)
    @@rank = i32s(MAX)
    @@nlen = i32s(MAX)
    @@tmp = i32s(MAX)
    @@try = game_alloc(MAX).as(Int8*)
    @@unmet = i32s(MAX)
    @@best = game_alloc(MAX).as(Int8*)
    @@names = game_alloc(MAX &* NAME)
    @@fidx = i32s(GROUP)
    @@fdmg = i32s(GROUP)
    @@ok = !@@grp.null? && !@@met.null? && !@@wins.null? && !@@draws.null? && !@@played.null? &&
           !@@points.null? && !@@dmg.null? && !@@rank.null? && !@@nlen.null? && !@@tmp.null? && !@@try.null? && !@@unmet.null? && !@@best.null? &&
           !@@names.null? && !@@fidx.null? && !@@fdmg.null?
  end

  # ---- accessors ------------------------------------------------------------
  def self.robots : Int32
    @@n
  end

  def self.battles : Int32
    @@groups &* @@seeds
  end

  def self.done : Int32
    @@done
  end

  def self.rounds : Int32
    @@rounds
  end

  def self.seeds : Int32
    @@seeds
  end

  def self.seed : UInt32
    @@seed
  end

  def self.hash : UInt32
    @@hash
  end

  def self.wins(i : Int32) : Int32
    @@wins[i]
  end

  def self.draws(i : Int32) : Int32
    @@draws[i]
  end

  def self.played(i : Int32) : Int32
    @@played[i]
  end

  def self.points(i : Int32) : Int32
    @@points[i]
  end

  def self.damage_sum(i : Int32) : Int32
    @@dmg[i]
  end

  # Average damage taken per battle, 0..100.
  def self.avg_damage(i : Int32) : Int32
    @@played[i] > 0 ? (@@dmg[i] &+ @@played[i].unsafe_div(2)).unsafe_div(@@played[i]) : 0
  end

  # Robot at rank k (0 = best), after rank_all.
  def self.at_rank(k : Int32) : Int32
    @@rank[k]
  end

  def self.met(a : Int32, b : Int32) : Int32
    @@met[a &* MAX &+ b].to_i32!
  end

  def self.final_done? : Bool
    @@fdone
  end

  # Final winner (robot), -1 if the final was a draw or not played.
  def self.final_winner : Int32
    @@fwin
  end

  def self.finalists : Int32
    @@fn
  end

  def self.finalist(k : Int32) : Int32
    @@fidx[k]
  end

  def self.final_damage(k : Int32) : Int32
    @@fdmg[k]
  end

  # The champion: the final's winner, else the best-ranked robot.
  def self.champion : Int32
    return @@fwin if @@fdone && @@fwin >= 0
    @@n > 0 ? @@rank[0] : -1
  end

  def self.name(i : Int32) : UInt8*
    @@names + (i &* NAME).to_i64!
  end

  def self.name_len(i : Int32) : Int32
    @@nlen[i]
  end

  def self.set_name(i : Int32, p : UInt8*, n : Int32) : Nil
    return if i < 0 || i >= @@n
    n = NAME if n > NAME
    d = name(i)
    k = 0
    while k < n
      d[k] = p[k]
      k = k &+ 1
    end
    @@nlen[i] = n
  end

  def self.set_name(i : Int32, s : String) : Nil
    set_name(i, s.to_unsafe, s.bytesize)
  end

  # ---- random numbers (schedule only; battles seed the engine themselves) ----
  def self.rnd : UInt32
    x = @@rng
    x = x ^ x.unsafe_shl(13)
    x = x ^ x.unsafe_shr(17)
    x = x ^ x.unsafe_shl(5)
    @@rng = x
    x
  end

  def self.mix(a : UInt32, b : UInt32) : UInt32
    h = (a ^ 0x9E3779B9_u32) &* 0x85EBCA6B_u32
    h = (h ^ b ^ h.unsafe_shr(13)) &* 0xC2B2AE35_u32
    h ^ h.unsafe_shr(16)
  end

  # ---- schedule ---------------------------------------------------------------
  # A new tournament of n robots (2..MAX). False if it cannot be held.
  def self.setup(n : Int32, seed : UInt32, seeds : Int32) : Bool
    return false unless alloc
    return false if n < 2 || n > MAX
    seeds = 1 if seeds < 1
    seeds = MAX_SEEDS if seeds > MAX_SEEDS
    @@n = n
    @@seed = seed
    @@seeds = seeds
    @@done = 0
    @@hash = 2166136261_u32
    @@fn = 0
    @@fwin = -1
    @@fdone = false
    i = 0
    while i < MAX
      @@wins[i] = 0; @@draws[i] = 0; @@played[i] = 0; @@points[i] = 0; @@dmg[i] = 0
      @@nlen[i] = 0
      @@rank[i] = i
      i = i &+ 1
    end
    i = 0
    while i < MAX &* MAX
      @@met[i] = 0_u8
      i = i &+ 1
    end
    @@rng = mix(seed, n.to_u32!) | 1_u32
    @@rounds = 0
    @@groups = 0
    while @@rounds < MAX_ROUNDS
      add_round
      @@rounds = @@rounds &+ 1
      break if all_met?
    end
    true
  end

  def self.all_met? : Bool
    a = 0
    while a < @@n
      b = a &+ 1
      while b < @@n
        return false if @@met[a &* MAX &+ b] == 0_u8
        b = b &+ 1
      end
      a = a &+ 1
    end
    true
  end

  # One round: every robot in exactly one group. TRIES greedy candidates
  # (each from its own shuffle); the one that adds the most new pairs.
  TRIES = 16

  def self.add_round : Nil
    ng = (@@n &+ GROUP &- 1).unsafe_div(GROUP)
    best = -1
    c = 0
    while c < @@n
      @@unmet[c] = unmet(c)
      c = c &+ 1
    end
    t = 0
    while t < TRIES
      build_round(@@try, ng)
      gain = new_pairs(@@try, ng)
      if gain > best
        best = gain
        i = 0
        while i < ng &* GROUP
          @@best[i] = @@try[i]
          i = i &+ 1
        end
      end
      t = t &+ 1
    end
    row = @@grp + (@@groups &* GROUP).to_i64!
    i = 0
    while i < ng &* GROUP
      row[i] = @@best[i]
      i = i &+ 1
    end
    g = 0
    while g < ng # meetings
      r = row + (g &* GROUP).to_i64!
      a = 0
      while a < GROUP && r[a] >= 0_i8
        b = 0
        while b < GROUP && r[b] >= 0_i8
          if a != b
            x = r[a].to_i32! &* MAX &+ r[b].to_i32!
            @@met[x] = @@met[x] &+ 1_u8 if @@met[x] < 255_u8
          end
          b = b &+ 1
        end
        a = a &+ 1
      end
      g = g &+ 1
    end
    @@groups = @@groups &+ ng
  end

  # Pairs in the ng groups at rows that have not met yet.
  def self.new_pairs(rows : Int8*, ng : Int32) : Int32
    k = 0
    g = 0
    while g < ng
      r = rows + (g &* GROUP).to_i64!
      a = 0
      while a < GROUP && r[a] >= 0_i8
        b = a &+ 1
        while b < GROUP && r[b] >= 0_i8
          k = k &+ 1 if @@met[r[a].to_i32! &* MAX &+ r[b].to_i32!] == 0_u8
          b = b &+ 1
        end
        a = a &+ 1
      end
      g = g &+ 1
    end
    k
  end

  # Robots c has not met yet.
  def self.unmet(c : Int32) : Int32
    k = 0
    o = 0
    while o < @@n
      k = k &+ 1 if o != c && @@met[c &* MAX &+ o] == 0_u8
      o = o &+ 1
    end
    k
  end

  # One greedy round into rows: each place goes to the robot that met the
  # group's members least (ties: more others still to meet, then the
  # shuffled order).
  def self.build_round(rows : Int8*, ng : Int32) : Nil
    n = @@n
    perm = @@tmp
    i = 0
    while i < n
      perm[i] = i
      i = i &+ 1
    end
    i = n &- 1
    while i > 0 # Fisher-Yates
      j = rnd.unsafe_mod((i &+ 1).to_u32!).to_i32!
      t = perm[i]; perm[i] = perm[j]; perm[j] = t
      i = i &- 1
    end
    base = n.unsafe_div(ng)
    extra = n &- base &* ng
    used = 0_u64
    g = 0
    while g < ng
      size = g < extra ? base &+ 1 : base
      row = rows + (g &* GROUP).to_i64!
      k = 0
      while k < GROUP
        row[k] = -1_i8
        k = k &+ 1
      end
      k = 0
      while k < size
        pick = -1
        pick_cost = 0x7FFFFFFF
        pick_un = -1
        q = 0
        while q < n
          c = perm[q]
          if (used & 1_u64.unsafe_shl(c)) == 0_u64
            cost = 0
            m = 0
            while m < k
              cost = cost &+ @@met[c &* MAX &+ row[m].to_i32!].to_i32!
              m = m &+ 1
            end
            un = @@unmet[c]
            if cost < pick_cost || (cost == pick_cost && un > pick_un)
              pick_cost = cost
              pick_un = un
              pick = c
            end
          end
          q = q &+ 1
        end
        row[k] = pick.to_i8!
        used = used | 1_u64.unsafe_shl(pick)
        k = k &+ 1
      end
      g = g &+ 1
    end
  end

  # Robots of battle k into idx (battle order); their number.
  def self.lineup(k : Int32, idx : Int32*) : Int32
    gi = k.unsafe_div(@@seeds)
    s = k &- gi &* @@seeds
    row = @@grp + (gi &* GROUP).to_i64!
    m = 0
    while m < GROUP && row[m] >= 0_i8
      m = m &+ 1
    end
    r = 0
    while r < m
      idx[r] = row[(r &+ s).unsafe_mod(m)].to_i32!
      r = r &+ 1
    end
    m
  end

  # Engine seed of battle k (below 2^31, odd).
  def self.seed_of(k : Int32) : UInt32
    (mix(@@seed, (k &+ 1).to_u32!) & 0x7FFFFFFF_u32) | 1_u32
  end

  def self.final_seed : UInt32
    (mix(@@seed ^ 0xF17A1_u32, @@n.to_u32!) & 0x7FFFFFFF_u32) | 1_u32
  end

  # ---- results -------------------------------------------------------------------
  def self.taken(r : Int32) : Int32
    return 100 if RB.failed?(r) || !RB.active?(r)
    d = RB.damage(r)
    d > 100 ? 100 : (d < 0 ? 0 : d)
  end

  # The battle that just ran (RB, over) with robots idx[0, m]: the next one.
  def self.record(m : Int32, idx : Int32*) : Nil
    w = RB.winner
    r = 0
    while r < m
      i = idx[r]
      @@played[i] = @@played[i] &+ 1
      @@dmg[i] = @@dmg[i] &+ taken(r)
      if r == w
        @@wins[i] = @@wins[i] &+ 1
        @@points[i] = @@points[i] &+ 3
      elsif w < 0 && RB.active?(r)
        @@draws[i] = @@draws[i] &+ 1
        @@points[i] = @@points[i] &+ 1
      end
      r = r &+ 1
    end
    @@hash = RB.fnv(@@hash, RB.result_hash.to_i32!)
    @@done = @@done &+ 1
    rank_all
  end

  # a ranks above b
  def self.better?(a : Int32, b : Int32) : Bool
    return @@points[a] > @@points[b] if @@points[a] != @@points[b]
    return @@wins[a] > @@wins[b] if @@wins[a] != @@wins[b]
    da = @@dmg[a].to_i64! &* @@played[b].to_i64!
    db = @@dmg[b].to_i64! &* @@played[a].to_i64!
    return da < db if da != db
    a < b
  end

  def self.rank_all : Nil
    i = 0
    while i < @@n
      @@rank[i] = i
      i = i &+ 1
    end
    i = 1
    while i < @@n # insertion sort
      v = @@rank[i]
      j = i &- 1
      while j >= 0 && better?(v, @@rank[j])
        @@rank[j &+ 1] = @@rank[j]
        j = j &- 1
      end
      @@rank[j &+ 1] = v
      i = i &+ 1
    end
  end

  # The top four (fewer if fewer robots), best first.
  def self.final_lineup(idx : Int32*) : Int32
    rank_all
    m = @@n < GROUP ? @@n : GROUP
    k = 0
    while k < m
      idx[k] = @@rank[k]
      @@fidx[k] = @@rank[k]
      k = k &+ 1
    end
    @@fn = m
    m
  end

  def self.record_final(m : Int32, idx : Int32*) : Nil
    w = RB.winner
    @@fwin = w >= 0 ? idx[w] : -1
    r = 0
    while r < m
      @@fdmg[r] = taken(r)
      r = r &+ 1
    end
    @@fdone = true
    @@hash = RB.fnv(@@hash, RB.result_hash.to_i32!)
    @@hash = RB.fnv(@@hash, @@fwin)
  end

  # ---- compact standings (badge link W message, main/tourney_net.c) -----------
  # Per rank: robot u8, wins u8, draws u8, played u8, damage sum u16; then
  # the champion and the final winner (robot, 255 none).
  CENTRY = 6

  def self.compact(p : UInt8*) : Int32
    rank_all
    k = 0
    while k < @@n
      i = @@rank[k]
      e = p + (k &* CENTRY).to_i64!
      e[0] = i.to_u8!
      e[1] = (@@wins[i] > 255 ? 255 : @@wins[i]).to_u8!
      e[2] = (@@draws[i] > 255 ? 255 : @@draws[i]).to_u8!
      e[3] = (@@played[i] > 255 ? 255 : @@played[i]).to_u8!
      put16(e + 4_i64, @@dmg[i] > 65535 ? 65535 : @@dmg[i])
      k = k &+ 1
    end
    c = champion
    e = p + (@@n &* CENTRY).to_i64!
    e[0] = (c >= 0 ? c : 255).to_u8!
    e[1] = (@@fdone && @@fwin >= 0 ? @@fwin : 255).to_u8!
    @@n &* CENTRY &+ 2
  end

  # Standings from compact's bytes (the organizer's, official); names and
  # the schedule stay. False if they do not fit this tournament.
  def self.adopt(p : UInt8*, len : Int32) : Bool
    return false if len != @@n &* CENTRY &+ 2
    k = 0
    while k < @@n
      return false if p[k &* CENTRY].to_i32! >= @@n
      k = k &+ 1
    end
    k = 0
    while k < @@n
      e = p + (k &* CENTRY).to_i64!
      i = e[0].to_i32!
      @@rank[k] = i
      @@wins[i] = e[1].to_i32!
      @@draws[i] = e[2].to_i32!
      @@played[i] = e[3].to_i32!
      @@points[i] = @@wins[i] &* 3 &+ @@draws[i]
      @@dmg[i] = get16(e + 4_i64)
      k = k &+ 1
    end
    w = p[@@n &* CENTRY &+ 1].to_i32!
    @@fwin = w < @@n ? w : -1
    @@fdone = true
    true
  end

  # ---- the standings as bytes (NVS on the badge, the badge link) ---------------
  # "RTT1", n, seeds, rounds, flags, seed u32, hash u32, battles u16,
  # champion u8 (its rank, 255 none), final winner rank u8 (255 draw),
  # then n entries in rank order: name[16], wins u16, draws u16,
  # played u16, points u16, damage sum u32 (28 bytes). Little endian.
  HDR   = 22
  ENTRY = 28

  def self.blob_size(n : Int32) : Int32
    HDR &+ n &* ENTRY
  end

  def self.put16(p : UInt8*, v : Int32) : Nil
    p[0] = (v & 0xFF).to_u8!
    p[1] = (v.unsafe_shr(8) & 0xFF).to_u8!
  end

  def self.put32(p : UInt8*, v : UInt32) : Nil
    p[0] = (v & 0xFF_u32).to_u8!
    p[1] = (v.unsafe_shr(8) & 0xFF_u32).to_u8!
    p[2] = (v.unsafe_shr(16) & 0xFF_u32).to_u8!
    p[3] = (v.unsafe_shr(24) & 0xFF_u32).to_u8!
  end

  def self.get16(p : UInt8*) : Int32
    p[0].to_i32! | p[1].to_i32!.unsafe_shl(8)
  end

  def self.get32(p : UInt8*) : UInt32
    p[0].to_u32! | p[1].to_u32!.unsafe_shl(8) | p[2].to_u32!.unsafe_shl(16) | p[3].to_u32!.unsafe_shl(24)
  end

  def self.rank_of(robot : Int32) : Int32
    k = 0
    while k < @@n
      return k if @@rank[k] == robot
      k = k &+ 1
    end
    255
  end

  # The standings into p (blob_size(robots) bytes); the size.
  def self.save(p : UInt8*, flags : Int32) : Int32
    rank_all
    p[0] = 0x52_u8; p[1] = 0x54_u8; p[2] = 0x54_u8; p[3] = 0x31_u8 # RTT1
    p[4] = @@n.to_u8!
    p[5] = @@seeds.to_u8!
    p[6] = @@rounds.to_u8!
    p[7] = flags.to_u8!
    put32(p + 8_i64, @@seed)
    put32(p + 12_i64, @@hash)
    put16(p + 16_i64, @@done)
    c = champion
    p[18] = (c >= 0 ? rank_of(c) : 255).to_u8!
    p[19] = (@@fdone && @@fwin >= 0 ? rank_of(@@fwin) : 255).to_u8!
    p[20] = 0_u8
    p[21] = 0_u8
    k = 0
    while k < @@n
      i = @@rank[k]
      e = p + (HDR &+ k &* ENTRY).to_i64!
      nm = name(i)
      j = 0
      while j < NAME
        e[j] = j < @@nlen[i] ? nm[j] : 0_u8
        j = j &+ 1
      end
      put16(e + 16_i64, @@wins[i])
      put16(e + 18_i64, @@draws[i])
      put16(e + 20_i64, @@played[i])
      put16(e + 22_i64, @@points[i])
      put32(e + 24_i64, @@dmg[i].to_u32!)
      k = k &+ 1
    end
    blob_size(@@n)
  end

  # Standings back from save's bytes (for showing them: robot i = rank i,
  # no schedule). The flags byte, or -1 if p[0, len] is not a table.
  def self.load(p : UInt8*, len : Int32) : Int32
    return -1 unless alloc
    return -1 if len < HDR || p[0] != 0x52_u8 || p[1] != 0x54_u8 || p[2] != 0x54_u8 || p[3] != 0x31_u8
    n = p[4].to_i32!
    return -1 if n < 1 || n > MAX || len < blob_size(n)
    @@n = n
    @@seeds = p[5].to_i32!
    @@rounds = p[6].to_i32!
    @@seed = get32(p + 8_i64)
    @@hash = get32(p + 12_i64)
    @@done = get16(p + 16_i64)
    @@groups = 0
    k = 0
    while k < n
      e = p + (HDR &+ k &* ENTRY).to_i64!
      j = 0
      while j < NAME && e[j] != 0_u8
        j = j &+ 1
      end
      set_name(k, e, j)
      @@wins[k] = get16(e + 16_i64)
      @@draws[k] = get16(e + 18_i64)
      @@played[k] = get16(e + 20_i64)
      @@points[k] = get16(e + 22_i64)
      @@dmg[k] = get32(e + 24_i64).to_i32!
      @@rank[k] = k
      k = k &+ 1
    end
    fw = p[19].to_i32!
    @@fwin = fw < n ? fw : -1
    @@fdone = p[18].to_i32! < n
    @@fn = 0
    p[7].to_i32!
  end
end
