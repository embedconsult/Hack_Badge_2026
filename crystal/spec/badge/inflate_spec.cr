require "../spec_helper"
require "compress/zlib"
require "compress/deflate"

private def zlib_compress(data : Bytes, level : Int32) : Bytes
  io = IO::Memory.new
  Compress::Zlib::Writer.open(io, level: level) { |z| z.write(data) }
  io.to_slice
end

private def deflate_compress(data : Bytes, level : Int32) : Bytes
  io = IO::Memory.new
  Compress::Deflate::Writer.open(io, level: level) { |z| z.write(data) }
  io.to_slice
end

private def reference_inflate(data : Bytes) : Bytes
  Compress::Zlib::Reader.open(IO::Memory.new(data)) { |z| z.getb_to_end }
end

# Pulls the whole stream out of `decoder` in `chunk`-sized reads.
private def drain(decoder, chunk : Int32) : Bytes
  result = IO::Memory.new
  buf = Bytes.new(chunk)
  loop do
    n = decoder.read(buf)
    result.write(buf[0, n])
    break if n < chunk
  end
  decoder.finished?.should be_true
  result.to_slice
end

private def idat_stream(png : Bytes) : Bytes
  io = IO::Memory.new
  pos = 8
  while pos + 8 <= png.size
    len = IO::ByteFormat::BigEndian.decode(UInt32, png[pos, 4]).to_i
    type = String.new(png[pos + 4, 4])
    io.write(png[pos + 8, len]) if type == "IDAT"
    pos += 12 + len
  end
  io.to_slice
end

private def sample_inputs : Array(Bytes)
  rng = Random.new(1234)
  random = Bytes.new(70_000) { rng.rand(256).to_u8 }
  text = ("The quick brown fox jumps over the lazy badge. " * 2000).to_slice
  # Low-entropy noise: many short matches and a skewed literal alphabet.
  skewed = Bytes.new(100_000) { (rng.rand(4) == 0 ? rng.rand(256) : rng.rand(6)).to_u8 }
  runs = Bytes.new(50_000) { |i| ((i // 300) % 3).to_u8 }
  [Bytes.empty, Bytes[42], random, text, skewed, runs]
end

describe Badge::Inflate do
  it "matches Compress::Zlib on varied data at every compression level" do
    sample_inputs.each do |input|
      (0..9).each do |level|
        compressed = zlib_compress(input, level)
        [1, 13, 4096, 1 << 20].each do |chunk|
          drain(Badge::Inflate.zlib(compressed), chunk).should eq(input)
        end
      end
    end
  end

  it "decodes raw DEFLATE streams" do
    sample_inputs.each do |input|
      [0, 1, 6, 9].each do |level|
        drain(Badge::Inflate.raw(deflate_compress(input, level)), 999).should eq(input)
      end
    end
  end

  it "matches Compress::Zlib on the IDAT streams of every PNG under data/" do
    files = Dir.glob(File.join(__DIR__, "../../../data/{graphics,gallery}/*.png"))
    files.size.should be > 50
    files.each do |path|
      stream = idat_stream(File.read(path).to_slice)
      drain(Badge::Inflate.zlib(stream), 241).should eq(reference_inflate(stream))
    end
  end

  it "decodes a hand-built fixed-Huffman block" do
    # zlib.compress(b"a") with fixed codes: 78 9c 4b 04 00 00 62 00 62
    stream = Bytes[0x78, 0x9c, 0x4b, 0x04, 0x00, 0x00, 0x62, 0x00, 0x62]
    drain(Badge::Inflate.zlib(stream), 8).should eq("a".to_slice)
  end

  it "sizes the window from the zlib header" do
    Badge::Inflate.zlib(Bytes[0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]).window_size.should eq(32768)
    Badge::Inflate.zlib(Bytes[0x08, 0x1d, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]).window_size.should eq(256)
  end

  it "raises on malformed streams" do
    good = zlib_compress(("hello badge " * 100).to_slice, 6)

    expect_raises(Badge::Inflate::Error) { Badge::Inflate.zlib(Bytes[0x78, 0x9d]) }     # header check
    expect_raises(Badge::Inflate::Error) { Badge::Inflate.zlib(Bytes[0x79, 0x9c - 6]) } # method 9
    expect_raises(Badge::Inflate::Error) { Badge::Inflate.zlib(Bytes[0x78, 0xbb]) }     # preset dict
    expect_raises(Badge::Inflate::Error) { drain(Badge::Inflate.zlib(good[0, good.size - 5]), 64) }

    bad_adler = good.dup
    bad_adler[-1] ^= 1
    expect_raises(Badge::Inflate::Error, "adler-32 mismatch") { drain(Badge::Inflate.zlib(bad_adler), 64) }

    # Block type 3 is reserved.
    expect_raises(Badge::Inflate::Error, "invalid block type") { drain(Badge::Inflate.zlib(Bytes[0x78, 0x9c, 0x07]), 8) }
    # Stored block whose NLEN is not the complement of LEN.
    expect_raises(Badge::Inflate::Error, "stored block length mismatch") do
      drain(Badge::Inflate.zlib(Bytes[0x78, 0x9c, 0x01, 0x05, 0x00, 0x00, 0x00]), 8)
    end
    # Fixed block starting with a match (distance 1 with no history).
    expect_raises(Badge::Inflate::Error, "distance too far back") do
      drain(Badge::Inflate.zlib(Bytes[0x78, 0x9c, 0x03, 0x02, 0x00]), 8)
    end
  end

  it "survives random corruption without crashing" do
    rng = Random.new(99)
    good = zlib_compress(sample_inputs[4][0, 20_000], 6)
    300.times do
      bad = good.dup
      4.times { bad[rng.rand(bad.size)] = rng.rand(256).to_u8 }
      begin
        drain(Badge::Inflate.zlib(bad), 512)
      rescue Badge::Inflate::Error
      end
    end
  end
end
