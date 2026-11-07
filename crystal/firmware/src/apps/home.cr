# Home screen: an icon grid of every registered app (src/apps/app.cr),
# 4 x 2 per page. Menu - / Menu + or the right knob move the selection
# (moving past the last icon of a page turns the page), User A or B opens
# the app. Menu + and Menu - together come back here from any app.
#
# The grid is drawn and cleanly refreshed once on entry; a selection move
# only changes the two frame outlines and goes out as one differential
# update (EPD.refresh_diff: only the changed pixels are driven, ~0.65 s).
# Input that arrives during an update is folded into the next one.
# Idea and grid proportions after badge os's home screen (yigitabi5444).

module Home
  COLS     = 4
  PER_PAGE = 8
  PITCH_X  = 240
  X0       = 40
  Y0       = 80
  PITCH_Y  = 280
  LABEL_DY = Apps::ICON + 14
  FRAME    = 6
  PAD      = 14
  KNOB_STEP = 300 # right-knob travel (of 4096) per icon

  @@sel = 0
  @@shown_sel = -1
  @@shown_page = -1
  @@kref = -1

  def self.sel : Int32
    @@sel
  end

  def self.sel=(v : Int32) : Nil
    @@sel = v
  end

  def self.page_of(i : Int32) : Int32
    i.unsafe_div(PER_PAGE)
  end

  def self.pages : Int32
    (Apps.count &+ PER_PAGE &- 1).unsafe_div(PER_PAGE)
  end

  def self.cell_x(i : Int32) : Int32
    X0 &+ (i.unsafe_mod(PER_PAGE).unsafe_mod(COLS)) &* PITCH_X
  end

  def self.cell_y(i : Int32) : Int32
    Y0 &+ (i.unsafe_mod(PER_PAGE).unsafe_div(COLS)) &* PITCH_Y
  end

  def self.sel_frame(i : Int32, black : Bool) : Nil
    Gfx.frame(cell_x(i) &- PAD, cell_y(i) &- PAD, Apps::ICON &+ 2 &* PAD, LABEL_DY &+ 21 &+ 2 &* PAD, FRAME, black)
  end

  def self.draw_page(page : Int32) : Nil
    EPD.fill(EPD::WHITE)
    TopBar.draw("HOME", "< PREV", "NEXT >", "A: OPEN", "B: OPEN")
    n = Apps.count
    i = page &* PER_PAGE
    last = i &+ PER_PAGE
    last = n if last > n
    while i < last
      x = cell_x(i)
      y = cell_y(i)
      Apps.icon(i, x, y)
      Gfx.text_c(x &+ Apps::ICON.unsafe_div(2), y &+ LABEL_DY, Apps.name(i), 3)
      i = i &+ 1
    end
    np = pages
    if np > 1
      p = 0
      while p < np
        dx = EPD::WIDTH.unsafe_div(2) &- np &* 16 &+ p &* 32
        if p == page
          Gfx.box(dx, 612, 16, 16, true)
        else
          Gfx.frame(dx, 612, 16, 16, 3)
        end
        p = p &+ 1
      end
    end
    Gfx.text_c(EPD::WIDTH.unsafe_div(2), 648, "KNOB R: SCROLL   MENU + AND - TOGETHER: HOME FROM ANY APP", 2)
    @@shown_page = page
  end

  def self.enter : Nil
    n = Apps.count
    @@sel = 0 if @@sel < 0 || @@sel >= n
    @@kref = -1
    draw_page(page_of(@@sel))
    sel_frame(@@sel, true)
    @@shown_sel = @@sel
    Apps.show_clean
  end

  def self.tick(now : Int32, inp : LibGames::Input) : Nil
    n = Apps.count
    return if n == 0
    if Games.pressed?(inp, Games::BTN_A) || Games.pressed?(inp, Games::BTN_B)
      Shared.target = @@sel
      return
    end
    s = @@sel
    s = s &+ 1 if Games.pressed?(inp, Games::BTN_PLUS)
    s = s &- 1 if Games.pressed?(inp, Games::BTN_MINUS)
    k = Games.knob_right(inp)
    @@kref = k if @@kref < 0
    d = k &- @@kref
    while d >= KNOB_STEP
      s = s &+ 1
      d = d &- KNOB_STEP
      @@kref = @@kref &+ KNOB_STEP
    end
    while d <= 0 &- KNOB_STEP
      s = s &- 1
      d = d &+ KNOB_STEP
      @@kref = @@kref &- KNOB_STEP
    end
    s = s.unsafe_mod(n)
    s = s &+ n if s < 0
    @@sel = s
    return if s == @@shown_sel
    if page_of(s) != @@shown_page
      draw_page(page_of(s))
    else
      sel_frame(@@shown_sel, false)
    end
    sel_frame(s, true)
    @@shown_sel = s
    Apps.show
  end
end
