# Streaming PNG decoder that renders straight into the e-paper planes
# (black + red, 120 bytes x 672 rows, MSB = leftmost pixel). Ported from
# crystal/src/badge/png.cr to the --prelude=empty style (module state, raw
# pointers, error codes instead of exceptions); same color mapping:
#   r >= 128, g < 128, b < 128 -> red;  r, g, b < 128 -> black;  else white.
# Pixels with alpha < 128 (alpha channel, palette tRNS, gray tRNS key) are
# left alone. Non-interlaced only; every color type and bit depth.

require "./inflate"

module PNG
  WHITE = 0_u8
  BLACK = 1_u8
  RED   = 2_u8
  SKIP  = 3_u8

  COLOR_GRAY       = 0
  COLOR_RGB        = 2
  COLOR_PALETTE    = 3
  COLOR_GRAY_ALPHA = 4
  COLOR_RGBA       = 6

  FB_WIDTH  = 960
  FB_HEIGHT = 672

  # Error codes (0 = ok); inflate errors are reported as 100 + Inflate.err.
  E_SIGNATURE = 1
  E_CHUNK     = 2 # truncated chunk / length too large
  E_CRC       = 3
  E_IHDR      = 4 # first chunk not IHDR, or bad size / depth / type / method
  E_INTERLACE = 5
  E_PLTE      = 6
  E_NO_DATA   = 7
  E_TRUNCATED = 8
  E_FILTER    = 9
  E_MEMORY    = 10

  @@err = 0
  @@data = uninitialized UInt8*
  @@size = 0
  @@check_crc = true
  # IDAT source
  @@pos = 0
  @@end = 0
  @@next_chunk = 0
  @@done = false
  # header
  @@width = 0
  @@height = 0
  @@depth = 0
  @@ctype = 0
  @@kinds = uninitialized UInt8*
  @@line_a = uninitialized UInt8*
  @@line_b = uninitialized UInt8*
  @@line_cap = 0

  def self.err : Int32
    @@err
  end

  def self.width : Int32
    @@width
  end

  def self.height : Int32
    @@height
  end

  def self.fail(code : Int32) : Nil
    @@err = code if @@err == 0
  end

  @[AlwaysInline]
  def self.be32u(p : Int32) : UInt32
    d = @@data
    d[p].to_u32!.unsafe_shl(24) | d[p &+ 1].to_u32!.unsafe_shl(16) | d[p &+ 2].to_u32!.unsafe_shl(8) | d[p &+ 3].to_u32!
  end

  def self.type?(p : Int32, a : UInt8, b : UInt8, c : UInt8, d : UInt8) : Bool
    x = @@data
    x[p] == a && x[p &+ 1] == b && x[p &+ 2] == c && x[p &+ 3] == d
  end

  @@crc_table = Pointer(UInt32).null

  # CRC-32 lookup table (reflected 0xEDB88320), computed once.
  def self.crc_table : UInt32*
    if @@crc_table.null?
      t = LibIDF.heap_caps_malloc(1024_u32, 0x804_u32).as(UInt32*)
      return t if t.null?
      n = 0
      while n < 256
        c = n.to_u32!
        k = 0
        while k < 8
          c = (c & 1_u32) != 0_u32 ? c.unsafe_shr(1) ^ 0xedb88320_u32 : c.unsafe_shr(1)
          k = k &+ 1
        end
        t[n] = c
        n = n &+ 1
      end
      @@crc_table = t
    end
    @@crc_table
  end

  def self.crc32(p : Int32, n : Int32) : UInt32
    crc = 0xffffffff_u32
    t = crc_table
    i = 0
    if t.null? # no memory for the table: bitwise
      while i < n
        crc = crc ^ @@data[p &+ i].to_u32!
        k = 0
        while k < 8
          crc = (crc & 1_u32) != 0_u32 ? crc.unsafe_shr(1) ^ 0xedb88320_u32 : crc.unsafe_shr(1)
          k = k &+ 1
        end
        i = i &+ 1
      end
    else
      while i < n
        crc = t[((crc ^ @@data[p &+ i].to_u32!) & 0xFF_u32).to_i32!] ^ crc.unsafe_shr(8)
        i = i &+ 1
      end
    end
    crc ^ 0xffffffff_u32
  end

  # Length of the chunk whose length field is at `p`, or -1 on error.
  def self.chunk_length(p : Int32) : Int32
    if p > @@size &- 8
      fail(E_CHUNK)
      return -1
    end
    v = be32u(p)
    if v > 0x7fff_ffff_u32 || v.to_i32! > @@size &- p &- 12
      fail(E_CHUNK)
      return -1
    end
    len = v.to_i32!
    if @@check_crc && crc32(p &+ 4, len &+ 4) != be32u(p &+ 8 &+ len)
      fail(E_CRC)
      return -1
    end
    len
  end

  # ---- IDAT byte source (used by Inflate.need_byte) ------------------------

  def self.enter(chunk : Int32) : Nil
    len = chunk_length(chunk)
    if len < 0
      @@done = true
      @@end = @@pos
      return
    end
    @@pos = chunk &+ 8
    @@end = @@pos &+ len
    @@next_chunk = @@end &+ 4
    @@done = true if @@next_chunk > @@size &- 8
  end

  def self.next_byte : Int32
    while @@pos >= @@end
      return -1 if @@done
      if type?(@@next_chunk &+ 4, 0x49_u8, 0x44_u8, 0x41_u8, 0x54_u8) # IDAT
        enter(@@next_chunk)
      else
        @@done = true
      end
    end
    b = @@data[@@pos].to_i32!
    @@pos = @@pos &+ 1
    b
  end

  # ---- decoding --------------------------------------------------------------

  @[AlwaysInline]
  def self.color_kind(r : UInt8, g : UInt8, b : UInt8) : UInt8
    if g < 128_u8 && b < 128_u8
      r >= 128_u8 ? RED : BLACK
    else
      WHITE
    end
  end

  def self.parse_header : Bool
    sig = 0x89_u8
    if @@size < 33 || @@data[0] != sig || !type?(1, 0x50_u8, 0x4e_u8, 0x47_u8, 0x0d_u8) ||
       @@data[5] != 0x0a_u8 || @@data[6] != 0x1a_u8 || @@data[7] != 0x0a_u8
      fail(E_SIGNATURE)
      return false
    end
    len = chunk_length(8)
    return false if len < 0
    unless len == 13 && type?(12, 0x49_u8, 0x48_u8, 0x44_u8, 0x52_u8) # IHDR
      fail(E_IHDR)
      return false
    end
    w = be32u(16)
    h = be32u(20)
    @@depth = @@data[24].to_i32!
    @@ctype = @@data[25].to_i32!
    d = @@depth
    ct = @@ctype
    valid = if ct == COLOR_GRAY
              d == 1 || d == 2 || d == 4 || d == 8 || d == 16
            elsif ct == COLOR_PALETTE
              d == 1 || d == 2 || d == 4 || d == 8
            elsif ct == COLOR_RGB || ct == COLOR_GRAY_ALPHA || ct == COLOR_RGBA
              d == 8 || d == 16
            else
              false
            end
    if !valid || w == 0_u32 || h == 0_u32 || w > 0x1000000_u32 || h > 0x1000000_u32 ||
       @@data[26] != 0_u8 || @@data[27] != 0_u8
      fail(E_IHDR)
      return false
    end
    if @@data[28] != 0_u8
      fail(E_INTERLACE)
      return false
    end
    @@width = w.to_i32!
    @@height = h.to_i32!
    true
  end

  def self.channels : Int32
    ct = @@ctype
    ct == COLOR_RGB ? 3 : (ct == COLOR_GRAY_ALPHA ? 2 : (ct == COLOR_RGBA ? 4 : 1))
  end

  def self.unfilter(filter : UInt8, cur : UInt8*, prev : UInt8*, n : Int32, bpp : Int32) : Nil
    f = filter.to_i32!
    i = 0
    if f == 0
    elsif f == 1
      i = bpp
      while i < n
        cur[i] = cur[i] &+ cur[i &- bpp]
        i = i &+ 1
      end
    elsif f == 2
      while i < n
        cur[i] = cur[i] &+ prev[i]
        i = i &+ 1
      end
    elsif f == 3
      while i < n
        left = i >= bpp ? cur[i &- bpp].to_i32! : 0
        cur[i] = cur[i] &+ (left &+ prev[i].to_i32!).unsafe_shr(1).to_u8!
        i = i &+ 1
      end
    elsif f == 4
      while i < n
        a = 0
        c = 0
        if i >= bpp
          a = cur[i &- bpp].to_i32!
          c = prev[i &- bpp].to_i32!
        end
        b = prev[i].to_i32!
        p = a &+ b &- c
        pa = p &- a
        pa = 0 &- pa if pa < 0
        pb = p &- b
        pb = 0 &- pb if pb < 0
        pc = p &- c
        pc = 0 &- pc if pc < 0
        pred = pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)
        cur[i] = cur[i] &+ pred.to_u8!
        i = i &+ 1
      end
    else
      fail(E_FILTER)
    end
  end

  @[AlwaysInline]
  def self.plot(black : UInt8*, red : UInt8*, i : Int32, kind : UInt8) : Nil
    idx = i.unsafe_shr(3)
    bit = 0x80_u8.unsafe_shr(i & 7)
    clear = bit ^ 0xff_u8
    if kind == RED
      red[idx] = red[idx] | bit
      black[idx] = black[idx] & clear
    elsif kind == BLACK
      black[idx] = black[idx] | bit
      red[idx] = red[idx] & clear
    elsif kind == WHITE
      black[idx] = black[idx] & clear
      red[idx] = red[idx] & clear
    end
  end

  def self.render_row(row : UInt8*, x0 : Int32, x1 : Int32, base : Int32, black : UInt8*, red : UInt8*) : Nil
    d = @@depth
    ct = @@ctype
    kinds = @@kinds
    px = x0
    if ct == COLOR_GRAY || ct == COLOR_PALETTE
      if d < 8
        mask = 1.unsafe_shl(d) &- 1
        while px < x1
          bi = px &* d
          sample = row[bi.unsafe_shr(3)].to_i32!.unsafe_shr(8 &- d &- (bi & 7)) & mask
          plot(black, red, base &+ px, kinds[sample])
          px = px &+ 1
        end
      else
        step = d.unsafe_shr(3)
        while px < x1
          plot(black, red, base &+ px, kinds[row[px &* step].to_i32!])
          px = px &+ 1
        end
      end
    else
      s = d.unsafe_shr(3)
      ch = channels
      while px < x1
        o = px &* ch &* s
        kind = WHITE
        if ct == COLOR_RGB
          kind = color_kind(row[o], row[o &+ s], row[o &+ 2 &* s])
        elsif ct == COLOR_GRAY_ALPHA
          kind = row[o &+ s] < 128_u8 ? SKIP : kinds[row[o].to_i32!]
        else
          kind = row[o &+ 3 &* s] < 128_u8 ? SKIP : color_kind(row[o], row[o &+ s], row[o &+ 2 &* s])
        end
        plot(black, red, base &+ px, kind)
        px = px &+ 1
      end
    end
  end

  # Decodes the PNG at data[0, size] into the planes with its top-left corner
  # at (x, y), clipped to 960 x 672. Returns true on success, else see `err`.
  def self.draw(data : UInt8*, size : Int32, black : UInt8*, red : UInt8*, x : Int32, y : Int32,
                check_crc : Bool) : Bool
    @@err = 0
    @@data = data
    @@size = size
    @@check_crc = check_crc
    return false unless parse_header

    @@kinds = Inflate.alloc(256) if @@kinds.null?
    kinds = @@kinds
    if kinds.null?
      fail(E_MEMORY)
      return false
    end
    i = 0
    while i < 256
      kinds[i] = WHITE
      i = i &+ 1
    end

    # Walk ancillary chunks up to the first IDAT.
    have_plte = false
    trns_pos = -1
    trns_len = 0
    pos = 33
    while true
      len = chunk_length(pos)
      return false if len < 0
      body = pos &+ 8
      if type?(pos &+ 4, 0x49_u8, 0x44_u8, 0x41_u8, 0x54_u8) # IDAT
        break
      elsif type?(pos &+ 4, 0x50_u8, 0x4c_u8, 0x54_u8, 0x45_u8) # PLTE
        n = len.unsafe_div(3)
        if len.unsafe_mod(3) != 0 || len == 0 || len > 768 ||
           (@@ctype == COLOR_PALETTE && n > 1.unsafe_shl(@@depth))
          fail(E_PLTE)
          return false
        end
        if @@ctype == COLOR_PALETTE
          # Indices >= n (out of the palette's range; invalid PNG) keep the
          # WHITE set above, so they can never read past the 256-entry table.
          i = 0
          while i < n
            p = body &+ i &* 3
            kinds[i] = color_kind(data[p], data[p &+ 1], data[p &+ 2])
            i = i &+ 1
          end
        end
        have_plte = true
      elsif type?(pos &+ 4, 0x74_u8, 0x52_u8, 0x4e_u8, 0x53_u8) # tRNS
        trns_pos = body
        trns_len = len
      elsif type?(pos &+ 4, 0x49_u8, 0x45_u8, 0x4e_u8, 0x44_u8) # IEND
        fail(E_NO_DATA)
        return false
      end
      pos = body &+ len &+ 4
    end
    idat_pos = pos

    if @@ctype == COLOR_PALETTE
      unless have_plte
        fail(E_PLTE)
        return false
      end
      if trns_pos >= 0
        n = trns_len < 256 ? trns_len : 256
        i = 0
        while i < n
          kinds[i] = SKIP if data[trns_pos &+ i] < 128_u8
          i = i &+ 1
        end
      end
    elsif @@ctype == COLOR_GRAY || @@ctype == COLOR_GRAY_ALPHA
      dd = @@depth > 8 ? 8 : @@depth
      maxv = 1.unsafe_shl(dd) &- 1
      s = 0
      while s <= maxv
        kinds[s] = (s &* 255).unsafe_div(maxv) < 128 ? BLACK : WHITE
        s = s &+ 1
      end
      if @@ctype == COLOR_GRAY && trns_pos >= 0 && trns_len == 2 && @@depth <= 8
        key = data[trns_pos].to_i32!.unsafe_shl(8) | data[trns_pos &+ 1].to_i32!
        kinds[key] = SKIP if key <= maxv
      end
    end

    bits_pp = channels &* @@depth
    row_bytes = (@@width &* bits_pp &+ 7).unsafe_shr(3)
    bpp = bits_pp.unsafe_shr(3)
    bpp = 1 if bpp < 1
    if row_bytes &+ 1 > @@line_cap
      # Rows of large images can exceed internal RAM comfortably; use any 8-bit heap.
      # Grow: free the old pair first (they were allocated together).
      unless @@line_cap == 0
        LibIDF.heap_caps_free(@@line_a.as(Void*))
        LibIDF.heap_caps_free(@@line_b.as(Void*))
      end
      @@line_a = LibIDF.heap_caps_malloc((row_bytes &+ 1).to_u32!, 0x4_u32).as(UInt8*)
      @@line_b = LibIDF.heap_caps_malloc((row_bytes &+ 1).to_u32!, 0x4_u32).as(UInt8*)
      if @@line_a.null? || @@line_b.null?
        # Free whichever half succeeded, so a retry starts clean.
        LibIDF.heap_caps_free(@@line_a.as(Void*)) unless @@line_a.null?
        LibIDF.heap_caps_free(@@line_b.as(Void*)) unless @@line_b.null?
        @@line_a = Pointer(UInt8).null
        @@line_b = Pointer(UInt8).null
        @@line_cap = 0
        fail(E_MEMORY)
        return false
      end
      @@line_cap = row_bytes &+ 1
    end
    prev = @@line_a
    cur = @@line_b
    i = 0
    while i <= row_bytes
      prev[i] = 0_u8
      i = i &+ 1
    end

    @@done = false
    @@pos = 0
    @@end = 0
    enter(idat_pos)
    return false if @@err != 0
    unless Inflate.start
      fail(Inflate.err == 0 ? E_MEMORY : 100 &+ Inflate.err)
      return false
    end

    # Entirely off-screen (also keeps 0 - x below from overflowing for
    # Int32::MIN): nothing to draw, but the image is still decoded/checked.
    visible = x > 0 &- @@width && x < FB_WIDTH && y > 0 &- @@height && y < FB_HEIGHT
    unless visible
      x = 0
      y = 0
    end
    x_start = x < 0 ? 0 &- x : 0
    x_end = FB_WIDTH &- x
    x_end = @@width if x_end > @@width
    x_end = 0 if x_end < 0
    row = 0
    while row < @@height
      sy = y &+ row
      break if visible && sy >= FB_HEIGHT
      if Inflate.read(cur, row_bytes &+ 1) != row_bytes &+ 1
        fail(Inflate.err != 0 ? 100 &+ Inflate.err : (@@err != 0 ? @@err : E_TRUNCATED))
        return false
      end
      unfilter(cur[0], cur + 1_i64, prev + 1_i64, row_bytes, bpp)
      return false if @@err != 0
      if visible && sy >= 0 && x_start < x_end
        render_row(cur + 1_i64, x_start, x_end, sy &* FB_WIDTH &+ x, black, red)
      end
      t = prev
      prev = cur
      cur = t
      row = row &+ 1
    end
    # Every row decoded: finish the zlib stream so its Adler-32 is checked.
    # (Rows cut off at the bottom of the screen are not decoded, so then the
    # checksum can't be verified.)
    if row == @@height && !Inflate.finish_stream
      fail(100 &+ Inflate.err)
      return false
    end
    true
  end
end
