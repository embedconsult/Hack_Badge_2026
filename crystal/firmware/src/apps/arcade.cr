# Arcade games as registry apps (src/apps/app.cr): BLOCKS, ALIENS, ROCKS.
# Game logic lives in src/games/{blocks,aliens,rocks}.cr (host specs in
# test/arcade_spec.cr); this file only runs them on the panel.
#
# Our own reimplementation of the arcade apps in yigitabi5444's
# supercon26-badge-os ("falling blocks, a wave of descending aliens, and a
# field of drifting rocks to shoot"); thanks to its author.
#
# Frames: each game advances on a fixed ~0.65 s step (Arcade::STEP_MS), so
# every frame is one whole-panel differential update (Apps.show, ~0.65 s;
# ~1.5 fps). Every CLEAN_EVERY frames, a full clean refresh (Apps.show_clean,
# ~3.5 s) clears the ghosts that diff frames leave behind (Pong needed 12 too).
# Menu +/- still switch apps (the games don't own them).

require "../games/blocks"
require "../games/aliens"
require "../games/rocks"

module ArcadeRun
  CLEAN_EVERY = 20 # was 12; each clean also reopens the diff session (up to ~7 s in all)
  BLOCKS = 0
  ALIENS = 1
  ROCKS  = 2

  @@inited = 0 # bit per game
  @@failed = 0
  @@frames = 0

  def self.ok?(g : Int32) : Bool
    (@@failed & 1.unsafe_shl(g)) == 0
  end

  def self.draw(g : Int32) : Nil
    if g == BLOCKS
      Blocks.render(EPD.black, EPD.red)
      TopBar.draw("BLOCKS", "< PREV", "NEXT >", "A: TURN", "B: DROP")
    elsif g == ALIENS
      Aliens.render(EPD.black, EPD.red)
      TopBar.draw("ALIENS", "< PREV", "NEXT >", "A: FIRE", "B: FIRE")
    else
      Rocks.render(EPD.black, EPD.red)
      TopBar.draw("ROCKS", "< PREV", "NEXT >", "A: FIRE", "B: THRUST")
    end
  end

  # Draw the game, then a clean refresh (first frame).
  def self.enter(g : Int32) : Nil
    if (@@inited & 1.unsafe_shl(g)) == 0
      @@inited = @@inited | 1.unsafe_shl(g)
      Games.seed(millis.to_u32! | 1_u32)
      ok = g == BLOCKS ? Blocks.init : (g == ALIENS ? Aliens.init : Rocks.init)
      @@failed = @@failed | 1.unsafe_shl(g) unless ok
    end
    if ok?(g)
      if g == BLOCKS
        Blocks.resync
      elsif g == ALIENS
        Aliens.resync
      else
        Rocks.resync
      end
      draw(g)
    else
      EPD.fill(EPD::WHITE)
      TopBar.draw("ARCADE", "< PREV", "NEXT >", "", "")
      Gfx.text_c(EPD::WIDTH.unsafe_div(2), 300, "OUT OF MEMORY", 4)
    end
    @@frames = 0
    Apps.show_clean
  end

  def self.tick(g : Int32, now : Int32, inp : LibGames::Input) : Nil
    return unless ok?(g)
    changed = g == BLOCKS ? Blocks.tick(now, inp) : (g == ALIENS ? Aliens.tick(now, inp) : Rocks.tick(now, inp))
    return unless changed
    draw(g)
    @@frames = @@frames &+ 1
    if @@frames >= CLEAN_EVERY
      @@frames = 0
      Apps.show_clean
    else
      Apps.show
    end
  end
end

module BlocksApp
  include App
  ORDER = 300
  NAME  = "BLOCKS"
  COLOR = 0xFF5000_u32

  def self.icon(x : Int32, y : Int32) : Nil
    Gfx.tile(x, y)
    # a T piece falling onto a stack with a gap
    Gfx.box(x &+ 56, y &+ 24, 22, 22, false)
    Gfx.box(x &+ 80, y &+ 24, 22, 22, false)
    Gfx.box(x &+ 104, y &+ 24, 22, 22, false)
    Gfx.box(x &+ 80, y &+ 48, 22, 22, false)
    Gfx.box(x &+ 32, y &+ 112, 22, 22, false)
    Gfx.box(x &+ 56, y &+ 112, 22, 22, false)
    Gfx.box(x &+ 104, y &+ 112, 22, 22, false)
    Gfx.box(x &+ 32, y &+ 88, 22, 22, false)
  end

  def self.enter : Nil
    ArcadeRun.enter(ArcadeRun::BLOCKS)
  end

  def self.tick(now : Int32, inp : LibGames::Input) : Nil
    ArcadeRun.tick(ArcadeRun::BLOCKS, now, inp)
  end
end

module AliensApp
  include App
  ORDER = 301
  NAME  = "ALIENS"
  COLOR = 0x78FF00_u32

  def self.icon(x : Int32, y : Int32) : Nil
    Gfx.tile(x, y)
    # the middle-row alien, 11 x 8 at 10 px, in white
    r = 0
    while r < 8
      bits = Aliens.sprite_row(1, r)
      c = 0
      while c < 11
        Gfx.box(x &+ 25 &+ c &* 10, y &+ 30 &+ r &* 10, 10, 10, false) if (bits.unsafe_shr(10 &- c) & 1) != 0
        c = c &+ 1
      end
      r = r &+ 1
    end
    Gfx.box(x &+ 56, y &+ 128, 48, 14, false) # cannon
    Gfx.box(x &+ 74, y &+ 118, 12, 10, false)
  end

  def self.enter : Nil
    ArcadeRun.enter(ArcadeRun::ALIENS)
  end

  def self.tick(now : Int32, inp : LibGames::Input) : Nil
    ArcadeRun.tick(ArcadeRun::ALIENS, now, inp)
  end
end

module RocksApp
  include App
  ORDER = 302
  NAME  = "ROCKS"
  COLOR = 0x8C00FF_u32

  def self.icon(x : Int32, y : Int32) : Nil
    Gfx.tile(x, y)
    Gfx.disc(x &+ 104, y &+ 56, 30, false)
    Gfx.disc(x &+ 104, y &+ 56, 22, true)
    Gfx.disc(x &+ 46, y &+ 118, 14, false)
    Gfx.disc(x &+ 46, y &+ 118, 8, true)
    # ship: a white wedge pointing up-right
    i = 0
    while i < 30
      Gfx.box(x &+ 40 &+ i, y &+ 70 &- i.unsafe_div(2), 6, 20 &- (i &* 2).unsafe_div(3), false)
      i = i &+ 2
    end
  end

  def self.enter : Nil
    ArcadeRun.enter(ArcadeRun::ROCKS)
  end

  def self.tick(now : Int32, inp : LibGames::Input) : Nil
    ArcadeRun.tick(ArcadeRun::ROCKS, now, inp)
  end
end
