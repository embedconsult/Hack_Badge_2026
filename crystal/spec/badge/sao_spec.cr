require "../spec_helper"

describe Badge::Sao do
  it "sets up the shared I2C bus at 400 kHz on GPIO18/17" do
    mock = Badge::HAL::Mock.new
    Badge::Sao.init_bus(mock)
    mock.i2c_config[0].should eq({18, 17, 400_000})
  end

  it "knows each port's GPIOs" do
    mock = Badge::HAL::Mock.new
    {Badge::Sao.sao1(mock), Badge::Sao.sao2(mock), Badge::Sao.sao3(mock)}.map { |s| {s.gpio1, s.gpio2} }
      .should eq({ {2, 42}, {4, 5}, {7, 6} })
  end

  it "refuses transfers until an address is set" do
    mock = Badge::HAL::Mock.new
    sao = Badge::Sao.sao1(mock)
    sao.read(Bytes.new(2)).should eq Badge::Sao::NO_ADDRESS
    sao.write(Bytes[1]).should eq Badge::Sao::NO_ADDRESS
    mock.i2c_log.should be_empty
  end

  it "uses the address it was given (not 0, unlike the original set_address)" do
    mock = Badge::HAL::Mock.new
    mock.add_i2c_device(0x36, Bytes[0x0A, 0xBC])
    sao = Badge::Sao.sao1(mock)
    (sao.address = 0x36).should be_true
    sao.address.should eq 0x36
    sao.write(Bytes[0x0E]).should eq 1
    buf = Bytes.new(2)
    sao.read(buf).should eq 2
    buf.should eq Bytes[0x0A, 0xBC]
    mock.i2c_log.map(&.addr).uniq.should eq [0x36]
  end

  it "rejects addresses outside 7 bits" do
    sao = Badge::Sao.sao2(Badge::HAL::Mock.new)
    (sao.address = 0x80).should be_false
    (sao.address = -1).should be_false
    sao.address.should be_nil
  end

  it "reads registers with a repeated start and reports NACKs" do
    mock = Badge::HAL::Mock.new
    mock.add_i2c_device(0x36, Bytes[0x01, 0x23])
    sao = Badge::Sao.sao3(mock)
    sao.address = 0x36
    buf = Bytes.new(2)
    sao.read_reg(0x0E_u8, buf).should eq 2
    mock.i2c_log[0].data.should eq Bytes[0x0E]
    mock.i2c_log[0].stop.should be_false
    mock.i2c_log[1].read.should be_true
    sao.address = 0x40
    sao.read_reg(0x0E_u8, buf).should eq Badge::HAL::ENODEV
  end
end

describe Badge::BoardIO do
  it "drives the active-low status LED and reads the divided supply" do
    mock = Badge::HAL::Mock.new
    board = Badge::BoardIO.new(mock)
    mock.levels[1].should be_true # off at boot
    board.status_led = true
    mock.levels[1].should be_false
    mock.set_adc_mv(14, 2100)
    board.regulator_input_mv.should eq 4200
  end
end

describe Badge::HAL do
  it "computes wrapping tick differences" do
    Badge::HAL.ticks_diff(5_u32, UInt32::MAX - 4).should eq 10
    Badge::HAL.ticks_diff(0_u32, 10_u32).should eq -10
  end

  it "mock reads inputs high by default and follows scripts" do
    mock = Badge::HAL::Mock.new
    mock.gpio_read(12).should be_true
    mock.script_input(12, [false, true])
    mock.gpio_read(12).should be_false
    mock.gpio_read(12).should be_true
    mock.gpio_read(12).should be_true
  end
end
