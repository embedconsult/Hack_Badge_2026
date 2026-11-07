# Network mode screens and hooks (C side: main/net.c; protocol:
# crystal/net/PROTOCOL.md).
#
# - LINK screen: network on/off (User A), IP, channel and the badges heard
#   (BeagleBadges, Crystal badges, badge os badges over ESP-NOW).
# - PONG screen: badge os's two-badge Pong. User A pairs (press on both
#   badges within half a second), or a BeagleBadge's Pong app pairs with a
#   `pong` command. In a game: left knob, or A up / B down. The game runs in
#   net.c; this file only draws the latest state, as fast as the panel goes.
# - Nametag text comes from net.c (`text first|last`, saved in NVS).
# - Remote command lines are executed by the shell task (Shell.run_remote).

lib LibIDF
  fun cr_net_on : Bool
  fun cr_net_set(on : Bool) : Void
  fun cr_net_set_ap(on : Bool) : Void
  fun cr_net_take_line(buf : UInt8*, max : Int32) : Int32
  fun cr_net_input(l : Int32, r : Int32, b : UInt32) : Void
  fun cr_net_screen(s : Int32) : Void
  fun cr_net_version : UInt32
  fun cr_net_status_text(buf : UInt8*, max : Int32) : Int32
  fun cr_net_print_status : Void
  fun cr_pong_get(v : Int16*) : Int32
  fun cr_name_len(i : Int32) : Int32
  fun cr_name_ptr(i : Int32) : UInt8*
  fun cr_name_set(s : UInt8*, n : Int32) : Void
end

module Shared
  REQ_REDRAW = 8_u32 # re-enter the current screen (new nametag text)
end

# Nametag name from net.c, scaled down to fit when long.
def draw_name_net : Nil
  n0 = LibIDF.cr_name_len(0)
  n1 = LibIDF.cr_name_len(1)
  nm = n0 > n1 ? n0 : n1
  scale = NAME_SCALE
  if nm > 0
    s = 920.unsafe_div(nm &* 6 &- 1)
    scale = s if s < scale
  end
  scale = 2 if scale < 2
  line_h = 7 &* scale
  gap = 2 &* scale
  lines = n1 > 0 ? 2 : 1
  hh = lines == 2 ? 2 &* line_h &+ gap : line_h
  top = BAND_TOP &+ (BAND_BOTTOM &- BAND_TOP &- hh).unsafe_div(2)
  w0 = n0 == 0 ? 0 : (n0 &* 6 &- 1) &* scale
  draw_bytes((EPD::WIDTH &- w0).unsafe_div(2), top, LibIDF.cr_name_ptr(0), n0, EPD::BLACK, scale)
  if lines == 2
    w1 = (n1 &* 6 &- 1) &* scale
    draw_bytes((EPD::WIDTH &- w1).unsafe_div(2), top &+ line_h &+ gap, LibIDF.cr_name_ptr(1), n1, EPD::BLACK, scale)
  end
end

