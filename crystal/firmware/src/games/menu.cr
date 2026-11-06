# Mode selector: Menu + / Menu - cycle Nametag -> Sketch -> Life -> Snake.
# Each game is initialised lazily on first entry and keeps its state when
# you leave it; on every entry its knob reference is resynced.
#
# Firmware loop sketch:
#   Menu.init
#   loop: inp = Games.input(mv_l, mv_r, held, prev_held)
#         if Menu.tick(millis, inp)
#           if Menu.needs_background?             # Sketch: Etch frame
#             Sketch.prep_background(EPD.black, EPD.red)
#             PNG.draw(etch_png, ..., EPD.black, EPD.red, ...)
#           if Menu.render(EPD.black, EPD.red)   # false => Nametag
#             Menu.want_clean? ? fast refresh with cleaning flash
#             : Menu.dirty_box(...) ? partial B/W window of that box
#             : fast 1-pass B/W refresh
#   (Menu.dirty_rects(r, max) gives up to 4 smaller rects instead; 0 = full.)
#           else draw the nametag and do a full colour refresh

require "./common"
require "./life"
require "./snake"
require "./sketch"

module Menu
  NAMETAG = 0
  SKETCH  = 1
  LIFE    = 2
  SNAKE   = 3
  COUNT   = 4

  @@mode = NAMETAG
  @@inited = 0 # bit per mode
  @@failed = 0 # bit per mode whose init failed
  @@switched = true # the last tick() true was a mode switch (full refresh)

  def self.mode : Int32
    @@mode
  end

  # Nametag uses the slow full-colour refresh; the games use fast B/W.
  def self.full_color? : Bool
    @@mode == NAMETAG
  end

  # Sketch only: decode sketch_frame.png into the planes before render.
  def self.needs_background? : Bool
    @@mode == SKETCH && ok? && Sketch.needs_background?
  end

  # Sketch only: this refresh should use the cleaning flash. Call after render.
  def self.want_clean? : Bool
    @@mode == SKETCH && ok? && Sketch.want_clean?
  end

  # false if a game's allocation failed (that game then stays inert).
  def self.ok? : Bool
    (@@failed & 1.unsafe_shl(@@mode)) == 0
  end

  def self.init(mode : Int32 = NAMETAG) : Nil
    enter(mode)
  end

  def self.enter(mode : Int32) : Nil
    mode = 0 if mode < 0 || mode >= COUNT
    @@mode = mode
    first = (@@inited & 1.unsafe_shl(mode)) == 0
    @@inited = @@inited | 1.unsafe_shl(mode)
    ok = true
    if mode == SKETCH
      ok = Sketch.init if first
      Sketch.resync
    elsif mode == LIFE
      ok = Life.init if first
      Life.resync
    elsif mode == SNAKE
      ok = Snake.init if first
      Snake.resync
    end
    @@failed = @@failed | 1.unsafe_shl(mode) unless ok
  end

  # true = the panel needs a refresh (mode switch or game update).
  def self.tick(now : Int32, inp : LibGames::Input) : Bool
    @@switched = true
    if Games.pressed?(inp, Games::BTN_PLUS)
      enter(@@mode &+ 1 == COUNT ? 0 : @@mode &+ 1)
      return true
    end
    if Games.pressed?(inp, Games::BTN_MINUS)
      enter(@@mode == 0 ? COUNT &- 1 : @@mode &- 1)
      return true
    end
    return false unless ok?
    @@switched = false
    if @@mode == SKETCH
      Sketch.tick(now, inp)
    elsif @@mode == LIFE
      Life.tick(now, inp)
    elsif @@mode == SNAKE
      Snake.tick(now, inp)
    else
      false
    end
  end

  # Draws the active game; false = Nametag (caller draws it itself).
  def self.render(black : UInt8*, red : UInt8*) : Bool
    return false unless ok?
    if @@mode == SKETCH
      Sketch.render(black, red)
    elsif @@mode == LIFE
      Life.render(black, red)
    elsif @@mode == SNAKE
      Snake.render(black, red)
    else
      return false
    end
    true
  end

  # Partial window (inclusive pixels) for the refresh tick() just requested;
  # false = full refresh (mode switch, Nametag, restart/reseed/game over...).
  def self.dirty_box(x0 : Int32*, y0 : Int32*, x1 : Int32*, y1 : Int32*) : Bool
    return false if @@switched || !ok?
    if @@mode == SKETCH
      Sketch.dirty_box(x0, y0, x1, y1)
    elsif @@mode == LIFE
      Life.dirty_box(x0, y0, x1, y1)
    elsif @@mode == SNAKE
      Snake.dirty_box(x0, y0, x1, y1)
    else
      false
    end
  end

  # Up to `max` rects {x0, y0, x1, y1} into dst[4*i..]; 0 = full refresh.
  # Sketch always gives its single box.
  def self.dirty_rects(dst : Int32*, max : Int32) : Int32
    return 0 if @@switched || !ok? || max < 1
    if @@mode == SKETCH
      Sketch.dirty_box(dst, dst + 1_i64, dst + 2_i64, dst + 3_i64) ? 1 : 0
    elsif @@mode == LIFE
      Life.dirty_rects(dst, max)
    elsif @@mode == SNAKE
      Snake.dirty_rects(dst, max)
    else
      0
    end
  end
end
