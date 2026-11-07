# zlib / DEFLATE decompressor (RFC 1950/1951), ported from
# crystal/src/badge/inflate.cr to the firmware's --prelude=empty style:
# module-level state instead of classes, raw pointers instead of Slice,
# and an error code instead of exceptions (no unwinder on this target).
#
# One stream at a time. Input is a byte source supplied by the caller
# through `next_byte` (see PNG::IdatSource). Memory: a 32 KiB window plus
# ~1.5 KiB of Huffman tables, allocated once on first use.

module Inflate
  MAXBITS  =  15
  MAXLCODE = 286
  MAXDCODE =  30
  FIXLCODE = 288
  WINDOW   = 32768

  ST_HEADER = 0
  ST_STORED = 1
  ST_HUFF   = 2
  ST_DONE   = 3

  # Error codes (0 = ok)
  E_EOF        =  1 # unexpected end of compressed data
  E_HEADER     =  2 # bad zlib header
  E_HUFF       =  3 # over-subscribed or invalid Huffman code
  E_SYMBOL     =  4 # invalid length/distance symbol
  E_DISTANCE   =  5 # distance too far back
  E_STORED     =  6 # stored block length mismatch
  E_BLOCK      =  7 # invalid block type / counts / lengths
  E_ADLER      =  8 # adler-32 mismatch
  E_EXTRA      =  9 # data after the image in the zlib stream

  @@ready = false
  @@err = 0
  @@window = uninitialized UInt8*
  @@lengths = uninitialized UInt8*
  # Each code: count[MAXBITS+1] then symbols; offs is scratch.
  @@lcount = uninitialized UInt16*
  @@lsym = uninitialized UInt16*
  @@dcount = uninitialized UInt16*
  @@dsym = uninitialized UInt16*
  @@offs = uninitialized UInt16*
  # Fixed-block codes, built once in setup; @@lc.. point at the codes in use.
  @@flcount = uninitialized UInt16*
  @@flsym = uninitialized UInt16*
  @@fdcount = uninitialized UInt16*
  @@fdsym = uninitialized UInt16*
  @@lc = uninitialized UInt16*
  @@ls = uninitialized UInt16*
  @@dc = uninitialized UInt16*
  @@ds = uninitialized UInt16*
  @@len_base = uninitialized UInt16*
  @@len_extra = uninitialized UInt8*
  @@dist_base = uninitialized UInt16*
  @@dist_extra = uninitialized UInt8*
  @@clen_order = uninitialized UInt8*

  @@bitbuf = 0_u32
  @@bitcnt = 0
  @@state = 0
  @@last = false
  @@copy_len = 0
  @@copy_dist = 0
  @@stored_left = 0
  @@adler_a = 1_u32
  @@adler_b = 0_u32
  @@adler_n = 0
  @@have = 0
  @@wpos = 0

  def self.err : Int32
    @@err
  end

  # Internal RAM (fast) when a block that big is free, else PSRAM: with
  # Wi-Fi, the robot VM and the 12 KiB shell stacks the largest internal
  # block can be under the 32 KiB window, and the Etch-a-Sketch frame
  # then failed to decode (PNG E_MEMORY, a white Sketch screen).
  def self.alloc(n : Int32) : UInt8*
    p = LibIDF.heap_caps_malloc(n.to_u32!, 0x804_u32).as(UInt8*) # MALLOC_CAP_INTERNAL | 8BIT
    p = LibIDF.heap_caps_malloc(n.to_u32!, 0x4_u32).as(UInt8*) if p.null? # any 8-bit heap (PSRAM)
    p
  end

  # Allocates buffers and computes the RFC 1951 base/extra tables.
  def self.setup : Bool
    return true if @@ready
    @@window = alloc(WINDOW)
    @@lengths = alloc(FIXLCODE + MAXDCODE)
    @@lcount = alloc((MAXBITS + 1) * 2).as(UInt16*)
    @@lsym = alloc(FIXLCODE * 2).as(UInt16*)
    @@dcount = alloc((MAXBITS + 1) * 2).as(UInt16*)
    @@dsym = alloc(MAXDCODE * 2).as(UInt16*)
    @@offs = alloc((MAXBITS + 1) * 2).as(UInt16*)
    @@len_base = alloc(29 * 2).as(UInt16*)
    @@len_extra = alloc(29)
    @@dist_base = alloc(30 * 2).as(UInt16*)
    @@dist_extra = alloc(30)
    @@clen_order = alloc(19)
    @@flcount = alloc((MAXBITS + 1) * 2).as(UInt16*)
    @@flsym = alloc(FIXLCODE * 2).as(UInt16*)
    @@fdcount = alloc((MAXBITS + 1) * 2).as(UInt16*)
    @@fdsym = alloc(MAXDCODE * 2).as(UInt16*)
    # Every allocation is checked (they are made once and never freed).
    return false if @@window.null? || @@lengths.null? || @@lcount.null? || @@lsym.null? ||
                    @@dcount.null? || @@dsym.null? || @@offs.null? || @@len_base.null? ||
                    @@len_extra.null? || @@dist_base.null? || @@dist_extra.null? ||
                    @@clen_order.null? || @@flcount.null? || @@flsym.null? ||
                    @@fdcount.null? || @@fdsym.null?

    # Length codes 257..285: extra = 0 for the first 8, then (i-4)/4; 258 last.
    b = 3
    i = 0
    while i < 29
      e = i < 8 ? 0 : (i &- 4).unsafe_shr(2)
      e = 0 if i == 28
      @@len_extra[i] = e.to_u8!
      @@len_base[i] = (i == 28 ? 258 : b).to_u16!
      b = b &+ 1.unsafe_shl(e)
      i = i &+ 1
    end
    # Distance codes 0..29: extra = 0 for the first 4, then (i-2)/2.
    b = 1
    i = 0
    while i < 30
      e = i < 4 ? 0 : (i &- 2).unsafe_shr(1)
      @@dist_extra[i] = e.to_u8!
      @@dist_base[i] = b.to_u16!
      b = b &+ 1.unsafe_shl(e)
      i = i &+ 1
    end
    # Code-length order: 16 17 18 0 8 7 9 6 10 5 11 4 12 3 13 2 14 1 15
    @@clen_order[0] = 16_u8
    @@clen_order[1] = 17_u8
    @@clen_order[2] = 18_u8
    @@clen_order[3] = 0_u8
    j = 0
    while j < 15
      v = (j & 1) == 0 ? 8 &+ j.unsafe_shr(1) : 7 &- (j &- 1).unsafe_shr(1)
      @@clen_order[4 &+ j] = v.to_u8!
      j = j &+ 1
    end
    # Fixed Huffman codes (RFC 1951 3.2.6), built once.
    l = @@lengths
    i = 0
    while i < FIXLCODE
      l[i] = (i < 144 ? 8 : (i < 256 ? 9 : (i < 280 ? 7 : 8))).to_u8!
      i = i &+ 1
    end
    build(@@flcount, @@flsym, l, FIXLCODE)
    i = 0
    while i < MAXDCODE
      l[i] = 5_u8
      i = i &+ 1
    end
    build(@@fdcount, @@fdsym, l, MAXDCODE)
    @@ready = true
    true
  end

  def self.fail(code : Int32) : Nil
    @@err = code if @@err == 0
    @@state = ST_DONE
  end

  def self.need_byte : Int32
    b = PNG.next_byte
    if b < 0
      fail(E_EOF)
      return 0
    end
    b
  end

  @[AlwaysInline]
  def self.bits(need : Int32) : Int32
    while @@bitcnt < need
      @@bitbuf = @@bitbuf | need_byte.to_u32!.unsafe_shl(@@bitcnt)
      @@bitcnt = @@bitcnt &+ 8
    end
    val = @@bitbuf & (1_u32.unsafe_shl(need) &- 1_u32)
    @@bitbuf = @@bitbuf.unsafe_shr(need)
    @@bitcnt = @@bitcnt &- need
    val.to_i32!
  end

  # Starts a zlib stream: reads and checks the 2-byte header.
  def self.start : Bool
    return false unless setup
    @@err = 0
    @@bitbuf = 0_u32
    @@bitcnt = 0
    @@state = ST_HEADER
    @@last = false
    @@copy_len = 0
    @@copy_dist = 0
    @@stored_left = 0
    @@adler_a = 1_u32
    @@adler_b = 0_u32
    @@adler_n = 0
    @@have = 0
    @@wpos = 0
    cmf = need_byte
    flg = need_byte
    if (cmf & 0x0f) != 8 || (cmf.unsafe_shl(8) | flg).unsafe_mod(31) != 0 || (flg & 0x20) != 0 ||
       cmf.unsafe_shr(4) &+ 8 > 15
      fail(E_HEADER)
    end
    @@err == 0
  end

  # Canonical Huffman code from lengths[0, n] (puff representation).
  # Returns 0 for a complete code, > 0 for an incomplete one (the caller
  # decides whether that is allowed), -1 (and fails) if over-subscribed.
  def self.build(count : UInt16*, sym : UInt16*, lengths : UInt8*, n : Int32) : Int32
    i = 0
    while i <= MAXBITS
      count[i] = 0_u16
      i = i &+ 1
    end
    s = 0
    while s < n
      l = lengths[s].to_i32!
      count[l] = count[l] &+ 1_u16
      s = s &+ 1
    end
    return 0 if count[0].to_i32! == n # no codes
    left = 1
    len = 1
    while len <= MAXBITS
      left = left.unsafe_shl(1) &- count[len].to_i32!
      if left < 0
        fail(E_HUFF)
        return -1
      end
      len = len &+ 1
    end
    offs = @@offs
    offs[1] = 0_u16
    len = 1
    while len < MAXBITS
      offs[len &+ 1] = offs[len] &+ count[len]
      len = len &+ 1
    end
    s = 0
    while s < n
      l = lengths[s].to_i32!
      if l != 0
        sym[offs[l].to_i32!] = s.to_u16!
        offs[l] = offs[l] &+ 1_u16
      end
      s = s &+ 1
    end
    left
  end

  def self.decode(count : UInt16*, sym : UInt16*) : Int32
    code = 0
    first = 0
    index = 0
    len = 1
    while len <= MAXBITS
      code = code | bits(1)
      c = count[len].to_i32!
      return sym[index &+ (code &- first)].to_i32! if code &- c < first
      index = index &+ c
      first = (first &+ c).unsafe_shl(1)
      code = code.unsafe_shl(1)
      len = len &+ 1
    end
    fail(E_HUFF)
    0
  end

  @[AlwaysInline]
  def self.put(b : UInt8) : UInt8
    @@window[@@wpos] = b
    @@wpos = (@@wpos &+ 1) & (WINDOW &- 1)
    @@have = @@have &+ 1 if @@have < WINDOW
    @@adler_a = @@adler_a &+ b.to_u32!
    @@adler_b = @@adler_b &+ @@adler_a
    @@adler_n = @@adler_n &+ 1
    if @@adler_n == 5552
      @@adler_a = @@adler_a.unsafe_mod(65521_u32)
      @@adler_b = @@adler_b.unsafe_mod(65521_u32)
      @@adler_n = 0
    end
    b
  end

  def self.start_match(sym : Int32) : Nil
    sym = sym &- 257
    if sym >= 29
      fail(E_SYMBOL)
      return
    end
    len = @@len_base[sym].to_i32! &+ bits(@@len_extra[sym].to_i32!)
    dsym = decode(@@dc, @@ds)
    if dsym >= 30
      fail(E_SYMBOL)
      return
    end
    dist = @@dist_base[dsym].to_i32! &+ bits(@@dist_extra[dsym].to_i32!)
    if dist > @@have
      fail(E_DISTANCE)
      return
    end
    @@copy_len = len
    @@copy_dist = dist
  end

  def self.fixed_tables : Nil
    @@lc = @@flcount
    @@ls = @@flsym
    @@dc = @@fdcount
    @@ds = @@fdsym
  end

  def self.dynamic_tables : Nil
    nlen = bits(5) &+ 257
    ndist = bits(5) &+ 1
    ncode = bits(4) &+ 4
    if nlen > MAXLCODE || ndist > MAXDCODE
      fail(E_BLOCK)
      return
    end
    l = @@lengths
    i = 0
    while i < 19
      l[@@clen_order[i].to_i32!] = i < ncode ? bits(3).to_u8! : 0_u8
      i = i &+ 1
    end
    if build(@@lcount, @@lsym, l, 19) != 0 # code-length code must be complete
      fail(E_HUFF)
      return
    end
    index = 0
    total = nlen &+ ndist
    while index < total && @@err == 0
      sym = decode(@@lcount, @@lsym)
      return if @@err != 0
      if sym < 16
        l[index] = sym.to_u8!
        index = index &+ 1
      else
        len = 0_u8
        rep = 0
        if sym == 16
          if index == 0
            fail(E_BLOCK)
            return
          end
          len = l[index &- 1]
          rep = 3 &+ bits(2)
        elsif sym == 17
          rep = 3 &+ bits(3)
        else
          rep = 11 &+ bits(7)
        end
        if index &+ rep > total
          fail(E_BLOCK)
          return
        end
        while rep > 0
          l[index] = len
          index = index &+ 1
          rep = rep &- 1
        end
      end
    end
    if l[256] == 0_u8
      fail(E_BLOCK)
      return
    end
    # Incomplete codes are only allowed when they hold a single code (puff).
    left = build(@@dcount, @@dsym, l + nlen.to_i64!, ndist)
    if left < 0 || (left > 0 && ndist &- @@dcount[0].to_i32! != 1)
      fail(E_HUFF)
      return
    end
    left = build(@@lcount, @@lsym, l, nlen)
    if left < 0 || (left > 0 && nlen &- @@lcount[0].to_i32! != 1)
      fail(E_HUFF)
      return
    end
    @@lc = @@lcount
    @@ls = @@lsym
    @@dc = @@dcount
    @@ds = @@dsym
  end

  def self.block_header : Nil
    @@last = bits(1) == 1
    t = bits(2)
    if t == 0
      @@bitbuf = 0_u32
      @@bitcnt = 0
      len = need_byte | need_byte.unsafe_shl(8)
      nlen = need_byte | need_byte.unsafe_shl(8)
      if len != (nlen ^ 0xffff)
        fail(E_STORED)
        return
      end
      @@stored_left = len
      @@state = ST_STORED
    elsif t == 1
      fixed_tables
      @@state = ST_HUFF
    elsif t == 2
      dynamic_tables
      @@state = ST_HUFF
    else
      fail(E_BLOCK)
    end
  end

  def self.finish : Nil
    @@bitbuf = 0_u32
    @@bitcnt = 0
    expected = 0_u32
    i = 0
    while i < 4
      expected = expected.unsafe_shl(8) | need_byte.to_u32!
      i = i &+ 1
    end
    actual = @@adler_b.unsafe_mod(65521_u32).unsafe_shl(16) | @@adler_a.unsafe_mod(65521_u32)
    fail(E_ADLER) if actual != expected
    @@state = ST_DONE
  end

  # Fills dst[0, size]; returns the number of bytes written (less than
  # size only at end of stream or on error; check `err`).
  def self.read(dst : UInt8*, size : Int32) : Int32
    n = 0
    while n < size
      return n if @@err != 0
      if @@copy_len > 0
        while @@copy_len > 0 && n < size
          dst[n] = put(@@window[(@@wpos &- @@copy_dist) & (WINDOW &- 1)])
          n = n &+ 1
          @@copy_len = @@copy_len &- 1
        end
        next
      end
      st = @@state
      if st == ST_HUFF
        sym = decode(@@lc, @@ls)
        if sym < 256
          dst[n] = put(sym.to_u8!)
          n = n &+ 1
        elsif sym == 256
          @@state = ST_HEADER
        else
          start_match(sym)
        end
      elsif st == ST_STORED
        if @@stored_left == 0
          @@state = ST_HEADER
        else
          dst[n] = put(need_byte.to_u8!)
          n = n &+ 1
          @@stored_left = @@stored_left &- 1
        end
      elsif st == ST_HEADER
        if @@last
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

  # After the last row: decode on to the end of the stream (the final
  # end-of-block and the Adler-32 check). Any further output is an error.
  def self.finish_stream : Bool
    scratch = 0_u8
    while @@err == 0 && @@state != ST_DONE
      if read(pointerof(scratch), 1) != 0
        fail(E_EXTRA)
      end
    end
    @@err == 0
  end
end
