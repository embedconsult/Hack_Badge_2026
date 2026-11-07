# The robot engine built the way the badge builds it (--prelude=empty, no
# stdlib), run on the host: plays a match of the robot files given and
# prints the result, so it can be compared with the std-prelude spec build.
#   crystal build --prelude=empty crystal/firmware/test/robots/empty_prelude.cr -o /tmp/rb
#   /tmp/rb <seed> <limit> robot1.cr robot2.cr [...]
#   /tmp/rb tourney <seed> <seeds> robot1.cr robot2.cr [...]
#     a tournament (src/robots/tourney.cr) of the robot files, in that
#     order: standings, the final and the tournament hash
# (test/robonet/ and crystal/net/sim_badge.py use it as the battle engine)
require "../../src/rt"

lib LibC
  fun calloc(n : UInt64, size : UInt64) : Void*
  fun fopen(path : UInt8*, mode : UInt8*) : Void*
  fun fread(p : Void*, size : UInt64, n : UInt64, f : Void*) : UInt64
  fun fclose(f : Void*) : Int32
  fun printf(fmt : UInt8*, ...) : Int32
  fun atoi(s : UInt8*) : Int32
end

# Like the badge's heap_caps_malloc, memory is not zeroed: fill it with
# garbage so a read before write shows up as a different match.
def game_alloc(n : Int32) : UInt8*
  p = LibC.calloc(n.to_u64!, 1_u64).as(UInt8*)
  i = 0
  while i < n
    p[i] = 0xA5_u8
    i = i &+ 1
  end
  p
end

require "../../src/robots/battle"
require "../../src/robots/tourney"

def load_file(r : Int32, path : UInt8*, buf : UInt8*) : Bool
  f = LibC.fopen(path, "rb".to_unsafe)
  return false if f.null?
  len = LibC.fread(buf.as(Void*), 1_u64, RL::SRC_MAX.to_u64!, f).to_i32!
  LibC.fclose(f)
  RB.load(r, buf, len)
  true
end

def same?(a : UInt8*, s : String) : Bool
  p = s.to_unsafe
  i = 0
  while i <= s.bytesize
    return false if a[i] != p[i]
    i = i &+ 1
  end
  true
end

# rb tourney <seed> <seeds> files...: robot i = file i
def tourney(argc : Int32, argv : UInt8**) : Int32
  seed = LibC.atoi(argv[2]).to_u32!
  seeds = LibC.atoi(argv[3])
  n = argc &- 4
  return 2 unless Tour.setup(n, seed, seeds)
  buf = game_alloc(RL::SRC_MAX)
  idx = game_alloc(16).as(Int32*)
  LibC.printf("tourney robots %d battles %d rounds %d seeds %d seed %u\n".to_unsafe, n, Tour.battles, Tour.rounds,
    Tour.seeds, seed)
  k = 0
  while k < Tour.battles
    m = Tour.lineup(k, idx)
    r = 0
    while r < m
      return 3 unless load_file(r, argv[4 &+ idx[r]], buf)
      Tour.set_name(idx[r], RC.name(r), RC.name_len(r)) if Tour.name_len(idx[r]) == 0
      r = r &+ 1
    end
    RB.start(m, Tour.seed_of(k).to_u64!, RB::CYCLE_LIMIT)
    RB.run
    LibC.printf("battle %d n %d robots %d %d %d %d seed %u winner %d cycles %d hash %u\n".to_unsafe, k, m,
      idx[0], m > 1 ? idx[1] : -1, m > 2 ? idx[2] : -1, m > 3 ? idx[3] : -1, Tour.seed_of(k), RB.winner,
      RB.cycles, RB.result_hash)
    Tour.record(m, idx)
    k = k &+ 1
  end
  m = Tour.final_lineup(idx)
  r = 0
  while r < m
    return 3 unless load_file(r, argv[4 &+ idx[r]], buf)
    r = r &+ 1
  end
  RB.start(m, Tour.final_seed.to_u64!, RB::CYCLE_LIMIT)
  RB.run
  Tour.record_final(m, idx)
  k = 0
  while k < n
    i = Tour.at_rank(k)
    nm = Tour.name(i)
    nm[Tour.name_len(i)] = 0_u8 if Tour.name_len(i) < Tour::NAME
    LibC.printf("rank %d robot %d wins %d draws %d played %d points %d damage %d avg %d name %.16s\n".to_unsafe,
      k &+ 1, i, Tour.wins(i), Tour.draws(i), Tour.played(i), Tour.points(i), Tour.damage_sum(i),
      Tour.avg_damage(i), nm)
    k = k &+ 1
  end
  LibC.printf("final n %d robots %d %d %d %d seed %u winner %d\n".to_unsafe, m, idx[0], m > 1 ? idx[1] : -1,
    m > 2 ? idx[2] : -1, m > 3 ? idx[3] : -1, Tour.final_seed, Tour.final_winner)
  LibC.printf("champion %d\n".to_unsafe, Tour.champion)
  LibC.printf("hash %u\n".to_unsafe, Tour.hash)
  t = game_alloc(Tour::MAX &* Tour::CENTRY &+ 2)
  tl = Tour.compact(t)
  LibC.printf("table ".to_unsafe)
  k = 0
  while k < tl
    LibC.printf("%02x".to_unsafe, t[k].to_i32!)
    k = k &+ 1
  end
  LibC.printf("\n".to_unsafe)
  0
end

fun main(argc : Int32, argv : UInt8**) : Int32
  return tourney(argc, argv) if argc >= 6 && same?(argv[1], "tourney")
  return 2 if argc < 5
  seed = LibC.atoi(argv[1])
  limit = LibC.atoi(argv[2])
  n = argc &- 3
  buf = game_alloc(RL::SRC_MAX)
  r = 0
  while r < n
    f = LibC.fopen(argv[r &+ 3], "rb".to_unsafe)
    return 3 if f.null?
    len = LibC.fread(buf.as(Void*), 1_u64, RL::SRC_MAX.to_u64!, f).to_i32!
    LibC.fclose(f)
    RB.load(r, buf, len)
    r = r &+ 1
  end
  RB.start(n, seed.to_u64!, limit)
  RB.run
  LibC.printf("cycles %d winner %d hash %u\n".to_unsafe, RB.cycles, RB.winner, RB.result_hash)
  r = 0
  while r < n
    LibC.printf("robot %d damage %d x %d y %d restarts %d cycles %d failed %d msg %s\n".to_unsafe, r,
      RB.damage(r), RB.x(r), RB.y(r), RB.restarts(r), RB.robot_cycles(r), RB.failed?(r) ? 1 : 0, RB.msg(r))
    r = r &+ 1
  end
  0
end
