# Packs a slide deck for the badge's Slides app (see slidec.cr):
#
#   cd crystal/firmware
#   crystal run slides/convert.cr -- [--red] [--preview DIR] [SRC [OUT]]
#
# SRC defaults to slides/deck.json (or slides/deck.md if there is no .json),
# OUT to main/slides.bin, which the firmware embeds. --preview DIR also
# writes DIR/slide-NN.png, each slide as the badge draws it (same player
# code, src/games/slide_deck.cr). test/slides_spec.cr fails while
# main/slides.bin is out of date with the deck.

require "../src/games/slide_deck"
require "./slidec"

here = File.dirname(__FILE__)
red = false
preview = nil
args = [] of String
it = ARGV.each
while (a = it.next) != Iterator::Stop::INSTANCE
  case a
  when "--red"     then red = true
  when "--preview" then preview = it.next.as?(String) || abort("slides: --preview needs a directory")
  else                  args << a.as(String)
  end
end
src = args[0]? || SlideC.default_source(here)
dst = args[1]? || File.expand_path(File.join(here, "..", "main", "slides.bin"))

deck = SlideC.convert(src, red)
File.write(dst, deck)
n = SlideDeck.count(deck.to_unsafe, deck.size)
puts "slides: #{n} slides, #{deck.size} bytes -> #{dst}"

if dir = preview
  Dir.mkdir_p(dir)
  font = SlideC.font(File.read(File.join(here, "..", "main", "font5x7.h")))
  black = Pointer(UInt8).malloc(Games::PLANE)
  red_p = Pointer(UInt8).malloc(Games::PLANE)
  n.times do |i|
    SlideDeck.render(deck.to_unsafe, deck.size, i, black, red_p, font.to_unsafe)
    path = File.join(dir, "slide-%02d.png" % (i + 1))
    File.open(path, "w") { |f| SlideC.png(f, black, red_p) }
  end
  puts "slides: previews in #{dir}"
end
