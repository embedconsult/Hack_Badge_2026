# Streaming zlib / raw DEFLATE (RFC 1950 / RFC 1951) decompressor.
#
# Written for the badge's minimal runtime: no IO, no heap allocation after
# construction. Memory use is one history window (sized from the zlib
# header, at most 32 KiB) plus fixed Huffman tables (~1.4 KiB).
#
# Input comes from a *source* object that responds to `next_byte : Int32`
# and returns -1 at end of input (see `SliceSource`). Output is pulled with
# `Decoder#read`, so callers can decompress a PNG one scanline at a time.
module Badge::Inflate
  class Error < Exception
  end

  # Byte source over a single slice.
  class SliceSource
    getter pos : Int32 = 0

    def initialize(@data : Bytes)
    end

    def next_byte : Int32
      return -1 if @pos >= @data.size
      b = @data[@pos].to_i32
      @pos += 1
      b
    end
  end

  MAXBITS  =  15
  MAXLCODE = 286
  MAXDCODE =  30
  FIXLCODE = 288

  LENGTH_BASE  = StaticArray[3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
  LENGTH_EXTRA = StaticArray[0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
  DIST_BASE    = StaticArray[1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
  DIST_EXTRA   = StaticArray[0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
  CLEN_ORDER   = StaticArray[16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

  # Canonical Huffman code stored as code-length counts plus symbols in
  # canonical order (the "puff" representation: tiny and allocation-free).
  class Huffman
    getter count : Slice(UInt16)
    getter symbol : Slice(UInt16)

    def initialize(max_symbols : Int32)
      @count = Slice(UInt16).new(MAXBITS + 1)
      @symbol = Slice(UInt16).new(max_symbols)
      @offs = Slice(UInt16).new(MAXBITS + 1)
    end

    # Builds the code from `lengths[0, n]`. Raises on an over-subscribed
    # code; incomplete codes are accepted (unused codes fail in `decode`).
    def build(lengths : Bytes, n : Int32) : Nil
      @count.fill(0_u16)
      n.times { |sym| @count[lengths[sym]] += 1 }
      return if @count[0] == n # no codes: only legal for an unused distance tree

      left = 1
      (1..MAXBITS).each do |len|
        left <<= 1
        left -= @count[len].to_i32
        raise Error.new("over-subscribed huffman code") if left < 0
      end

      @offs[1] = 0_u16
      (1...MAXBITS).each { |len| @offs[len + 1] = @offs[len] + @count[len] }
      n.times do |sym|
        len = lengths[sym]
        next if len == 0
        @symbol[@offs[len]] = sym.to_u16
        @offs[len] += 1
      end
    end
  end

  class Decoder(S)
    STATE_HEADER = 0
    STATE_STORED = 1
    STATE_HUFF   = 2
    STATE_DONE   = 3

    getter window_size : Int32
    getter total_out : UInt64 = 0_u64

    # `zlib: true` expects a 2-byte zlib header and Adler-32 trailer;
    # `zlib: false` decodes raw DEFLATE with a `1 << window_bits` window.
    def initialize(@src : S, @zlib : Bool = true, window_bits : Int32 = 15)
      @bitbuf = 0_u32
      @bitcnt = 0
      @state = STATE_HEADER
      @last = false
      @copy_len = 0
      @copy_dist = 0
      @stored_left = 0
      @adler_a = 1_u32
      @adler_b = 0_u32
      @adler_n = 0
      @have = 0

      if @zlib
        cmf = need_byte
        flg = need_byte
        raise Error.new("bad zlib header") if (cmf & 0x0f) != 8
        raise Error.new("bad zlib header check") if ((cmf << 8) | flg) % 31 != 0
        raise Error.new("zlib preset dictionary not supported") if (flg & 0x20) != 0
        window_bits = (cmf >> 4) + 8
        raise Error.new("bad zlib window size") if window_bits > 15
      end
      raise Error.new("bad window size") unless 8 <= window_bits <= 15
      @window_size = 1 << window_bits
      @mask = @window_size - 1
      @wpos = 0
      @window = Bytes.new(@window_size)

      @lencode = Huffman.new(FIXLCODE)
      @distcode = Huffman.new(MAXDCODE)
      @lengths = Bytes.new(FIXLCODE + MAXDCODE)
    end

    def finished? : Bool
      @state == STATE_DONE
    end

    # Fills `dst` with decompressed bytes and returns how many were written.
    # Returns less than `dst.size` only once the stream has ended.
    def read(dst : Bytes) : Int32
      n = 0
      size = dst.size
      while n < size
        if @copy_len > 0
          mask = @mask
          while @copy_len > 0 && n < size
            dst[n] = put(@window[(@wpos - @copy_dist) & mask])
            n += 1
            @copy_len -= 1
          end
          next
        end

        case @state
        when STATE_HUFF
          sym = decode(@lencode)
          if sym < 256
            dst[n] = put(sym.to_u8)
            n += 1
          elsif sym == 256
            @state = STATE_HEADER
          else
            start_match(sym)
          end
        when STATE_STORED
          if @stored_left == 0
            @state = STATE_HEADER
          else
            dst[n] = put(need_byte.to_u8)
            n += 1
            @stored_left -= 1
          end
        when STATE_HEADER
          if @last
            finish
          else
            block_header
          end
        else
          break
        end
      end
      n
    end

    @[AlwaysInline]
    private def put(b : UInt8) : UInt8
      @window[@wpos] = b
      @wpos = (@wpos + 1) & @mask
      @have += 1 if @have < @window_size
      @total_out += 1
      if @zlib
        @adler_a += b
        @adler_b += @adler_a
        @adler_n += 1
        if @adler_n == 5552
          @adler_a %= 65521_u32
          @adler_b %= 65521_u32
          @adler_n = 0
        end
      end
      b
    end

    private def need_byte : Int32
      b = @src.next_byte
      raise Error.new("unexpected end of compressed data") if b < 0
      b
    end

    @[AlwaysInline]
    private def bits(need : Int32) : Int32
      while @bitcnt < need
        @bitbuf |= need_byte.to_u32 << @bitcnt
        @bitcnt += 8
      end
      val = @bitbuf & ((1_u32 << need) &- 1)
      @bitbuf >>= need
      @bitcnt -= need
      val.to_i32
    end

    private def decode(h : Huffman) : Int32
      count = h.count
      code = 0
      first = 0
      index = 0
      (1..MAXBITS).each do |len|
        code |= bits(1)
        c = count[len].to_i32
        return h.symbol[index + (code - first)].to_i32 if code - c < first
        index += c
        first += c
        first <<= 1
        code <<= 1
      end
      raise Error.new("invalid huffman code")
    end

    private def start_match(sym : Int32) : Nil
      sym -= 257
      raise Error.new("invalid length symbol") if sym >= 29
      len = LENGTH_BASE[sym] + bits(LENGTH_EXTRA[sym])
      dsym = decode(@distcode)
      raise Error.new("invalid distance symbol") if dsym >= 30
      dist = DIST_BASE[dsym] + bits(DIST_EXTRA[dsym])
      raise Error.new("distance too far back") if dist > @have
      @copy_len = len
      @copy_dist = dist
    end

    private def block_header : Nil
      @last = bits(1) == 1
      case bits(2)
      when 0
        # Stored: drop the partial byte (fewer than 8 bits are ever buffered).
        @bitbuf = 0_u32
        @bitcnt = 0
        len = need_byte | (need_byte << 8)
        nlen = need_byte | (need_byte << 8)
        raise Error.new("stored block length mismatch") if len != (~nlen & 0xffff)
        @stored_left = len
        @state = STATE_STORED
      when 1
        fixed_tables
        @state = STATE_HUFF
      when 2
        dynamic_tables
        @state = STATE_HUFF
      else
        raise Error.new("invalid block type")
      end
    end

    private def fixed_tables : Nil
      l = @lengths
      (0...144).each { |i| l[i] = 8_u8 }
      (144...256).each { |i| l[i] = 9_u8 }
      (256...280).each { |i| l[i] = 7_u8 }
      (280...FIXLCODE).each { |i| l[i] = 8_u8 }
      @lencode.build(l, FIXLCODE)
      MAXDCODE.times { |i| l[i] = 5_u8 }
      @distcode.build(l, MAXDCODE)
    end

    private def dynamic_tables : Nil
      nlen = bits(5) + 257
      ndist = bits(5) + 1
      ncode = bits(4) + 4
      raise Error.new("bad dynamic block counts") if nlen > MAXLCODE || ndist > MAXDCODE

      l = @lengths
      19.times { |i| l[CLEN_ORDER[i]] = i < ncode ? bits(3).to_u8 : 0_u8 }
      @lencode.build(l, 19)

      index = 0
      total = nlen + ndist
      while index < total
        sym = decode(@lencode)
        if sym < 16
          l[index] = sym.to_u8
          index += 1
        else
          len = 0_u8
          case sym
          when 16
            raise Error.new("repeat with no first length") if index == 0
            len = l[index - 1]
            rep = 3 + bits(2)
          when 17
            rep = 3 + bits(3)
          else
            rep = 11 + bits(7)
          end
          raise Error.new("too many code lengths") if index + rep > total
          rep.times do
            l[index] = len
            index += 1
          end
        end
      end
      raise Error.new("missing end-of-block code") if l[256] == 0

      # Distance lengths follow the literal/length lengths in `l`; build the
      # distance code first from a shifted view, then the literal code.
      @distcode.build(l[nlen, ndist], ndist)
      @lencode.build(l, nlen)
    end

    private def finish : Nil
      if @zlib
        @bitbuf = 0_u32
        @bitcnt = 0
        expected = 0_u32
        4.times { expected = (expected << 8) | need_byte.to_u32 }
        actual = ((@adler_b % 65521_u32) << 16) | (@adler_a % 65521_u32)
        raise Error.new("adler-32 mismatch") if actual != expected
      end
      @state = STATE_DONE
    end
  end

  # Convenience constructor for a zlib stream held in one slice.
  def self.zlib(data : Bytes) : Decoder(SliceSource)
    Decoder(SliceSource).new(SliceSource.new(data), zlib: true)
  end

  # Convenience constructor for a raw DEFLATE stream held in one slice.
  def self.raw(data : Bytes, window_bits : Int32 = 15) : Decoder(SliceSource)
    Decoder(SliceSource).new(SliceSource.new(data), zlib: false, window_bits: window_bits)
  end
end
