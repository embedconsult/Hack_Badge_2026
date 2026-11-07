# Debug shell on the USB-Serial/JTAG console (crystal_shell_task, started
# from main.c with a small stack). Reads the RX FIFO directly (no driver,
# so the console output path is untouched), line-buffered, one command per
# line. Commands that touch the panel are handed to the main task through
# Shared requests, so only the main task ever drives the EPD.

lib LibIDF
  fun cr_console_read(buf : UInt8*, max : Int32) : Int32
  fun cr_print(s : UInt8*) : Void
  fun cr_log3(msg : UInt8*, a : Int32, b : Int32, c : Int32) : Void
  fun cr_heap_free(caps : UInt32) : Int32
  fun esp_restart : Void
  fun cr_time_set(y : Int32, mo : Int32, d : Int32, h : Int32, mi : Int32) : Void
end

module Shell
  LINE_MAX = 300 # room for `ota url <long url>`
  TOK_MAX  =  6

  @@line = Pointer(UInt8).null
  @@len = 0
  @@ts = Pointer(Int32).null # token starts
  @@tl = Pointer(Int32).null # token lengths
  @@nt = 0

  def self.say(s : String) : Nil
    LibIDF.cr_print(s.to_unsafe)
  end

  def self.tok_is(i : Int32, w : String) : Bool
    return false if i >= @@nt || @@tl[i] != w.bytesize
    p = w.to_unsafe
    j = 0
    while j < @@tl[i]
      return false if @@line[@@ts[i] &+ j] != p[j]
      j = j &+ 1
    end
    true
  end

  # Integer token i (optional '-'); `bad` if missing or not a number.
  def self.tok_int(i : Int32, bad : Int32) : Int32
    return bad if i >= @@nt
    s = @@ts[i]
    e = s &+ @@tl[i]
    neg = false
    if @@line[s] == 0x2D_u8
      neg = true
      s = s &+ 1
    end
    return bad if s >= e
    v = 0
    while s < e
      c = @@line[s].to_i32!
      return bad if c < 0x30 || c > 0x39
      v = v &* 10 &+ (c &- 0x30)
      s = s &+ 1
    end
    neg ? 0 &- v : v
  end

  def self.tokenize : Nil
    @@nt = 0
    i = 0
    while i < @@len && @@nt < TOK_MAX
      while i < @@len && @@line[i] == 0x20_u8
        i = i &+ 1
      end
      break if i >= @@len
      @@ts[@@nt] = i
      while i < @@len && @@line[i] != 0x20_u8
        i = i &+ 1
      end
      @@tl[@@nt] = i &- @@ts[@@nt]
      @@nt = @@nt &+ 1
    end
  end

  # App by registry NAME (src/apps/app.cr), or "home"; -1 if none.
  def self.screen_of(i : Int32) : Int32
    return -1 if i >= @@nt
    Apps.find(@@line + @@ts[i].to_i64!, @@tl[i])
  end

  SOURCE_URL = "https://github.com/embedconsult/Hack_Badge_2026/tree/crystal"

  def self.banner : Nil
    say("badge ")
    LibIDF.cr_print(LibIDF.cr_version)
    say("\n")
    say(SOURCE_URL)
    say("\n")
  end

  def self.help_short : Nil
    banner
    say("version status reboot mode press hold knob text\n")
    say("net wifi ota sketch stroke dump upd flag clean\n")
    say("clock usbflash inkf\n")
    say("help all: details\n")
  end

  def self.help : Nil
    say("commands:\n")
    say("  help | version | status | reboot\n")
    say("  mode <home|nametag|portrait|sketch|...|any app name>\n")
    say("  weather [<lat> <lon> [c|f] [name]] | weather place <city> | weather units <c|f>\n")
    say("  net on | net off | net status   (badge link: UDP 4626 + ESP-NOW)\n")
    say("  net ap on | net ap off          (own access point on channel 1, for badge os)\n")
    say("  clock <Y> <M> <D> <h> <m>       (set local time, Schedule NOW/NEXT)\n")
    say("  text <first>[|<last>]           (nametag name, saved)\n")
    say("  press <a|b|plus|minus> | hold a | colour | clean\n")
    say("  knob <l|r> <mV> | knob off\n")
    say("  stroke x0 y0 x1 y1        (Sketch canvas, then a refresh)\n")
    say("  dump <red|black> <row0> <rows>\n")
    say("  sketch quickdraw         (Sketch: the six-shooter)\n")
    say("  usbflash                 (badge-to-badge USB update state)\n")
    say("  upd [<sketch|life|snake> <full|win|diff|diffwin|ink>]\n")
    say("  flag <QUICK_OPEN|SK_RED_INK_PLAIN|SKIP_ZERO_RED|SK_WIN> <0|1>\n")
    say("  wifi <ssid> <password> | wifi off | wifi forget | wifi status\n")
    say("  ota | ota force | ota url <url|default> | ota status\n")
  end

  # wifi / ota (src/ota.cr): the work runs on the OTA worker task, which
  # prints its own result. The password is the rest of the line (it may
  # contain spaces; trailing spaces are dropped) and is never echoed.
  def self.ota_job(job : Int32, ta : Int32, rest_b : Bool) : Nil
    a = ta >= 0 && ta < @@nt ? @@line + @@ts[ta].to_i64! : Pointer(UInt8).null
    alen = ta >= 0 && ta < @@nt ? @@tl[ta] : 0
    b = Pointer(UInt8).null
    blen = 0
    if rest_b && ta &+ 1 < @@nt
      s = @@ts[ta &+ 1]
      e = @@len
      while e > s && @@line[e &- 1] == 0x20_u8
        e = e &- 1
      end
      b = @@line + s.to_i64!
      blen = e &- s
    end
    r = Ota.cmd(job, a, alen, b, blen)
    i = 0
    while i < @@len # scrub the password from the line buffer
      @@line[i] = 0_u8
      i = i &+ 1
    end
    if r == 1
      say("busy: an ota/wifi job is running\n")
    elsif r != 0
      say("failed: no memory for the ota task\n")
    end
  end

  def self.wifi : Nil
    if tok_is(1, "off")
      ota_job(Ota::JOB_WIFI_OFF, -1, false)
    elsif tok_is(1, "forget")
      ota_job(Ota::JOB_WIFI_FORGET, -1, false)
    elsif tok_is(1, "status") || @@nt == 1
      ota_job(Ota::JOB_WIFI_STATUS, -1, false)
    elsif @@nt >= 2
      ota_job(Ota::JOB_WIFI_SET, 1, true) # no password = open network
    end
  end

  def self.ota : Nil
    if @@nt == 1
      say("ota: checking for an update (progress on the panel and here)\n")
      ota_job(Ota::JOB_UPDATE, -1, false)
      LibIDF.cr_notify_main
    elsif tok_is(1, "force")
      ota_job(Ota::JOB_FORCE, -1, false)
      LibIDF.cr_notify_main
    elsif tok_is(1, "url") && @@nt == 3
      ota_job(Ota::JOB_URL_SET, 2, false)
    elsif tok_is(1, "status")
      ota_job(Ota::JOB_STATUS, -1, false)
    else
      say("usage: ota | ota force | ota url <url|default> | ota status\n")
    end
  end

  def self.status : Nil
    LibIDF.cr_log3("status: screen / target / live".to_unsafe, Shared.screen, Shared.target, Shared.live? ? 1 : 0)
    LibIDF.cr_log3("status: rendering / panel busy / session open".to_unsafe,
      Shared.rendering? ? 1 : 0, EPD.busy? ? 1 : 0, EPD.session_open? ? 1 : 0)
    LibIDF.cr_log3("status: last kind / pulls / panel ms".to_unsafe, EPD.latched_kind, EPD.fast_pulls, EPD.panel_ms)
    LibIDF.cr_log3("status: upload ms / restart ms / session images".to_unsafe, EPD.upload_ms, EPD.restart_ms, EPD.session_images)
    LibIDF.cr_log3("status: collapsed pulls redone / - / -".to_unsafe, EPD.collapsed, 0, 0)
    LibIDF.cr_log3("status: quick session / QUICK_OPEN / SKIP_ZERO_RED".to_unsafe,
      EPD.quick? ? 1 : 0, EPD.quick_open? ? 1 : 0, EPD.skip_zero_red? ? 1 : 0)
    LibIDF.cr_log3("status: SK_RED_INK_PLAIN / sketch colour / red frame".to_unsafe,
      Shared.red_ink_plain? ? 1 : 0, SkState.colour? ? 1 : 0, SkState.red_frame? ? 1 : 0)
    # Red plane: non-zero bytes (read-only scan) and the last exact check.
    rd = EPD.red
    nz = 0
    i = 0
    while i < EPD::PLANE
      nz = nz &+ 1 if rd[i] != 0_u8
      i = i &+ 1
    end
    LibIDF.cr_log3("status: red non-zero bytes / last M / M first row".to_unsafe, nz, RedCheck.last, RedCheck.first_row)
    LibIDF.cr_log3("status: knob mV l / r / override".to_unsafe, Shared.mv_l, Shared.mv_r, Shared.knob_ovr? ? 1 : 0)
    LibIDF.cr_log3("status: free stack knob / main / shell".to_unsafe,
      LibIDF.cr_stack_free(false).to_i32!, LibIDF.cr_stack_free(true).to_i32!, LibIDF.cr_stack_free_self.to_i32!)
    LibIDF.cr_log3("status: free heap internal / psram / -".to_unsafe,
      LibIDF.cr_heap_free(0x800_u32), LibIDF.cr_heap_free(0x400_u32), 0)
    LibIDF.cr_log3("status: boot count / reset reason / uptime ms".to_unsafe,
      Store.boots, Store.reset_reason, millis)
    LibIDF.cr_log3("status: upd sketch / life / snake (0 full 1 win 2 diff 3 diffwin 4 ink)".to_unsafe,
      Shared.upd(SCR_SKETCH), Shared.upd(SCR_LIFE), Shared.upd(SCR_SNAKE))
    LibIDF.cr_log3("status: diff session open / pulls / -".to_unsafe, EPD.diff_open? ? 1 : 0, EPD.diff_n, 0)
  end

  def self.dump(red : Bool) : Nil
    r0 = tok_int(2, -1)
    n = tok_int(3, 1)
    if r0 < 0 || r0 >= EPD::HEIGHT || n < 1
      say("usage: dump <red|black> <row0> <rows>\n")
      return
    end
    p = red ? EPD.red : EPD.black
    r = r0
    while r < r0 &+ n && r < EPD::HEIGHT
      nz = 0
      sum = 0
      c = 0
      while c < EPD::ROW_BYTES
        v = p[r &* EPD::ROW_BYTES &+ c]
        nz = nz &+ 1 if v != 0_u8
        sum = sum &+ v.to_i32! &* (c &+ 1)
        c = c &+ 1
      end
      LibIDF.cr_log3("dump: row / non-zero bytes / checksum".to_unsafe, r, nz, sum)
      r = r &+ 1
    end
  end

  def self.upd : Nil
    if @@nt >= 3
      app = tok_is(1, "sketch") ? SCR_SKETCH : (tok_is(1, "life") ? SCR_LIFE : (tok_is(1, "snake") ? SCR_SNAKE : -1))
      m = tok_is(2, "full") ? UPD_FULL : (tok_is(2, "win") ? UPD_WIN : (tok_is(2, "diffwin") ? UPD_DIFFWIN : (tok_is(2, "diff") ? UPD_DIFF : (tok_is(2, "ink") ? UPD_INK : -1))))
      if app < 0 || m < 0
        say("usage: upd [<sketch|life|snake> <full|win|diff|diffwin|ink>]\n")
        return
      end
      Shared.set_upd(app, m)
      say("ok\n")
    end
    LibIDF.cr_log3("upd: sketch / life / snake (0 full 1 win 2 diff 3 diffwin 4 ink)".to_unsafe,
      Shared.upd(SCR_SKETCH), Shared.upd(SCR_LIFE), Shared.upd(SCR_SNAKE))
  end

  def self.flag : Nil
    v = tok_int(2, -1)
    if v < 0 || v > 1
      say("usage: flag <QUICK_OPEN|SK_RED_INK_PLAIN|SKIP_ZERO_RED|SK_WIN> <0|1>\n")
      return
    end
    on = v == 1
    if tok_is(1, "QUICK_OPEN")
      EPD.quick_open = on
    elsif tok_is(1, "SK_RED_INK_PLAIN")
      Shared.red_ink_plain = on
    elsif tok_is(1, "INK_WIN")
      Shared.ink_win = on
    elsif tok_is(1, "SK_WIN")
      Shared.sk_win = on
    elsif tok_is(1, "SKIP_ZERO_RED")
      EPD.skip_zero_red = on
    else
      say("unknown flag\n")
      return
    end
    say("ok\n")
  end

  def self.execute : Nil
    tokenize
    return if @@nt == 0
    if tok_is(0, "help") || tok_is(0, "?")
      @@nt > 1 ? help : help_short
    elsif tok_is(0, "version") || tok_is(0, "hello") || tok_is(0, "helo")
      banner
    elsif tok_is(0, "status")
      status
    elsif tok_is(0, "reboot")
      say("rebooting\n")
      LibIDF.esp_restart
    elsif tok_is(0, "mode")
      s = screen_of(1)
      if s < 0
        say("usage: mode <home|nametag|portrait|sketch|...|any app name>\n")
      else
        Shared.target = s
        LibIDF.cr_notify_main
        say("ok\n")
      end
    elsif tok_is(0, "press")
      if tok_is(1, "plus") || tok_is(1, "minus")
        t = Shared.target
        Shared.target = step_screen(t, tok_is(1, "plus"))
      elsif tok_is(1, "a")
        Shared.inject_buttons(Games::BTN_A)
      elsif tok_is(1, "b")
        Shared.inject_buttons(Games::BTN_B)
      else
        say("usage: press <a|b|plus|minus>\n")
        return
      end
      LibIDF.cr_notify_main
      say("ok\n")
    elsif (tok_is(0, "hold") && tok_is(1, "a")) || tok_is(0, "colour") || tok_is(0, "color")
      Shared.request(Shared::REQ_HOLD_A)
      LibIDF.cr_notify_main
      say("ok\n")
    elsif tok_is(0, "clean")
      Shared.request(Shared::REQ_CLEAN)
      LibIDF.cr_notify_main
      say("ok\n")
    elsif tok_is(0, "knob")
      if tok_is(1, "off")
        Shared.knob_override(-1, -1)
        say("ok\n")
      else
        mv = tok_int(2, -1)
        if mv < 0 || mv > 3300 || !(tok_is(1, "l") || tok_is(1, "r"))
          say("usage: knob <l|r> <mV> | knob off\n")
        else
          if tok_is(1, "l")
            Shared.knob_override(mv, Shared.ovr_r < 0 ? Shared.mv_r : Shared.ovr_r)
          else
            Shared.knob_override(Shared.ovr_l < 0 ? Shared.mv_l : Shared.ovr_l, mv)
          end
          say("ok\n")
        end
      end
    elsif tok_is(0, "stroke")
      x0 = tok_int(1, -1)
      y0 = tok_int(2, -1)
      x1 = tok_int(3, -1)
      y1 = tok_int(4, -1)
      if x0 < 0 || y0 < 0 || x1 < 0 || y1 < 0
        say("usage: stroke x0 y0 x1 y1\n")
      else
        Shared.request_stroke(x0, y0, x1, y1)
        LibIDF.cr_notify_main
        say("ok\n")
      end
    elsif tok_is(0, "dump")
      if tok_is(1, "red")
        dump(true)
      elsif tok_is(1, "black")
        dump(false)
      else
        say("usage: dump <red|black> <row0> <rows>\n")
      end
    elsif tok_is(0, "flag")
      flag
    elsif tok_is(0, "upd")
      upd
    elsif tok_is(0, "sketch") && tok_is(1, "quickdraw")
      Shared.request(Shared::REQ_QUICKDRAW)
      say("ok\n")
    elsif tok_is(0, "wtest")
      # wtest <A> <B> <C>: 20 level digits each (see main.cr wtest)
      ok = @@nt >= 4
      t = 1
      while ok && t <= 3
        ok = false if @@tl[t] != 20
        t = t &+ 1
      end
      if ok
        c = WTest.codes
        t = 1
        while t <= 3
          k = 0
          while k < 20
            c[(t &- 1) &* 20 &+ k] = (@@line + (@@ts[t] &+ k).to_i64!).value &- 48_u8
            k = k &+ 1
          end
          t = t &+ 1
        end
        WTest.pulls = tok_int(4, 1)
        Shared.request(Shared::REQ_WTEST)
        LibIDF.cr_notify_main
        say("ok\n")
      else
        say("usage: wtest <A> <B> <C> (20 digits 0-3 each)\n")
      end
    elsif tok_is(0, "diffe")
      # diffe <vdl> <vdh>: diff table black -> white drive frames (new session)
      EPD.diff_erase(tok_int(1, EPD.diff_el), tok_int(2, EPD.diff_eh)) if @@nt >= 3
      LibIDF.cr_log3("diffe: vdl / vdh / -".to_unsafe, EPD.diff_el, EPD.diff_eh, 0)
    elsif tok_is(0, "inkf")
      # inkf <f1> <f3> <fe>: ink command drive frames (new session)
      EPD.ink_frames(tok_int(1, EPD.ink_f1), tok_int(2, EPD.ink_f3), tok_int(3, EPD.ink_fe)) if @@nt >= 4
      LibIDF.cr_log3("inkf: f1 / f3 / fe".to_unsafe, EPD.ink_f1, EPD.ink_f3, EPD.ink_fe)
    elsif tok_is(0, "reg")
      # reg <osc> <tcon> (decimal): session timing experiment (EPD.x_regs)
      EPD.x_regs(tok_int(1, EPD.x_osc), tok_int(2, EPD.x_tcon)) if @@nt >= 3
      LibIDF.cr_log3("reg: osc / tcon / -".to_unsafe, EPD.x_osc, EPD.x_tcon, 0)
    elsif tok_is(0, "usbflash")
      B2bApp.report # src/apps/b2b.cr (read-only: starting needs the badge's buttons)
    elsif tok_is(0, "wifi")
      wifi
    elsif tok_is(0, "ota")
      ota
    elsif tok_is(0, "weather")
      LibIDF.cr_weather_cmd(@@line, @@len) # main/apps_net.c: parses, saves, prints
    elsif tok_is(0, "net")
      if tok_is(1, "ap") && (tok_is(2, "on") || tok_is(2, "off"))
        LibIDF.cr_net_set_ap(tok_is(2, "on"))
        say(tok_is(2, "on") ? "net: own access point BADGE-LINK-xxxx on channel 1 (saved)\n" : "net: station mode (saved)\n")
      elsif tok_is(1, "on")
        LibIDF.cr_net_set(true)
        say("net: on (saved)\n")
      elsif tok_is(1, "off")
        LibIDF.cr_net_set(false)
        say("net: off (saved)\n")
      else
        LibIDF.cr_net_print_status
      end
      LibIDF.cr_notify_main
    elsif tok_is(0, "clock") && @@nt == 6
      # local (Pasadena) time, for the Schedule app's NOW / NEXT marks
      LibIDF.cr_time_set(tok_int(1, 2026), tok_int(2, 11), tok_int(3, 7), tok_int(4, 12), tok_int(5, 0))
      say("ok\n")
    elsif tok_is(0, "text") && @@nt >= 2
      s = @@ts[1]
      e = @@len
      while e > s && @@line[e &- 1] == 0x20_u8
        e = e &- 1
      end
      LibIDF.cr_name_set(@@line + s.to_i64!, e &- s)
      Shared.target = SCR_NAMETAG
      Shared.request(Shared::REQ_REDRAW)
      LibIDF.cr_notify_main
      say("ok\n")
    else
      say("unknown command (help)\n")
    end
  end

  def self.run : Nil
    @@line = LibIDF.heap_caps_malloc(LINE_MAX.to_u32!, 0x804_u32).as(UInt8*)
    @@ts = LibIDF.heap_caps_malloc((TOK_MAX &* 4).to_u32!, 0x804_u32).as(Int32*)
    @@tl = LibIDF.heap_caps_malloc((TOK_MAX &* 4).to_u32!, 0x804_u32).as(Int32*)
    rx = LibIDF.heap_caps_malloc(64_u32, 0x804_u32).as(UInt8*)
    return if @@line.null? || @@ts.null? || @@tl.null? || rx.null?
    say("\n")
    banner
    say("type help\n> ")
    while true
      n = LibIDF.cr_console_read(rx, 64)
      i = 0
      while i < n
        c = rx[i]
        if c == 0x0A_u8 || c == 0x0D_u8
          if @@len > 0 # empty lines (e.g. the LF of a CRLF) are ignored
            say("\n")
            execute
            @@len = 0
            say("> ")
          end
        elsif @@len < LINE_MAX &- 1
          @@line[@@len] = c
          @@len = @@len &+ 1
        end
        i = i &+ 1
      end
      run_remote
      LibIDF.vTaskDelay(ms_to_ticks(20_u32))
    end
  end

  # Command lines from the network (main/net.c already allowed them): run
  # them here like typed ones, in a second line buffer.
  @@rline = Pointer(UInt8).null

  def self.run_remote : Nil
    @@rline = LibIDF.heap_caps_malloc(128_u32, 0x804_u32).as(UInt8*) if @@rline.null?
    return if @@rline.null?
    while true
      n = LibIDF.cr_net_take_line(@@rline, 127)
      return if n <= 0
      keep_line = @@line
      keep_len = @@len
      @@line = @@rline
      @@len = n
      say("[net] ")
      @@rline[n] = 0_u8
      LibIDF.cr_print(@@rline)
      say("\n")
      execute
      @@line = keep_line
      @@len = keep_len
    end
  end
end

fun crystal_shell_task(arg : Void*) : Void
  Shell.run
end
