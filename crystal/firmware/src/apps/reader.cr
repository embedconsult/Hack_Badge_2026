# Hackaday and News: an RSS reader, one post per screen with its picture;
# User A opens it to read (pages, with its pictures). Feeds:
# hackaday.com/blog/feed/ and BBC World (feeds.bbci.co.uk/news/world).
# Menu - / + (or the right knob): previous / next post, or page up / down
# while reading. B: reload (browser) or back (reading).
# Idea: yigitabi5444's badge os Hackaday and News apps.

module Reader
  CLEAN_EVERY = 6 # differential updates between full clean refreshes

  @@app = 0
  @@post = 0    # selected post
  @@page = -1   # -1 = browser card, else page of the open post
  @@pages = 1
  @@sig = 0_u32
  @@drawn = 0
  @@diffs = 0
  @@st_shown = 0

  def self.draw(app : Int32) : Nil
    EPD.fill(EPD::WHITE)
    LibIDF.cr_reader_draw(app, EPD.black, @@post, @@page)
    title = app == NetApps::HACKADAY ? "HACKADAY" : "NEWS"
    st = LibIDF.cr_reader_state(app)
    if st != 1
      TopBar.draw(title, "", "", "A: RELOAD", "")
    elsif @@page < 0
      TopBar.draw(title, "< PREV", "NEXT >", "A: READ", "B: RELOAD")
    else
      TopBar.draw(title, "< PAGE UP", "PAGE DOWN >", "A: NEXT PAGE", "B: BACK")
    end
    @@sig = LibIDF.cr_reader_sig(app, @@post, @@page)
    @@st_shown = st
    @@drawn = millis
  end

  def self.show(clean : Bool) : Nil
    @@diffs = @@diffs &+ 1
    if clean || @@diffs >= CLEAN_EVERY
      @@diffs = 0
      Apps.show_clean
    else
      Apps.show
    end
  end

  def self.enter(app : Int32) : Nil
    @@app = app
    LibIDF.cr_app_enter(app)
    NetApps.knob_reset
    n = LibIDF.cr_reader_count(app)
    @@post = 0 if @@post >= n
    @@page = -1
    @@pages = LibIDF.cr_reader_view(app, @@post, @@page)
    draw(app)
    @@diffs = 0
    Apps.show_clean
  end

  def self.leave : Nil
    LibIDF.cr_app_leave
  end

  def self.tick(app : Int32, now : Int32, inp : LibGames::Input) : Nil
    LibIDF.cr_app_tick
    st = LibIDF.cr_reader_state(app)
    steps = NetApps.knob_steps(inp)
    steps = steps &+ 1 if Games.pressed?(inp, Games::BTN_PLUS)
    steps = steps &- 1 if Games.pressed?(inp, Games::BTN_MINUS)
    a = Games.pressed?(inp, Games::BTN_A)
    b = Games.pressed?(inp, Games::BTN_B)
    scene = false
    if st != 1
      if a || (b && st == 2)
        LibIDF.cr_app_reload(app)
        @@post = 0
        @@page = -1
      end
    else
      n = LibIDF.cr_reader_count(app)
      if @@page < 0
        if steps != 0
          @@post = (@@post &+ steps).unsafe_mod(n)
          @@post = @@post &+ n if @@post < 0
          scene = true
        end
        if a
          @@page = 0
          scene = true
        elsif b
          LibIDF.cr_app_reload(app)
        end
      else
        if steps != 0
          pg = @@page &+ steps
          pg = 0 if pg < 0
          pg = @@pages &- 1 if pg >= @@pages
          scene = pg != @@page
          @@page = pg
        end
        if a # next page; after the last, the next post's card
          scene = true
          if @@page &+ 1 < @@pages
            @@page = @@page &+ 1
          else
            @@page = -1
            @@post = @@post &+ 1 < n ? @@post &+ 1 : 0
          end
        elsif b
          @@page = -1
          scene = true
        end
      end
      @@pages = LibIDF.cr_reader_view(app, @@post, @@page) if scene
    end
    sig = LibIDF.cr_reader_sig(app, @@post, @@page)
    if scene || (sig != @@sig && now &- @@drawn >= 1500)
      was = @@st_shown
      draw(app)
      show(was != 1 && @@st_shown == 1) # the first post after "Loading": clean
    end
  end
end

module HackadayApp
  include App
  ORDER     = 200
  NAME      = "HACKADAY"
  COLOR     = 0xFFFFFF_u32
  OWNS_MENU = true

  # Jolly wrencher-ish: a skull over crossed wrenches.
  def self.icon(x : Int32, y : Int32) : Nil
    Gfx.tile(x, y)
    NetApps.wline(x &+ 30, y &+ 30, x &+ 130, y &+ 130, 14)
    NetApps.wline(x &+ 130, y &+ 30, x &+ 30, y &+ 130, 14)
    Gfx.disc(x &+ 30, y &+ 30, 14, false)
    Gfx.disc(x &+ 130, y &+ 30, 14, false)
    Gfx.disc(x &+ 30, y &+ 130, 14, false)
    Gfx.disc(x &+ 130, y &+ 130, 14, false)
    Gfx.disc(x &+ 80, y &+ 72, 38, true)
    Gfx.disc(x &+ 80, y &+ 72, 32, false)
    Gfx.box(x &+ 62, y &+ 92, 36, 22, false)
    Gfx.disc(x &+ 67, y &+ 70, 8, true)
    Gfx.disc(x &+ 93, y &+ 70, 8, true)
    Gfx.box(x &+ 70, y &+ 104, 4, 10, true)
    Gfx.box(x &+ 86, y &+ 104, 4, 10, true)
  end

  def self.enter : Nil
    Reader.enter(NetApps::HACKADAY)
  end

  def self.tick(now : Int32, inp : LibGames::Input) : Nil
    Reader.tick(NetApps::HACKADAY, now, inp)
  end

  def self.leave : Nil
    Reader.leave
  end
end

module NewsApp
  include App
  ORDER     = 201
  NAME      = "NEWS"
  COLOR     = 0xBB1919_u32
  OWNS_MENU = true

  # A folded newspaper.
  def self.icon(x : Int32, y : Int32) : Nil
    Gfx.tile(x, y)
    Gfx.box(x &+ 28, y &+ 34, 104, 92, false)
    Gfx.box(x &+ 38, y &+ 44, 84, 14, true)
    Gfx.box(x &+ 38, y &+ 66, 38, 30, true)
    k = 0
    while k < 4
      Gfx.box(x &+ 84, y &+ 66 &+ k &* 10, 38, 4, true)
      Gfx.box(x &+ 38, y &+ 104 &+ (k & 1) &* 10, 84, 4, true) if k < 2
      k = k &+ 1
    end
  end

  def self.enter : Nil
    Reader.enter(NetApps::NEWS)
  end

  def self.tick(now : Int32, inp : LibGames::Input) : Nil
    Reader.tick(NetApps::NEWS, now, inp)
  end

  def self.leave : Nil
    Reader.leave
  end
end
