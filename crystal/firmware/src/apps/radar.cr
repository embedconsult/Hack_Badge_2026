# Radar: badges heard over the badge link (src/net.cr, main/net.c: UDP
# announces + ESP-NOW), nearest first, with a distance estimated from RSSI
# (smoothed); with 3+ badges (this one included) also a map fitted to every
# pairwise distance the badges share in their announces' heard lists
# (crystal/net/PROTOCOL.md, "Radar"). User A: clean refresh (or network on);
# B: network off. Idea and map approach: yigitabi5444's badge os Radar.

module RadarApp
  include App
  ORDER = 203
  NAME  = "RADAR"
  COLOR = 0x00FF60_u32

  UPDATE_MS   = 1000 # model update
  MIN_SHOW_MS = 3000 # panel updates at most this often
  CLEAN_EVERY = 15

  @@shown = 0_u32
  @@sig = 0_u32
  @@last = 0
  @@drawn = 0
  @@diffs = 0

  # Rings and a blip.
  def self.icon(x : Int32, y : Int32) : Nil
    Gfx.tile(x, y)
    r = 64
    while r > 0
      Gfx.disc(x &+ 80, y &+ 80, r, false)
      Gfx.disc(x &+ 80, y &+ 80, r &- 6, true)
      r = r &- 22
    end
    NetApps.wline(x &+ 80, y &+ 80, x &+ 124, y &+ 36, 6)
    Gfx.disc(x &+ 108, y &+ 96, 9, false)
    Gfx.disc(x &+ 56, y &+ 58, 7, false)
  end

  def self.draw : Nil
    EPD.fill(EPD::WHITE)
    LibIDF.cr_radar_draw(EPD.black)
    TopBar.draw("RADAR", "", "", LibIDF.cr_net_on ? "A: CLEAN" : "A: NET ON", LibIDF.cr_net_on ? "B: NET OFF" : "")
    @@shown = @@sig
    @@drawn = millis
  end

  def self.enter : Nil
    LibIDF.cr_app_enter(NetApps::RADAR)
    @@sig = LibIDF.cr_radar_update
    @@last = millis
    draw
    @@diffs = 0
    Apps.show_clean
  end

  def self.leave : Nil
    LibIDF.cr_app_leave
  end

  def self.tick(now : Int32, inp : LibGames::Input) : Nil
    if Games.pressed?(inp, Games::BTN_A)
      if LibIDF.cr_net_on
        @@sig = LibIDF.cr_radar_update
        draw
        @@diffs = 0
        Apps.show_clean
        return
      end
      LibIDF.cr_net_set(true)
    end
    LibIDF.cr_net_set(false) if Games.pressed?(inp, Games::BTN_B) && LibIDF.cr_net_on
    if now &- @@last >= UPDATE_MS || inp.pressed != 0_u32
      @@last = now
      @@sig = LibIDF.cr_radar_update
    end
    if @@sig != @@shown && (now &- @@drawn >= MIN_SHOW_MS || inp.pressed != 0_u32)
      draw
      @@diffs = @@diffs &+ 1
      if @@diffs >= CLEAN_EVERY
        @@diffs = 0
        Apps.show_clean
      else
        Apps.show
      end
    end
  end
end
