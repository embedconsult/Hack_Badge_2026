# WS2812 pixels on the knob SAOs, driven by the RMT peripheral with a bytes
# encoder (10 MHz resolution: 0 = 0.3 us high + 0.9 us low, 1 = 0.9 + 0.3).
# One TX channel and one encoder per pixel, each pixel on its own GPIO.

lib LibIDF
  struct RmtTxChannelConfig
    gpio_num : Int32
    clk_src : Int32
    resolution_hz : UInt32
    mem_block_symbols : UInt32
    trans_queue_depth : UInt32
    intr_priority : Int32
    flags : UInt32
  end

  struct RmtBytesEncoderConfig
    bit0 : UInt32 # rmt_symbol_word_t: duration0:15 level0:1 duration1:15 level1:1
    bit1 : UInt32
    flags : UInt32 # bit 0 = msb_first
  end

  struct RmtTransmitConfig
    loop_count : Int32
    flags : UInt32
  end

  fun rmt_new_tx_channel(cfg : RmtTxChannelConfig*, chan : Void**) : Int32
  fun rmt_new_bytes_encoder(cfg : RmtBytesEncoderConfig*, enc : Void**) : Int32
  fun rmt_enable(chan : Void*) : Int32
  fun rmt_transmit(chan : Void*, enc : Void*, payload : Void*, n : UInt32, cfg : RmtTransmitConfig*) : Int32
  fun rmt_tx_wait_all_done(chan : Void*, timeout_ms : Int32) : Int32
end

module Pixel
  RMT_CLK_SRC_DEFAULT = 4
  RES_HZ              = 10_000_000_u32

  def self.symbol(d0 : UInt32, l0 : UInt32, d1 : UInt32, l1 : UInt32) : UInt32
    d0 | l0.unsafe_shl(15) | d1.unsafe_shl(16) | l1.unsafe_shl(31)
  end

  # Returns false on error; chan/enc receive the handles.
  def self.open(gpio : Int32, chan : Void**, enc : Void**) : Bool
    cfg = LibIDF::RmtTxChannelConfig.new
    cfg.gpio_num = gpio
    cfg.clk_src = RMT_CLK_SRC_DEFAULT
    cfg.resolution_hz = RES_HZ
    cfg.mem_block_symbols = 48_u32
    cfg.trans_queue_depth = 2_u32
    err = LibIDF.rmt_new_tx_channel(pointerof(cfg), chan)
    if err != 0
      log2("led: rmt_new_tx_channel gpio / err", gpio, err)
      return false
    end
    ecfg = LibIDF::RmtBytesEncoderConfig.new
    ecfg.bit0 = symbol(3_u32, 1_u32, 9_u32, 0_u32)
    ecfg.bit1 = symbol(9_u32, 1_u32, 3_u32, 0_u32)
    ecfg.flags = 1_u32 # WS2812 wants MSB first
    err = LibIDF.rmt_new_bytes_encoder(pointerof(ecfg), enc)
    err = LibIDF.rmt_enable(chan.value) if err == 0
    log2("led: pixel on gpio / err", gpio, err)
    err == 0
  end

  # Blocking send of one pixel with step-by-step logging (bring-up test).
  def self.show_blocking(chan : Void*, enc : Void*, buf : UInt8*, r : UInt8, g : UInt8, b : UInt8) : Int32
    buf[0] = g
    buf[1] = r
    buf[2] = b
    tcfg = LibIDF::RmtTransmitConfig.new
    log("led:   rmt_transmit ...", 0)
    err = LibIDF.rmt_transmit(chan, enc, buf.as(Void*), 3_u32, pointerof(tcfg))
    log("led:   rmt_transmit err", err)
    err = LibIDF.rmt_tx_wait_all_done(chan, 1000)
    log("led:   rmt_tx_wait_all_done(1000 ms) err", err)
    err
  end

  # Sends one GRB pixel from buf (3 bytes, DMA not required).
  def self.show(chan : Void*, enc : Void*, buf : UInt8*, r : UInt8, g : UInt8, b : UInt8) : Nil
    LibIDF.rmt_tx_wait_all_done(chan, 50) # previous frame done; buf free again
    buf[0] = g
    buf[1] = r
    buf[2] = b
    tcfg = LibIDF::RmtTransmitConfig.new
    tcfg.flags = 2_u32 # queue_nonblocking: never stall the knob loop
    LibIDF.rmt_transmit(chan, enc, buf.as(Void*), 3_u32, pointerof(tcfg))
  end

  # Hue 0..1535 (six 256-step sectors) at the given brightness -> r, g, b.
  def self.hue(h : Int32, v : Int32, rgb : UInt8*) : Nil
    sector = h.unsafe_shr(8)
    f = h & 255
    up = (f &* v).unsafe_div(255).to_u8!
    dn = ((255 &- f) &* v).unsafe_div(255).to_u8!
    full = v.to_u8!
    r = 0_u8
    g = 0_u8
    b = 0_u8
    if sector == 0
      r = full; g = up
    elsif sector == 1
      r = dn; g = full
    elsif sector == 2
      g = full; b = up
    elsif sector == 3
      g = dn; b = full
    elsif sector == 4
      r = up; b = full
    else
      r = full; b = dn
    end
    rgb[0] = r
    rgb[1] = g
    rgb[2] = b
  end
end
