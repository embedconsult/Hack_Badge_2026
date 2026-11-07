# Shared bindings and helpers for the network content apps: Hackaday and
# News (reader.cr), Weather (weather.cr) and Radar (radar.cr). Downloads,
# parsing and screen drawing are C (main/apps_net.c, feed.c, weather.c,
# radar.c, apps_gfx.c; host tests in test/apps/); these modules handle the
# buttons, what is on screen and when the panel refreshes.
# After yigitabi5444's badge os apps of the same names (our own code).

lib LibIDF
  fun cr_app_enter(app : Int32) : Void
  fun cr_app_leave : Void
  fun cr_app_tick : Void
  fun cr_app_reload(app : Int32) : Void
  fun cr_reader_state(app : Int32) : Int32 # 0 loading, 1 ready, 2 failed
  fun cr_reader_count(app : Int32) : Int32
  fun cr_reader_view(app : Int32, post : Int32, page : Int32) : Int32 # page count
  fun cr_reader_sig(app : Int32, post : Int32, page : Int32) : UInt32
  fun cr_reader_draw(app : Int32, plane : UInt8*, post : Int32, page : Int32) : Void
  fun cr_weather_draw(plane : UInt8*) : Void
  fun cr_weather_sig : UInt32
  fun cr_weather_toggle_units : Void
  fun cr_weather_cmd(line : UInt8*, n : Int32) : Void
  fun cr_radar_update : UInt32
  fun cr_radar_draw(plane : UInt8*) : Void
end

module NetApps
  HACKADAY = 1 # main/apps_net.c APP_*
  NEWS     = 2
  WEATHER  = 3
  RADAR    = 4

  KNOB_STEP = 350 # right-knob travel (of 4096) per step

  @@kref = -1

  # Right knob as detents: -n / +n steps since the last call.
  def self.knob_steps(inp : LibGames::Input) : Int32
    k = Games.knob_right(inp)
    if @@kref < 0
      @@kref = k
      return 0
    end
    d = k &- @@kref
    if d >= KNOB_STEP || d <= 0 &- KNOB_STEP
      n = d.unsafe_div(KNOB_STEP)
      @@kref = @@kref &+ n &* KNOB_STEP
      return n
    end
    0
  end

  def self.knob_reset : Nil
    @@kref = -1
  end

  # Icon helpers: a white line t px thick (for icons on the black tile).
  def self.wline(x0 : Int32, y0 : Int32, x1 : Int32, y1 : Int32, t : Int32) : Nil
    dx = x1 &- x0
    dy = y1 &- y0
    ax = dx < 0 ? 0 &- dx : dx
    ay = dy < 0 ? 0 &- dy : dy
    n = ax > ay ? ax : ay
    n = 1 if n == 0
    i = 0
    while i <= n
      Gfx.box(x0 &+ (dx &* i).unsafe_div(n) &- t.unsafe_div(2), y0 &+ (dy &* i).unsafe_div(n) &- t.unsafe_div(2), t, t, false)
      i = i &+ 1
    end
  end
end
