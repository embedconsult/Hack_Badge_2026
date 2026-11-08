# Slides: a talk, one slide per screen, from the deck embedded at build time
# (main/slides.bin, EMBED_FILES). The deck is data: firmware/slides/
# convert.cr packs firmware/slides/deck.json (or deck.md) into it, layout
# included; src/games/slide_deck.cr draws it. Swapping the talk is a data
# change: replace the deck source and rerun the converter.
#
# Right knob, Menu - / + or B / A: previous / next slide (clamped at both
# ends; presses made during a refresh are not lost). Every slide is a full clean
# refresh (~3.5 s); a slide with red uses the slow colour refresh (~30 s,
# a Menu press aborts it). Menu + and Menu - together: home. The slide
# shown is kept when you leave and come back.

lib LibIDF
  fun cr_slides_bin : UInt8*
  fun cr_slides_bin_size : Int32
end

require "../games/slide_deck"

module SlidesApp
  include App
  ORDER     = 120
  NAME      = "SLIDES"
  COLOR     = 0xFFFFFF_u32
  OWNS_MENU = true

  @@cur = 0

  # A slide on a stand: title bar and three bullet lines.
  def self.icon(x : Int32, y : Int32) : Nil
    Gfx.tile(x, y)
    Gfx.box(x &+ 22, y &+ 28, 116, 84, false)
    Gfx.box(x &+ 32, y &+ 38, 96, 12, true)
    k = 0
    while k < 3
      Gfx.box(x &+ 32, y &+ 62 &+ k &* 16, 8, 8, true)
      Gfx.box(x &+ 46, y &+ 62 &+ k &* 16, 70 &- k &* 14, 8, true)
      k = k &+ 1
    end
    Gfx.box(x &+ 76, y &+ 112, 8, 24, false)
    Gfx.box(x &+ 56, y &+ 132, 48, 6, false)
  end

  def self.count : Int32
    SlideDeck.count(LibIDF.cr_slides_bin, LibIDF.cr_slides_bin_size)
  end

  def self.draw : Nil
    d = LibIDF.cr_slides_bin
    n = LibIDF.cr_slides_bin_size
    if count == 0
      EPD.fill(EPD::WHITE)
      TopBar.draw(NAME, "", "", "", "")
      Gfx.text_c(EPD::WIDTH.unsafe_div(2), 300, "NO SLIDE DECK IN THIS BUILD", 3)
      Apps.show_clean(true)
      return
    end
    @@cur = SlideDeck.step(@@cur, 0, count)
    red = SlideDeck.render(d, n, @@cur, EPD.black, EPD.red, LibIDF.cr_font5x7)
    log2("slides: slide / red", @@cur &+ 1, red ? 1 : 0)
    if red
      colour_refresh
    else
      RedRes.replaced
      Apps.show_clean(true)
    end
  end

  def self.enter : Nil
    NetApps.knob_reset
    draw
  end

  def self.tick(now : Int32, inp : LibGames::Input) : Nil
    steps = NetApps.knob_steps(inp)
    steps = steps &+ 1 if Games.pressed?(inp, Games::BTN_PLUS) || Games.pressed?(inp, Games::BTN_A)
    steps = steps &- 1 if Games.pressed?(inp, Games::BTN_MINUS) || Games.pressed?(inp, Games::BTN_B)
    return if steps == 0
    nxt = SlideDeck.step(@@cur, steps, count)
    return if nxt == @@cur
    @@cur = nxt
    draw
  end
end
