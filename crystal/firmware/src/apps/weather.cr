# Weather: now and the next five days from Open-Meteo for the saved place
# (shell: `weather <lat> <lon> [c|f] [name]`, `weather place <city>`,
# `weather units <c|f>`; default Pasadena). Updates on entry when older than
# 30 min, every 30 min while on screen, and on User A. B: Celsius/Fahrenheit.
# Idea: yigitabi5444's badge os Weather app.

module WeatherApp
  include App
  ORDER = 202
  NAME  = "WEATHER"
  COLOR = 0x00A0FF_u32

  @@sig = 0_u32
  @@drawn = 0

  # Sun behind a cloud.
  def self.icon(x : Int32, y : Int32) : Nil
    Gfx.tile(x, y)
    Gfx.disc(x &+ 98, y &+ 58, 30, false)
    k = 0
    while k < 8
      Gfx.box(x &+ 96 &+ (k == 0 ? 40 : (k == 4 ? -40 : 0)), y &+ 56 &+ (k == 2 ? 40 : (k == 6 ? -40 : 0)), 6, 6, false) if (k & 1) == 0
      k = k &+ 1
    end
    Gfx.disc(x &+ 52, y &+ 98, 24, true)
    Gfx.disc(x &+ 82, y &+ 84, 32, true)
    Gfx.disc(x &+ 112, y &+ 102, 22, true)
    Gfx.disc(x &+ 52, y &+ 98, 20, false)
    Gfx.disc(x &+ 82, y &+ 84, 28, false)
    Gfx.disc(x &+ 112, y &+ 102, 18, false)
    Gfx.box(x &+ 40, y &+ 100, 84, 20, false)
  end

  def self.draw : Nil
    EPD.fill(EPD::WHITE)
    LibIDF.cr_weather_draw(EPD.black)
    TopBar.draw("WEATHER", "", "", "A: UPDATE", "B: C/F")
    @@sig = LibIDF.cr_weather_sig
    @@drawn = millis
  end

  def self.enter : Nil
    LibIDF.cr_app_enter(NetApps::WEATHER)
    draw
    Apps.show_clean
  end

  def self.leave : Nil
    LibIDF.cr_app_leave
  end

  def self.tick(now : Int32, inp : LibGames::Input) : Nil
    LibIDF.cr_app_tick
    LibIDF.cr_app_reload(NetApps::WEATHER) if Games.pressed?(inp, Games::BTN_A)
    LibIDF.cr_weather_toggle_units if Games.pressed?(inp, Games::BTN_B)
    sig = LibIDF.cr_weather_sig
    if sig != @@sig && now &- @@drawn >= 1000
      draw
      Apps.show
    end
  end
end
