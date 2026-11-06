require "./inflate"

# Streaming PNG decoder that renders straight into the e-paper's two 1-bit
# framebuffers (black plane and red plane, MSB-first, bit index
# `y * fb_width + x`), as `lib/large_png.py#show_png` does.
#
# Peak heap use for one `draw`: the inflate window (<= 32 KiB, taken from
# the zlib header), its Huffman tables (~1.4 KiB) and two scanline buffers
# of `row_bytes + 1` each. Nothing is allocated per row or per pixel.
#
# Supported: every non-interlaced PNG color type and bit depth
# (grayscale 1/2/4/8/16, RGB 8/16, palette 1/2/4/8, gray+alpha 8/16,
# RGBA 8/16) with all five filter types. Interlaced images raise.
#
# Color mapping (shared by palette entries, RGB pixels and gray levels, the
# latter treated as r = g = b, using the high byte of 16-bit samples):
#   r >= 128, g < 128, b < 128 -> red   (red bit set, black bit cleared)
#   r, g, b all < 128          -> black (black bit set, red bit cleared)
#   anything else              -> white (both bits cleared)
# Pixels with alpha < 128 (alpha channel, palette tRNS, or the gray tRNS
# key for depths <= 8) are transparent and leave the framebuffers alone.
module Badge::PNG
  class Error < Exception
  end

  SCREEN_WIDTH  = 960
  SCREEN_HEIGHT = 672

  WHITE = 0_u8
  BLACK = 1_u8
  RED   = 2_u8
  SKIP  = 3_u8

  COLOR_GRAY       = 0
  COLOR_RGB        = 2
  COLOR_PALETTE    = 3
  COLOR_GRAY_ALPHA = 4
  COLOR_RGBA       = 6

  MAX_DIMENSION = 1 << 24

  record Header, width : Int32, height : Int32, bit_depth : Int32, color_type : Int32, interlace : Int32 do
    def channels : Int32
      case color_type
      when COLOR_RGB        then 3
      when COLOR_GRAY_ALPHA then 2
      when COLOR_RGBA       then 4
      else                       1
      end
    end

    def bits_per_pixel : Int32
      channels * bit_depth
    end

    # Bytes per complete pixel, at least 1 (the filter "bpp").
    def filter_bpp : Int32
      b = bits_per_pixel >> 3
      b < 1 ? 1 : b
    end

    def row_bytes : Int32
      (width * bits_per_pixel + 7) >> 3
    end
  end

  # Classifies an 8-bit RGB color into WHITE, BLACK or RED.
  @[AlwaysInline]
  def self.color_kind(r : Int, g : Int, b : Int) : UInt8
    if g < 128 && b < 128
      r >= 128 ? RED : BLACK
    else
      WHITE
    end
  end

  # Updates a running CRC-32 (IEEE, reflected). Start with 0xffffffff and
  # xor the result with 0xffffffff when done.
  def self.crc32_update(crc : UInt32, data : Bytes) : UInt32
    data.each do |byte|
      crc ^= byte
      8.times do
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320_u32 : crc >> 1
      end
    end
    crc
  end

  def self.crc32(data : Bytes) : UInt32
    crc32_update(0xffffffff_u32, data) ^ 0xffffffff_u32
  end

  SIGNATURE = StaticArray[0x89_u8, 0x50_u8, 0x4e_u8, 0x47_u8, 0x0d_u8, 0x0a_u8, 0x1a_u8, 0x0a_u8]

  @[AlwaysInline]
  def self.be32(data : Bytes, pos : Int32) : Int32
    v = (data[pos].to_u32 << 24) | (data[pos + 1].to_u32 << 16) | (data[pos + 2].to_u32 << 8) | data[pos + 3].to_u32
    raise Error.new("chunk length too large") if v > 0x7fff_ffff_u32
    v.to_i32
  end

  @[AlwaysInline]
  def self.chunk_type?(data : Bytes, pos : Int32, a : Char, b : Char, c : Char, d : Char) : Bool
    data[pos] == a.ord && data[pos + 1] == b.ord && data[pos + 2] == c.ord && data[pos + 3] == d.ord
  end

  # Validates the chunk at `pos` (length field offset) fits in `data` and
  # returns its data length. Optionally checks its CRC.
  def self.chunk_length(data : Bytes, pos : Int32, check_crc : Bool) : Int32
    raise Error.new("truncated chunk header") if pos > data.size - 8
    len = be32(data, pos)
    raise Error.new("truncated chunk") if len > data.size - pos - 12
    if check_crc
      expected = be32u(data, pos + 8 + len)
      raise Error.new("chunk crc mismatch") if crc32(data[pos + 4, len + 4]) != expected
    end
    len
  end

  @[AlwaysInline]
  def self.be32u(data : Bytes, pos : Int32) : UInt32
    (data[pos].to_u32 << 24) | (data[pos + 1].to_u32 << 16) | (data[pos + 2].to_u32 << 8) | data[pos + 3].to_u32
  end

  # Parses and validates the signature and IHDR.
  def self.header(data : Bytes, check_crc : Bool = true) : Header
    raise Error.new("not a png") if data.size < 8
    8.times { |i| raise Error.new("not a png") if data[i] != SIGNATURE[i] }
    len = chunk_length(data, 8, check_crc)
    raise Error.new("first chunk is not IHDR") unless chunk_type?(data, 12, 'I', 'H', 'D', 'R') && len == 13
    width = be32(data, 16)
    height = be32(data, 20)
    depth = data[24].to_i32
    ctype = data[25].to_i32
    raise Error.new("bad image size") if width <= 0 || height <= 0
    raise Error.new("image too large") if width > MAX_DIMENSION || height > MAX_DIMENSION
    valid = case ctype
            when COLOR_GRAY    then depth == 1 || depth == 2 || depth == 4 || depth == 8 || depth == 16
            when COLOR_PALETTE then depth == 1 || depth == 2 || depth == 4 || depth == 8
            when COLOR_RGB, COLOR_GRAY_ALPHA, COLOR_RGBA
              depth == 8 || depth == 16
            else
              false
            end
    raise Error.new("bad color type / bit depth") unless valid
    raise Error.new("unknown compression method") if data[26] != 0
    raise Error.new("unknown filter method") if data[27] != 0
    raise Error.new("bad interlace method") if data[28] > 1
    Header.new(width, height, depth, ctype, data[28].to_i32)
  end

  # Byte source that walks consecutive IDAT chunks inside the PNG slice.
  class IdatSource
    def initialize(@data : Bytes, chunk_pos : Int32, @check_crc : Bool)
      @pos = 0
      @end = 0
      @next_chunk = chunk_pos
      @done = false
      enter(chunk_pos)
    end

    def next_byte : Int32
      while @pos >= @end
        return -1 if @done
        if PNG.chunk_type?(@data, @next_chunk + 4, 'I', 'D', 'A', 'T')
          enter(@next_chunk)
        else
          @done = true
        end
      end
      b = @data[@pos].to_i32
      @pos += 1
      b
    end

    private def enter(chunk_pos : Int32) : Nil
      len = PNG.chunk_length(@data, chunk_pos, @check_crc)
      @pos = chunk_pos + 8
      @end = @pos + len
      @next_chunk = @end + 4
      # The next chunk header must exist for a well-formed file (IEND at least).
      @done = true if @next_chunk > @data.size - 8
    end
  end

  # Decodes `data` (a complete PNG file) and draws it with its top-left
  # corner at framebuffer column `x`, row `y`, clipping to the framebuffer.
  # `black` and `red` are 1-bit planes of `fb_width` pixels per row; the
  # framebuffer height is derived from the plane size. Returns the header.
  def self.draw(data : Bytes, black : Bytes, red : Bytes, x : Int32 = 0, y : Int32 = 0,
                fb_width : Int32 = SCREEN_WIDTH, check_crc : Bool = true) : Header
    raise ArgumentError.new("fb_width must be positive") if fb_width <= 0
    raise ArgumentError.new("planes differ in size") if black.size != red.size
    fb_height = ((black.size.to_i64 * 8) // fb_width).to_i32

    hdr = header(data, check_crc)
    raise Error.new("interlaced png not supported") if hdr.interlace != 0

    # Walk ancillary chunks up to the first IDAT.
    kinds_buf = StaticArray(UInt8, 256).new(WHITE)
    kinds = kinds_buf.to_slice
    have_plte = false
    trns_pos = -1
    trns_len = 0
    pos = 8 + 12 + 13
    loop do
      len = chunk_length(data, pos, check_crc)
      body = pos + 8
      if chunk_type?(data, pos + 4, 'I', 'D', 'A', 'T')
        break
      elsif chunk_type?(data, pos + 4, 'P', 'L', 'T', 'E')
        raise Error.new("bad PLTE length") if len % 3 != 0 || len == 0 || len > 768
        if hdr.color_type == COLOR_PALETTE
          raise Error.new("palette larger than bit depth allows") if len // 3 > (1 << hdr.bit_depth)
          (len // 3).times do |i|
            p = body + i * 3
            kinds[i] = color_kind(data[p], data[p + 1], data[p + 2])
          end
        end
        have_plte = true
      elsif chunk_type?(data, pos + 4, 't', 'R', 'N', 'S')
        trns_pos = body
        trns_len = len
      elsif chunk_type?(data, pos + 4, 'I', 'E', 'N', 'D')
        raise Error.new("no image data")
      end
      pos = body + len + 4
    end
    idat_pos = pos

    case hdr.color_type
    when COLOR_PALETTE
      raise Error.new("palette image without PLTE") unless have_plte
      if trns_pos >= 0
        n = trns_len < 256 ? trns_len : 256
        n.times { |i| kinds[i] = SKIP if data[trns_pos + i] < 128 }
      end
    when COLOR_GRAY, COLOR_GRAY_ALPHA
      # Table indexed by the raw sample (or the high byte of 16-bit ones).
      depth = hdr.bit_depth > 8 ? 8 : hdr.bit_depth
      maxv = (1 << depth) - 1
      (maxv + 1).times do |s|
        v = s * 255 // maxv
        kinds[s] = v < 128 ? BLACK : WHITE
      end
      if hdr.color_type == COLOR_GRAY && trns_pos >= 0 && trns_len == 2 && hdr.bit_depth <= 8
        key = (data[trns_pos].to_i32 << 8) | data[trns_pos + 1]
        kinds[key] = SKIP if key <= maxv
      end
    end

    row_bytes = hdr.row_bytes
    bpp = hdr.filter_bpp
    line_a = Bytes.new(row_bytes + 1)
    line_b = Bytes.new(row_bytes + 1)
    inflater = Inflate::Decoder(IdatSource).new(IdatSource.new(data, idat_pos, check_crc))

    # Horizontal clip, in image coordinates.
    x_start = x < 0 ? -x : 0
    x_end = fb_width.to_i64 - x
    x_end = hdr.width.to_i64 if x_end > hdr.width
    x_end_i = x_end < 0 ? 0 : x_end.to_i32

    begin
      prev = line_a
      cur = line_b
      hdr.height.times do |row|
        screen_y = y.to_i64 + row
        break if screen_y >= fb_height
        if inflater.read(cur) != cur.size
          raise Error.new("image data truncated")
        end
        unfilter(cur[0], cur + 1, prev + 1, bpp)
        if screen_y >= 0 && x_start < x_end_i
          base = screen_y * fb_width + x
          render_row(hdr, cur + 1, kinds, x_start, x_end_i, base, black, red)
        end
        prev, cur = cur, prev
      end
    rescue ex : Inflate::Error
      raise Error.new(ex.message)
    end
    hdr
  end

  # Reverses one PNG scanline filter in place.
  def self.unfilter(filter : UInt8, cur : Bytes, prev : Bytes, bpp : Int32) : Nil
    n = cur.size
    case filter
    when 0
    when 1
      (bpp...n).each { |i| cur[i] = cur[i] &+ cur[i - bpp] }
    when 2
      n.times { |i| cur[i] = cur[i] &+ prev[i] }
    when 3
      i = 0
      while i < n
        left = i >= bpp ? cur[i - bpp].to_i32 : 0
        cur[i] = cur[i] &+ ((left + prev[i]) >> 1).to_u8
        i += 1
      end
    when 4
      i = 0
      while i < n
        if i >= bpp
          a = cur[i - bpp].to_i32
          c = prev[i - bpp].to_i32
        else
          a = 0
          c = 0
        end
        b = prev[i].to_i32
        p = a + b - c
        pa = (p - a).abs
        pb = (p - b).abs
        pc = (p - c).abs
        pred = pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)
        cur[i] = cur[i] &+ pred.to_u8
        i += 1
      end
    else
      raise Error.new("bad filter type")
    end
  end

  @[AlwaysInline]
  def self.plot(black : Bytes, red : Bytes, i : Int64, kind : UInt8) : Nil
    idx = i >> 3
    bit = 0x80_u8 >> (i & 7)
    case kind
    when RED
      red[idx] |= bit
      black[idx] &= ~bit
    when BLACK
      black[idx] |= bit
      red[idx] &= ~bit
    when WHITE
      black[idx] &= ~bit
      red[idx] &= ~bit
    end
  end

  # Draws image columns `x0...x1` of one unfiltered scanline; `base` is
  # the framebuffer bit index of image column 0 on this row.
  def self.render_row(hdr : Header, row : Bytes, kinds : Bytes, x0 : Int32, x1 : Int32,
                      base : Int64, black : Bytes, red : Bytes) : Nil
    depth = hdr.bit_depth
    case hdr.color_type
    when COLOR_GRAY, COLOR_PALETTE
      if depth < 8
        mask = (1 << depth) - 1
        (x0...x1).each do |px|
          bit_index = px * depth
          sample = (row[bit_index >> 3].to_i32 >> (8 - depth - (bit_index & 7))) & mask
          plot(black, red, base + px, kinds[sample])
        end
      else
        step = depth >> 3
        (x0...x1).each { |px| plot(black, red, base + px, kinds[row[px * step]]) }
      end
    when COLOR_RGB
      s = depth >> 3
      (x0...x1).each do |px|
        o = px * 3 * s
        plot(black, red, base + px, color_kind(row[o], row[o + s], row[o + 2 * s]))
      end
    when COLOR_GRAY_ALPHA
      s = depth >> 3
      (x0...x1).each do |px|
        o = px * 2 * s
        kind = row[o + s] < 128 ? SKIP : kinds[row[o]]
        plot(black, red, base + px, kind)
      end
    when COLOR_RGBA
      s = depth >> 3
      (x0...x1).each do |px|
        o = px * 4 * s
        kind = row[o + 3 * s] < 128 ? SKIP : color_kind(row[o], row[o + s], row[o + 2 * s])
        plot(black, red, base + px, kind)
      end
    end
  end
end
