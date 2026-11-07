# Prints the parse-tree depth of robot files (RC::MAX_DEPTH is the limit):
#   crystal run crystal/firmware/test/robots/depth.cr -- robot.cr ...
require "../shim"
require "../../src/robots/compile"

RC.setup
ARGV.each do |f|
  src = File.read(f)
  if RL.parse(src.to_unsafe, src.bytesize)
    puts "#{RC.tree_depth} #{f}"
  else
    puts "error #{f}: #{String.new(RL.error, RL.error_len)}"
  end
end
