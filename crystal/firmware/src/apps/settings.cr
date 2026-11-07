# Settings: the badge opens a Wi-Fi access point "Badge-XXXX" (WPA2, a new
# random password each time, shown on screen and as a join QR code) with a
# settings page at http://192.168.4.1/: nametag text (two lines), the Wi-Fi
# the badge joins (OTA, network mode) and network mode on/off, saved to NVS
# (main/settings.c). Network mode pauses while Settings is open; the AP goes
# down when you leave. After badge os's Settings app (yigitabi5444).

lib LibIDF
  fun cr_settings_start : Int32
  fun cr_settings_stop : Void
  fun cr_settings_ssid : UInt8*
  fun cr_settings_pass : UInt8*
  fun cr_settings_saves : UInt32
  fun cr_settings_msg : UInt8*
  fun cr_settings_clients : Int32
  fun cr_settings_qr(which : Int32, out : UInt8*) : Int32
end

def cstr_len(p : UInt8*, max : Int32 = 80) : Int32
  n = 0
  while n < max && p[n] != 0_u8
    n = n &+ 1
  end
  n
end

module SettingsApp
  include App
  ORDER = 100
  NAME  = "SETTINGS"
  COLOR = 0xFF4000_u32

  QR_X  = 32
  QR_Y  = 96
  TX    = 400 # text column
  ST_Y  = 520 # status lines

  @@qr = Pointer(UInt8).null
  @@err = 0
  @@saves = 0_u32
  @@clients = -1
  @@last = 0
  @@up = false

  def self.icon(x : Int32, y : Int32) : Nil
    Gfx.tile(x, y)
    cx = x &+ 80
    cy = y &+ 80
    Gfx.disc(cx, cy, 52, false)
    # eight teeth
    Gfx.box(cx &- 12, cy &- 66, 24, 132, false)
    Gfx.box(cx &- 66, cy &- 12, 132, 24, false)
    k = 0
    while k < 30
      Gfx.box(cx &+ 30 &+ k.unsafe_div(2) &- 8, cy &- 30 &- k.unsafe_div(2) &- 8, 16, 16, false)
      Gfx.box(cx &- 30 &- k.unsafe_div(2) &- 8, cy &- 30 &- k.unsafe_div(2) &- 8, 16, 16, false)
      Gfx.box(cx &+ 30 &+ k.unsafe_div(2) &- 8, cy &+ 30 &+ k.unsafe_div(2) &- 8, 16, 16, false)
      Gfx.box(cx &- 30 &- k.unsafe_div(2) &- 8, cy &+ 30 &+ k.unsafe_div(2) &- 8, 16, 16, false)
      k = k &+ 2
    end
    Gfx.disc(cx, cy, 22, true)
  end

  def self.draw_qr(which : Int32, x : Int32, y : Int32, scale : Int32) : Nil
    n = LibIDF.cr_settings_qr(which, @@qr)
    r = 0
    while r < n
      c = 0
      while c < n
        Gfx.box(x &+ c &* scale, y &+ r &* scale, scale, scale, true) if @@qr[r &* n &+ c] != 0_u8
        c = c &+ 1
      end
      r = r &+ 1
    end
  end

  def self.draw_status : Nil
    Gfx.box(TX, ST_Y, EPD::WIDTH &- TX, EPD::HEIGHT &- ST_Y, false)
    buf = Shared.label_buf
    x = Gfx.text(TX, ST_Y, "PHONES JOINED: ", 3)
    n = put_decimal(buf, @@clients < 0 ? 0 : @@clients)
    Gfx.bytes(x, ST_Y, buf, n, 3)
    m = LibIDF.cr_settings_msg
    Gfx.bytes(TX, ST_Y &+ 40, m, cstr_len(m, 46), 2)
    Gfx.text(TX, ST_Y &+ 80, "LEAVING SETTINGS TURNS THE HOTSPOT OFF", 2)
  end

  def self.draw : Nil
    EPD.fill(EPD::WHITE)
    TopBar.draw(NAME, "< APP", "APP >", "", "")
    if @@err != 0
      Gfx.text(40, 120, "COULD NOT START THE HOTSPOT", 4)
      Gfx.text(40, 180, @@err == 1 ? "THE RADIO IS BUSY (ONLINE UPDATE?)" : "HTTP SERVER FAILED", 3)
      Gfx.text(40, 230, "LEAVE AND OPEN SETTINGS AGAIN", 3)
      return
    end
    draw_qr(0, QR_X, QR_Y, 10)
    Gfx.text_c(QR_X &+ 145, QR_Y &+ 300, "SCAN TO JOIN", 3)
    Gfx.text(TX, 80, "1. JOIN THIS WI-FI", 3)
    s = LibIDF.cr_settings_ssid
    Gfx.bytes(TX &+ 30, 116, s, cstr_len(s, 15), 5)
    Gfx.text(TX, 180, "PASSWORD", 3)
    pw = LibIDF.cr_settings_pass
    Gfx.bytes(TX &+ 30, 212, pw, cstr_len(pw, 11), 5)
    Gfx.text(TX, 280, "2. OPEN", 3)
    Gfx.text(TX &+ 30, 316, "192.168.4.1", 5)
    Gfx.text(TX, 380, "NAMETAG, WI-FI, NETWORK MODE", 2)
    draw_qr(1, TX &+ 330, 400, 4)
    draw_status
  end

  def self.enter : Nil
    @@qr = LibIDF.heap_caps_malloc(37_u32 * 37_u32, 0x804_u32).as(UInt8*) if @@qr.null?
    EPD.fill(EPD::WHITE)
    TopBar.draw(NAME, "< APP", "APP >", "", "")
    Shared.rendering = true
    @@err = LibIDF.cr_settings_start
    @@up = @@err == 0
    log("settings: start (0 = ok)", @@err)
    @@saves = LibIDF.cr_settings_saves
    @@clients = LibIDF.cr_settings_clients
    @@last = millis
    draw
    Apps.show_clean
  end

  def self.tick(now : Int32, inp : LibGames::Input) : Nil
    return unless @@up
    return if now &- @@last < 1000
    @@last = now
    c = LibIDF.cr_settings_clients
    s = LibIDF.cr_settings_saves
    return if c == @@clients && s == @@saves
    @@clients = c
    @@saves = s
    draw_status
    Apps.show
  end

  def self.leave : Nil
    LibIDF.cr_settings_stop if @@up
    @@up = false
  end
end
