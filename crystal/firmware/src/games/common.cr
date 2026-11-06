# Shared helpers for the badge games. Written for --prelude=empty (module
# state, raw pointers, wrapping arithmetic, no String formatting, no GC) but
# free of ESP-IDF calls so the same files compile on the host with the
# standard prelude (see test/).
#
# The including program must define
#   def game_alloc(n : Int32) : UInt8*
# (badge: require "./games/badge"; host: test/shim.cr). Allocations are made
# once per game and never freed.
#
# Planes are 1 bit per pixel, 960x672, 120 bytes per row, MSB = leftmost.

lib LibGames
  struct Input
    left_mv : Int32  # calibrated millivolts, left knob
    right_mv : Int32 # calibrated millivolts, right knob
    held : UInt32    # Games::BTN_* bits currently down
    pressed : UInt32 # Games::BTN_* bits that went down since the last tick
  end
end

module Games
  W         = 960
  H         = 672
  ROW_BYTES = 120
  PLANE     = 80640

  BTN_A     = 1_u32 # User A
  BTN_B     = 2_u32 # User B
  BTN_PLUS  = 4_u32 # Menu +
  BTN_MINUS = 8_u32 # Menu -

  # Knob ranges measured on the badge (calibrated mV).
  LEFT_MV_LO  =  694
  LEFT_MV_HI  = 2963
  RIGHT_MV_LO =   70
  RIGHT_MV_HI = 2703

  # Knob positions are Q12: 0..KNOB_ONE (0.0..1.0).
  KNOB_ONE = 4096

  @@rng = 0x2545F491_u32

  # Builds an Input; `pressed` = buttons down now that were up in prev_held.
  def self.input(left_mv : Int32, right_mv : Int32, held : UInt32, prev_held : UInt32) : LibGames::Input
    i = LibGames::Input.new
    i.left_mv = left_mv
    i.right_mv = right_mv
    i.held = held
    i.pressed = held & (prev_held ^ 0xFFFFFFFF_u32)
    i
  end

  def self.pressed?(inp : LibGames::Input, btn : UInt32) : Bool
    (inp.pressed & btn) != 0_u32
  end

  # mV clamped to [lo, hi] -> 0..KNOB_ONE
  def self.knob(mv : Int32, lo : Int32, hi : Int32) : Int32
    mv = lo if mv < lo
    mv = hi if mv > hi
    ((mv &- lo) &* KNOB_ONE).unsafe_div(hi &- lo)
  end

  def self.knob_left(inp : LibGames::Input) : Int32
    knob(inp.left_mv, LEFT_MV_LO, LEFT_MV_HI)
  end

  def self.knob_right(inp : LibGames::Input) : Int32
    knob(inp.right_mv, RIGHT_MV_LO, RIGHT_MV_HI)
  end

  # Inverse of knob(): Q12 position -> mV (handy for tests / simulators).
  def self.mv_for(pos : Int32, lo : Int32, hi : Int32) : Int32
    lo &+ (pos &* (hi &- lo)).unsafe_div(KNOB_ONE)
  end

  # ---- xorshift32 RNG ----------------------------------------------------

  def self.seed(s : UInt32) : Nil
    @@rng = s == 0_u32 ? 0x2545F491_u32 : s
  end

  def self.rand : UInt32
    x = @@rng
    x = x ^ x.unsafe_shl(13)
    x = x ^ x.unsafe_shr(17)
    x = x ^ x.unsafe_shl(5)
    @@rng = x
    x
  end

  # 0 <= r < n (n > 0)
  def self.rand_below(n : Int32) : Int32
    rand.unsafe_mod(n.to_u32!).to_i32!
  end

  # ---- 1-bit plane drawing -----------------------------------------------

  def self.zero(p : UInt8*, n : Int32) : Nil
    i = 0
    while i < n
      p[i] = 0_u8
      i = i &+ 1
    end
  end

  def self.copy(dst : UInt8*, src : UInt8*, n : Int32) : Nil
    i = 0
    while i < n
      dst[i] = src[i]
      i = i &+ 1
    end
  end

  # White screen: both planes cleared.
  def self.clear(black : UInt8*, red : UInt8*) : Nil
    zero(black, PLANE)
    zero(red, PLANE)
  end

  def self.set(p : UInt8*, x : Int32, y : Int32) : Nil
    return if x < 0 || y < 0 || x >= W || y >= H
    i = y &* ROW_BYTES &+ x.unsafe_shr(3)
    p[i] = p[i] | 0x80_u8.unsafe_shr(x & 7)
  end

  def self.get(p : UInt8*, x : Int32, y : Int32) : Bool
    return false if x < 0 || y < 0 || x >= W || y >= H
    i = y &* ROW_BYTES &+ x.unsafe_shr(3)
    (p[i] & 0x80_u8.unsafe_shr(x & 7)) != 0_u8
  end

  # Filled rectangle, clipped to the panel.
  def self.fill_rect(p : UInt8*, x0 : Int32, y0 : Int32, w : Int32, h : Int32) : Nil
    x1 = x0 &+ w
    y1 = y0 &+ h
    x0 = 0 if x0 < 0
    y0 = 0 if y0 < 0
    x1 = W if x1 > W
    y1 = H if y1 > H
    y = y0
    while y < y1
      row = p + (y &* ROW_BYTES).to_i64!
      x = x0
      while x < x1
        if (x & 7) == 0 && x &+ 8 <= x1
          row[x.unsafe_shr(3)] = 0xFF_u8
          x = x &+ 8
        else
          i = x.unsafe_shr(3)
          row[i] = row[i] | 0x80_u8.unsafe_shr(x & 7)
          x = x &+ 1
        end
      end
      y = y &+ 1
    end
  end

  # Rectangle outline `t` px thick, inside (x0, y0, w, h).
  def self.rect_outline(p : UInt8*, x0 : Int32, y0 : Int32, w : Int32, h : Int32, t : Int32) : Nil
    fill_rect(p, x0, y0, w, t)
    fill_rect(p, x0, y0 &+ h &- t, w, t)
    fill_rect(p, x0, y0, t, h)
    fill_rect(p, x0 &+ w &- t, y0, t, h)
  end
end
