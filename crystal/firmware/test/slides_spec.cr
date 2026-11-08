require "spec"
require "../src/games/slide_deck"
require "../slides/slidec"

private SLIDES = File.expand_path("../slides", __DIR__)
private MAIN   = File.expand_path("../main", __DIR__)

private def font : Bytes
  SlideC.font(File.read(File.join(MAIN, "font5x7.h")))
end

private def ink(p : UInt8*) : Int32
  n = 0
  Games::PLANE.times { |i| n += p[i].popcount }
  n
end

private def md_deck : String
  <<-MD
  # First slide
  - one
  * two
  ---
  # Second
  A paragraph with “quotes” — and an arrow →.
  ![A crayon](https://example.com/crayon.png)
  ---

  MD
end

describe SlideDeck do
  it "steps and clamps at both ends" do
    SlideDeck.step(0, 1, 5).should eq 1
    SlideDeck.step(4, 1, 5).should eq 4
    SlideDeck.step(0, -1, 5).should eq 0
    SlideDeck.step(2, 7, 5).should eq 4
    SlideDeck.step(3, -2, 5).should eq 1
    SlideDeck.step(9, 0, 5).should eq 4 # a stale index after a smaller deck
    SlideDeck.step(0, 1, 0).should eq 0
  end

  it "rejects what isn't a whole deck" do
    good = SlideC.pack(SlideC.from_markdown(md_deck))
    SlideDeck.count(good.to_unsafe, good.size).should eq 2
    SlideDeck.count(good.to_unsafe, good.size - 1).should eq 0
    bad = good.dup
    bad[0] = 'X'.ord.to_u8
    SlideDeck.count(bad.to_unsafe, bad.size).should eq 0
    SlideDeck.count(Pointer(UInt8).null, 0).should eq 0
    black = Pointer(UInt8).malloc(Games::PLANE)
    red = Pointer(UInt8).malloc(Games::PLANE)
    SlideDeck.render(good.to_unsafe, good.size, 2, black, red, font.to_unsafe).should be_false
    ink(black).should eq 0
  end
end

describe SlideC do
  it "turns typography into the font's ASCII" do
    SlideC.ascii("“Hi” — it’s 3 × 4 → 12 · ok…").should eq %("Hi" - it's 3 x 4 -> 12 - ok...)
    SlideC.ascii("a\u{1F600}b").should eq "a?b"
  end

  it "reads body HTML: paragraphs, bullets, line breaks, images" do
    s = SlideC::Slide.new("t")
    SlideC.html(%(<p class="x">One &amp; two</p><ul><li>A<b>B</b></li><li>C</li></ul><div>x<br>y</div><img src="u" alt="Alt &quot;q&quot;">), s)
    s.items.map(&.kind).should eq [SlideC::Kind::Para, SlideC::Kind::Bullet, SlideC::Kind::Bullet, SlideC::Kind::Para]
    s.items.map(&.text).should eq ["One & two", "A B", "C", "x\ny"]
    s.images.should eq [%(Alt "q")]
  end

  it "reads the Markdown form" do
    d = SlideC.from_markdown(md_deck)
    d.size.should eq 2
    d[0].title.should eq "First slide"
    d[0].items.map(&.text).should eq ["one", "two"]
    d[1].items.map(&.text).should eq [%(A paragraph with "quotes" - and an arrow ->.)]
    d[1].images.should eq ["A crayon"]
  end

  it "reads the workshop JSON form, programs included" do
    json = %([{"title":"Cover: sub","type":"cover","image":"u","alt":"pic","notes":"hidden"},
              {"title":"P","program":[{"op":"TAKE","dish":2,"next":2,"empty":0},{"op":"ADD","dish":1,"next":1}]}])
    d = SlideC.from_json(json)
    d[0].title.should eq "Cover"
    d[0].subtitle.should eq "sub"
    d[0].images.should eq ["pic"]
    d[0].items.should be_empty
    d[1].items.map(&.text).should eq ["Step 1: TAKE cup 2, got one -> 2, empty -> STOP", "Step 2: ADD cup 1, next -> 1"]
  end

  it "wraps at word boundaries and splits long words" do
    SlideC.wrap("aa bb cc dd", 5).should eq ["aa bb", "cc dd"]
    SlideC.wrap("abcdefgh", 3).should eq ["abc", "def", "gh"]
    SlideC.wrap("a\nb c", 9).should eq ["a", "b c"]
    SlideC.cut(["aaaa", "bbbb", "cccc"], 2, 4).should eq ["aaaa", "b..."]
  end

  it "shrinks the text to fit and never draws past the content area" do
    long = SlideC::Slide.new("A title long enough to need a second line on the panel")
    40.times { |i| long.items << SlideC::Item.new(SlideC::Kind::Bullet, "Bullet #{i} with several words in it") }
    recs = SlideC.layout(long, 0, 1)
    texts = recs.compact_map(&.as?(SlideC::Text))
    texts.map(&.scale).should contain 2
    texts.any?(&.s.ends_with?("...")).should be_true
    texts.each { |t| (t.y + 7 * t.scale).should be <= SlideC::H }
  end
end

describe "the embedded deck" do
  src = SlideC.default_source(SLIDES)
  slides = SlideC.load(src)
  deck = SlideC.pack(slides)

  it "is up to date: main/slides.bin == convert.cr's output for #{File.basename(src)}" do
    bin = File.read(File.join(MAIN, "slides.bin")).to_slice
    (bin == deck || bin == SlideC.pack(slides, red: true)).should be_true # with or without --red
  end

  it "lays every slide out inside the panel in printable ASCII" do
    slides.each_with_index do |s, i|
      SlideC.layout(s, i, slides.size).each do |r|
        case r
        when SlideC::Text
          r.s.each_byte { |b| (0x20..0x7E).should contain b }
          (r.x + SlideC.text_w(r.s, r.scale)).should be <= SlideC::W
          (r.y + 7 * r.scale).should be <= SlideC::H
        when SlideC::Box, SlideC::Frame
          (r.x + r.w).should be <= SlideC::W
          (r.y + r.h).should be <= SlideC::H
        end
      end
    end
  end

  it "draws every slide, black only unless asked for red" do
    n = SlideDeck.count(deck.to_unsafe, deck.size)
    n.should eq slides.size
    black = Pointer(UInt8).malloc(Games::PLANE)
    red = Pointer(UInt8).malloc(Games::PLANE)
    f = font
    n.times do |i|
      SlideDeck.render(deck.to_unsafe, deck.size, i, black, red, f.to_unsafe).should be_false
      ink(black).should be > 0
      ink(red).should eq 0
    end
    reds = SlideC.pack(slides, red: true)
    SlideDeck.red?(reds.to_unsafe, reds.size, 0).should be_true
    SlideDeck.render(reds.to_unsafe, reds.size, 0, black, red, f.to_unsafe).should be_true
    ink(red).should be > 0
  end
end
