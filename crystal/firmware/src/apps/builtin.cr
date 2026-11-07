# Registry entries for the built-in screens (drawn and run by main.cr;
# BUILTIN keeps their SCR_* numbers = ORDER = grid index).

module NametagApp
  include App
  ORDER   = 0
  BUILTIN = true
  NAME    = "NAMETAG"
  COLOR   = 0xFF0000_u32

  def self.icon(x : Int32, y : Int32) : Nil
    Gfx.tile(x, y)
    Gfx.box(x &+ 20, y &+ 36, 120, 88, false)
    Gfx.box(x &+ 20, y &+ 36, 120, 30, true)
    Gfx.frame(x &+ 20, y &+ 36, 120, 88, 4)
    Gfx.text_c(x &+ 80, y &+ 44, "HELLO", 2, false)
    Gfx.box(x &+ 40, y &+ 92, 80, 8, true)
  end
end

module PortraitApp
  include App
  ORDER   = 1
  BUILTIN = true
  NAME    = "PORTRAIT"
  COLOR   = 0xFF00A0_u32

  def self.icon(x : Int32, y : Int32) : Nil
    Gfx.tile(x, y)
    Gfx.disc(x &+ 80, y &+ 62, 28, false)
    Gfx.disc(x &+ 80, y &+ 124, 35, false) # shoulders
    Gfx.box(x &+ 45, y &+ 124, 71, 36, false)
  end
end

module SketchApp
  include App
  ORDER   = 2
  BUILTIN = true
  NAME    = "SKETCH"
  COLOR   = 0xFFAA00_u32

  def self.icon(x : Int32, y : Int32) : Nil
    Gfx.tile(x, y)
    Gfx.box(x &+ 22, y &+ 24, 116, 80, false)
    # a stair-step line on the screen
    Gfx.box(x &+ 34, y &+ 80, 30, 6, true)
    Gfx.box(x &+ 58, y &+ 56, 6, 30, true)
    Gfx.box(x &+ 58, y &+ 56, 34, 6, true)
    Gfx.box(x &+ 86, y &+ 40, 6, 22, true)
    Gfx.box(x &+ 86, y &+ 40, 36, 6, true)
    Gfx.disc(x &+ 36, y &+ 130, 12, false)
    Gfx.disc(x &+ 124, y &+ 130, 12, false)
  end
end

module LifeApp
  include App
  ORDER   = 3
  BUILTIN = true
  NAME    = "LIFE"
  COLOR   = 0x00FF00_u32

  def self.icon(x : Int32, y : Int32) : Nil
    Gfx.tile(x, y)
    # a glider
    Gfx.box(x &+ 68, y &+ 32, 28, 28, false)
    Gfx.box(x &+ 100, y &+ 64, 28, 28, false)
    Gfx.box(x &+ 36, y &+ 96, 28, 28, false)
    Gfx.box(x &+ 68, y &+ 96, 28, 28, false)
    Gfx.box(x &+ 100, y &+ 96, 28, 28, false)
  end
end

module SnakeApp
  include App
  ORDER   = 4
  BUILTIN = true
  NAME    = "SNAKE"
  COLOR   = 0x00BEFF_u32

  def self.icon(x : Int32, y : Int32) : Nil
    Gfx.tile(x, y)
    Gfx.box(x &+ 28, y &+ 40, 96, 18, false)
    Gfx.box(x &+ 106, y &+ 40, 18, 60, false)
    Gfx.box(x &+ 40, y &+ 82, 84, 18, false)
    Gfx.box(x &+ 40, y &+ 82, 18, 46, false)
    Gfx.disc(x &+ 120, y &+ 124, 9, false) # food
  end
end

module DiagApp
  include App
  ORDER   = 5
  BUILTIN = true
  NAME    = "DIAG"
  COLOR   = 0xC8C8C8_u32

  def self.icon(x : Int32, y : Int32) : Nil
    Gfx.tile(x, y)
    # a square wave
    Gfx.box(x &+ 20, y &+ 100, 30, 8, false)
    Gfx.box(x &+ 46, y &+ 50, 8, 58, false)
    Gfx.box(x &+ 46, y &+ 50, 34, 8, false)
    Gfx.box(x &+ 76, y &+ 50, 8, 58, false)
    Gfx.box(x &+ 76, y &+ 100, 34, 8, false)
    Gfx.box(x &+ 106, y &+ 50, 8, 58, false)
    Gfx.box(x &+ 106, y &+ 50, 34, 8, false)
  end
end

module LinkApp
  include App
  ORDER   = 6
  BUILTIN = true
  NAME    = "LINK"
  COLOR   = 0x0000FF_u32

  def self.icon(x : Int32, y : Int32) : Nil
    Gfx.tile(x, y)
    Gfx.box(x &+ 44, y &+ 74, 72, 12, false)
    Gfx.disc(x &+ 44, y &+ 80, 24, false)
    Gfx.disc(x &+ 116, y &+ 80, 24, false)
    Gfx.disc(x &+ 44, y &+ 80, 12, true)
    Gfx.disc(x &+ 116, y &+ 80, 12, true)
  end
end

module PongApp
  include App
  ORDER   = 7
  BUILTIN = true
  NAME    = "PONG"
  COLOR   = 0xFFFFFF_u32

  def self.icon(x : Int32, y : Int32) : Nil
    Gfx.tile(x, y)
    Gfx.box(x &+ 22, y &+ 40, 12, 52, false)
    Gfx.box(x &+ 126, y &+ 76, 12, 52, false)
    Gfx.box(x &+ 72, y &+ 64, 16, 16, false)
    Gfx.box(x &+ 78, y &+ 20, 4, 120, false)
  end
end
