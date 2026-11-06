require "../spec_helper"
require "compress/zlib"
require "digest/crc32"

# Straightforward full-image reference decoder (whole IDAT stream inflated
# with Compress::Zlib, whole image unfiltered) producing one "kind" per pixel.
module PNGRef
  extend self

  record Image, width : Int32, height : Int32, kinds : Array(UInt8)

  def be32(b : Bytes, pos) : Int32
    IO::ByteFormat::BigEndian.decode(UInt32, b[pos, 4]).to_i32
  end

  def kind(r : Int32, g : Int32, b : Int32) : UInt8
    return Badge::PNG::RED if r >= 128 && g < 128 && b < 128
    return Badge::PNG::BLACK if r < 128 && g < 128 && b < 128
    Badge::PNG::WHITE
  end

  def decode(png : Bytes) : Image
    width = be32(png, 16)
    height = be32(png, 20)
    depth = png[24].to_i32
    ctype = png[25].to_i32
    palette = [] of {Int32, Int32, Int32}
    trns = Bytes.empty
    idat = IO::Memory.new
    pos = 8
    while pos + 8 <= png.size
      len = be32(png, pos)
      type = String.new(png[pos + 4, 4])
      body = png[pos + 8, len]
      case type
      when "PLTE" then (len // 3).times { |i| palette << {body[i*3].to_i32, body[i*3 + 1].to_i32, body[i*3 + 2].to_i32} }
      when "tRNS" then trns = body
      when "IDAT" then idat.write(body)
      end
      pos += 12 + len
    end
    raw = Compress::Zlib::Reader.open(IO::Memory.new(idat.to_slice)) { |z| z.getb_to_end }

    channels = {0 => 1, 2 => 3, 3 => 1, 4 => 2, 6 => 4}[ctype]
    bits = channels * depth
    stride = (width * bits + 7) // 8
    bpp = Math.max(1, bits // 8)
    rows = Array(Bytes).new
    prev = Bytes.new(stride)
    height.times do |y|
      f = raw[y * (stride + 1)]
      line = raw[y * (stride + 1) + 1, stride].dup
      stride.times do |i|
        a = i >= bpp ? line[i - bpp].to_i : 0
        b = prev[i].to_i
        c = i >= bpp ? prev[i - bpp].to_i : 0
        pred = case f
               when 0 then 0
               when 1 then a
               when 2 then b
               when 3 then (a + b) // 2
               when 4
                 p = a + b - c
                 pa, pb, pc = (p - a).abs, (p - b).abs, (p - c).abs
                 pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)
               else raise "bad filter"
               end
        line[i] = ((line[i].to_i + pred) % 256).to_u8
      end
      rows << line
      prev = line
    end

    maxv = (1 << depth) - 1
    sample = ->(row : Bytes, idx : Int32) do
      if depth < 8
        bit = idx * depth
        (row[bit // 8].to_i >> (8 - depth - bit % 8)) & maxv
      elsif depth == 8
        row[idx].to_i
      else
        (row[idx * 2].to_i << 8) | row[idx * 2 + 1]
      end
    end
    to8 = ->(v : Int32) { depth == 16 ? v >> 8 : v * 255 // maxv }

    kinds = Array(UInt8).new(width * height)
    rows.each do |row|
      width.times do |x|
        k = case ctype
            when 0
              v = sample.call(row, x)
              if trns.size == 2 && depth <= 8 && v == ((trns[0].to_i << 8) | trns[1])
                Badge::PNG::SKIP
              else
                g = to8.call(v)
                kind(g, g, g)
              end
            when 3
              i = sample.call(row, x)
              if i < trns.size && trns[i] < 128
                Badge::PNG::SKIP
              elsif i < palette.size
                r, g, b = palette[i]
                kind(r, g, b)
              else
                Badge::PNG::WHITE
              end
            when 2
              kind(to8.call(sample.call(row, x*3)), to8.call(sample.call(row, x*3 + 1)), to8.call(sample.call(row, x*3 + 2)))
            when 4
              if to8.call(sample.call(row, x*2 + 1)) < 128
                Badge::PNG::SKIP
              else
                g = to8.call(sample.call(row, x*2))
                kind(g, g, g)
              end
            else
              if to8.call(sample.call(row, x*4 + 3)) < 128
                Badge::PNG::SKIP
              else
                kind(to8.call(sample.call(row, x*4)), to8.call(sample.call(row, x*4 + 1)), to8.call(sample.call(row, x*4 + 2)))
              end
            end
        kinds << k
      end
    end
    Image.new(width, height, kinds)
  end

  # Renders `img` into copies of the planes with the same clipping rules.
  def render(img : Image, black : Bytes, red : Bytes, ox : Int32, oy : Int32, fb_w : Int32) : {Bytes, Bytes}
    black = black.dup
    red = red.dup
    fb_h = black.size * 8 // fb_w
    img.height.times do |y|
      img.width.times do |x|
        sx, sy = ox + x, oy + y
        next unless 0 <= sx < fb_w && 0 <= sy < fb_h
        k = img.kinds[y * img.width + x]
        next if k == Badge::PNG::SKIP
        i = sy * fb_w + sx
        bit = 0x80_u8 >> (i % 8)
        black[i // 8] &= ~bit
        red[i // 8] &= ~bit
        black[i // 8] |= bit if k == Badge::PNG::BLACK
        red[i // 8] |= bit if k == Badge::PNG::RED
      end
    end
    {black, red}
  end

  def popcount(b : Bytes) : Int32
    b.sum(0) { |x| x.popcount.to_i32 }
  end

  # --- tiny encoder for synthetic test images ---------------------------

  def chunk(io : IO, type : String, body : Bytes)
    io.write_bytes(body.size.to_u32, IO::ByteFormat::BigEndian)
    io.write(type.to_slice)
    io.write(body)
    crc = Digest::CRC32.checksum(type.to_slice + body) # (zlib returns 0 for an empty update)
    io.write_bytes(crc, IO::ByteFormat::BigEndian)
  end

  # Builds a PNG with random pixels; `filter_for_row` picks each row's filter.
  def encode(width, height, ctype, depth, rng : Random, plte : Bytes? = nil, trns : Bytes? = nil,
             level = 6, idat_split = 3, &filter_for_row : Int32 -> Int32) : Bytes
    channels = {0 => 1, 2 => 3, 3 => 1, 4 => 2, 6 => 4}[ctype]
    bits = channels * depth
    stride = (width * bits + 7) // 8
    bpp = Math.max(1, bits // 8)
    raw = IO::Memory.new
    prev = Bytes.new(stride)
    height.times do |y|
      line = Bytes.new(stride) { rng.rand(256).to_u8 }
      # Keep palette indices inside the palette.
      if ctype == 3 && plte
        n = plte.size // 3
        width.times do |x|
          bit = x * depth
          shift = 8 - depth - bit % 8
          v = rng.rand(n)
          line[bit // 8] = ((line[bit // 8] & ~(((1 << depth) - 1) << shift)) | (v << shift)).to_u8
        end
      end
      # Zero any padding bits at the end of the row.
      pad = stride * 8 - width * bits
      line[stride - 1] &= (0xff << pad).to_u8! if pad > 0
      f = filter_for_row.call(y)
      raw.write_byte(f.to_u8)
      stride.times do |i|
        a = i >= bpp ? line[i - bpp].to_i : 0
        b = prev[i].to_i
        c = i >= bpp ? prev[i - bpp].to_i : 0
        pred = case f
               when 1 then a
               when 2 then b
               when 3 then (a + b) // 2
               when 4
                 p = a + b - c
                 pa, pb, pc = (p - a).abs, (p - b).abs, (p - c).abs
                 pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)
               else 0
               end
        raw.write_byte(((line[i].to_i - pred) % 256).to_u8)
      end
      prev = line
    end
    z = IO::Memory.new
    Compress::Zlib::Writer.open(z, level: level) { |w| w.write(raw.to_slice) }
    zdata = z.to_slice

    png_out = IO::Memory.new
    png_out.write(Bytes[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    ihdr = IO::Memory.new
    ihdr.write_bytes(width.to_u32, IO::ByteFormat::BigEndian)
    ihdr.write_bytes(height.to_u32, IO::ByteFormat::BigEndian)
    ihdr.write(Bytes[depth, ctype, 0, 0, 0])
    chunk(png_out, "IHDR", ihdr.to_slice)
    chunk(png_out, "tEXt", "Comment\0synthetic".to_slice)
    chunk(png_out, "PLTE", plte) if plte
    chunk(png_out, "tRNS", trns) if trns
    # Split the zlib stream over several IDATs, including an empty one.
    part = Math.max(1, zdata.size // idat_split)
    off = 0
    first = true
    while off < zdata.size
      n = Math.min(part, zdata.size - off)
      chunk(png_out, "IDAT", zdata[off, n])
      chunk(png_out, "IDAT", Bytes.empty) if first
      first = false
      off += n
    end
    chunk(png_out, "IEND", Bytes.empty)
    png_out.to_slice
  end
end

private def fb_planes(w = Badge::PNG::SCREEN_WIDTH, h = Badge::PNG::SCREEN_HEIGHT)
  size = w * h // 8
  {Bytes.new(size), Bytes.new(size)}
end

private def fb_planes(r : Random, w = Badge::PNG::SCREEN_WIDTH, h = Badge::PNG::SCREEN_HEIGHT)
  size = w * h // 8
  {Bytes.new(size) { r.rand(256).to_u8 }, Bytes.new(size) { r.rand(256).to_u8 }}
end

private def check_draw(png : Bytes, black : Bytes, red : Bytes, x = 0, y = 0, fb_w = Badge::PNG::SCREEN_WIDTH, check_crc = true)
  ref = PNGRef.decode(png)
  want_black, want_red = PNGRef.render(ref, black, red, x, y, fb_w)
  Badge::PNG.draw(png, black, red, x, y, fb_w, check_crc: check_crc)
  black.should eq(want_black)
  red.should eq(want_red)
  ref
end

DATA_PNGS = Dir.glob(File.join(__DIR__, "../../../data/{graphics,gallery}/*.png")).sort

describe Badge::PNG do
  it "finds the test images" do
    DATA_PNGS.size.should be > 50
  end

  it "decodes every PNG under data/ to the same planes as a full reference decode" do
    DATA_PNGS.each do |path|
      png = File.read(path).to_slice
      black, red = fb_planes
      ref = check_draw(png, black, red)
      PNGRef.popcount(black).should eq(ref.kinds.count(Badge::PNG::BLACK))
      PNGRef.popcount(red).should eq(ref.kinds.count(Badge::PNG::RED))
      # No pixel is set in both planes.
      black.zip(red).all? { |b, r| b & r == 0 }.should be_true
    end
  end

  it "produces non-trivial red and black content for the colour gallery" do
    png = File.read(File.join(__DIR__, "../../../data/graphics/never_epd.png")).to_slice
    black, red = fb_planes
    Badge::PNG.draw(png, black, red)
    PNGRef.popcount(black).should be > 0
    PNGRef.popcount(red).should be > 0
  end

  it "clips at every edge and preserves pixels outside the image" do
    rng = Random.new(7)
    small = File.read(File.join(__DIR__, "../../../data/graphics/hopper.png")).to_slice
    big = File.read(File.join(__DIR__, "../../../data/graphics/never_epd.png")).to_slice
    [{small, -10, -20}, {small, 900, 600}, {small, 2000, 0}, {small, 0, -400},
     {small, 450, 300}, {big, -37, 5}, {big, 13, -101}, {big, 7, 3}].each do |png, x, y|
      black, red = fb_planes(rng)
      check_draw(png, black, red, x, y)
    end
  end

  it "supports a framebuffer width that differs from the image" do
    rng = Random.new(8)
    png = File.read(File.join(__DIR__, "../../../data/graphics/friday.png")).to_slice
    black, red = fb_planes(rng, 200, 64)
    check_draw(png, black, red, -3, 5, 200)
    black, red = fb_planes(rng, 101 * 8, 3)
    check_draw(png, black, red, 1, -1, 101)
  end

  it "decodes every colour type, bit depth and filter type" do
    rng = Random.new(42)
    formats = [{0, 1}, {0, 2}, {0, 4}, {0, 8}, {0, 16}, {2, 8}, {2, 16},
               {3, 1}, {3, 2}, {3, 4}, {3, 8}, {4, 8}, {4, 16}, {6, 8}, {6, 16}]
    formats.each do |(ctype, depth)|
      plte = nil
      trns = nil
      if ctype == 3
        n = Math.min(1 << depth, 3 + rng.rand(200))
        plte = Bytes.new(n * 3) { rng.rand(256).to_u8 }
        trns = Bytes.new(n // 2) { rng.rand(256).to_u8 }
      elsif ctype == 0 && depth <= 8
        trns = Bytes[0, rng.rand(1 << depth).to_u8]
      end
      (0..5).each do |filter|
        # filter 5 = a different filter on every row
        png = PNGRef.encode(29, 11, ctype, depth, rng, plte, trns, level: filter == 5 ? 0 : 6) do |row|
          filter == 5 ? row % 5 : filter
        end
        black, red = fb_planes(rng, 64, 24)
        check_draw(png, black, red, 3, 2, 64)
        black, red = fb_planes(rng, 64, 24)
        check_draw(png, black, red, -5, -4, 64)
      end
    end
  end

  it "maps grayscale and palette colours like large_png.py" do
    Badge::PNG.color_kind(255, 0, 0).should eq(Badge::PNG::RED)
    Badge::PNG.color_kind(128, 127, 127).should eq(Badge::PNG::RED)
    Badge::PNG.color_kind(127, 127, 127).should eq(Badge::PNG::BLACK)
    Badge::PNG.color_kind(0, 0, 0).should eq(Badge::PNG::BLACK)
    Badge::PNG.color_kind(255, 255, 255).should eq(Badge::PNG::WHITE)
    Badge::PNG.color_kind(255, 128, 0).should eq(Badge::PNG::WHITE)
    Badge::PNG.color_kind(0, 0, 200).should eq(Badge::PNG::WHITE)
  end

  it "reads the header" do
    png = File.read(File.join(__DIR__, "../../../data/graphics/supercon-x-splash.png")).to_slice
    hdr = Badge::PNG.header(png)
    {hdr.width, hdr.height, hdr.bit_depth, hdr.color_type}.should eq({960, 672, 2, 3})
    hdr.row_bytes.should eq(240)
  end

  it "computes CRC-32 like Digest::CRC32" do
    data = "IEND hello badge".to_slice
    Badge::PNG.crc32(data).should eq(Digest::CRC32.checksum(data))
  end

  it "raises Badge::PNG::Error on malformed files" do
    png = File.read(File.join(__DIR__, "../../../data/graphics/friday.png")).to_slice
    black, red = fb_planes

    expect_raises(Badge::PNG::Error, "not a png") { Badge::PNG.draw(Bytes[1, 2, 3], black, red) }
    expect_raises(Badge::PNG::Error) { Badge::PNG.draw(png[0, 20], black, red) }
    expect_raises(Badge::PNG::Error) { Badge::PNG.draw(png[0, png.size // 2], black, red) }

    bad_crc = png.dup
    bad_crc[-20] ^= 0x55 # inside the IDAT payload
    expect_raises(Badge::PNG::Error) { Badge::PNG.draw(bad_crc, black, red) }

    interlaced = png.dup
    interlaced[28] = 1
    expect_raises(Badge::PNG::Error) { Badge::PNG.draw(interlaced, black, red, check_crc: false) }

    bad_depth = png.dup
    bad_depth[24] = 3
    expect_raises(Badge::PNG::Error, "bad color type / bit depth") { Badge::PNG.draw(bad_depth, black, red, check_crc: false) }

    rng = Random.new(1)
    bad_filter = PNGRef.encode(8, 4, 0, 8, rng) { |row| row == 2 ? 7 : 0 }
    expect_raises(Badge::PNG::Error, "bad filter type") { Badge::PNG.draw(bad_filter, black, red) }

    no_plte = PNGRef.encode(8, 4, 3, 8, rng) { 0 }
    expect_raises(Badge::PNG::Error, "palette image without PLTE") { Badge::PNG.draw(no_plte, black, red) }

    # Corrupt the zlib stream itself (CRC checking off): surfaces as PNG::Error.
    zbad = PNGRef.encode(8, 4, 0, 8, rng, level: 0) { 0 }
    idat = (8...zbad.size - 4).find! { |i| String.new(zbad[i, 4]) == "IDAT" }
    zbad[idat + 6] ^= 0xff # stored-block LEN
    expect_raises(Badge::PNG::Error) { Badge::PNG.draw(zbad, black, red, check_crc: false) }
  end

  it "accepts a bad CRC when checking is disabled" do
    png = File.read(File.join(__DIR__, "../../../data/graphics/friday.png")).to_slice
    bad = png.dup
    bad[-13] ^= 0xff # last byte of the IDAT CRC (IEND chunk is the last 12 bytes)
    black, red = fb_planes
    expect_raises(Badge::PNG::Error, "chunk crc mismatch") { Badge::PNG.draw(bad, black, red) }
    check_draw(bad, black, red, check_crc: false) # reference ignores CRCs
    Badge::PNG.draw(bad, black, red, check_crc: false)
  end
end

describe "Badge::PNG fuzzing" do
  it "only ever raises Badge::PNG::Error on corrupted input" do
    rng = Random.new(2026)
    png = File.read(File.join(__DIR__, "../../../data/graphics/supercon-x-splash.png")).to_slice
    black, red = fb_planes
    200.times do
      bad = png.dup
      3.times { bad[rng.rand(bad.size)] = rng.rand(256).to_u8 }
      bad = bad[0, rng.rand(bad.size)] if rng.rand(4) == 0
      begin
        Badge::PNG.draw(bad, black, red, rng.rand(-100..100), rng.rand(-100..100), check_crc: false)
      rescue Badge::PNG::Error
      end
    end
  end
end
