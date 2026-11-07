# Battle specs for the badge robot engine (src/robots/battle.cr) against
# upstream crystal-robots' Field#run_stepwise, motion update by motion update.
#   crystal/firmware/test/robots/upstream.sh
#   crystal spec crystal/firmware/test/robots_battle_spec.cr   (also runs robots_spec)
require "./robots_spec"
require "./robots/upstream/src/battle/step_robot"
require "../src/robots/battle"

# Robots for the corners: runtime errors, deep recursion, strings, globals
# across restarts, case/when, break inside case, top-level code, math.
EXTRA_ROBOTS = {
  "faulty" => <<-R,
    global(n, 0)
    main("Faulty") do
      n += 1
      drive(n * 37, 30)
      x = "s" + n
    end
    R
  "deep" => <<-R,
    def down(k)
      down(k + 1)
    end
    main("Deep") do
      scan(rand(360), 10)
      down(0)
    end
    R
  "chatty" => <<-R,
    LIMIT = 3
    global(shots, 0)
    puts "booting"
    if LIMIT > 2
      puts LIMIT
    end
    def aim(d)
      case d % 4
      when 0
        "north"
      when 1
        1
      else
        d
      end
    end
    main("Chatty") do
      d = 0
      while true
        r = scan(d, 10)
        case r > 0
        when 1
          cannon(d, r)
          shots += 1
          if shots % 5 == 0
            puts aim(shots)
          end
          break
        else
          d += 20
        end
        until speed == 0
        end
        drive(d, 40)
      end
      puts "restart"
    end
    R
  "lazy" => <<-R,
    def f
      x
    end
    main("Lazy") do
      if rand(2) == 0
        x = 5
      end
      drive(rand(360), 100)
      y = sqrt(-50) + atan(-300000) + sin(-45) + cos(400) + tan(30)
      z = -7 / 2 + -7 % 3 + 7 // -2 + 7 % -3 + 5 / 0 + 5 % 0 ^ 3
      puts z + y
      w = f
    end
    R
}

def robot_source(name : String) : String
  if (s = EXTRA_ROBOTS[name]?)
    return s
  end
  corpus.find { |(n, _)| n.starts_with?(name) }.not_nil![1]
end

# Everything visible in one motion update: robots, then missiles in flight.
def rb_frame : String
  String.build do |io|
    RB.robots.times do |r|
      io << '[' << RB.x(r) << ',' << RB.y(r) << ',' << RB.heading(r) << ',' << RB.speed(r) << ','
      io << RB.damage(r) << ',' << RB.scan_dir(r) << ',' << RB.active?(r) << ',' << RB.cannon_dir(r) << ','
      io << RB.fired?(r) << ']'
    end
    RB.robots.times do |r|
      2.times do |k|
        st = RB.missile_state(r, k)
        next if st == RB::AVAIL
        io << '{' << r << ',' << k << ',' << RB.missile_x(r, k) << ',' << RB.missile_y(r, k) << ','
        io << (st == RB::EXPLODING) << '}'
      end
    end
  end
end

def up_frame(f : CrystalRobots::Battle::Frame) : String
  String.build do |io|
    f.robots.each do |s|
      io << '[' << s.x << ',' << s.y << ',' << s.heading << ',' << s.speed << ',' << s.damage << ','
      io << s.scan << ',' << s.active << ',' << s.cannon << ',' << s.fired << ']'
    end
    f.missiles.each do |m|
      io << '{' << m.owner << ',' << m.slot << ',' << m.x << ',' << m.y << ',' << m.exploding << '}'
    end
  end
end

# Run one match on both engines and compare every motion update.
def same_battle(names : Array(String), seed : Int32, limit : Int32) : Nil
  entries = names.map { |n| {n, robot_source(n)} }
  field = CrystalRobots::Battle::Field.new(entries, seed: seed.to_u64, limit: limit.to_i64, max_frames: limit)
  field.run_stepwise
  entries.each_with_index { |(_, src), r| RB.load(r, src.to_unsafe, src.bytesize) }
  RB.start(entries.size, seed.to_u64, limit)
  label = "#{names.join(" vs ")} seed #{seed}"
  fail "#{label}: start differs" unless up_frame(field.frames[0]) == rb_frame
  fighting = field.frames.size - 1 # frames 1.. are the fight's updates (every = 1)
  while RB.update
    u = RB.updates
    next unless u <= fighting && field.frames[u].cycle == RB.cycles && !RB.over?
    a = rb_frame
    b = up_frame(field.frames[u])
    fail "#{label}: update #{u} (cycle #{RB.cycles}) differs\n badge    #{a}\n upstream #{b}" unless a == b
  end
  STDERR.puts "#{label}: #{RB.updates} updates, cycles #{RB.cycles}, winner #{RB.winner}, dmg #{(0...RB.robots).map { |r| RB.damage(r) }} restarts #{(0...RB.robots).map { |r| RB.restarts(r) }} failed #{(0...RB.robots).map { |r| RB.failed?(r) }}" if ENV["RB_VERBOSE"]?
  {label, RB.cycles}.should eq({label, field.cycles.to_i32})
  {label, rb_frame}.should eq({label, up_frame(field.frames.last)})
  field.robots.each_with_index do |r, i|
    {label, i, RB.robot_cycles(i), RB.restarts(i), RB.active?(i), RB.failed?(i)}.should eq(
      {label, i, r.cycles.to_i32, r.restarts, r.active, !r.error.nil?})
    if (e = r.error)
      # upstream joins every checker problem with "; "; the badge keeps the first
      # and says "Cannot reduce MainHead at 1:1" where upstream prints the glyph string
      mine = String.new(RB.msg(i), RB.msg_len(i))
      theirs = e.split("; ")[0]
      theirs = theirs.sub(/ \(([A-Za-z]+)\) in .* at /) { " at " }.sub(/Cannot reduce \S+/, "Cannot reduce") if theirs.starts_with?("Cannot reduce")
      mine = mine.sub(/Cannot reduce \S+/, "Cannot reduce")
      {label, i, mine}.should eq({label, i, theirs})
    end
  end
