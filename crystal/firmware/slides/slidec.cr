# Slide deck converter (host side, standard prelude): turns a deck source
# into the packed "SLD1" deck that the Slides app (src/apps/slides.cr) shows,
# one slide per screen. All layout happens here: font scale, word wrap and
# placement, so the badge only replays records (src/games/slide_deck.cr has
# the format).
#
# Sources (by file extension):
#   .json  the mechanical-turk workshop deck format (www/workshop-v2/
#          slides.json): an array of {title, bullets, body (HTML), image,
#          alt, steps, program, type, ...}. Speaker notes and metadata are
#          not shown.
#   .md    slides separated by a line "---"; "# Title", "- bullet" or
#          "* bullet", "![alt](url)" for an image, other lines paragraphs.
# Images are not drawn yet: each one is a framed box with its alt text.
# Text is the badge's 5x7 ASCII font; typographic Unicode is transliterated
# (quotes, dashes, arrows), anything else becomes '?'.

require "json"
require "compress/zlib"
require "digest/crc32"

module SlideC
  W      = 960
  H      = 672
  MARGIN =  40
  BLACK  = 1_u8
  RED    = 2_u8

  enum Kind
    Para
    Bullet
    Heading
    Code
  end

  record Item, kind : Kind, text : String

  class Slide
    property title : String
    property subtitle = ""
    property items = [] of Item
    property images = [] of String # alt text, one box each

    def initialize(@title : String)
    end
  end

  # ---- text ---------------------------------------------------------------

  TRANSLIT = {
    '‘' => "'", '’' => "'", '‚' => ",", '“' => "\"", '”' => "\"", '„' => "\"",
    '–' => "-", '—' => " - ", '−' => "-", '·' => "-", '•' => "*", '…' => "...",
    '→' => "->", '←' => "<-", '≠' => "!=", '≤' => "<=", '≥' => ">=", '×' => "x",
    '÷' => "/", '°' => " deg", '½' => "1/2", '©' => "(c)", ' ' => " ",
    ' ' => " ", ' ' => " ", 'é' => "e", 'è' => "e", 'á' => "a",
    'à' => "a", 'ó' => "o", 'ö' => "o", 'ü' => "u", 'ä' => "a", 'ñ' => "n", 'í' => "i",
  }

  # Printable ASCII only, whitespace runs collapsed to one space; U+2028
  # (from <br>) becomes a hard line break, "\n".
  def self.ascii(s : String) : String
    res = String.build do |io|
      s.each_char do |c|
        if c == ' '
          io << '\n'
        elsif c == '\n' || c == '\t' || c == '\r'
          io << ' '
        elsif c.ord >= 0x20 && c.ord <= 0x7E
          io << c
        elsif t = TRANSLIT[c]?
          io << t
        else
          io << '?'
        end
      end
    end
    res.gsub(/ {2,}/, " ").gsub(/ *\n */, "\n").strip
  end

  def self.entities(s : String) : String
    s.gsub(/&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos|nbsp);/) do |_, m|
      e = m[1]
      if e.starts_with?("#x")
        e[2..].to_i(16).chr.to_s
      elsif e.starts_with?('#')
        e[1..].to_i.chr.to_s
      else
        {"amp" => "&", "lt" => "<", "gt" => ">", "quot" => "\"", "apos" => "'", "nbsp" => " "}[e]
      end
    end
  end

  BLOCK = %w(p div li ul ol h1 h2 h3 h4 tr table section blockquote pre)

  # Body HTML -> items and image alt texts. Block tags end a run of text;
  # <li> starts a bullet, <h*> a heading, <img alt> an image; <br> breaks
  # the line; other inline tags (span, b, strong, a, ...) separate words.
  def self.html(src : String, slide : Slide) : Nil
    kind = Kind::Para
    buf = String::Builder.new
    flush = ->{
      t = ascii(entities(buf.to_s))
      slide.items << Item.new(kind, t) unless t.empty?
      buf = String::Builder.new
    }
    src.scan(/<[^>]*>|[^<]+/) do |m|
      tok = m[0]
      unless tok.starts_with?('<')
        buf << tok
        next
      end
      name = tok.match(/^<\/?\s*([a-zA-Z0-9]+)/).try(&.[1].downcase) || ""
      closing = tok.starts_with?("</")
      if name == "br"
        buf << ' '
      elsif name == "img"
        flush.call
        alt = tok.match(/alt="([^"]*)"/).try(&.[1]) || ""
        slide.images << ascii(entities(alt))
      elsif BLOCK.includes?(name)
        flush.call
        kind = if closing
                 Kind::Para
               elsif name == "li"
                 Kind::Bullet
               elsif name.starts_with?('h')
                 Kind::Heading
               else
                 Kind::Para
               end
      else
        buf << ' '
      end
    end
    flush.call
  end

  def self.plain(s : String) : String
    ascii(entities(s.gsub(/<br\s*\/?>/, " ").gsub(/<[^>]*>/, "")))
  end

  # ---- sources --------------------------------------------------------------

  def self.load(path : String) : Array(Slide)
    text = File.read(path)
    path.ends_with?(".md") ? from_markdown(text) : from_json(text)
  end

  def self.step_no(v : JSON::Any?) : String
    return "STOP" if v.nil? || v.raw == 0 || v.raw == 0_i64 || v.as_s? == "STOP"
    v.to_s
  end

  def self.from_json(text : String) : Array(Slide)
    JSON.parse(text).as_a.map do |j|
      title = plain(j["title"]?.try(&.as_s?) || "")
      s = Slide.new(title)
      if j["type"]?.try(&.as_s?) == "cover" && (k = title.index(": "))
        s.title = title[0, k]
        s.subtitle = title[k + 2..]
      end
      if img = j["image"]?.try(&.as_s?)
        s.images << plain(j["alt"]?.try(&.as_s?) || img)
      end
      j["bullets"]?.try(&.as_a?).try &.each { |b| t = plain(b.as_s); s.items << Item.new(Kind::Bullet, t) unless t.empty? }
      html(j["body"]?.try(&.as_s?) || "", s)
      j["steps"]?.try(&.as_a?).try &.each { |st| s.items << Item.new(Kind::Bullet, plain(st["text"]?.try(&.as_s?) || "")) }
      j["program"]?.try(&.as_a?).try &.each_with_index do |st, i|
        op = st["op"]?.try(&.as_s?) || "?"
        line = "Step #{i + 1}: #{op} cup #{st["dish"]?}, "
        line += op == "TAKE" ? "got one -> #{step_no(st["next"]?)}, empty -> #{step_no(st["empty"]?)}" : "next -> #{step_no(st["next"]?)}"
        s.items << Item.new(Kind::Code, line)
      end
      s
    end
  end

  def self.from_markdown(text : String) : Array(Slide)
    text.split(/^---\s*$/m).compact_map do |chunk|
      s = Slide.new("")
      chunk.each_line do |l|
        l = l.strip
        next if l.empty?
        if l.starts_with?("# ")
          s.title = ascii(l[2..])
        elsif l.starts_with?("## ")
          s.items << Item.new(Kind::Heading, ascii(l[3..]))
        elsif m = l.match(/^!\[([^\]]*)\]\(([^)]*)\)$/)
          s.images << ascii(m[1].empty? ? m[2] : m[1])
        elsif l.starts_with?("- ") || l.starts_with?("* ")
          s.items << Item.new(Kind::Bullet, ascii(l[2..]))
        else
          s.items << Item.new(Kind::Para, ascii(l))
        end
      end
      s.title.empty? && s.items.empty? && s.images.empty? ? nil : s
    end
  end

  # ---- layout ---------------------------------------------------------------

  # Characters of the 5x7 font (6 px cell) that fit w px at scale.
  def self.cols(w : Int32, scale : Int32) : Int32
    (w + scale) // (6 * scale)
  end

  def self.text_w(s : String, scale : Int32) : Int32
    s.empty? ? 0 : (s.bytesize * 6 - 1) * scale
  end

  # Greedy word wrap to lines of at most n characters (long words split,
  # "\n" a hard break).
  def self.wrap(s : String, n : Int32) : Array(String)
    s.split('\n').flat_map { |para| wrap_line(para, n) }
  end

  def self.wrap_line(s : String, n : Int32) : Array(String)
    lines = [] of String
    cur = ""
    s.split(' ').each do |word|
      next if word.empty?
      while word.size > n
        lines << cur unless cur.empty?
        cur = ""
        lines << word[0, n]
        word = word[n..]
      end
      if cur.empty?
        cur = word
      elsif cur.size + 1 + word.size <= n
        cur += " " + word
      else
        lines << cur
        cur = word
      end
    end
    lines << cur unless cur.empty?
    lines
  end

  # Cuts lines to max, the last one ending in "..." when something was cut.
  def self.cut(lines : Array(String), max : Int32, n : Int32) : Array(String)
    return lines if lines.size <= max
    return [] of String if max <= 0
    res = lines[0, max]
    last = res[-1]
    last = last[0, n - 3].rstrip if last.size > n - 3
    res[-1] = last + "..."
    res
  end

  # Display list records (see src/games/slide_deck.cr).
  abstract struct Rec
  end

  record Text < Rec, x : Int32, y : Int32, scale : Int32, color : UInt8, s : String
  record Box < Rec, x : Int32, y : Int32, w : Int32, h : Int32, color : UInt8
  record Frame < Rec, x : Int32, y : Int32, w : Int32, h : Int32, t : Int32, color : UInt8

  FOOT_Y  = H - 30 # page number row (scale 2)
  BOTTOM  = H - 44 # content ends above it
  GUTTER  =     40
  IMG_COL =    300 # image column width when text shares the slide

  # Lays out one slide; red = title rule and bullet markers in red (the
  # badge then needs its slow colour refresh for that slide, ~30 s).
  def self.layout(s : Slide, index : Int32, total : Int32, red : Bool = false) : Array(Rec)
    recs = [] of Rec
    accent = red ? RED : BLACK
    width = W - 2 * MARGIN
    y = 32
    title = s.title.empty? ? " " : s.title
    tscale, tlines = {6, 5, 4, 3}.each do |sc|
      l = wrap(title, cols(width, sc))
      break {sc, l} if l.size <= 2
    end || {3, cut(wrap(title, cols(width, 3)), 3, cols(width, 3))}
    tlines.each do |l|
      recs << Text.new(MARGIN, y, tscale, BLACK, l)
      y += 9 * tscale
    end
    unless s.subtitle.empty?
      wrap(s.subtitle, cols(width, 4)).first(2).each do |l|
        recs << Text.new(MARGIN, y, 4, BLACK, l)
        y += 36
      end
    end
    y += 6
    recs << Box.new(MARGIN, y, width, 4, accent)
    top = y + 28

    text_w = width
    img_x = MARGIN
    img_w = width
    if !s.images.empty? && !s.items.empty?
      text_w = width - IMG_COL - GUTTER
      img_x = MARGIN + text_w + GUTTER
      img_w = IMG_COL
    end

    body(recs, s.items, MARGIN, top, text_w, BOTTOM - top, accent) unless s.items.empty?
    images(recs, s.images, img_x, top, img_w, BOTTOM - top) unless s.images.empty?

    foot = "#{index + 1}/#{total}"
    recs << Text.new(W - MARGIN - text_w(foot, 2), FOOT_Y, 2, BLACK, foot)
    recs
  end

  # Items in [x, x + w) from y, at the largest scale (4..2) that fits h.
  def self.body(recs : Array(Rec), items : Array(Item), x : Int32, y : Int32, w : Int32, h : Int32, accent : UInt8) : Nil
    {4, 3, 2}.each do |sc|
      recs1 = [] of Rec
      if place(recs1, items, x, y, w, y + h, sc, accent, sc == 2)
        recs.concat(recs1)
        return
      end
    end
  end

  # Places items at one scale; false if they don't fit (unless forced, then
  # cut, with "..." on the last line that fits).
  def self.place(dst : Array(Rec), items : Array(Item), x : Int32, y : Int32, w : Int32, ymax : Int32, sc : Int32, accent : UInt8, force : Bool) : Bool
    lh = 10 * sc
    indent = 2 * 6 * sc
    items.each do |it|
      tx = it.kind.bullet? ? x + indent : x
      n = cols(w - (tx - x), sc)
      lines = wrap(it.text, n)
      room = (ymax - y + 2 * sc) // lh
      full = lines.size <= room
      unless full
        return false unless force
        lines = cut(lines, room, n)
        if lines.empty? # no room left at all: mark the last line drawn
          if i = dst.rindex(&.is_a?(Text))
            t = dst[i].as(Text)
            dst[i] = t.copy_with(s: (t.s.size > n - 3 ? t.s[0, n - 3].rstrip : t.s) + "...")
          end
          return true
        end
      end
      dst << Box.new(x + sc, y + 2 * sc, 4 * sc, 4 * sc, accent) if it.kind.bullet?
      lines.each do |l|
        dst << Text.new(tx, y, sc, BLACK, l)
        y += lh
      end
      return true unless full
      y += 4 * sc # item gap
    end
    true
  end

  # Image placeholders stacked in the column: a frame, "IMAGE", the alt text.
  def self.images(recs : Array(Rec), alts : Array(String), x : Int32, y : Int32, w : Int32, h : Int32) : Nil
    gap = 16
    bh = (h - gap * (alts.size - 1)) // alts.size
    alts.each do |alt|
      recs << Frame.new(x, y, w, bh, 3, BLACK)
      recs << Text.new(x + 14, y + 14, 2, BLACK, "IMAGE")
      n = cols(w - 28, 2)
      room = (bh - 14 - 14 - 26 + 4) // 20
      cut(wrap(alt.empty? ? "(no description)" : alt, n), room, n).each_with_index do |l, i|
        recs << Text.new(x + 14, y + 40 + i * 20, 2, BLACK, l)
      end
      y += bh + gap
    end
  end

  # ---- packing --------------------------------------------------------------

  def self.put16(io : IO, v : Int32) : Nil
    raise "slidec: #{v} out of u16 range" unless 0 <= v <= 0xFFFF
    io.write_bytes(v.to_u16, IO::ByteFormat::LittleEndian)
  end

  def self.encode(recs : Array(Rec)) : Bytes
    io = IO::Memory.new
    recs.each do |r|
      case r
      when Text
        s = r.s.byte_slice(0, 255)
        io.write_byte(1_u8); put16(io, r.x); put16(io, r.y)
        io.write_byte(r.scale.to_u8); io.write_byte(r.color); io.write_byte(s.bytesize.to_u8)
        io.write(s.to_slice)
      when Box
        io.write_byte(2_u8); put16(io, r.x); put16(io, r.y); put16(io, r.w); put16(io, r.h)
        io.write_byte(r.color)
      when Frame
        io.write_byte(3_u8); put16(io, r.x); put16(io, r.y); put16(io, r.w); put16(io, r.h)
        io.write_byte(r.t.to_u8); io.write_byte(r.color)
      end
    end
    io.write_byte(0_u8)
    io.to_slice
  end

  def self.pack(slides : Array(Slide), red : Bool = false) : Bytes
    raise "slidec: no slides" if slides.empty?
    bodies = slides.map_with_index { |s, i| encode(layout(s, i, slides.size, red)) }
    io = IO::Memory.new
    io << "SLD1"
    put16(io, slides.size); put16(io, 0)
    off = 8 + (slides.size + 1) * 4
    bodies.each do |b|
      io.write_bytes(off.to_u32, IO::ByteFormat::LittleEndian)
      off += b.size
    end
    io.write_bytes(off.to_u32, IO::ByteFormat::LittleEndian)
    bodies.each { |b| io.write(b) }
    io.to_slice
  end

  def self.convert(path : String, red : Bool = false) : Bytes
    pack(load(path), red)
  end

  # The deck the firmware embeds: slides/deck.json, else slides/deck.md.
  def self.default_source(dir : String) : String
    json = File.join(dir, "deck.json")
    File.exists?(json) ? json : File.join(dir, "deck.md")
  end

  # Both planes as an indexed PNG (white / black / red), for --preview.
  def self.png(io : IO, black : UInt8*, red : UInt8*) : Nil
    raw = IO::Memory.new
    Compress::Zlib::Writer.open(raw) do |z|
      row = Bytes.new(W + 1) # filter byte 0, then one palette index per pixel
      H.times do |y|
        W.times do |x|
          i = y * (W // 8) + (x >> 3)
          m = 0x80_u8 >> (x & 7)
          row[x + 1] = (red[i] & m) != 0 ? 2_u8 : ((black[i] & m) != 0 ? 1_u8 : 0_u8)
        end
        z.write(row)
      end
    end
    io.write(Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    ihdr = IO::Memory.new
    ihdr.write_bytes(W.to_u32, IO::ByteFormat::BigEndian)
    ihdr.write_bytes(H.to_u32, IO::ByteFormat::BigEndian)
    ihdr.write(Bytes[8, 3, 0, 0, 0]) # 8-bit, palette
    chunk(io, "IHDR", ihdr.to_slice)
    chunk(io, "PLTE", Bytes[255, 255, 255, 0, 0, 0, 200, 0, 0])
    chunk(io, "IDAT", raw.to_slice)
    chunk(io, "IEND", Bytes.empty)
  end

  def self.chunk(io : IO, type : String, data : Bytes) : Nil
    io.write_bytes(data.size.to_u32, IO::ByteFormat::BigEndian)
    io << type
    io.write(data)
    crc = Digest::CRC32.update(data, Digest::CRC32.update(type.to_slice, Digest::CRC32.initial))
    io.write_bytes(crc, IO::ByteFormat::BigEndian)
  end

  # The badge's 5x7 font, read from main/font5x7.h (95 glyphs x 5 bytes).
  def self.font(header : String) : Bytes
    bytes = header.scan(/\{((?:0x[0-9A-Fa-f]{2},?){5})\}/).flat_map { |m| m[1].split(',').reject(&.empty?).map(&.to_u8(prefix: true)) }
    raise "slidec: font has #{bytes.size} bytes" unless bytes.size == 95 * 5
    Bytes.new(bytes.size) { |i| bytes[i] }
  end
end
