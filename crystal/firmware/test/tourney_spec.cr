# Host specs for robot tournaments (src/robots/tourney.cr) with the badge's
# battle engine and its built-in robots.
#   crystal spec crystal/firmware/test/tourney_spec.cr
require "spec"
require "./shim"
require "../src/robots/battle"
require "../src/robots/roster"
require "../src/robots/tourney"

# A tournament of the built-ins idx (roster indices); returns every battle's
# (robots, winner) and leaves Tour holding the result.
def play_tourney(robots : Array(Int32), seed : UInt32, seeds : Int32)
  Tour.setup(robots.size, seed, seeds).should be_true
  idx = Pointer(Int32).malloc(4)
  log = [] of {Array(Int32), Int32, Array(Int32)}
  Tour.battles.times do |k|
    m = Tour.lineup(k, idx)
    lineup = (0...m).map { |r| idx[r] }
    lineup.each_with_index do |i, r|
      s = Roster.source(robots[i])
      RB.load(r, s.to_unsafe, s.bytesize).should be_true
      Tour.set_name(i, RC.name(r), RC.name_len(r)) if Tour.name_len(i) == 0
    end
    RB.start(m, Tour.seed_of(k).to_u64!, RB::CYCLE_LIMIT)
    RB.run
    log << {lineup, RB.winner, (0...m).map { |r| Tour.taken(r) }}
    Tour.record(m, idx)
  end
  m = Tour.final_lineup(idx)
  m.times do |r|
    s = Roster.source(robots[idx[r]])
    RB.load(r, s.to_unsafe, s.bytesize)
  end
  RB.start(m, Tour.final_seed.to_u64!, RB::CYCLE_LIMIT)
  RB.run
  Tour.record_final(m, idx)
  log
end

