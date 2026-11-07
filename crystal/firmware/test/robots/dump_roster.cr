# Writes the built-in robots (src/robots/roster.cr) to <dir>/<name>.cr, for
# host tests that need them as files (test/robots/tourney.sh, test/robonet/).
#   crystal run test/robots/dump_roster.cr -- <dir>
require "../../src/robots/roster"

dir = ARGV[0]? || "."
Dir.mkdir_p(dir)
Roster::COUNT.times { |i| File.write(File.join(dir, "#{Roster.file(i)}.cr"), Roster.source(i)) }
