# Host specs for the badge robot engine (src/robots/), differential against
# upstream crystal-robots (fetched by test/robots/upstream.sh):
#
#   crystal/firmware/test/robots/upstream.sh
#   crystal spec crystal/firmware/test/robots_spec.cr
require "spec"
require "./shim"
require "./robots/upstream/src/compiler"
require "../src/robots/lang"

UPSTREAM = "#{__DIR__}/robots/upstream"

# Upstream rule symbol for each RL::R_* id.
RULE_NAMES = %w(lex main_head def_head global literal call0 call call1 call2 paren neg
  mul add cmp eq and or command1 command2 assign opassign if_head elsif_head
  while_head until_head case_head when_head return break exprstmt if while until
  case def main program)

# Every robot upstream ships: examples/*.cr and the code block of robots/*.md.
def corpus : Array({String, String})
  list = [] of {String, String}
  Dir.glob("#{UPSTREAM}/examples/*.cr").sort.each { |f| list << {File.basename(f), File.read(f)} }
  Dir.glob("#{UPSTREAM}/robots/*.md").sort.each do |f|
    if (m = File.read(f).match(/```crystal\n(.*?)```/m))
      list << {File.basename(f), m[1]}
    end
  end
  list
end

def rl_parse(src : String) : Bool
  RL.parse(src.to_unsafe, src.bytesize)
end

def rl_error : String
  String.new(RL.error, RL.error_len)
end

# S-expression of an RL tree: (rule kids...) with leaves as their text.
def rl_tree(i : Int32, io : IO) : Nil
  if RL.leaf?(i)
    io << String.new(RL.src + RL.start(i), RL.length(i)).inspect
  else
    io << '(' << RULE_NAMES[RL.rule(i)]
    RL.nkids(i).times { |k| io << ' '; rl_tree(RL.kid(i, k), io) }
    io << ')'
  end
end

def up_tree(p : CrystalRobots::Compiler::Program, i : Int32, io : IO) : Nil
  n = p[i]
  if n.level == 0
    io << p.value(n).inspect
  else
    io << '(' << n.rule
    p.children(i).each { |k| io << ' '; up_tree(p, k, io) }
    io << ')'
  end
end

# Compare RL against upstream on one source: same accept/reject, same
# derivation (rule and glyph count of every pass), same tree, and on a
# reject the same error location.
def same_parse(src : String, label : String = "") : Nil
  prog = CrystalRobots::Compiler::Program.new(src)
  err = CrystalRobots::Compiler::Parser.try_parse(prog)
  ok = rl_parse(src)
  if err
    fail "#{label}: upstream rejects (#{err.message}) but RL accepts" if ok
    loc = err.message.to_s.match(/ at (\d+):(\d+)\z/).not_nil!
    rl_loc = rl_error.match(/ at (\d+):(\d+)\z/)
    fail "#{label}: RL error #{rl_error.inspect} has no location (upstream #{err.message})" unless rl_loc
    {rl_loc[1], rl_loc[2]}.should eq({loc[1], loc[2]})
    return
  end
  fail "#{label}: RL rejects (#{rl_error}) but upstream accepts" unless ok
  RL.passes.should eq prog.passes
  prog.passes.times do |k|
    {k, RULE_NAMES[RL.pass_rule(k)], RL.pass_size(k)}.should eq({k, prog.rules[k].to_s, prog.layers[k].size})
  end
  a = String.build { |io| rl_tree(RL.root, io) }
  b = String.build { |io| up_tree(prog, prog.root, io) }
  a.should eq b
end

# Deterministic mutations of a source: drop or duplicate a line, drop one
# character, swap two adjacent lines.
def mutants(src : String, n : Int32, seed : Int32) : Array(String)
  r = Random.new(seed)
  lines = src.lines(chomp: false)
  out = [] of String
  n.times do
    l = lines.dup
    case r.rand(4)
    when 0 then l.delete_at(r.rand(l.size)) if l.size > 1
    when 1 then i = r.rand(l.size); l.insert(i, l[i])
    when 2
      s = l.join
      out << (s.size > 1 ? s.sub(r.rand(s.size), "") : s)
      next
    else
      i = r.rand(l.size - 1 > 0 ? l.size - 1 : 1)
      l.swap(i, i + 1) if i + 1 < l.size
    end
    out << l.join
  end
  out
end

describe "RL parser" do
  it "parses every upstream robot exactly like upstream" do
    corpus.size.should be > 8
    corpus.each { |(name, src)| same_parse(src, name) }
  end

  it "agrees with upstream on small programs and errors" do
    [
      "", "\n\n", "x = 1", "x = 1 + 2 * 3 - 4 / 5 // 6 % 7", "a = -b * -3",
      "puts 1 + 2", "drive angle, 0", "x = scan(10, 2) > 0 && speed == 0 || loc_x < 5",
      "x = 1 ^ 2 | 3 & 4", "y = (1 + 2) * (3 - -4)", "x += 1; y -= 2; z *= 3; w %= 4",
      "main(\"A\") do\n  while true\n  end\nend", "def f\nend", "def g()\nend", "def h(a, b, c)\n  return a\nend",
      "if a\nb = 1\nelsif c\nd = 2\nelse\ne = 3\nend", "case x\nwhen 1\ny = 2\nwhen 2\nelse\ny = 3\nend",
      "until x > 3\nx += 1\nend", "global(g, 5)", "x = f(1, g(2), h)", "x = !y", "x = 1 +", "end",
      "if x\nelse y\nend", "x = \"open", "x = 1 # comment\n# more", "a = b = c", "f(1)(2)",
      "return", "break", "x = rand 4", "puts", "x = true; y = false", "x = 99 $ 1",
      "main(\"A\") do\nputs \"hi\"\nend", "x = sin(30) + cos 60", "x == y", "1 + 2\n3",
      "drive(1, 2, 3)", "def f(1)\nend", "x = (((1)))", "x = - - 1", "x = 1 - -1", "y = a-1",
    ].each { |s| same_parse(s, s.inspect) }
  end

  it "really builds trees" do
    src = File.read("#{UPSTREAM}/examples/sniper.cr")
    rl_parse(src).should be_true
    RL.passes.should be > 20
    String.build { |io| rl_tree(RL.root, io) }.size.should be > 1000
    acc = 0
    rej = 0
    mutants(src, 40, 3).each { |m| rl_parse(m) ? (acc += 1) : (rej += 1) }
    (acc > 5 && rej > 5).should be_true
    rl_parse("x = 1 +").should be_false
    rl_error.should start_with "Cannot reduce"
  end

  it "agrees with upstream on mutated robots" do
    corpus.each_with_index do |(name, src), k|
      mutants(src, 40, k + 1).each_with_index { |m, j| same_parse(m, "#{name} mutant #{j}") }
    end
  end
end
