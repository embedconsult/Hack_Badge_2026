# Robot sources on the badge (C side: main/robots.c, 8 slots in the
# "storage" partition) and the `robot` shell command. Uploads are parsed
# and checked at once (on the uploading task, under RobotLock, in the
# engine's spare program slot RC::CHECK_SLOT), so the sender learns about a
# syntax error right away; a battle loads them again on the main task.
#
#   robot | robot list            slots and built-in robots
#   robot put <slot>              then the source, ended by a line "."
#   robot show <slot> | robot del <slot>
#   robot run <r1> <r2> [r3] [r4] [@seed]  r = a slot number or a built-in
#                                 name (sniper, rook, ...); opens ROBOTS

require "../robots/battle"
require "../robots/roster"

lib LibIDF
  fun cr_robot_slots : Int32
  fun cr_robot_max : Int32
  fun cr_robot_len(k : Int32) : Int32
  fun cr_robot_read(k : Int32, buf : UInt8*, max : Int32) : Int32
  fun cr_robot_write(k : Int32, src : UInt8*, n : Int32, name : UInt8*) : Bool
  fun cr_robot_name(k : Int32, out : UInt8*) : Bool
  fun cr_atomic_xchg(p : UInt32*, v : UInt32) : UInt32
  fun vTaskDelay(ticks : UInt32) : Void
  fun cr_print(s : UInt8*) : Void
end

# The engine's parse/compile workspace is shared: one user at a time.
module RobotLock
  @@word = 0_u32

  def self.take : Nil
    while LibIDF.cr_atomic_xchg(pointerof(@@word), 1_u32) != 0_u32
      LibIDF.vTaskDelay(1_u32)
    end
  end

  def self.give : Nil
    LibIDF.cr_atomic_xchg(pointerof(@@word), 0_u32)
  end
end

module RobotStore
  CODE_SLOT = 100 # line-up code of slot k: CODE_SLOT + k; built-ins: roster index

  @@buf = Pointer(UInt8).null

  def self.buf : UInt8*
    @@buf = game_alloc(RL::SRC_MAX &+ 1) if @@buf.null?
    @@buf
  end

  # Parse and check src[0, n] in the spare slot. 0 = fine (msg: the robot's
  # name), 1 = rejected (msg: the error with line:col). msg is
  # zero-terminated, at most max - 1 bytes.
  def self.check(src : UInt8*, n : Int32, msg : UInt8*, max : Int32) : Int32
    RobotLock.take
    ok = RC.load(RC::CHECK_SLOT, src, n)
    p = ok ? RC.name(RC::CHECK_SLOT) : RL.error
    k = ok ? RC.name_len(RC::CHECK_SLOT) : RL.error_len
    k = max &- 1 if k > max &- 1
    i = 0
    while i < k
      msg[i] = p[i]
      i = i &+ 1
    end
    msg[k] = 0_u8
    RobotLock.give
    ok ? 0 : 1
  end

  # Load line-up code c (slot or built-in) as battle robot r.
  def self.load(r : Int32, c : Int32) : Bool
    RobotLock.take
    ok = false
    if c >= CODE_SLOT
      b = buf
      n = LibIDF.cr_robot_read(c &- CODE_SLOT, b, RL::SRC_MAX)
      n = 0 if n < 0
      ok = RB.load(r, b, n)
    else
      s = Roster.source(c)
      ok = RB.load(r, s.to_unsafe, s.bytesize)
    end
    RobotLock.give
    ok
  end

  # Built-in robot whose file name is p[0, n], or -1.
  def self.builtin(p : UInt8*, n : Int32) : Int32
    i = 0
    while i < Roster::COUNT
      return i if Gfx.same_word?(p, n, Roster.file(i))
      i = i &+ 1
    end
    -1
  end
end

# C side of the Settings page (main/settings.c) checks uploads through this.
fun cr_robot_check(src : UInt8*, n : Int32, msg : UInt8*, max : Int32) : Int32
  RobotStore.check(src, n, msg, max)
end

