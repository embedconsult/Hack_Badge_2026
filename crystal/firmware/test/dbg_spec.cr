require "spec"
require "../src/dbg"

private def cat(w : String) : Int32
  Dbg.category(w.to_unsafe, w.bytesize)
end

describe Dbg do
  it "starts with every chatty log off" do
    Dbg.mask.should eq 0
    Dbg.on?(Dbg::KNOB).should be_false
    Dbg.on?(Dbg::FRAME).should be_false
    Dbg.on?(Dbg::IDF).should be_false
  end

  it "turns one category on and off without touching the others" do
    Dbg.set(Dbg::KNOB, true)
    Dbg.on?(Dbg::KNOB).should be_true
    Dbg.on?(Dbg::FRAME).should be_false
    Dbg.set(Dbg::FRAME, true)
    Dbg.set(Dbg::KNOB, false)
    Dbg.mask.should eq Dbg::FRAME
    Dbg.set(Dbg::ALL, false)
    Dbg.mask.should eq 0
  end

  it "maps the shell words to categories" do
    cat("knob").should eq Dbg::KNOB
    cat("frame").should eq Dbg::FRAME
    cat("idf").should eq Dbg::IDF
    cat("all").should eq Dbg::ALL
    cat("kno").should eq 0
    cat("knobs").should eq 0
    cat("").should eq 0
  end
end
