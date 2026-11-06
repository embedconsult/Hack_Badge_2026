# Badge-side allocator for the games (newlib malloc; with CONFIG_SPIRAM the
# larger buffers, e.g. the 80 KB sketch canvas, may land in PSRAM).
# The host tests provide their own game_alloc in test/shim.cr instead.

lib LibGamesMem
  fun malloc(size : UInt32) : Void*
end

def game_alloc(n : Int32) : UInt8*
  LibGamesMem.malloc(n.to_u32!).as(UInt8*)
end
