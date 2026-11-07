# Helpers shared by the arcade games (blocks.cr, aliens.cr, rocks.cr):
# a chunky 3x5 font for scores and short words, thick lines, a 32-step
# integer sine, and knob bucketing with hysteresis. Same rules as common.cr
# (no prelude, no floats, wrapping arithmetic), so they run on the host too.
#
# The arcade games are our own reimplementation of the ideas in
# yigitabi5444's supercon26-badge-os ("falling blocks, a wave of descending
# aliens, and a field of drifting rocks to shoot"); thanks to its author.
#
# Frame budget: a whole-panel differential refresh takes ~0.65 s, so every
# game advances on a fixed step of STEP_MS (~1.5 fps), draws black only
# with chunky shapes, and keeps the top LABEL_H rows free for the firmware's
# mode label. The firmware runs a full clean refresh every ~12 frames.

require "./common"

module Arcade
  STEP_MS = 650 # default game step: one panel frame
  LABEL_H =  48 # rows 0..47 belong to the firmware's mode label

  # ---- 3x5 glyphs ----------------------------------------------------------
  # 15 bits, row-major from the top, MSB of each 3-bit row = left column.

  def self.glyph(c : UInt8) : Int32
    ch = c.to_i32!
    ch = ch &- 32 if ch >= 97 && ch <= 122 # lower case -> upper
    if ch == 48
      0b111_101_101_101_111
    elsif ch == 49
      0b010_110_010_010_111
    elsif ch == 50
      0b111_001_111_100_111
    elsif ch == 51
      0b111_001_111_001_111
    elsif ch == 52
      0b101_101_111_001_001
    elsif ch == 53
      0b111_100_111_001_111
    elsif ch == 54
      0b111_100_111_101_111
    elsif ch == 55
      0b111_001_001_001_001
    elsif ch == 56
      0b111_101_111_101_111
    elsif ch == 57
      0b111_101_111_001_111
    elsif ch == 65 # A
      0b010_101_111_101_101
    elsif ch == 66 # B
      0b110_101_110_101_110
    elsif ch == 67 # C
      0b111_100_100_100_111
    elsif ch == 68 # D
      0b110_101_101_101_110
    elsif ch == 69 # E
      0b111_100_110_100_111
    elsif ch == 70 # F
      0b111_100_110_100_100
    elsif ch == 71 # G
      0b111_100_101_101_111
    elsif ch == 72 # H
      0b101_101_111_101_101
    elsif ch == 73 # I
      0b111_010_010_010_111
    elsif ch == 75 # K
      0b101_101_110_101_101
    elsif ch == 76 # L
      0b100_100_100_100_111
    elsif ch == 77 # M
      0b101_111_111_101_101
    elsif ch == 78 # N
      0b110_101_101_101_101
    elsif ch == 79 # O
      0b111_101_101_101_111
    elsif ch == 80 # P
      0b111_101_111_100_100
    elsif ch == 82 # R
      0b110_101_110_101_101
    elsif ch == 83 # S
      0b111_100_111_001_111
    elsif ch == 84 # T
      0b111_010_010_010_010
    elsif ch == 85 # U
      0b101_101_101_101_111
    elsif ch == 86 # V
      0b101_101_101_101_010
    elsif ch == 87 # W
      0b101_101_111_111_101
    elsif ch == 88 # X
      0b101_101_010_101_101
    elsif ch == 89 # Y
      0b101_101_010_010_010
    elsif ch == 33 # !
      0b010_010_010_000_010
    elsif ch == 58 # :
      0b000_010_000_010_000
    elsif ch == 45 # -
      0b000_000_111_000_000
    else
      0
    end
  end

  # One glyph, each font pixel an s x s block. Returns the advance (4 * s).
  def self.draw_char(p : UInt8*, x : Int32, y : Int32, c : UInt8, s : Int32) : Int32
    g = glyph(c)
    row = 0
    while row < 5
      col = 0
      while col < 3
        bit = 14 &- (row &* 3 &+ col)
        Games.fill_rect(p, x &+ col &* s, y &+ row &* s, s, s) if (g.unsafe_shr(bit) & 1) != 0
        col = col &+ 1
      end
      row = row &+ 1
    end
    4 &* s
  end

  def self.text_width(n : Int32, s : Int32) : Int32
    n <= 0 ? 0 : n &* 4 &* s &- s
  end

  def self.draw_text(p : UInt8*, x : Int32, y : Int32, t : String, s : Int32) : Int32
    q = t.to_unsafe
    i = 0
    while i < t.bytesize
      x = x &+ draw_char(p, x, y, q[i], s)
      i = i &+ 1
    end
    x
  end

  def self.digits(n : Int32) : Int32
    n = 0 if n < 0
    k = 1
    while n >= 10
      n = n.unsafe_div(10)
      k = k &+ 1
    end
    k
  end

  # Decimal n (>= 0), at least `min` digits (leading zeros), left at x.
  def self.draw_number(p : UInt8*, x : Int32, y : Int32, n : Int32, s : Int32, min : Int32 = 1) : Int32
    n = 0 if n < 0
    k = digits(n)
    k = min if min > k
    i = k &- 1
    while i >= 0
      d = n.unsafe_mod(10)
      n = n.unsafe_div(10)
      draw_char(p, x &+ i &* 4 &* s, y, (48 &+ d).to_u8!, s)
      i = i &- 1
    end
    x &+ k &* 4 &* s
  end

  # ---- lines -----------------------------------------------------------------

  # Line from (x0, y0) to (x1, y1), t px thick (a t x t square per step).
  def self.line(p : UInt8*, x0 : Int32, y0 : Int32, x1 : Int32, y1 : Int32, t : Int32) : Nil
    dx = x1 &- x0
    dy = y1 &- y0
    sx = dx < 0 ? -1 : 1
    sy = dy < 0 ? -1 : 1
    dx = 0 &- dx if dx < 0
    dy = 0 &- dy if dy < 0
    h = t.unsafe_shr(1)
    err = dx &- dy
    x = x0
    y = y0
    while true
      Games.fill_rect(p, x &- h, y &- h, t, t)
      break if x == x1 && y == y1
      e2 = err &* 2
      if e2 > 0 &- dy
        err = err &- dy
        x = x &+ sx
      end
      if e2 < dx
        err = err &+ dx
        y = y &+ sy
      end
    end
  end

  # ---- trig ------------------------------------------------------------------
  # 32 directions; dir 0 = +x (right), increasing clockwise on screen
  # (y grows downwards). Q10 results (1024 = 1.0).

  def self.sin_q(k : Int32) : Int32
    if k == 0
      0
    elsif k == 1
      200
    elsif k == 2
      392
    elsif k == 3
      569
    elsif k == 4
      724
    elsif k == 5
      851
    elsif k == 6
      946
    elsif k == 7
      1004
    else
      1024
    end
  end

  def self.sin32(d : Int32) : Int32
    d = d & 31
    if d <= 8
      sin_q(d)
    elsif d <= 16
      sin_q(16 &- d)
    elsif d <= 24
      0 &- sin_q(d &- 16)
    else
      0 &- sin_q(32 &- d)
    end
  end

  def self.cos32(d : Int32) : Int32
    sin32(d &+ 8)
  end

  # ---- knobs -------------------------------------------------------------------

  # Knob position k (Q12) -> bucket 0..n-1, keeping `cur` while k is within
  # `hyst` (Q12) of its range, so a knob resting on a boundary doesn't flicker.
  def self.bucket(k : Int32, n : Int32, cur : Int32, hyst : Int32) : Int32
    b = (k &* n).unsafe_div(Games::KNOB_ONE &+ 1)
    return b if cur < 0 || cur >= n || b == cur
    lo = (cur &* (Games::KNOB_ONE &+ 1)).unsafe_div(n) &- hyst
    hi = ((cur &+ 1) &* (Games::KNOB_ONE &+ 1)).unsafe_div(n) &+ hyst
    k >= lo && k < hi ? cur : b
  end

  # Thick frame around the whole panel below the label (game over marker).
  def self.over_frame(p : UInt8*) : Nil
    Games.rect_outline(p, 0, LABEL_H, Games::W, Games::H &- LABEL_H, 8)
  end

  # Centred banner: white box with a black outline and the text inside.
  def self.banner(p : UInt8*, t : String, s : Int32, cy : Int32) : Nil
    w = text_width(t.bytesize, s)
    h = 5 &* s
    x = (Games::W &- w).unsafe_div(2)
    y = cy &- h.unsafe_div(2)
    clear_rect(p, x &- 24, y &- 24, w &+ 48, h &+ 48)
    Games.rect_outline(p, x &- 24, y &- 24, w &+ 48, h &+ 48, 6)
    draw_text(p, x, y, t, s)
  end

  # Clears a rect (white), clipped.
  def self.clear_rect(p : UInt8*, x0 : Int32, y0 : Int32, w : Int32, h : Int32) : Nil
    y = y0
    while y < y0 &+ h
      x = x0
      while x < x0 &+ w
        if x >= 0 && y >= 0 && x < Games::W && y < Games::H
          i = y &* Games::ROW_BYTES &+ x.unsafe_shr(3)
          p[i] = p[i] & (0x80_u8.unsafe_shr(x & 7) ^ 0xFF_u8)
        end
        x = x &+ 1
      end
      y = y &+ 1
    end
  end
end
