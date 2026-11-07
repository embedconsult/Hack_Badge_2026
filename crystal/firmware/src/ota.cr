# Over-the-air updates from GitHub releases (Crystal side; the Wi-Fi, NVS
# and HTTPS work is in main/ota.c on its own 10 KB worker task).
#
# - Shell (shell.cr): wifi <ssid> <password> | wifi off | wifi forget |
#   wifi status | ota | ota force | ota url <url|default> | ota status.
# - DIAG screen: hold User B for a second to check for an update now.
# - While an update job runs, the main task does no other e-paper work: it
#   sits in Ota.ui, which only redraws a status screen on state changes (and
#   every 25 % while downloading); the LEDs pulse (Shared.rendering).
# - Rollback: a new image must call Ota.boot_ok (after the first screen is
#   drawn) or the bootloader / a 90 s guard timer rolls it back.

lib LibIDF
  fun cr_ota_cmd(job : Int32, a : UInt8*, alen : Int32, b : UInt8*, blen : Int32) : Int32
  fun cr_ota_running : Bool
  fun cr_ota_state : Int32
  fun cr_ota_pct : Int32
  fun cr_ota_msg : UInt8*
  fun cr_ota_boot_ok : Int32
  fun cr_ota_boot_failed : Void
end

module Shared
  # Buttons held at the knob task's last poll (not latched).
  def self.held_now : UInt32
    @@held
  end
end

module Ota
  # Jobs and states: keep in sync with main/ota.c.
  JOB_UPDATE      = 1
  JOB_FORCE       = 2
  JOB_WIFI_SET    = 3
  JOB_WIFI_OFF    = 4
  JOB_WIFI_STATUS = 5
  JOB_WIFI_FORGET = 6
  JOB_URL_SET     = 7
  JOB_STATUS      = 8

  ST_CONNECTING  = 1
  ST_CHECKING    = 2
  ST_DOWNLOADING = 3
  ST_UP_TO_DATE  = 4
  ST_FAILED      = 5
  ST_REBOOTING   = 6

  HOLD_B_MS   = 1000 # DIAG: hold User B this long to update
  RESULT_MS   = 6000 # final status stays up this long before the screen returns

  # 0 = started, 1 = another job is running, 2 = no memory for the task.
  def self.cmd(job : Int32, a : UInt8*, alen : Int32, b : UInt8*, blen : Int32) : Int32
    LibIDF.cr_ota_cmd(job, a, alen, b, blen)
  end

  def self.start(force : Bool) : Int32
    cmd(force ? JOB_FORCE : JOB_UPDATE, Pointer(UInt8).null, 0, Pointer(UInt8).null, 0)
  end

  def self.running? : Bool
    LibIDF.cr_ota_running
  end

  # True on the first boot of a freshly updated image.
  def self.boot_ok : Bool
    LibIDF.cr_ota_boot_ok != 0
  end

  def self.boot_failed : Nil
    LibIDF.cr_ota_boot_failed
  end

  # DIAG, on a User B press: true once B has been held HOLD_B_MS (update),
  # false if it is released before (a tap).
  def self.b_held? : Bool
    t0 = millis
    while millis &- t0 < HOLD_B_MS
      return false if (Shared.held_now & Games::BTN_B) == 0_u32
      delay_ms(20)
    end
    true
  end

  def self.msg_len(m : UInt8*) : Int32
    n = 0
    while n < 76 && m[n] != 0_u8
      n = n &+ 1
    end
    n
  end

  def self.draw(st : Int32, pct : Int32) : Nil
    EPD.fill(EPD::WHITE)
    draw_text(40, 40, "UPDATE", EPD::BLACK, 10)
    draw_version(EPD::WIDTH &- 12, 12)
    m = LibIDF.cr_ota_msg
    show_msg = true
    if st == ST_CONNECTING
      draw_text(40, 200, "CONNECTING TO WI-FI", EPD::BLACK, 4)
    elsif st == ST_CHECKING
      draw_text(40, 200, "CHECKING FOR UPDATE", EPD::BLACK, 4)
      show_msg = false
    elsif st == ST_DOWNLOADING
      buf = Shared.label_buf
      x = draw_text_end(40, 200, "DOWNLOADING ", 4)
      n = put_decimal(buf, pct)
      buf[n] = 0x25_u8 # '%'
      draw_bytes(x, 200, buf, n &+ 1, EPD::BLACK, 4)
    elsif st == ST_UP_TO_DATE
      draw_text(40, 200, "UP TO DATE", EPD::BLACK, 4)
    elsif st == ST_REBOOTING
      draw_text(40, 200, "UPDATED - REBOOTING", EPD::BLACK, 4)
      show_msg = false
    else
      draw_text(40, 200, "FAILED:", EPD::BLACK, 4)
    end
    draw_bytes(40, 270, m, msg_len(m), EPD::BLACK, 2) if show_msg
    draw_text(40, 420, "WI-FI: SHELL 'WIFI <SSID> <PASS>'", EPD::BLACK, 3)
    draw_text(40, 460, "LED PULSING = UPDATE IN PROGRESS", EPD::BLACK, 3)
    fast_bw(2, WIN_LUT)
  end

  def self.draw_text_end(x : Int32, y : Int32, s : String, scale : Int32) : Int32
    draw_text(x, y, s, EPD::BLACK, scale)
    x &+ s.bytesize &* 6 &* scale
  end

  # Main task: status screen while the update job runs (no other e-paper
  # work meanwhile), then back to screen scr. Does not return on success
  # (the worker reboots into the new image).
  def self.ui(scr : Int32) : Nil
    log("ota: update running, e-paper paused", scr)
    Shared.rendering = true # LEDs pulse = busy
    shown = -1
    while true
      run = running?
      st = LibIDF.cr_ota_state
      pct = LibIDF.cr_ota_pct
      key = st == ST_DOWNLOADING ? st &* 100 &+ pct.unsafe_div(25) : st &* 100
      if key != shown
        shown = key
        draw(st, st == ST_DOWNLOADING ? pct.unsafe_div(25) &* 25 : pct)
      end
      break unless run
      delay_ms(200)
    end
    delay_ms(RESULT_MS)
    Shared.take_buttons # presses during the update don't act on the screen
    RedRes.residue = true # its big text leaves a ghost: slow clean when idle
    enter_screen(scr, false)
    Shared.rendering = false
  end
end