module RobotShell
  @@slot = -1 # capturing `robot put` into this slot
  @@len = 0
  @@over = false
  @@msg = Pointer(UInt8).null
  @@last = 0 # millis of the last captured line
  IDLE_MS = 30_000

  def self.capturing? : Bool
    @@slot >= 0
  end

  def self.say(s : String) : Nil
    LibIDF.cr_print(s.to_unsafe)
  end

  def self.say_int(v : Int32) : Nil
    b = msg
    k = put_decimal(b, v < 0 ? 0 &- v : v)
    if v < 0
      Shell.say("-")
    end
    b[k] = 0_u8
    LibIDF.cr_print(b)
  end

  # The shell task's own source buffer (the main task loads battles from RobotStore.buf).
  @@src = Pointer(UInt8).null

  def self.src_buf : UInt8*
    @@src = game_alloc(RL::SRC_MAX &+ 1) if @@src.null?
    @@src
  end

  def self.msg : UInt8*
    @@msg = game_alloc(128) if @@msg.null?
    @@msg
  end

  # A line while `robot put` is capturing; "." ends the source, "abort"
  # drops it.
  def self.line(p : UInt8*, n : Int32) : Nil
    @@last = millis
    if n == 1 && p[0] == 0x2E_u8
      finish
      return
    end
    if Gfx.same_word?(p, n, "abort")
      @@slot = -1
      say("robot: put aborted, nothing saved\n")
      return
    end
    b = src_buf
    if @@len &+ n &+ 1 > LibIDF.cr_robot_max
      @@over = true
      return
    end
    i = 0
    while i < n
      b[@@len &+ i] = p[i]
      i = i &+ 1
    end
    b[@@len &+ n] = 0x0A_u8
    @@len = @@len &+ n &+ 1
  end

  # Shell loop, every ~20 ms: a capture idle for IDLE_MS (console gone?) is
  # dropped so later commands are not swallowed.
  def self.poll(now : Int32) : Nil
    return unless capturing?
    return if now &- @@last < IDLE_MS
    @@slot = -1
    say("\nrobot: put timed out (30 s without a line), nothing saved\n> ")
  end

  def self.finish : Nil
    slot = @@slot
    @@slot = -1
    if @@over
      say("robot: too long (max ")
      say_int(LibIDF.cr_robot_max)
      say(" bytes), not saved\n")
      return
    end
    m = msg
    if RobotStore.check(src_buf, @@len, m, 128) != 0
      say("robot: not saved: ")
      LibIDF.cr_print(m)
      say("\n")
      return
    end
    if LibIDF.cr_robot_write(slot, src_buf, @@len, m)
      say("robot: slot ")
      say_int(slot)
      say(" = ")
      LibIDF.cr_print(m)
      say("\n")
    else
      say("robot: flash write failed\n")
    end
  end

  def self.list : Nil
    say("slots:\n")
    k = 0
    while k < LibIDF.cr_robot_slots
      n = LibIDF.cr_robot_len(k)
      say("  ")
      say_int(k)
      if n < 0
        say(": empty\n")
      else
        say(": ")
        LibIDF.cr_robot_name(k, msg)
        LibIDF.cr_print(msg)
        say(" (")
        say_int(n)
        say(" bytes)\n")
      end
      k = k &+ 1
    end
    say("built-in:")
    i = 0
    while i < Roster::COUNT
      say(" ")
      say(Roster.file(i))
      i = i &+ 1
    end
    say("\n")
  end

  def self.show(k : Int32) : Nil
    b = src_buf
    n = LibIDF.cr_robot_read(k, b, RL::SRC_MAX)
    if n < 0
      say("robot: slot empty\n")
      return
    end
    b[n] = 0_u8
    LibIDF.cr_print(b)
    say("\n.\n")
  end

  # `robot ...` (Shell tokens 1..)
  def self.command : Nil
    slots = LibIDF.cr_robot_slots
    if Shell.tokens < 2 || Shell.tok_is(1, "list")
      list
    elsif Shell.tok_is(1, "put") || Shell.tok_is(1, "show") || Shell.tok_is(1, "del")
      k = Shell.tok_int(2, -1)
      if k < 0 || k >= slots
        say("usage: robot put|show|del <0..")
        say_int(slots &- 1)
        say(">\n")
      elsif Shell.tok_is(1, "put")
        @@slot = k
        @@len = 0
        @@over = false
        @@last = millis
        say("(robot source for slot ")
        say_int(k)
        say("; end with a line '.'; 'abort' cancels)\n")
      elsif Shell.tok_is(1, "show")
        show(k)
      else
        say(LibIDF.cr_robot_write(k, src_buf, 0, Pointer(UInt8).null) ? "robot: slot emptied\n" : "robot: failed\n")
      end
    elsif Shell.tok_is(1, "run")
      run
    else
      say("usage: robot [list] | robot put|show|del <slot> | robot run <r1> <r2> [r3] [r4] [@seed]\n")
    end
  end

  def self.run : Nil
    n = 0
    seed = 0
    i = 2
    while i < Shell.tokens
      p = Shell.tok_ptr(i)
      if p[0] == 0x40_u8 # @seed
        seed = 0
        j = 1
        while j < Shell.tok_len(i) && p[j] >= 0x30_u8 && p[j] <= 0x39_u8
          seed = seed &* 10 &+ (p[j] &- 0x30_u8).to_i32!
          j = j &+ 1
        end
        i = i &+ 1
        next
      end
      v = Shell.tok_int(i, -1)
      c = -1
      if v >= 0 && v < LibIDF.cr_robot_slots
        if LibIDF.cr_robot_len(v) < 0
          say("robot: slot ")
          say_int(v)
          say(" is empty\n")
          return
        end
        c = RobotStore::CODE_SLOT &+ v
      elsif v >= 0
        say("robot: no slot ")
        say_int(v)
        say("\n")
        return
      else
        c = RobotStore.builtin(Shell.tok_ptr(i), Shell.tok_len(i))
        if c < 0
          say("robot: no built-in robot like that (robot list)\n")
          return
        end
      end
      if c >= 0
        if n == 4
          say("robot: at most 4 robots\n")
          return
        end
        RobotsApp.request(n, c)
        n = n &+ 1
      end
      i = i &+ 1
    end
    if n < 2
      say("robot: a battle needs 2 to 4 robots\n")
      return
    end
    RobotsApp.request_run(n, seed)
    id = Apps.find("ROBOTS".to_unsafe, 6)
    Shared.target = id if id >= 0
    LibIDF.cr_notify_main
    say("ok\n")
  end
end
