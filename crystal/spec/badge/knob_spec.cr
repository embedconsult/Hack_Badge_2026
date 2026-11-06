require "../spec_helper"

describe Badge::Knob do
  describe ".counts_from_mv" do
    it "maps 10%..90% of 3.3 V onto 0..4095" do
      Badge::Knob.counts_from_mv(330).should eq 0
      Badge::Knob.counts_from_mv(1650).should eq 2048 # mid-scale = 180 degrees
      Badge::Knob.counts_from_mv(990).should eq 1024  # 90 degrees
      Badge::Knob.counts_from_mv(2969).should eq 4094
      Badge::Knob.counts_from_mv(2970).should eq 4095 # clamped (360 == 0)
    end

    it "clamps outside the endpoints" do
      Badge::Knob.counts_from_mv(0).should eq 0
      Badge::Knob.counts_from_mv(3300).should eq 4095
    end

    it "supports custom and reversed endpoints" do
      Badge::Knob.counts_from_mv(1000, 0, 4096).should eq 1000
      Badge::Knob.counts_from_mv(2970, 2970, 330).should eq 0
      Badge::Knob.counts_from_mv(990, 2970, 330).should eq 3072
      Badge::Knob.counts_from_mv(5, 7, 7).should eq 0
    end
  end

  it "converts counts to degrees" do
    Badge::Knob.counts_to_degrees(1024).should eq 90.0_f32
    Badge::Knob.counts_to_decidegrees(2048).should eq 1800
    Badge::Knob.counts_to_decidegrees(4095).should eq 3599
  end

  it "computes signed wraparound deltas" do
    Badge::Knob.wrap_delta(10, 4090).should eq 16
    Badge::Knob.wrap_delta(4090, 10).should eq -16
    Badge::Knob.wrap_delta(2047, 0).should eq 2047
    Badge::Knob.wrap_delta(2048, 0).should eq -2048
    Badge::Knob.wrap_delta(100, 100).should eq 0
  end

  it "reads the ADC on SAO1 GPIO1 / SAO3 GPIO1" do
    mock = Badge::HAL::Mock.new
    k1 = Badge::Knob.knob1(mock)
    k2 = Badge::Knob.knob2(mock)
    mock.adc_pins.should eq [2, 7]
    mock.set_adc_mv(2, 990)
    mock.set_adc_uv(7, 1_650_400)
    k1.update.should eq 1024
    k2.update.should eq 2048
    k1.raw_mv.should eq 990
    k1.degrees.should eq 90.0_f32
    k2.decidegrees.should eq 1800
  end

  it "smooths readings with an EMA" do
    mock = Badge::HAL::Mock.new
    k = Badge::Knob.new(mock, 2)
    k.feed(1000).should eq 1000
    k.feed(1400).should eq 1100 # 1/4 of the step
    k.feed(1400).should eq 1175
    40.times { k.feed(1400) }
    k.angle.should eq 1400
  end

  it "smooths across the 4095/0 wrap the short way" do
    mock = Badge::HAL::Mock.new
    k = Badge::Knob.new(mock, 2)
    k.feed(4080)
    k.feed(16).should eq 4088 # +32 counts / 4, not toward 2048
    10.times { k.feed(16) }
    k.angle.should be < 20
  end

  it "passes readings straight through with smoothing 0" do
    k = Badge::Knob.new(Badge::HAL::Mock.new, 2)
    k.smoothing = 0
    k.feed(10)
    k.feed(3000).should eq 3000
  end

  it "reports deltas with a deadband that doesn't lose slow turns" do
    k = Badge::Knob.new(Badge::HAL::Mock.new, 2)
    k.smoothing = 0
    k.feed(100)
    k.delta.should eq 0 # reference
    k.feed(102)
    k.delta.should eq 0 # within deadband of 3
    k.feed(104)
    k.delta.should eq 4 # accumulated from 100
    k.feed(4090)
    k.delta.should eq -110 # backwards through zero
    k.feed(20)
    k.delta.should eq 26 # forwards through zero
    k.reset_delta
    k.feed(500)
    k.delta.should eq 0
  end
end