module LinkUI
  TXT_MAX  = 900
  TOP      =  48 # badge os court starts 48 px down (its top bar)
  CH       = EPD::HEIGHT - TOP
  BALL     =  24
  PADW     =  16
  PADH     = 120
  PADX     =  24
  CLEAN_AT =  12 # frames between full-drive refreshes (diff frames leave ball ghosts)

  @@txt = Pointer(UInt8).null
  @@pv = Pointer(Int16).null
  @@shown = Pointer(Int16).null
  @@ver = 0_u32
  @@last = 0
  @@frames = 0

  def self.alloc : Bool
    @@txt = LibIDF.heap_caps_malloc(TXT_MAX.to_u32!, 0x804_u32).as(UInt8*) if @@txt.null?
    @@pv = LibIDF.heap_caps_malloc(32_u32, 0x804_u32).as(Int16*) if @@pv.null?
    @@shown = LibIDF.heap_caps_malloc(32_u32, 0x804_u32).as(Int16*) if @@shown.null?
    !@@txt.null? && !@@pv.null? && !@@shown.null?
  end

  # Text lines (separated by '\n') from x, y down, `step` px apart.
  def self.draw_lines(buf : UInt8*, n : Int32, x : Int32, y : Int32, scale : Int32, step : Int32) : Nil
    s = 0
    i = 0
    while i <= n
      if i == n || buf[i] == 0x0A_u8
        draw_bytes(x, y, buf + s.to_i64!, i &- s, EPD::BLACK, scale) if i > s
        y = y &+ step
        s = i &+ 1
        return if y > EPD::HEIGHT &- 8 &* scale
      end
      i = i &+ 1
    end
  end

  def self.draw_link : Nil
    EPD.fill(EPD::WHITE)
    draw_text(16, 12, "LINK", EPD::BLACK, 6)
    draw_text(200, 24, "A: NET ON/OFF   BADGE LINK PROTOCOL v1, UDP 4626 + ESP-NOW", EPD::BLACK, 2)
    EPD.fill_rect(0, 64, EPD::WIDTH, 4, EPD::BLACK)
    n = LibIDF.cr_net_status_text(@@txt, TXT_MAX)
    draw_lines(@@txt, n, 16, 84, 3, 34)
  end

  def self.box_outline(x : Int32, y : Int32, w : Int32, h : Int32, t : Int32) : Nil
    EPD.fill_rect(x, y, w, t, EPD::BLACK)
    EPD.fill_rect(x, y &+ h &- t, w, t, EPD::BLACK)
    EPD.fill_rect(x, y, t, h, EPD::BLACK)
    EPD.fill_rect(x &+ w &- t, y, t, h, EPD::BLACK)
  end

  # badge os's court: your paddle on the left (solid), the other hollow.
  def self.draw_pong : Nil
    v = @@pv
    st = v[0].to_i32!
    host = v[1] != 0_i16
    mirror = !host
    EPD.fill(EPD::WHITE)
    if st == 2
      draw_text(16, 14, "PONG   KNOB L OR A/B: PADDLE   FIRST TO 4", EPD::BLACK, 3)
    elsif st == 1
      draw_text(16, 14, "PONG   PAIRING...", EPD::BLACK, 3)
    elsif st == 3
      draw_text(16, 14, "PONG   NO PEER: PRESS A AGAIN", EPD::BLACK, 3)
    else
      draw_text(16, 14, LibIDF.cr_net_on ? "PONG   A: PAIR (BOTH BADGES AT ONCE)" : "PONG   NET IS OFF: LINK SCREEN, A", EPD::BLACK, 3)
    end
    EPD.fill_rect(0, TOP &- 4, EPD::WIDTH, 4, EPD::BLACK)
    y = TOP
    while y < EPD::HEIGHT
      EPD.fill_rect(EPD::WIDTH.unsafe_div(2) &- 4, y &+ 12, 8, 24, EPD::BLACK)
      y = y &+ 48
    end
    live = st == 2
    EPD.fill_rect(0, TOP, 8, CH, EPD::BLACK) if live
    p = 0
    while p < 2
      left = (p == 0) != mirror
      x = left ? PADX : EPD::WIDTH &- PADX &- PADW
      py = TOP &+ v[4 &+ p].to_i32!
      if left
        EPD.fill_rect(x, py, PADW, PADH, EPD::BLACK)
      else
        box_outline(x, py, PADW, PADH, 4)
      end
      k = 0
      sc = v[6 &+ p].to_i32!
      while k < sc && k < 4
        bx = left ? EPD::WIDTH.unsafe_div(2) &- 60 &- 48 &* k : EPD::WIDTH.unsafe_div(2) &+ 36 &+ 48 &* k
        EPD.fill_rect(bx, TOP &+ 12, 24, 24, EPD::BLACK)
        k = k &+ 1
      end
      p = p &+ 1
    end
    return unless live
    bx = v[2].to_i32!
    bx = EPD::WIDTH &- bx &- BALL if mirror
    EPD.fill_rect(bx, TOP &+ v[3].to_i32!, BALL, BALL, EPD::BLACK)
  end

  def self.enter(scr : Int32) : Nil
    return unless alloc
    @@frames = 0
    if scr == SCR_LINK
      @@ver = LibIDF.cr_net_version
      draw_link
    else
      LibIDF.cr_pong_get(@@pv)
      copy_shown
      draw_pong
    end
    fast_bw(3, EPD::LUT_BASE)
    @@last = millis
  end

  def self.copy_shown : Nil
    i = 0
    while i < 10
      @@shown[i] = @@pv[i]
      i = i &+ 1
    end
  end

  def self.changed? : Bool
    i = 0
    while i < 8 # not the frame counter
      return true if @@shown[i] != @@pv[i]
      i = i &+ 1
    end
    false
  end

  def self.frame : Nil
    @@frames = @@frames &+ 1
    if @@frames >= CLEAN_AT
      @@frames = 0
      fast_bw(3, EPD::LUT_BASE)
    else
      EPD.fast_pulls = GAME_PULLS
      EPD.refresh_diff
    end
  end

  # Main loop, every pass on LINK / PONG.
  def self.tick(scr : Int32, now : Int32, inp : LibGames::Input) : Nil
    return unless alloc
    if scr == SCR_LINK
      LibIDF.cr_net_set(!LibIDF.cr_net_on) if Games.pressed?(inp, Games::BTN_A)
      v = LibIDF.cr_net_version
      if v != @@ver && now &- @@last >= 3000
        @@ver = v
        Shared.rendering = true
        draw_link
        frame
        Shared.rendering = false
        @@last = millis
      end
    else
      LibIDF.cr_pong_get(@@pv)
      if changed?
        copy_shown
        Shared.rendering = true
        draw_pong
        frame
        Shared.rendering = false
      end
    end
  end
end
