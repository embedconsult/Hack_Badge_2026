# Supercon schedule (port of apps/schedule.py): data/schedule.csv is
# embedded in the firmware (main/schedule.csv, EMBED_FILES) and parsed
# here. One day per page set, talks and workshops in time order, 8 per
# page: time, room, title (up to two lines) and speaker.
#   right knob: move the cursor (the page follows)   A / B: page up / down
# When the clock is set (SNTP in network mode, or shell `clock`) and it is
# Supercon (6-8 Nov 2026, Pasadena time), running sessions are marked NOW
# and the next slot NEXT, and the app opens there.
# Cursor and NOW/NEXT changes are differential updates (~0.65 s).

lib LibIDF
  fun cr_schedule_csv : UInt8*
  fun cr_schedule_csv_size : Int32
  fun cr_time_local(v : Int32*) : Bool
end

module ScheduleApp
  include App
  ORDER = 110
  NAME  = "SCHEDULE"
  COLOR = 0x00FF60_u32

  MAX_E    = 120
  F        = 10 # ints per entry
  E_DAY    = 0
  E_MIN    = 1
  E_TIME   = 2 # (offset, length) pairs into @@txt
  E_STAGE  = 4
  E_TALK   = 6
  E_SPKR   = 8
  PER_PAGE = 8
  ROW_Y    = 92
  ROW_H    = 72
  TEXT_X   = 184
  WRAP     = 62 # characters per title line at scale 2
  KNOB_STEP = 250
  YEAR     = 2026
  MONTH    = 11
  FIRST_DAY = 6 # Fri 6 Nov 2026

  @@txt = Pointer(UInt8).null
  @@e = Pointer(Int32).null
  @@ord = Pointer(Int32).null # sorted entry numbers
  @@n = 0
  @@tv = Pointer(Int32).null  # time: y, mo, d, h, mi
  @@cur = 0
  @@shown_cur = -1
  @@shown_page = -1
  @@shown_key = -2
  @@kref = -1
  @@diffs = 0
  @@last_t = 0
  @@jumped = false

  def self.icon(x : Int32, y : Int32) : Nil
    Gfx.tile(x, y)
    Gfx.box(x &+ 28, y &+ 34, 104, 100, false)
    Gfx.box(x &+ 28, y &+ 34, 104, 24, false)
    Gfx.box(x &+ 28, y &+ 54, 104, 4, true)
    r = 0
    while r < 3
      c = 0
      while c < 4
        Gfx.box(x &+ 36 &+ c &* 24, y &+ 66 &+ r &* 22, 16, 14, true)
        c = c &+ 1
      end
      r = r &+ 1
    end
    Gfx.box(x &+ 48, y &+ 24, 8, 20, false)
    Gfx.box(x &+ 104, y &+ 24, 8, 20, false)
  end

  # ---- CSV --------------------------------------------------------------

  def self.field_is(o : Int32, l : Int32, w : String) : Bool
    Gfx.same_word?(@@txt + o.to_i64!, l, w)
  end

  def self.digits(o : Int32, l : Int32) : Int32
    v = 0
    i = 0
    while i < l
      c = @@txt[o &+ i].to_i32!
      v = v &* 10 &+ (c &- 0x30) if c >= 0x30 && c <= 0x39
      i = i &+ 1
    end
    v
  end

  # Parses the CSV (quoted fields with "" escapes) into @@e, sorted by
  # day, time and file order. Columns are found by header name.
  def self.load : Bool
    return true if @@n > 0
    src = LibIDF.cr_schedule_csv
    size = LibIDF.cr_schedule_csv_size
    @@txt = LibIDF.heap_caps_malloc((size &+ 1).to_u32!, 0x404_u32).as(UInt8*)
    @@e = LibIDF.heap_caps_malloc((MAX_E &* F &* 4).to_u32!, 0x404_u32).as(Int32*)
    @@ord = LibIDF.heap_caps_malloc((MAX_E &* 4).to_u32!, 0x404_u32).as(Int32*)
    @@tv = LibIDF.heap_caps_malloc(32_u32, 0x804_u32).as(Int32*)
    fo = LibIDF.heap_caps_malloc(64_u32, 0x804_u32).as(Int32*) # field offsets / lengths (16 fields)
    col = LibIDF.heap_caps_malloc(32_u32, 0x804_u32).as(Int32*) # day, time, stage, talk, speaker
    return false if @@txt.null? || @@e.null? || @@ord.null? || @@tv.null? || fo.null? || col.null?
    k = 0
    while k < 5
      col[k] = k
      k = k &+ 1
    end
    w = 0       # write position in @@txt
    nf = 0      # fields in this row
    start = 0
    quoted = false
    row = 0
    i = 0
    while i <= size
      c = i < size ? src[i] : 0x0A_u8
      if quoted
        if c == 0x22_u8 && i &+ 1 < size && src[i &+ 1] == 0x22_u8
          @@txt[w] = c
          w = w &+ 1
          i = i &+ 1
        elsif c == 0x22_u8
          quoted = false
        elsif i < size
          @@txt[w] = c
          w = w &+ 1
        else
          quoted = false
          i = i &- 1 # end of data inside quotes: close the row below
        end
      elsif c == 0x22_u8
        quoted = true
      elsif c == 0x2C_u8 || c == 0x0A_u8
        if nf < 8
          fo[nf &* 2] = start
          fo[nf &* 2 &+ 1] = w &- start
          nf = nf &+ 1
        end
        start = w
        if c == 0x0A_u8
          if row == 0
            k = 0
            while k < nf
              o = fo[k &* 2]
              l = fo[k &* 2 &+ 1]
              col[0] = k if field_is(o, l, "day")
              col[1] = k if field_is(o, l, "time")
              col[2] = k if field_is(o, l, "stage")
              col[3] = k if field_is(o, l, "talk")
              col[4] = k if field_is(o, l, "speaker")
              k = k &+ 1
            end
          elsif nf >= 5 && @@n < MAX_E && fo[col[1] &* 2 &+ 1] > 0
            add(fo, col)
          end
          row = row &+ 1 if nf > 1 || fo[1] > 0
          nf = 0
        end
      elsif c != 0x0D_u8
        @@txt[w] = c
        w = w &+ 1
      end
      i = i &+ 1
    end
    LibIDF.heap_caps_free(fo.as(Void*))
    LibIDF.heap_caps_free(col.as(Void*))
    sort
    log("schedule: entries", @@n)
    @@n > 0
  end

  def self.add(fo : Int32*, col : Int32*) : Nil
    e = @@e + (@@n &* F).to_i64!
    k = 0
    while k < 4
      c = col[k &+ 1]
      e[E_TIME &+ k &* 2] = fo[c &* 2]
      e[E_TIME &+ k &* 2 &+ 1] = fo[c &* 2 &+ 1]
      k = k &+ 1
    end
    d0 = fo[col[0] &* 2]
    dl = fo[col[0] &* 2 &+ 1]
    c1 = dl > 1 ? Gfx.upper(@@txt[d0 &+ 1]) : 0_u8
    e[E_DAY] = Gfx.upper(@@txt[d0]) == 0x46_u8 ? 0 : (c1 == 0x55_u8 ? 2 : 1) # Fri / Sun / Sat
    # "HH:MM"
    t0 = e[E_TIME]
    tl = e[E_TIME &+ 1]
    colon = 0
    while colon < tl && @@txt[t0 &+ colon] != 0x3A_u8
      colon = colon &+ 1
    end
    e[E_MIN] = digits(t0, colon) &* 60 &+ (colon < tl ? digits(t0 &+ colon &+ 1, tl &- colon &- 1) : 0)
    @@ord[@@n] = @@n
    @@n = @@n &+ 1
  end

  def self.key(i : Int32) : Int32
    e = @@e + (i &* F).to_i64!
    (e[E_DAY] &* 2000 &+ e[E_MIN]) &* 256 &+ i
  end

  def self.sort : Nil
    i = 1
    while i < @@n
      v = @@ord[i]
      kv = key(v)
      j = i &- 1
      while j >= 0 && key(@@ord[j]) > kv
        @@ord[j &+ 1] = @@ord[j]
        j = j &- 1
      end
      @@ord[j &+ 1] = v
      i = i &+ 1
    end
  end

  def self.ent(pos : Int32) : Int32*
    @@e + (@@ord[pos] &* F).to_i64!
  end

  # ---- pages --------------------------------------------------------------

  def self.day_start(d : Int32) : Int32
    i = 0
    while i < @@n && ent(i)[E_DAY] < d
      i = i &+ 1
    end
    i
  end

  def self.day_count(d : Int32) : Int32
    day_start(d &+ 1) &- day_start(d)
  end

  # Page id of a position: day * 100 + page in that day.
  def self.page_of(pos : Int32) : Int32
    d = ent(pos)[E_DAY]
    d &* 100 &+ (pos &- day_start(d)).unsafe_div(PER_PAGE)
  end

  def self.page_first(page : Int32) : Int32
    d = page.unsafe_div(100)
    day_start(d) &+ page.unsafe_mod(100) &* PER_PAGE
  end

  # ---- clock --------------------------------------------------------------

  # Today's day index (0 Fri .. 2 Sun) and minutes, or -1 if unknown / not
  # during Supercon.
  def self.today : Int32
    return -1 unless LibIDF.cr_time_local(@@tv)
    return -1 if @@tv[0] != YEAR || @@tv[1] != MONTH
    d = @@tv[2] &- FIRST_DAY
    d >= 0 && d <= 2 ? d : -1
  end

  def self.now_min : Int32
    @@tv[3] &* 60 &+ @@tv[4]
  end

  # End of the session at pos: the next start in the same room that day,
  # else start + 60 min.
  def self.end_min(pos : Int32) : Int32
    e = ent(pos)
    j = pos &+ 1
    while j < @@n && ent(j)[E_DAY] == e[E_DAY]
      f = ent(j)
      return f[E_MIN] if f[E_MIN] > e[E_MIN] && f[E_STAGE &+ 1] == e[E_STAGE &+ 1] &&
                         same_text(f[E_STAGE], e[E_STAGE], e[E_STAGE &+ 1])
      j = j &+ 1
    end
    e[E_MIN] &+ 60
  end

  def self.same_text(a : Int32, b : Int32, l : Int32) : Bool
    i = 0
    while i < l
      return false if @@txt[a &+ i] != @@txt[b &+ i]
      i = i &+ 1
    end
    true
  end

  # 1 = NOW, 2 = NEXT, 0 = neither (td = today, nm = minutes now).
  def self.mark(pos : Int32, td : Int32, nm : Int32) : Int32
    return 0 if td < 0
    e = ent(pos)
    return 0 if e[E_DAY] != td
    return 1 if e[E_MIN] <= nm && nm < end_min(pos)
    nxt = next_min(td, nm)
    nxt >= 0 && e[E_MIN] == nxt ? 2 : 0
  end

  def self.next_min(td : Int32, nm : Int32) : Int32
    i = day_start(td)
    while i < @@n && ent(i)[E_DAY] == td
      m = ent(i)[E_MIN]
      return m if m > nm
      i = i &+ 1
    end
    -1
  end

  # Position to open at: the first NOW, else the first NEXT entry.
  def self.jump_pos(td : Int32, nm : Int32) : Int32
    return -1 if td < 0
    i = day_start(td)
    best = -1
    while i < @@n && ent(i)[E_DAY] == td
      mk = mark(i, td, nm)
      return i if mk == 1
      best = i if mk == 2 && best < 0
      i = i &+ 1
    end
    best
  end

  # ---- drawing ------------------------------------------------------------

  def self.day_name(d : Int32) : String
    d == 0 ? "FRIDAY 6 NOV" : (d == 1 ? "SATURDAY 7 NOV" : "SUNDAY 8 NOV")
  end

  def self.wrap_at(o : Int32, l : Int32, max : Int32) : Int32
    return l if l <= max
    k = max
    while k > 0 && @@txt[o &+ k] != 0x20_u8
      k = k &- 1
    end
    k > 0 ? k : max
  end

  def self.draw_row(pos : Int32, slot : Int32, mk : Int32) : Nil
    e = ent(pos)
    y = ROW_Y &+ slot &* ROW_H
    if mk == 1
      Gfx.box(16, y &- 4, 100, 30, true)
      Gfx.bytes(20, y, @@txt + e[E_TIME].to_i64!, e[E_TIME &+ 1], 3, false)
    else
      Gfx.bytes(20, y, @@txt + e[E_TIME].to_i64!, e[E_TIME &+ 1], 3)
    end
    sl = e[E_STAGE &+ 1]
    sl = 13 if sl > 13
    Gfx.bytes(20, y &+ 30, @@txt + e[E_STAGE].to_i64!, sl, 2)
    if mk != 0
      Gfx.box(20, y &+ 48, mk == 1 ? 40 : 52, 18, true)
      Gfx.text(24, y &+ 50, mk == 1 ? "NOW" : "NEXT", 2, false)
    end
    o = e[E_TALK]
    l = e[E_TALK &+ 1]
    k = wrap_at(o, l, WRAP)
    Gfx.bytes(TEXT_X, y, @@txt + o.to_i64!, k, 2)
    ty = y &+ 20
    if k < l
      o2 = o &+ k
      l2 = l &- k
      if @@txt[o2] == 0x20_u8
        o2 = o2 &+ 1
        l2 = l2 &- 1
      end
      k2 = wrap_at(o2, l2, WRAP)
      if k2 < l2 && k2 > 3 # cut: end with "..."
        Gfx.bytes(TEXT_X, ty, @@txt + o2.to_i64!, k2, 2)
        Gfx.text(TEXT_X &+ k2 &* 12, ty, "...", 2)
      else
        Gfx.bytes(TEXT_X, ty, @@txt + o2.to_i64!, k2, 2)
      end
      ty = ty &+ 20
    end
    sp = e[E_SPKR &+ 1]
    sp = WRAP &- 2 if sp > WRAP &- 2
    Gfx.box(TEXT_X, ty &+ 7, 10, 4, true)
    Gfx.bytes(TEXT_X &+ 18, ty &+ 2, @@txt + e[E_SPKR].to_i64!, sp, 2)
    Gfx.box(TEXT_X, y &+ ROW_H &- 6, EPD::WIDTH &- TEXT_X &- 16, 1, true)
  end

  def self.cursor(pos : Int32, black : Bool) : Nil
    slot = (pos &- page_first(page_of(pos)))
    Gfx.box(0, ROW_Y &+ slot &* ROW_H &- 6, 10, ROW_H &- 4, black)
  end

  def self.draw_page(page : Int32, td : Int32, nm : Int32) : Nil
    EPD.fill(EPD::WHITE)
    TopBar.draw(NAME, "< APP", "APP >", "A: PAGE UP", "B: PAGE DOWN")
    d = page.unsafe_div(100)
    p = page.unsafe_mod(100)
    np = (day_count(d) &+ PER_PAGE &- 1).unsafe_div(PER_PAGE)
    x = Gfx.text(20, 54, day_name(d), 3)
    if np > 1
      buf = Shared.label_buf
      buf[0] = 0x20_u8
      n = 1 &+ put_decimal(buf + 1, p &+ 1)
      buf[n] = 0x2F_u8
      n = n &+ 1
      n = n &+ put_decimal(buf + n.to_i64!, np)
      Gfx.bytes(x &+ 12, 54, buf, n, 3)
    end
    if td >= 0
      buf = Shared.label_buf
      buf[0] = 0x30_u8 &+ (@@tv[3].unsafe_div(10)).to_u8!
      buf[1] = 0x30_u8 &+ (@@tv[3].unsafe_mod(10)).to_u8!
      buf[2] = 0x3A_u8
      buf[3] = 0x30_u8 &+ (@@tv[4].unsafe_div(10)).to_u8!
      buf[4] = 0x30_u8 &+ (@@tv[4].unsafe_mod(10)).to_u8!
      Gfx.text(EPD::WIDTH &- 16 &- 11 &* 18, 54, "NOW", 3)
      Gfx.bytes(EPD::WIDTH &- 16 &- 5 &* 18, 54, buf, 5, 3)
    else
      Gfx.text(EPD::WIDTH &- 16 &- 20 &* 12, 58, "KNOB R: SCROLL", 2)
    end
    Gfx.box(0, 84, EPD::WIDTH, 2, true)
    first = page_first(page)
    i = 0
    while i < PER_PAGE && first &+ i < @@n && ent(first &+ i)[E_DAY] == d
      draw_row(first &+ i, i, mark(first &+ i, td, nm))
      i = i &+ 1
    end
    @@shown_page = page
  end

  # Redraw whatever changed; one refresh. clean = full clean refresh.
  def self.update(clean : Bool) : Nil
    td = today
    nm = td >= 0 ? now_min : 0
    tkey = td >= 0 ? td &* 10000 &+ nm : -1
    pg = page_of(@@cur)
    if clean || pg != @@shown_page || tkey != @@shown_key
      draw_page(pg, td, nm)
      @@shown_key = tkey
    elsif @@shown_cur >= 0
      cursor(@@shown_cur, false)
    end
    cursor(@@cur, true)
    @@shown_cur = @@cur
    @@diffs = @@diffs &+ 1
    if clean || @@diffs >= 16
      @@diffs = 0
      Apps.show_clean
    else
      Apps.show
    end
  end

  def self.enter : Nil
    @@shown_page = -1
    @@shown_cur = -1
    @@kref = -1
    unless load
      EPD.fill(EPD::WHITE)
      TopBar.draw(NAME, "< APP", "APP >", "", "")
      Gfx.text(40, 120, "NO SCHEDULE DATA", 4)
      Apps.show_clean
      return
    end
    td = today
    if td >= 0
      j = jump_pos(td, now_min)
      @@cur = j >= 0 ? j : day_start(td)
      @@jumped = true
    end
    @@cur = 0 if @@cur >= @@n
    @@last_t = millis
    update(true)
  end

  def self.tick(now : Int32, inp : LibGames::Input) : Nil
    return if @@n == 0
    c = @@cur
    if Games.pressed?(inp, Games::BTN_A)
      f = page_first(page_of(c))
      c = f > 0 ? page_first(page_of(f &- 1)) : page_first(page_of(@@n &- 1))
    end
    if Games.pressed?(inp, Games::BTN_B)
      f = page_first(page_of(c))
      i = f
      pg = page_of(c)
      while i < @@n && page_of(i) == pg
        i = i &+ 1
      end
      c = i < @@n ? i : 0
    end
    k = Games.knob_right(inp)
    @@kref = k if @@kref < 0
    while k &- @@kref >= KNOB_STEP
      c = c &+ 1 if c &+ 1 < @@n
      @@kref = @@kref &+ KNOB_STEP
    end
    while @@kref &- k >= KNOB_STEP
      c = c &- 1 if c > 0
      @@kref = @@kref &- KNOB_STEP
    end
    timed = false
    if now &- @@last_t >= 30_000 # NOW / NEXT marks and the clock
      @@last_t = now
      td = today
      tkey = td >= 0 ? td &* 10000 &+ now_min : -1
      if tkey != @@shown_key
        timed = true
        if td >= 0 && !@@jumped # the clock just got set: go to now
          @@jumped = true
          j = jump_pos(td, now_min)
          c = j if j >= 0
        end
      end
    end
    return if c == @@cur && !timed
    @@cur = c
    update(false)
  end
end
