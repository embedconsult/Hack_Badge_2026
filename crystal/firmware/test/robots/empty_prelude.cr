# Type-checks the robot engine under the badge's --prelude=empty (no stdlib):
#   crystal build --prelude=empty --no-codegen crystal/firmware/test/robots/empty_prelude.cr
require "../../src/rt"

lib LibC
  fun calloc(n : UInt64, size : UInt64) : Void*
end

def game_alloc(n : Int32) : UInt8*
  LibC.calloc(n.to_u64!, 1_u64).as(UInt8*)
end

require "../../src/robots/lang"

src = "main(\"A\") do\n  drive(90, 50)\nend\n"
RL.parse(src.to_unsafe, src.bytesize)