describe "Tour schedule" do
  it "puts every robot in one group per round and lets every pair meet" do
    (2..Tour::MAX).each do |n|
      Tour.setup(n, 7_u32, 1).should be_true
      idx = Pointer(Int32).malloc(4)
      seen = Array.new(n) { 0 }
      Tour.battles.times do |k|
        m = Tour.lineup(k, idx)
        m.should be >= 2
        m.should be <= 4
        (0...m).map { |r| idx[r] }.uniq.size.should eq m
        (0...m).each { |r| seen[idx[r]] += 1 }
      end
      seen.uniq.should eq [Tour.rounds] # one group per robot per round
      n.times { |a| n.times { |b| Tour.met(a, b).should be > 0 if a != b } }
      lower = Math.max(1, (n - 1 + 2) // 3) # every robot meets <= 3 others a round
      Tour.rounds.should be <= lower * 2 + 1
    end
  end

  it "rotates the robot order across seeds and gives each battle its own seed" do
    Tour.setup(4, 1_u32, 3)
    idx = Pointer(Int32).malloc(4)
    orders = (0...3).map { |k| Tour.lineup(k, idx); (0...4).map { |r| idx[r] } }
    orders.uniq.size.should eq 3
    orders.map(&.sort).uniq.size.should eq 1
    (0...Tour.battles).map { |k| Tour.seed_of(k) }.uniq.size.should eq Tour.battles
  end

  it "is the same schedule for the same robots and seed" do
    a = [] of Int32
    b = [] of Int32
    idx = Pointer(Int32).malloc(4)
    {a, b}.each do |dst|
      Tour.setup(18, 99_u32, 2)
      Tour.battles.times { |k| m = Tour.lineup(k, idx); m.times { |r| dst << idx[r] }; dst << Tour.seed_of(k).to_i32! }
    end
    a.should eq b
    Tour.setup(18, 100_u32, 2)
    c = [] of Int32
    Tour.battles.times { |k| m = Tour.lineup(k, idx); m.times { |r| c << idx[r] } }
    c.should_not eq a[0, c.size]
  end
end

describe "Tour results" do
  it "scores every battle: 3 for the sole survivor, 1 each for survivors at the limit" do
    robots = (0...Roster::COUNT).to_a
    log = play_tourney(robots, 42_u32, 2)
    pts = Array.new(robots.size) { 0 }
    wins = Array.new(robots.size) { 0 }
    played = Array.new(robots.size) { 0 }
    dmg = Array.new(robots.size) { 0 }
    log.each do |lineup, w, taken|
      lineup.each_with_index do |i, r|
        played[i] += 1
        dmg[i] += taken[r]
        if r == w
          wins[i] += 1
          pts[i] += 3
        end
      end
    end
    robots.size.times do |i|
      Tour.wins(i).should eq wins[i]
      Tour.played(i).should eq played[i]
      Tour.damage_sum(i).should eq dmg[i]
      Tour.points(i).should eq wins[i] * 3 + Tour.draws(i)
      Tour.points(i).should be >= pts[i]
    end
    # ranking is sorted
    (0...robots.size - 1).each do |k|
      a = Tour.at_rank(k)
      b = Tour.at_rank(k + 1)
      Tour.better?(a, b).should be_true
    end
    # the target never wins; names come from main("...")
    t = robots.index(9).not_nil!
    Tour.wins(t).should eq 0
    String.new(Tour.name(t), Tour.name_len(t)).should eq "Target"
    Tour.finalists.should eq 4
    Tour.final_done?.should be_true
    (0...4).map { |k| Tour.finalist(k) }.should eq (0...4).map { |k| Tour.at_rank(k) }
  end

  it "plays the same tournament again (hash, standings, champion)" do
    robots = [0, 1, 4, 5, 6, 9]
    play_tourney(robots, 5_u32, 2)
    h = Tour.hash
    table = (0...robots.size).map { |k| i = Tour.at_rank(k); {i, Tour.points(i), Tour.damage_sum(i)} }
    champ = Tour.champion
    play_tourney(robots, 5_u32, 2)
    Tour.hash.should eq h
    (0...robots.size).map { |k| i = Tour.at_rank(k); {i, Tour.points(i), Tour.damage_sum(i)} }.should eq table
    Tour.champion.should eq champ
    play_tourney(robots, 6_u32, 2)
    Tour.hash.should_not eq h
  end

  it "keeps a robot that does not compile in, with full damage" do
    Tour.setup(3, 3_u32, 1)
    idx = Pointer(Int32).malloc(4)
    m = Tour.lineup(0, idx)
    m.should eq 3
    bad = "main(\"Bad\") do\n  drive(\n"
    m.times do |r|
      if idx[r] == 2
        RB.load(r, bad.to_unsafe, bad.bytesize).should be_false
      else
        s = Roster.source(idx[r])
        RB.load(r, s.to_unsafe, s.bytesize)
      end
    end
    RB.start(m, Tour.seed_of(0).to_u64!, RB::CYCLE_LIMIT)
    RB.run
    Tour.record(m, idx)
    Tour.damage_sum(2).should eq 100
    Tour.wins(2).should eq 0
  end

  it "saves and loads the standings" do
    robots = (0...Roster::COUNT).to_a
    play_tourney(robots, 11_u32, 1)
    buf = Pointer(UInt8).malloc(Tour.blob_size(robots.size))
    n = Tour.save(buf, 1)
    n.should eq Tour::HDR + robots.size * Tour::ENTRY
    want = (0...robots.size).map do |k|
      i = Tour.at_rank(k)
      {String.new(Tour.name(i), Tour.name_len(i)), Tour.wins(i), Tour.draws(i), Tour.played(i), Tour.points(i), Tour.damage_sum(i)}
    end
    champ = Tour.champion
    champ_name = String.new(Tour.name(champ), Tour.name_len(champ))
    battles = Tour.done
    h = Tour.hash
    Tour.setup(2, 1_u32, 1) # forget
    Tour.load(buf, n).should eq 1
    Tour.robots.should eq robots.size
    Tour.done.should eq battles
    Tour.hash.should eq h
    (0...robots.size).map do |k|
      Tour.at_rank(k).should eq k
      {String.new(Tour.name(k), Tour.name_len(k)), Tour.wins(k), Tour.draws(k), Tour.played(k), Tour.points(k), Tour.damage_sum(k)}
    end.should eq want
    c = Tour.champion
    String.new(Tour.name(c), Tour.name_len(c)).should eq champ_name
    Tour.load(buf, n - 1).should eq -1
    buf[0] = 0_u8
    Tour.load(buf, n).should eq -1
  end
end
