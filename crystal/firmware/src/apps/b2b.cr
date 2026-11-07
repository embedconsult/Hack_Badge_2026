# USB FLASH: badge-to-badge update over a USB-C cable (C side: main/b2b.c).
# This badge becomes a USB host and copies its own bootloader, partition
# table and running app (-> ota_0) onto the connected badge through that
# badge's ROM loader, then resets it. Idea after yigitabi5444's badge os
# ("Flash another badge"); our own implementation.
#
# Both badges must run on battery: the USB-C port is sink-only (5.1k CC
# pull-downs, no VBUS output), so the host cannot power the target.
# Starting takes the USB PHY from the console until reboot, so leaving
# this app after a start restarts the badge. Hence A asks first (confirm
# screen: "console will disconnect; reboot to restore"); a second A within
# CONFIRM_MS starts, B or the timeout cancels. Shell: `usbflash` prints the
# state.

lib LibIDF
  fun cr_b2b_start : Int32
  fun cr_b2b_stop : Void
  fun cr_b2b_state : Int32
  fun cr_b2b_pct : Int32
  fun cr_b2b_host : Bool
  fun cr_b2b_msg : UInt8*
  fun cr_b2b_restart : Void
end

module B2bApp
  include App
  ORDER = 390
  NAME  = "USBFLASH"
  COLOR = 0xFFFFFF_u32

  ST_IDLE   = 0
  ST_WAIT   = 1
  ST_SYNC   = 2
  ST_COPY   = 3
  ST_VERIFY = 4
  ST_DONE   = 5
  ST_FAIL   = 6

  @@shown_state = -1
  @@shown_pct = -1
  @@done_at = 0
  @@err = 0
  @@confirm = 0 # time of the first A (0 = not asking)
  CONFIRM_MS = 15_000
  ST_CONFIRM = 100 # UI-only state: waiting for the second A

  def self.state_name(st : Int32) : String
    st == ST_IDLE ? "idle" : st == ST_WAIT ? "waiting for a badge" : st == ST_SYNC ? "connecting (ROM loader)" :
      st == ST_COPY ? "copying" : st == ST_VERIFY ? "verifying" : st == ST_DONE ? "done" :
      st == ST_FAIL ? "failed" : "?"
  end

  # Shell `usbflash`: state, progress, USB host, last error.
  def self.report : Nil
    st = LibIDF.cr_b2b_state
    LibIDF.cr_print("usbflash: ".to_unsafe)
    LibIDF.cr_print(state_name(st).to_unsafe)
    LibIDF.cr_print(@@confirm != 0 ? " (on screen: confirm, press A again)\n".to_unsafe : "\n".to_unsafe)
    LibIDF.cr_log3("usbflash: state / pct / usb host installed".to_unsafe, st, LibIDF.cr_b2b_pct, LibIDF.cr_b2b_host ? 1 : 0)
    m = LibIDF.cr_b2b_msg
    if m[0] != 0_u8
      LibIDF.cr_print("usbflash: last error: ".to_unsafe)
      LibIDF.cr_print(m)
      LibIDF.cr_print("\n".to_unsafe)
    end
    LibIDF.cr_print("usbflash: start only on the badge (A twice in USBFLASH); it disconnects this console\n".to_unsafe) unless LibIDF.cr_b2b_host
  end

  def self.icon(x : Int32, y : Int32) : Nil
    Gfx.tile(x, y)
    # two badges joined by a cable, an arrow between them
    Gfx.frame(x &+ 16, y &+ 40, 48, 64, 5, false)
    Gfx.frame(x &+ 96, y &+ 40, 48, 64, 5, false)
    Gfx.box(x &+ 36, y &+ 104, 6, 24, false)
    Gfx.box(x &+ 118, y &+ 104, 6, 24, false)
    Gfx.box(x &+ 36, y &+ 122, 88, 6, false)
    Gfx.box(x &+ 70, y &+ 68, 20, 8, false)
    Gfx.box(x &+ 84, y &+ 62, 6, 20, false)
  end

  def self.msg_len(p : UInt8*) : Int32
    n = 0
    while n < 60 && p[n] != 0_u8
      n = n &+ 1
    end
    n
  end

  def self.draw(st : Int32, pct : Int32) : Nil
    EPD.fill(EPD::WHITE)
    busy = st == ST_WAIT || st == ST_SYNC || st == ST_COPY || st == ST_VERIFY
    TopBar.draw("USB FLASH", "< PREV", "NEXT >", busy ? "" : "A: START", busy ? "B: STOP" : "")
    Gfx.text(48, 80, "FLASH ANOTHER BADGE", 5)
    if st == ST_CONFIRM
      TopBar.draw("USB FLASH", "< PREV", "NEXT >", "A: START", "B: CANCEL")
      Gfx.box(40, 180, 880, 64, true)
      Gfx.text(64, 196, "START USB HOST MODE?", 5, false)
      Gfx.text(48, 290, "The USB console will disconnect;", 4)
      Gfx.text(48, 340, "reboot to restore it. Leaving", 4)
      Gfx.text(48, 390, "this app reboots the badge.", 4)
      Gfx.text(48, 470, "A again: start    B: cancel", 4)
    elsif st == ST_IDLE || st == ST_FAIL
      Gfx.text(48, 180, "Copies this badge's firmware onto", 3)
      Gfx.text(48, 216, "another badge over a USB-C cable.", 3)
      Gfx.text(48, 276, "1. Both badges ON BATTERY (unplug", 3)
      Gfx.text(48, 312, "   them from computers / chargers).", 3)
      Gfx.text(48, 360, "2. Connect them with a USB-C cable.", 3)
      Gfx.text(48, 408, "3. Press A. The other badge keeps", 3)
      Gfx.text(48, 444, "   its settings (name, Wi-Fi).", 3)
      Gfx.text(48, 504, "Badge on stock MicroPython: hold", 2)
      Gfx.text(48, 528, "BOOT and tap RESET on it first.", 2)
      if st == ST_FAIL
        m = LibIDF.cr_b2b_msg
        Gfx.box(40, 570, 880, 56, true)
        x = Gfx.text(56, 584, "FAILED: ", 4, false)
        Gfx.bytes(x, 584, m, msg_len(m), 4, false)
      elsif @@err != 0
        Gfx.text(48, 584, "USB HOST START FAILED", 4)
      end
    elsif st == ST_WAIT
      Gfx.text(48, 220, "WAITING FOR A BADGE...", 4)
      Gfx.text(48, 300, "Connect the other badge with a", 3)
      Gfx.text(48, 336, "USB-C cable. Both on battery.", 3)
    else
      label = st == ST_SYNC ? "CONNECTING" : (st == ST_COPY ? "COPYING" : (st == ST_VERIFY ? "VERIFYING" : "DONE!"))
      Gfx.text(48, 220, label, 6)
      Gfx.frame(48, 340, 720, 80, 6)
      Gfx.box(60, 352, (696 &* pct).unsafe_div(100), 56, true) if pct > 0
      buf = Shared.label_buf
      n = put_decimal(buf, pct)
      buf[n] = 0x25_u8
      Gfx.bytes(800, 360, buf, n &+ 1, 6)
      if st == ST_DONE
        Gfx.text(48, 480, "The other badge restarts now.", 3)
        Gfx.text(48, 520, "This badge restarts in a moment.", 3)
      else
        Gfx.text(48, 480, "Keep the cable connected.", 3)
      end
    end
  end

  def self.enter : Nil
    @@confirm = 0
    st = LibIDF.cr_b2b_state
    @@shown_state = st
    @@shown_pct = LibIDF.cr_b2b_pct
    draw(st, @@shown_pct)
    Apps.show_clean
  end

  def self.tick(now : Int32, inp : LibGames::Input) : Nil
    st = LibIDF.cr_b2b_state
    busy = st == ST_WAIT || st == ST_SYNC || st == ST_COPY || st == ST_VERIFY
    if @@confirm != 0 && (Games.pressed?(inp, Games::BTN_B) || now &- @@confirm > CONFIRM_MS)
      @@confirm = 0 # cancelled
    elsif @@confirm != 0 && Games.pressed?(inp, Games::BTN_A)
      @@confirm = 0
      @@err = LibIDF.cr_b2b_start
      st = ST_WAIT if @@err == 0
      @@shown_state = -1 if @@err != 0
    elsif Games.pressed?(inp, Games::BTN_A) && !busy && st != ST_DONE
      if LibIDF.cr_b2b_host
        @@err = LibIDF.cr_b2b_start # host already up (a retry): no console left to lose
        st = ST_WAIT if @@err == 0
      else
        @@confirm = now | 1 # first A: ask
      end
    elsif Games.pressed?(inp, Games::BTN_B) && busy
      LibIDF.cr_b2b_stop
    end
    if st == ST_DONE
      @@done_at = now if @@done_at == 0
      if now &- @@done_at > 4000
        Store.screen = SCR_HOME
        LibIDF.cr_b2b_restart # USB back to the console
      end
    end
    st = ST_CONFIRM if @@confirm != 0
    pct = LibIDF.cr_b2b_pct
    pct = 0 unless st == ST_COPY || st == ST_VERIFY || st == ST_DONE
    if st != @@shown_state || pct &- @@shown_pct >= 2 || (st == ST_DONE && pct != @@shown_pct)
      big = st != @@shown_state
      @@shown_state = st
      @@shown_pct = pct
      draw(st, pct)
      big ? Apps.show_clean : Apps.show
    end
  end

  # The PHY belongs to the USB host now: restart to get the console back.
  def self.leave : Nil
    return unless LibIDF.cr_b2b_host
    LibIDF.cr_b2b_stop
    Store.screen = Shared.target
    LibIDF.cr_b2b_restart
  end
end
