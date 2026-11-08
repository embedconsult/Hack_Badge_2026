# Slide deck player: draws one slide of a packed deck into the black / red
# planes. The deck is data made on the host by firmware/slides/slidec.cr
# (layout, wrapping and font choice all happen there); this file only reads
# its records. Written for --prelude=empty and free of ESP-IDF calls, so the
# host specs (test/slides_spec.cr) and the converter's --preview run it too.
#
# Format "SLD1", little-endian:
#   0  "SLD1"
#   4  u16 slide count n, u16 0
#   8  u32 offset[n + 1]   (from the deck start; offset[n] = deck size)
#   then each slide: records until op 0
#     0                                end of slide
#     1 x:u16 y:u16 scale:u8 color:u8 len:u8 bytes[len]
#                                      text, 5x7 font (6x8 cell), ASCII
#     2 x:u16 y:u16 w:u16 h:u16 color:u8
#                                      filled rectangle
#     3 x:u16 y:u16 w:u16 h:u16 t:u8 color:u8
#                                      outline t px thick, inside the rect
#   color: 1 black, 2 red (EPD::BLACK / EPD::RED)

require "./common"

module SlideDeck
  OP_END   = 0
  OP_TEXT  = 1
  OP_RECT  = 2
  OP_FRAME = 3
  BLACK    = 1
  RED      = 2

  def self.u16(p : UInt8*) : Int32
    p[0].to_i32! | p[1].to_i32!.unsafe_shl(8)
  end

  def self.u32(p : UInt8*) : Int32
    p[0].to_i32! | p[1].to_i32!.unsafe_shl(8) | p[2].to_i32!.unsafe_shl(16) | p[3].to_i32!.unsafe_shl(24)
  end

  # Slide count, or 0 if this isn't a well-formed deck.
  def self.count(d : UInt8*, size : Int32) : Int32
    return 0 if d.null? || size < 12
    return 0 unless d[0] == 0x53_u8 && d[1] == 0x4C_u8 && d[2] == 0x44_u8 && d[3] == 0x31_u8 # SLD1
    n = u16(d + 4_i64)
    return 0 if 8 &+ (n &+ 1) &* 4 > size
    return 0 if u32(d + (8 &+ n &* 4).to_i64!) != size
    n
  end

  # Pager: slide after moving `steps` from cur, clamped to 0..n-1 (a talk
  # doesn't wrap from the last slide to the cover).
  def self.step(cur : Int32, steps : Int32, n : Int32) : Int32
    return 0 if n <= 0
    s = cur &+ steps
    s = 0 if s < 0
    s = n &- 1 if s >= n
    s
  end

  # True if slide i draws anything red (needs the slow colour refresh).
  def self.red?(d : UInt8*, size : Int32, i : Int32) : Bool
    walk(d, size, i, Pointer(UInt8).null, Pointer(UInt8).null, Pointer(UInt8).null)
  end

  # Clears both planes and draws slide i (font: 95 glyphs x 5 column bytes,
  # LSB = top row). Returns true if anything was red.
  def self.render(d : UInt8*, size : Int32, i : Int32, black : UInt8*, red : UInt8*, font : UInt8*) : Bool
    Games.clear(black, red)
    walk(d, size, i, black, red, font)
  end

  # Runs the records of slide i; draws only when black isn't null.
  def self.walk(d : UInt8*, size : Int32, i : Int32, black : UInt8*, red : UInt8*, font : UInt8*) : Bool
    n = count(d, size)
    return false if i < 0 || i >= n
    p = u32(d + (8 &+ i &* 4).to_i64!)
    stop = u32(d + (12 &+ i &* 4).to_i64!)
    any_red = false
    while p < stop
      op = d[p].to_i32!
      if op == OP_TEXT
        break if p &+ 8 > stop
        len = d[p &+ 7].to_i32!
        break if p &+ 8 &+ len > stop
        c = d[p &+ 6].to_i32!
        any_red = true if c == RED
        unless black.null?
          text(c == RED ? red : black, u16(d + (p &+ 1).to_i64!), u16(d + (p &+ 3).to_i64!),
            d[p &+ 5].to_i32!, d + (p &+ 8).to_i64!, len, font)
        end
        p = p &+ 8 &+ len
      elsif op == OP_RECT || op == OP_FRAME
        k = op == OP_RECT ? 10 : 11
        break if p &+ k > stop
        c = d[p &+ k &- 1].to_i32!
        any_red = true if c == RED
        unless black.null?
          pl = c == RED ? red : black
          x = u16(d + (p &+ 1).to_i64!)
          y = u16(d + (p &+ 3).to_i64!)
          w = u16(d + (p &+ 5).to_i64!)
          h = u16(d + (p &+ 7).to_i64!)
          if op == OP_RECT
            Games.fill_rect(pl, x, y, w, h)
          else
            Games.rect_outline(pl, x, y, w, h, d[p &+ 9].to_i32!)
          end
        end
        p = p &+ k
      else
        break # OP_END or an unknown op
      end
    end
    any_red
  end

  # n bytes in the 5x7 font, each font pixel a scale x scale block.
  def self.text(pl : UInt8*, x : Int32, y : Int32, scale : Int32, s : UInt8*, n : Int32, font : UInt8*) : Nil
    k = 0
    while k < n
      ch = s[k].to_i32!
      ch = 0x3F if ch < 0x20 || ch > 0x7E
      g = font + ((ch &- 0x20) &* 5).to_i64!
      col = 0
      while col < 5
        bits = g[col]
        row = 0
        while row < 7
          if (bits.unsafe_shr(row) & 1_u8) != 0_u8
            Games.fill_rect(pl, x &+ col &* scale, y &+ row &* scale, scale, scale)
          end
          row = row &+ 1
        end
        col = col &+ 1
      end
      x = x &+ 6 &* scale
      k = k &+ 1
    end
  end
end
