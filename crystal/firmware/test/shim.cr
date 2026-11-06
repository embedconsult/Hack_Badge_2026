# Host shim: the games compile with the standard prelude, which already has
# everything rt.cr provides (Pointer#[], #+, .null, #null?). Only the
# allocator the badge gets from src/games/badge.cr is needed here.

def game_alloc(n : Int32) : UInt8*
  Pointer(UInt8).malloc(n) # zeroed, GC-scanned via the class vars
end

require "../src/games/menu"
