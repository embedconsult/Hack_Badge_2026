# The SNAKES referee loop on the host: the Crystal rules engine and house
# snake (src/games/) with main/snakes.c's HTTP client, against the example
# bot. Run by run.sh (it starts the bots and builds bin/*.o):
#   crystal run arena_host.cr -- <port of bot A> <port of bot B>
# Plays a house + bot game, a bot vs bot game and a 4-snake game to the
# end, checking that every bot answered every turn in time.
require "../shim"
require "../../src/games/snakes_house"

@[Link(ldflags: "#{__DIR__}/bin/snakes.o #{__DIR__}/bin/cJSON.o -lm")]
lib LibSnk
  fun snk_session_alloc(s : Void*, alloc : Int32 -> Void*) : Bool
  fun snk_session_reset(s : Void*, n : Int32, seed : UInt32) : Void
  fun snk_session_set(s : Void*, i : Int32, name : UInt8*, url : UInt8*) : Void
  fun snk_session_resolve(s : Void*) : Void
  fun snk_session_call(s : Void*, ep : UInt8*, snap : Int32*, n : Int32, timeout : Int32) : Int32
  fun snk_host_move(s : Void*, i : Int32) : Int32
  fun snk_host_err(s : Void*, i : Int32) : Int32
  fun snk_host_ms(s : Void*, i : Int32) : Int32
  fun snk_host_size : Int32
  fun calloc(n : LibC::SizeT, m : LibC::SizeT) : Void*
  fun snk_league_reset(l : Void*) : Void
  fun snk_league_game(l : Void*, n : Int32, name : UInt8**, score : Int32*) : Void
  fun snk_league_text(l : Void*, out : UInt8*, n : Int32) : Int32
end

ports = ARGV.map(&.to_i)
abort "usage: arena_host.cr <port A> <port B>" if ports.size < 2
S = LibSnk.calloc(1, LibSnk.snk_host_size)
LibSnk.snk_session_alloc(S, ->(n : Int32) { LibSnk.calloc(1, n) }) || abort "alloc"

SNAP = Pointer(Int32).malloc(1024)
failures = 0

# entries: nil = house snake, else a bot port
def play(entries : Array(Int32?), seed : UInt32) : {Int32, Int32, Int32}
  n = entries.size
  LibSnk.snk_session_reset(S, n, seed)
  entries.each_with_index do |port, i|
    if port
      LibSnk.snk_session_set(S, i, "bot#{i}", "http://127.0.0.1:#{port}")
    else
      LibSnk.snk_session_set(S, i, "house", Pointer(UInt8).null)
    end
  end
  LibSnk.snk_session_resolve(S)
  SnakeRules.food_on = true
  SnakeRules.new_game(n, seed) || abort "new_game"
  k = SnakeRules.snapshot(SNAP, 1024)
  LibSnk.snk_session_call(S, "start", SNAP, k, 1000)
  moves = Pointer(Int32).malloc(SnakeRules::MAX)
  missed = 0
  slowest = 0
  until SnakeRules.over? || SnakeRules.turn >= 500
    k = SnakeRules.snapshot(SNAP, 1024)
    asked = LibSnk.snk_session_call(S, "move", SNAP, k, 500)
    n.times do |i|
      next unless SnakeRules.alive?(i)
      if entries[i]
        m = LibSnk.snk_host_move(S, i)
        if m < 0
          missed += 1
          STDERR.puts "turn #{SnakeRules.turn}: bot #{i} gave no move (err #{LibSnk.snk_host_err(S, i)})"
        end
        slowest = {slowest, LibSnk.snk_host_ms(S, i)}.max
        moves[i] = m
      else
        moves[i] = SnakeHouse.choose(i)
      end
    end
    SnakeRules.step(moves)
  end
  k = SnakeRules.snapshot(SNAP, 1024)
  LibSnk.snk_session_call(S, "end", SNAP, k, 500)
  {SnakeRules.turn, missed, slowest}
end

games = [
  {[nil, ports[0]] of Int32?, "house vs bot"},
  {[ports[0], ports[1]] of Int32?, "bot vs bot"},
  {[nil, ports[0], nil, ports[1]] of Int32?, "house, bot, house, bot"},
]
games.each_with_index do |(entries, label), g|
  turns, missed, slowest = play(entries, (g + 7).to_u32)
  w = SnakeRules.winner
  who = w < 0 ? "draw" : (entries[w] ? "bot#{w}" : "house#{w}")
  puts "arena_host: #{label}: #{turns} turns, winner #{who}, #{missed} missed moves, slowest answer #{slowest} ms"
  failures += 1 if missed > 0 || turns < 5 || !SnakeRules.over? && turns < 500
end
# a small league as `snakes league 4` plays it: both bots and the house
# snake every game, scores as src/apps/snakes.cr (alive: 100000 + length,
# else the turn it went out), into main/snakes.c's Elo table
league = LibSnk.calloc(1, 4096)
LibSnk.snk_league_reset(league)
names = ["house", "botA", "botB"]
4.times do |g|
  entries = [nil, ports[0], ports[1]] of Int32?
  turns, missed, _ = play(entries, (g + 100).to_u32)
  scores = (0...3).map { |i| SnakeRules.alive?(i) ? 100_000 + SnakeRules.length(i) : SnakeRules.out_turn(i) }
  ptrs = names.map(&.to_unsafe)
  LibSnk.snk_league_game(league, 3, ptrs.to_unsafe, scores.to_unsafe)
  failures += 1 if missed > 0
end
text = Bytes.new(1024)
LibSnk.snk_league_text(league, text.to_unsafe, 1024)
table = String.new(text.to_unsafe)
puts table
failures += 1 unless table.includes?("4 games") && names.all? { |n| table.includes?(n) }
elos = table.lines[2..].map { |l| l.split[2].to_i }
failures += 1 unless (elos.sum - 1500 * 3).abs <= 3 # zero-sum
puts failures == 0 ? "arena_host: ok" : "arena_host: #{failures} FAILED"
exit(failures == 0 ? 0 : 1)
