# Console debug output, off at every boot so the shell stays readable
# (shell `debug`). Session-only, not saved. Errors, the boot banner, the
# reset reason and anything a shell command prints are never gated.
# Pure (no ESP-IDF calls): test/dbg_spec.cr runs it on the host.
module Dbg
  KNOB  = 1 # knob task: knob raw / mV / hue once a second, stack every 10 s
  FRAME = 2 # per-refresh timing: EPD pulls and sessions, Sketch ink, game frames
  IDF   = 4 # ESP-IDF component INFO logs (wifi, OTA, HTTP, ...); WARN otherwise
  ALL   = 7

  @@on = 0

  def self.on?(cat : Int32) : Bool
    (@@on & cat) != 0
  end

  def self.mask : Int32
    @@on
  end

  def self.set(cat : Int32, on : Bool) : Nil
    @@on = on ? (@@on | cat) : (@@on & (cat ^ -1))
  end

  # Category bits for a shell word (`knob`, `frame`, `idf`, `all`), 0 if none.
  def self.category(w : UInt8*, n : Int32) : Int32
    return KNOB if word?(w, n, "knob")
    return FRAME if word?(w, n, "frame")
    return IDF if word?(w, n, "idf")
    return ALL if word?(w, n, "all")
    0
  end

  def self.word?(w : UInt8*, n : Int32, s : String) : Bool
    return false if n != s.bytesize
    p = s.to_unsafe
    i = 0
    while i < n
      return false if w[i] != p[i]
      i = i &+ 1
    end
    true
  end
end