end

describe "RB battle" do
  it "has upstream's trig table, random numbers and integer math" do
    91.times { |d| RB.trig(d).should eq CrystalRobots::Battle::TRIG_TBL[d] }
    (-400..400).each do |d|
      RB.lsin(d).should eq CrystalRobots::Battle.lsin(d)
      RB.lcos(d).should eq CrystalRobots::Battle.lcos(d)
      RB.normalize(d * 997).should eq CrystalRobots::Battle.normalize(d * 997)
    end
    rng = Random.new(42_u64)
    RB.seed(42_u64)
    [1, 2, 3, 4, 7, 360, 1000, 5000, 65536, 1 << 30, Int32::MAX].each do |lim|
      20.times { RB.rand(lim).should eq rng.rand(lim) }
    end
    [-7, 7, 0, 1, -1, Int32::MIN + 1, 13, -13, 100].each do |a|
      [-7, 7, 1, 3, -3, 10, 360].each do |b|
        RB.fdiv(a, b).should eq a // b
        RB.fmod(a, b).should eq a % b
      end
    end
    [0, 1, 2, 3, 4, 99, 100, 101, -50, 1 << 30, Int32::MAX, Int32::MIN].each do |n|
      RB.isqrt(n).should eq Math.isqrt(n.to_i64.abs).to_i32
    end
  end

  it "plays every pair of upstream robots exactly like upstream" do
    names = %w(counter rabbit rook sniper target circler dodger hunter turret wallhugger)
    names.each_with_index do |a, i|
      names.each_with_index do |b, j|
        same_battle([a, b], i * 10 + j + 1, 60_000) if j > i
      end
    end
  end

  it "plays full four-robot matches exactly like upstream" do
    [%w(sniper rook counter hunter), %w(circler dodger turret wallhugger),
     %w(rabbit target sniper hunter)].each_with_index do |four, k|
      same_battle(four, k + 7, 500_000)
    end
  end

  it "handles runtime errors, recursion, strings and top-level code like upstream" do
    same_battle(%w(faulty sniper), 3, 60_000)
    same_battle(%w(deep rook), 4, 60_000)
    same_battle(%w(chatty counter lazy), 5, 200_000)
    same_battle(%w(lazy faulty deep chatty), 6, 200_000)
  end

  it "plays the same match when built like the badge (--prelude=empty)" do
    bin = File.tempname("rb_empty")
    st = Process.run("crystal", ["build", "--prelude=empty", "#{__DIR__}/robots/empty_prelude.cr", "-o", bin],
      output: STDOUT, error: STDERR)
    st.success?.should be_true
    begin
      [{ %w(sniper rook counter rabbit), 7 }, { %w(sniper target counter rook), 11 }, { %w(rabbit sniper), 3 }].each do |(names, seed)|
        files = names.map { |n| corpus.find { |(f, _)| f.starts_with?(n) }.not_nil![0] }
        paths = files.map { |f| f.ends_with?(".md") ? "" : "#{UPSTREAM}/examples/#{f}" }
        next if paths.includes?("") # .md robots are tested in-process only
        out = `#{bin} #{seed} 500000 #{paths.join(' ')}`
        names.each_with_index { |n, r| RB.load(r, robot_source(n).to_unsafe, robot_source(n).bytesize) }
        RB.start(names.size, seed.to_u64, 500_000)
        RB.run
        expect = String.build do |io|
          io << "cycles " << RB.cycles << " winner " << RB.winner << '\n'
          names.size.times do |r|
            io << "robot " << r << " damage " << RB.damage(r) << " x " << RB.x(r) << " y " << RB.y(r)
            io << " restarts " << RB.restarts(r) << " cycles " << RB.robot_cycles(r) << " failed "
            io << (RB.failed?(r) ? 1 : 0) << " msg " << String.new(RB.msg(r), RB.msg_len(r)) << '\n'
          end
        end
        out.should eq expect
      end
    ensure
      File.delete?(bin)
    end
  end

  it "sits out robots that do not parse or check, with upstream's message" do
    EXTRA_ROBOTS["broken"] = "main(\"B\") do\n  x = 1 +\nend\n"
    EXTRA_ROBOTS["unchecked"] = "def f(a)\nend\nmain(\"U\") do\n  f\n  y += 1\n  break\nend\n"
    same_battle(%w(broken rook), 1, 30_000)
    same_battle(%w(unchecked broken counter), 2, 30_000)
  end
end
