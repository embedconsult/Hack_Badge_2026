# The robot engine built the way the badge builds it (--prelude=empty, no
# stdlib), run on the host: plays a match of the robot files given and
# prints the result, so it can be compared with the std-prelude spec build.
#   crystal build --prelude=empty crystal/firmware/test/robots/empty_prelude.cr -o /tmp/rb
#   /tmp/rb <seed> <limit> robot1.cr robot2.cr [...]
require "../../src/rt"

lib LibC
  fun calloc(n : UInt64, size : UInt64) : Void*
  fun fopen(path : UInt8*, mode : UInt8*) : Void*
  fun fread(p : Void*, size : UInt64, n : UInt64, f : Void*) : UInt64
  fun fclose(f : Void*) : Int32
  fun printf(fmt : UInt8*, ...) : Int32
  fun atoi(s : UInt8*) : Int32
end

def game_alloc(n : Int32) : UInt8*
  LibC.calloc(n.to_u64!, 1_u64).as(UInt8*)
end

require "../../src/robots/battle"

fun main(argc : Int32, argv : UInt8**) : Int32
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
  LibC.printf("cycles %d winner %d\n".to_unsafe, RB.cycles, RB.winner)
  r = 0
  while r < n
    LibC.printf("robot %d damage %d x %d y %d restarts %d cycles %d failed %d msg %s\n".to_unsafe, r,
      RB.damage(r), RB.x(r), RB.y(r), RB.restarts(r), RB.robot_cycles(r), RB.failed?(r) ? 1 : 0, RB.msg(r))
    r = r &+ 1
  end
  0
end
