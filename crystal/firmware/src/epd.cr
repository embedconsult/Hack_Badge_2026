# E-paper driver for the badge's 9.7" Pervasive Displays iTC panel
# (960x672 black/white/red, two COGs: CS1 = master = left half, CS2 = slave =
# right half).
#
# Primary reference: Hackaday's ESP32-S3 driver
#   2026-Billboard_Badge/firmware/esp32s3-itc97/src/epd97.cpp
# which reads the panel's OTP, detects the two revisions (E2969JS0B1 =
# "driver B", E2969JS084 = "driver 8") and takes its register values from the
# OTP. Fast refresh writes a short waveform to 0xB0. See ../EPD_NOTES.md.
#
# Differences from epd97.cpp (deliberate):
# - Register writes use hardware SPI too; only the OTP read (50 kHz, MOSI
#   turned around) is bitbanged, with the GPIO matrix re-pointed around it.
# - Planes go out per COG (RAM_RW + 0x10/0x11 to one COG, 40,320 bytes, then
#   the other COG), as the PDi reference and the Python driver do, instead
#   of line-interleaved 60-byte polling writes. That allows DMA in large
#   chunks: each chunk is packed from the PSRAM frame buffer into one of two
#   internal DMA buffers while the other one is on the wire.
#
# Frame buffers: 672 rows x 120 bytes, MSB = leftmost pixel, 1 = ink.
# A pixel is the (red, bw) bit pair: red = red bit set and bw bit clear.

lib LibIDF
  struct SpiBusConfig
    mosi_io_num : Int32
    miso_io_num : Int32
    sclk_io_num : Int32
    quadwp_io_num : Int32
    quadhd_io_num : Int32
    data4_io_num : Int32
    data5_io_num : Int32
    data6_io_num : Int32
    data7_io_num : Int32
    data_io_default_level : Bool
    max_transfer_sz : Int32
    flags : UInt32
    isr_cpu_id : Int32
    intr_flags : Int32
  end

  struct SpiDeviceConfig
    command_bits : UInt8
    address_bits : UInt8
    dummy_bits : UInt8
    mode : UInt8
    clock_source : Int32
    duty_cycle_pos : UInt16
    cs_ena_pretrans : UInt16
    cs_ena_posttrans : UInt8
    clock_speed_hz : Int32
    input_delay_ns : Int32
    sample_point : Int32
    spics_io_num : Int32
    flags : UInt32
    queue_size : Int32
    pre_cb : Void*
    post_cb : Void*
  end

  struct SpiTransaction
    flags : UInt32
    cmd : UInt16
    addr : UInt64
    length : UInt32
    rxlength : UInt32
    user : Void*
    tx_buffer : Void*
    rx_buffer : Void*
  end

  fun spi_bus_initialize(host : Int32, cfg : SpiBusConfig*, dma_chan : Int32) : Int32
  fun spi_bus_add_device(host : Int32, cfg : SpiDeviceConfig*, handle : Void**) : Int32
  fun spi_bus_remove_device(handle : Void*) : Int32
  fun spi_device_polling_transmit(handle : Void*, t : SpiTransaction*) : Int32
  fun spi_device_queue_trans(handle : Void*, t : SpiTransaction*, ticks : UInt32) : Int32
  fun spi_device_get_trans_result(handle : Void*, t : SpiTransaction**, ticks : UInt32) : Int32
  fun spi_device_get_actual_freq(handle : Void*, khz : Int32*) : Int32

  fun gpio_get_level(gpio_num : Int32) : Int32
  fun gpio_set_pull_mode(gpio_num : Int32, mode : Int32) : Int32
  fun esp_rom_gpio_connect_out_signal(gpio_num : UInt32, signal_idx : UInt32, out_inv : Bool, oen_inv : Bool) : Void
  fun heap_caps_malloc(size : UInt32, caps : UInt32) : Void*
  fun heap_caps_free(p : Void*) : Void
  fun esp_timer_get_time : Int64
  fun esp_rom_delay_us(us : UInt32) : Void

  # main/main.c
  fun cr_log(msg : UInt8*, v : Int32) : Void
  fun cr_log2(msg : UInt8*, a : Int32, b : Int32) : Void
  fun cr_hex(msg : UInt8*, data : UInt8*, n : Int32) : Void
  fun cr_check_layout(bus : Int32, dev : Int32, trans : Int32) : Int32
end

def log(msg : String, v : Int32) : Nil
  LibIDF.cr_log(msg.to_unsafe, v)
end

def log2(msg : String, a : Int32, b : Int32) : Nil
  LibIDF.cr_log2(msg.to_unsafe, a, b)
end

def millis : Int32
  LibIDF.esp_timer_get_time.unsafe_div(1000_i64).to_i32!
end

def delay_ms(ms : Int32) : Nil
  # CONFIG_FREERTOS_HZ=1000 (sdkconfig.defaults): 1 tick = 1 ms.
  LibIDF.vTaskDelay(ms.to_u32!) if ms > 0
end

module EPD
  CS1   = 13
  CS2   = 3
  BUSY1 = 12
  BUSY2 =  8
  DC    = 10
  RST   = 11
  SCK   = 21
  MOSI  = 47
  PWR   = 48 # EPD_PWR_ENABLE -> gate of Q2 (SK2301 P-FET, high side): LOW = panel powered

  SPI2_HOST          = 1
  SPI_DMA_CH_AUTO    = 3
  GPIO_MODE_INPUT    = 1
  GPIO_MODE_OUTPUT   = 2
  GPIO_PULLDOWN_ONLY = 1
  GPIO_FLOATING      = 3
  SIG_GPIO_OUT_IDX   = 256_u32
  FSPICLK_OUT_IDX    = 101_u32
  FSPID_OUT_IDX      = 103_u32
  MALLOC_CAP_8BIT     = 0x4_u32
  MALLOC_CAP_DMA      = 0x8_u32
  MALLOC_CAP_SPIRAM   = 0x400_u32
  MALLOC_CAP_INTERNAL = 0x800_u32
  PORT_MAX_DELAY      = 0xFFFFFFFF_u32

  WIDTH          = 960
  HEIGHT         = 672
  ROW_BYTES      = 120
  HALF_BYTES     =  60
  PLANE          = 80640
  MAX_CHUNK_ROWS = 272 # 272 * 60 = 16,320 bytes per DMA buffer
  OTP_LEN        =  88
  LUT8_BYTES     = 180
  LUTB_BYTES     = 400

  BOTH  = 0
  LEFT  = 1 # CS1, master
  RIGHT = 2 # CS2, slave

  WHITE = 0
  BLACK = 1
  RED   = 2

  # Timings from include/epd97_config.h (ms)
  T_RST_PWR   = 800
  T_RST_HI    =  50
  T_RST_LO    = 100
  T_RST_SET   = 400
  T_OFF_MIN   = 1500
  T_DISCHARGE =  300
  T_PRE_UPD   =  660
  T_PRE_SS    =  500 # EPD_T_PRE_SS (50) is in 10 ms units in k_upd
  REG45_084   = 0x86_u8
  REG45_B1    = 0x84_u8
  B_REFRESH_PULLS = 3 # epd97.cpp default for driver B fast refresh
  FAST_TIMEOUT_MS = 5_000   # BUSY wait for a fast waveform (~1.2 s per pull)
  SLOW_TIMEOUT_MS = 180_000 # BUSY wait for the OTP waveform (~33 s)

  # Skip uploading an all-zero red plane (0x11) when the last red upload in
  # this open session was all zeros too (~33 ms per frame). Assumes the COG
  # keeps its RAM between refreshes: NEEDS A HARDWARE CHECK; set false if
  # red ghosts appear after fast frames.
  SKIP_ZERO_RED = false

  # Change the fast LUT kind by rewriting 0xB0 inside an open session instead
  # of a ~5 s COG restart. epd97.cpp notes that a rewrite inside a session
  # "drops the panel back onto its own waveform", so this is OFF until it has
  # been tried on the panel.
  REWRITE_LUT_IN_SESSION = false

  @@dev = uninitialized Void*
  @@black = uninitialized UInt8*
  @@red = uninitialized UInt8*
  @@dma0 = uninitialized UInt8*
  @@dma1 = uninitialized UInt8*
  @@small = uninitialized UInt8*
  @@otp = uninitialized UInt8*
  @@lut = uninitialized UInt8*
  @@t0 = uninitialized LibIDF::SpiTransaction
  @@t1 = uninitialized LibIDF::SpiTransaction
  @@ts = uninitialized LibIDF::SpiTransaction
  @@chunk_rows = 68
  @@busy_poll_ms = 1
  @@second_pass_ms = 1000
  @@psram = false
  @@driver_b = false
  @@otp_valid = false
  @@power_off_ms = 0
  @@power_off_valid = false
  @@session_open = false
  @@lut_latched = false
  @@latched_fast = false
  @@prev_has_red = true # unknown at cold boot: assume red, so the first fast refresh runs slow
  @@keep_awake = false
  @@panel_ms = 0
  @@fast_pulls = B_REFRESH_PULLS
  @@lut_kind = 0         # LUT_* kind of the fast waveform (see build_lutb)
  @@latched_kind = 0
  @@upload_ms = 0
  @@probe = -1          # >= 0: probe LUT driving only that table (see build_probe)
  @@latched_probe = -1
  @@raw = false          # send black and red planes as they are (no red-as-ink)
  @@promote = true       # run a fast refresh slow when red is on the panel
  @@spi_fail = false     # an SPI call failed during the current frame
  @@red_zero = false     # COG red RAM known to be all zeros (this session)
  @@abortable = false    # a long BUSY wait may be cut short by request_abort
  @@abort = false

  def self.black : UInt8*
    @@black
  end

  def self.red : UInt8*
    @@red
  end

  def self.driver_b? : Bool
    @@driver_b
  end

  def self.chunk_rows=(n : Int32) : Nil
    n = 1 if n < 1
    @@chunk_rows = n > MAX_CHUNK_ROWS ? MAX_CHUNK_ROWS : n
  end

  def self.keep_awake=(v : Bool) : Nil
    @@keep_awake = v
  end

  def self.second_pass_ms=(v : Int32) : Nil
    @@second_pass_ms = v
  end

  # True if a fast refresh requested now would be run on the slow waveform
  # (red on the panel has to be cleared first).
  def self.fast_runs_slow? : Bool
    @@prev_has_red
  end

  def self.upload_ms : Int32
    @@upload_ms
  end

  def self.panel_ms : Int32
    @@panel_ms
  end

  # Waveform pulls per fast refresh on driver B (1..n). Fewer pulls = faster,
  # but less drive per image, so more ghosting.
  def self.fast_pulls=(n : Int32) : Nil
    @@fast_pulls = n < 1 ? 1 : n
  end

  # ---- setup -----------------------------------------------------------

  def self.out_pin(pin : Int32, level : UInt32) : Nil
    LibIDF.gpio_reset_pin(pin)
    LibIDF.gpio_set_level(pin, level) # latch the level before enabling the driver
    LibIDF.gpio_set_direction(pin, GPIO_MODE_OUTPUT)
    LibIDF.gpio_set_level(pin, level)
  end

  def self.in_pin(pin : Int32) : Nil
    LibIDF.gpio_reset_pin(pin) # input with pull-up
    LibIDF.gpio_set_direction(pin, GPIO_MODE_INPUT)
  end

  def self.zero(p : UInt8*, n : Int32) : Nil
    i = 0
    while i < n
      p[i] = 0_u8
      i = i &+ 1
    end
  end

  def self.alloc_plane : UInt8*
    p = LibIDF.heap_caps_malloc(PLANE.to_u32!, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT).as(UInt8*)
    if p.null?
      p = LibIDF.heap_caps_malloc(PLANE.to_u32!, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT).as(UInt8*)
    else
      @@psram = true
    end
    p
  end

  def self.dma_alloc(n : Int32) : UInt8*
    LibIDF.heap_caps_malloc(n.to_u32!, MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT).as(UInt8*)
  end

  def self.add_device(hz : Int32) : Int32
    dev_cfg = uninitialized LibIDF::SpiDeviceConfig
    zero(pointerof(dev_cfg).as(UInt8*), sizeof(LibIDF::SpiDeviceConfig))
    dev_cfg.mode = 0_u8 # the panel samples on the rising edge
    dev_cfg.clock_speed_hz = hz
    dev_cfg.spics_io_num = -1 # CS1/CS2 are driven by hand
    dev_cfg.queue_size = 2
    err = LibIDF.spi_bus_add_device(SPI2_HOST, pointerof(dev_cfg), pointerof(@@dev))
    if err != 0
      log("EPD: spi_bus_add_device failed, err", err)
      return err
    end
    khz = 0
    LibIDF.spi_device_get_actual_freq(@@dev, pointerof(khz))
    log2("EPD: spi_bus_add_device err / actual kHz", err, khz)
    err
  end

  def self.set_clock(hz : Int32) : Nil
    LibIDF.spi_bus_remove_device(@@dev)
    add_device(hz)
  end

  def self.init(hz : Int32) : Bool
    if LibIDF.cr_check_layout(sizeof(LibIDF::SpiBusConfig), sizeof(LibIDF::SpiDeviceConfig),
         sizeof(LibIDF::SpiTransaction)) != 0
      log("EPD: struct layout mismatch with C, aborting", 0)
      return false
    end

    out_pin(PWR, 1_u32) # panel supply off first; the gate has no pull resistor
    out_pin(DC, 1_u32)
    out_pin(RST, 1_u32)
    out_pin(CS1, 1_u32)
    out_pin(CS2, 1_u32)
    in_pin(BUSY1)
    in_pin(BUSY2)

    bus = uninitialized LibIDF::SpiBusConfig
    zero(pointerof(bus).as(UInt8*), sizeof(LibIDF::SpiBusConfig))
    bus.mosi_io_num = MOSI
    bus.miso_io_num = -1 # GPIO45 is a strapping pin; MISO isn't wired anyway
    bus.sclk_io_num = SCK
    bus.quadwp_io_num = -1
    bus.quadhd_io_num = -1
    bus.data4_io_num = -1
    bus.data5_io_num = -1
    bus.data6_io_num = -1
    bus.data7_io_num = -1
    bus.max_transfer_sz = MAX_CHUNK_ROWS * HALF_BYTES
    err = LibIDF.spi_bus_initialize(SPI2_HOST, pointerof(bus), SPI_DMA_CH_AUTO)
    log("EPD: spi_bus_initialize err", err)
    return false if err != 0
    return false if add_device(hz) != 0

    @@black = alloc_plane
    @@red = alloc_plane
    @@dma0 = dma_alloc(MAX_CHUNK_ROWS * HALF_BYTES)
    @@dma1 = dma_alloc(MAX_CHUNK_ROWS * HALF_BYTES)
    @@small = dma_alloc(64)
    @@lut = dma_alloc(LUTB_BYTES)
    @@otp = dma_alloc(OTP_LEN)
    if @@black.null? || @@red.null? || @@dma0.null? || @@dma1.null? || @@small.null? || @@lut.null? || @@otp.null?
      log("EPD: out of memory", 0)
      return false
    end
    log("EPD: planes in PSRAM (1) or internal RAM (0)", @@psram ? 1 : 0)
    fill(WHITE)

    t0 = millis
    ok = otp_read
    log("EPD: OTP probe ms", millis &- t0)
    if !ok
      cog_stop
      return false
    end
    # Leave the session open: the probe already powered up and reset the COG,
    # so the first refresh only needs the second reset (as in cog_initial).
    second_reset
    @@session_open = true
    @@lut_latched = false
    true
  end

  # ---- drawing (frame buffer coordinates, 960 x 672) --------------------

  def self.fill(color : Int32) : Nil
    bk = color == BLACK ? 0xFF_u8 : 0x00_u8
    rd = color == RED ? 0xFF_u8 : 0x00_u8
    i = 0
    while i < PLANE
      @@black[i] = bk
      @@red[i] = rd
      i = i &+ 1
    end
  end

  def self.set_pixel(x : Int32, y : Int32, color : Int32) : Nil
    return if x < 0 || y < 0 || x >= WIDTH || y >= HEIGHT
    i = y &* ROW_BYTES &+ x.unsafe_shr(3)
    mask = 0x80_u8.unsafe_shr(x & 7)
    clear = mask ^ 0xFF_u8
    if color == BLACK
      @@black[i] = @@black[i] | mask
      @@red[i] = @@red[i] & clear
    elsif color == RED
      @@red[i] = @@red[i] | mask
      @@black[i] = @@black[i] & clear
    else
      @@black[i] = @@black[i] & clear
      @@red[i] = @@red[i] & clear
    end
  end

  def self.fill_rect(x0 : Int32, y0 : Int32, w : Int32, h : Int32, color : Int32) : Nil
    y = y0
    while y < y0 &+ h
      x = x0
      while x < x0 &+ w
        set_pixel(x, y, color)
        x = x &+ 1
      end
      y = y &+ 1
    end
  end

  def self.has_red? : Bool
    p = @@red.as(UInt32*)
    i = 0
    while i < PLANE.unsafe_div(4)
      return true if p[i] != 0_u32
      i = i &+ 1
    end
    false
  end

  # ---- SPI framing --------------------------------------------------------

  # Raise the deselected side before lowering the selected one.
  def self.cs_lo(target : Int32) : Nil
    LibIDF.gpio_set_level(CS2, 1_u32) if target == LEFT
    LibIDF.gpio_set_level(CS1, 1_u32) if target == RIGHT
    LibIDF.gpio_set_level(CS1, 0_u32) if target != RIGHT
    LibIDF.gpio_set_level(CS2, 0_u32) if target != LEFT
  end

  def self.cs_hi : Nil
    LibIDF.gpio_set_level(CS1, 1_u32)
    LibIDF.gpio_set_level(CS2, 1_u32)
  end

  # Blocking write of n bytes from a DMA-capable buffer.
  def self.write(buf : UInt8*, n : Int32) : Nil
    zero(pointerof(@@ts).as(UInt8*), sizeof(LibIDF::SpiTransaction))
    @@ts.length = (n &* 8).to_u32!
    @@ts.tx_buffer = buf.as(Void*)
    err = LibIDF.spi_device_polling_transmit(@@dev, pointerof(@@ts))
    spi_error("polling_transmit", err) if err != 0
  end

  # Records an SPI failure: the frame in progress is abandoned by refresh.
  def self.spi_error(what : String, err : Int32) : Nil
    log(what, err)
    @@spi_fail = true
  end

  # Queues t; false (and the frame marked failed) if the driver refused it.
  def self.queue(t : LibIDF::SpiTransaction*) : Bool
    err = LibIDF.spi_device_queue_trans(@@dev, t, PORT_MAX_DELAY)
    if err != 0
      spi_error("EPD: spi_device_queue_trans err", err)
      return false
    end
    true
  end

  def self.reap : Nil
    done = uninitialized LibIDF::SpiTransaction*
    err = LibIDF.spi_device_get_trans_result(@@dev, pointerof(done), PORT_MAX_DELAY)
    spi_error("EPD: spi_device_get_trans_result err", err) if err != 0
  end

  # Index byte; afterwards DC is high and CS is up.
  def self.index(target : Int32, idx : UInt8) : Nil
    LibIDF.gpio_set_level(DC, 0_u32)
    cs_lo(target)
    @@small[0] = idx
    write(@@small, 1)
    cs_hi
    LibIDF.gpio_set_level(DC, 1_u32)
  end

  # Index then n bytes from a DMA-capable buffer.
  def self.send(target : Int32, idx : UInt8, buf : UInt8*, n : Int32) : Nil
    index(target, idx)
    cs_lo(target)
    write(buf, n)
    cs_hi
  end

  # Index followed by n (<= 6) literal data bytes.
  def self.cmd(target : Int32, idx : UInt8, n : Int32, a : UInt8, b : UInt8 = 0_u8, c : UInt8 = 0_u8,
               d : UInt8 = 0_u8, e : UInt8 = 0_u8, f : UInt8 = 0_u8) : Nil
    index(target, idx)
    @@small[0] = a
    @@small[1] = b
    @@small[2] = c
    @@small[3] = d
    @@small[4] = e
    @@small[5] = f
    cs_lo(target)
    write(@@small, n)
    cs_hi
  end

  def self.cmd1(idx : UInt8, a : UInt8) : Nil
    cmd(BOTH, idx, 1, a)
  end

  # n bytes of the OTP starting at off, to both COGs.
  def self.send_otp(idx : UInt8, off : Int32, n : Int32) : Nil
    i = 0
    while i < n
      @@small[8 &+ i] = @@otp[off &+ i]
      i = i &+ 1
    end
    send(BOTH, idx, @@small + 8_i64, n)
  end

  # Copy rows [row, row+n) of one half of a plane into dst. If `orp` is
  # given it is OR'ed in (fast refresh draws red as ink); a null plane
  # sends zeros.
  def self.pack(dst : UInt8*, plane : UInt8*, orp : UInt8*, half : Int32, row : Int32, n : Int32) : Nil
    total = n &* HALF_BYTES
    if plane.null?
      zero(dst, total)
      return
    end
    off = (row &* ROW_BYTES &+ half &* HALF_BYTES).to_i64!
    src = plane + off
    o = orp.null? ? orp : orp + off
    k = 0
    r = 0
    while r < n
      c = 0
      if o.null?
        while c < HALF_BYTES
          dst[k] = src[c]
          k = k &+ 1
          c = c &+ 1
        end
      else
        while c < HALF_BYTES
          dst[k] = src[c] | o[c]
          k = k &+ 1
          c = c &+ 1
        end
        o = o + ROW_BYTES.to_i64!
      end
      src = src + ROW_BYTES.to_i64!
      r = r &+ 1
    end
  end

  # Stream one half-plane (672 x 60 bytes) to one COG with index `idx`,
  # double-buffered through the two DMA buffers.
  def self.send_plane(target : Int32, idx : UInt8, plane : UInt8*, orp : UInt8*) : Nil
    half = target == RIGHT ? 1 : 0
    index(target, idx)
    cs_lo(target)
    rows = @@chunk_rows
    row = 0
    pending = 0
    use1 = false
    while row < HEIGHT && !@@spi_fail
      n = HEIGHT &- row
      n = rows if n > rows
      buf = use1 ? @@dma1 : @@dma0
      t = use1 ? pointerof(@@t1) : pointerof(@@t0)
      if pending == 2
        reap
        pending = 1
      end
      pack(buf, plane, orp, half, row, n)
      zero(t.as(UInt8*), sizeof(LibIDF::SpiTransaction))
      t.value.length = (n &* HALF_BYTES &* 8).to_u32!
      t.value.tx_buffer = buf.as(Void*)
      break unless queue(t)
      pending = pending &+ 1
      use1 = !use1
      row = row &+ n
    end
    while pending > 0 # only transactions that were actually queued
      reap
      pending = pending &- 1
    end
    cs_hi
  end

  # ---- bitbang (OTP read only) --------------------------------------------

  def self.bus_bitbang : Nil
    LibIDF.esp_rom_gpio_connect_out_signal(MOSI.to_u32!, SIG_GPIO_OUT_IDX, false, false)
    LibIDF.esp_rom_gpio_connect_out_signal(SCK.to_u32!, SIG_GPIO_OUT_IDX, false, false)
    LibIDF.gpio_set_direction(MOSI, GPIO_MODE_OUTPUT)
    LibIDF.gpio_set_direction(SCK, GPIO_MODE_OUTPUT)
    LibIDF.gpio_set_level(SCK, 0_u32)
    LibIDF.gpio_set_level(MOSI, 0_u32)
  end

  def self.bus_spi : Nil
    LibIDF.gpio_set_direction(MOSI, GPIO_MODE_OUTPUT)
    LibIDF.esp_rom_gpio_connect_out_signal(MOSI.to_u32!, FSPID_OUT_IDX, false, false)
    LibIDF.esp_rom_gpio_connect_out_signal(SCK.to_u32!, FSPICLK_OUT_IDX, false, false)
  end

  def self.bb_out_slow(v : UInt8) : Nil
    i = 0
    while i < 8
      LibIDF.gpio_set_level(MOSI, (v & 0x80_u8) != 0 ? 1_u32 : 0_u32)
      LibIDF.esp_rom_delay_us(10_u32)
      LibIDF.gpio_set_level(SCK, 1_u32)
      LibIDF.esp_rom_delay_us(10_u32)
      LibIDF.gpio_set_level(SCK, 0_u32)
      LibIDF.esp_rom_delay_us(10_u32)
      v = v.unsafe_shl(1)
      i = i &+ 1
    end
  end

  def self.bb_in_slow : UInt8
    v = 0_u8
    i = 0
    while i < 8
      LibIDF.gpio_set_level(SCK, 1_u32)
      LibIDF.esp_rom_delay_us(10_u32)
      v = v.unsafe_shl(1) | (LibIDF.gpio_get_level(MOSI) != 0 ? 1_u8 : 0_u8)
      LibIDF.gpio_set_level(SCK, 0_u32)
      LibIDF.esp_rom_delay_us(10_u32)
      i = i &+ 1
    end
    v
  end

  # ---- power, reset, OTP ----------------------------------------------------

  def self.power_on : Nil
    if @@power_off_valid
      off = millis &- @@power_off_ms
      delay_ms(T_OFF_MIN &- off) if off < T_OFF_MIN
      @@power_off_valid = false
    end
    LibIDF.gpio_set_level(PWR, 0_u32)
  end

  def self.power_off : Nil
    LibIDF.gpio_set_level(PWR, 1_u32)
    @@power_off_ms = millis
    @@power_off_valid = true
  end

  def self.cog_reset : Nil
    power_on
    delay_ms(T_RST_PWR)
    LibIDF.gpio_set_level(RST, 1_u32)
    delay_ms(T_RST_HI)
    LibIDF.gpio_set_level(RST, 0_u32)
    delay_ms(T_RST_LO)
    LibIDF.gpio_set_level(RST, 1_u32)
    delay_ms(T_RST_SET)
  end

  # Second reset after the OTP read, as the stock firmware does.
  def self.second_reset : Nil
    delay_ms(T_RST_HI)
    LibIDF.gpio_set_level(RST, 0_u32)
    delay_ms(T_RST_LO)
    LibIDF.gpio_set_level(RST, 1_u32)
    delay_ms(T_RST_SET)
  end

  def self.otp_read_raw(use_b9 : Bool) : Nil
    cog_reset
    if use_b9
      # Driver B opens with 0x70 to both COGs (configures the booster).
      cmd(BOTH, 0x70_u8, 2, 0x71_u8, 0x36_u8)
      LibIDF.gpio_set_level(DC, 0_u32)
      cs_lo(LEFT)
      bus_bitbang
      bb_out_slow(0xB9_u8)
    else
      cmd(LEFT, 0xA1_u8, 1, 0x00_u8)
      cmd(LEFT, 0xA7_u8, 1, 0x80_u8)
      cmd(LEFT, 0xA3_u8, 2, 0x00_u8, 0x40_u8)
      LibIDF.gpio_set_level(DC, 0_u32)
      cs_lo(LEFT)
      bus_bitbang
      bb_out_slow(0xA8_u8)
    end
    delay_ms(1)
    LibIDF.gpio_set_level(DC, 1_u32)
    LibIDF.gpio_set_direction(MOSI, GPIO_MODE_INPUT)
    LibIDF.gpio_set_pull_mode(MOSI, GPIO_PULLDOWN_ONLY)
    bb_in_slow # dummy byte
    i = 0
    while i < OTP_LEN
      @@otp[i] = bb_in_slow
      i = i &+ 1
    end
    cs_hi
    LibIDF.gpio_set_pull_mode(MOSI, GPIO_FLOATING)
    LibIDF.gpio_set_level(MOSI, 0_u32)
    bus_spi
  end

  def self.otp_sane? : Bool
    stage = 0
    while stage < 4
      sb = @@otp[0x20 &+ 8 &* stage]
      rp = sb & 0x7F_u8
      if sb == 0xFF_u8 || rp == 0_u8 || rp > 40_u8
        log2("EPD: OTP ramp stage implausible (stage, byte)", stage, sb.to_i32!)
        return false
      end
      stage = stage &+ 1
    end
    if @@otp[0x17] != 0x3B_u8 || @@otp[0x0D] != 0x3B_u8
      log2("EPD: OTP window check failed (DUW xe, DRFW xe)", @@otp[0x17].to_i32!, @@otp[0x0D].to_i32!)
      return false
    end
    true
  end

  def self.otp_read : Bool
    otp_read_raw(true)
    LibIDF.cr_hex("EPD: OTP (B9 read)".to_unsafe, @@otp, OTP_LEN)
    if @@otp[0x16] == 0x3B_u8 && @@otp[0x0D] == 0x3B_u8 && (@@otp[0x28] & 0x80_u8) != 0
      # Remap the driver-B block into the driver-8 layout.
      i = 0x1E
      while i > 0x12
        @@otp[i] = @@otp[i &- 1]
        i = i &- 1
      end
      i = 0
      while i < 32
        @@otp[0x20 &+ i] = @@otp[0x28 &+ i]
        i = i &+ 1
      end
      @@otp[0] = 0xA5_u8
      @@driver_b = true
      return false unless otp_sane?
      log("EPD: E2969JS0B1 (driver B) detected", 0)
      @@otp_valid = true
      return true
    end
    otp_read_raw(false)
    LibIDF.cr_hex("EPD: OTP (A8 read)".to_unsafe, @@otp, OTP_LEN)
    @@driver_b = false
    if @@otp[0] != 0xA5_u8 || !otp_sane?
      log("EPD: driver-8 OTP read unusable, header", @@otp[0].to_i32!)
      return false
    end
    log("EPD: E2969JS084 (driver 8) detected", 0)
    @@otp_valid = true
    true
  end

  # Power-up for a new session once the OTP is known.
  def self.cog_initial : Nil
    @@red_zero = false # new session: COG RAM contents unknown
    power_on
    delay_ms(T_RST_PWR)
    second_reset
  end

  def self.cog_stop : Nil
    @@red_zero = false
    cmd1(0x09_u8, 0x7F_u8)
    delay_ms(20)
    cmd1(0x05_u8, 0x7D_u8)
    cmd1(0x09_u8, 0x00_u8)
    delay_ms(200)
    LibIDF.gpio_set_level(DC, 0_u32)
    cs_lo(BOTH)
    delay_ms(150)
    LibIDF.gpio_set_level(RST, 0_u32)
    power_off
    delay_ms(T_DISCHARGE)
    cs_hi
    LibIDF.gpio_set_level(RST, 1_u32)
    @@session_open = false
    @@lut_latched = false
  end

  # ---- waveform tables ---------------------------------------------------------

  def self.build_lut8 : Nil
    t = 0
    while t < 5
      g = 0
      while g < 9
        q = @@lut + ((t &* 9 &+ g) &* 4).to_i64!
        if g == 0
          q[0] = t == 0 ? 0x66_u8 : (t == 4 ? 0x00_u8 : 0x99_u8)
          q[1] = 0x33_u8; q[2] = 0x33_u8; q[3] = 0x02_u8
        elsif g == 1
          q[0] = t == 0 ? 0x88_u8 : (t == 4 ? 0x00_u8 : 0x44_u8)
          q[1] = 0x31_u8; q[2] = 0x31_u8; q[3] = 0x09_u8
        else
          q[0] = 0x00_u8; q[1] = 0x10_u8; q[2] = 0x00_u8; q[3] = 0x01_u8
        end
        g = g &+ 1
      end
      t = t &+ 1
    end
  end

  def self.put_group_b(q : UInt8*, level : UInt8, on : UInt8, off : UInt8, rep : UInt8) : Nil
    q[0] = level
    q[1] = on; q[2] = off; q[3] = 1_u8 # EPD_B_PH2
    q[4] = on; q[5] = off; q[6] = 1_u8
    q[7] = rep
  end

  # epd_build_lutb() with the epd97_config.h defaults: shake 1 group, drive 4
  # groups (45 on / 1 off x3), red 9 groups (first clears to white).
  # shake = false replaces the shake group with ground: unchanged pixels are
  # then only pushed further towards the state they already have, so they
  # do not visibly blink (game frames). Less clearing, so more ghosting.
  # Fast LUT kinds (driver B):
  LUT_BASE       = 0 # epd97/upstream base: shake + 4 drive groups + 9 red groups
  LUT_NOSHAKE    = 1 # shake group replaced (paper gets one more white drive)
  LUT_BW         = 2 # upstream "short black/white": base with red idled after group 4
  LUT_NOSHAKE_BW = 3 # both
  # Keep-red kinds: tables 2 (red) and 3 are ground in every group, so pixels
  # whose red bit is set get no drive at all. Used with raw planes (red plane
  # sent as it is) to update black/white content around a red frame that a
  # slow refresh already put on the panel.
  LUT_KEEPRED         = 4 # shake + drive on tables 0/1
  LUT_NOSHAKE_KEEPRED = 5

  def self.build_lutb(kind : Int32) : Nil
    shake = kind == LUT_BASE || kind == LUT_BW || kind == LUT_KEEPRED
    bw = kind == LUT_BW || kind == LUT_NOSHAKE_BW
    keepred = kind == LUT_KEEPRED || kind == LUT_NOSHAKE_KEEPRED
    t = 0
    while t < 5
      g = 0
      while g < 10
        q = @@lut + ((t &* 10 &+ g) &* 8).to_i64!
        red_level = g <= 1 ? 0xAA_u8 : 0xFF_u8
        if t == 4 || (keepred && (t == 2 || t == 3))
          put_group_b(q, 0x00_u8, 1_u8, 1_u8, 1_u8)
        elsif g < 1 && !shake
          # No shake. The freed group gives paper (table 0) one extra white
          # drive, so pixels going black -> white (dying cells, the snake's
          # tail) clear in a single pull; every other table rests at ground.
          if t == 0
            put_group_b(q, 0xAA_u8, 45_u8, 3_u8, 3_u8)
          else
            put_group_b(q, 0x00_u8, 1_u8, 1_u8, 1_u8)
          end
        elsif g < 1
          shk = t == 1 ? 0x66_u8 : (t == 0 ? 0x99_u8 : (t == 2 ? 0xEE_u8 : 0x00_u8))
          put_group_b(q, shk, 10_u8, 10_u8, 3_u8)
        elsif g < 5
          if t == 1
            put_group_b(q, 0x44_u8, 45_u8, 1_u8, 3_u8)
          elsif t == 2
            put_group_b(q, red_level, 45_u8, 1_u8, 3_u8)
          elsif t == 0
            put_group_b(q, 0xAA_u8, 45_u8, 3_u8, 3_u8)
          else
            put_group_b(q, 0x00_u8, 45_u8, 1_u8, 3_u8)
          end
        elsif t == 2 && !bw
          put_group_b(q, red_level, 45_u8, 1_u8, 3_u8)
        else
          put_group_b(q, 0x00_u8, 1_u8, 1_u8, 1_u8)
        end
        g = g &+ 1
      end
      t = t &+ 1
    end
  end

  # Table-mapping probe (driver B): table k gets the ink drive (VDH, the 4
  # drive groups), every other table and group is ground. Shows on the panel
  # which (red, bw) bit pairs select table k.
  def self.build_probe(k : Int32) : Nil
    t = 0
    while t < 5
      g = 0
      while g < 10
        q = @@lut + ((t &* 10 &+ g) &* 8).to_i64!
        if t == k && g >= 1 && g < 5
          put_group_b(q, 0x44_u8, 45_u8, 1_u8, 3_u8)
        else
          put_group_b(q, 0x00_u8, 1_u8, 1_u8, 1_u8)
        end
        g = g &+ 1
      end
      t = t &+ 1
    end
  end

  def self.probe=(k : Int32) : Nil
    @@probe = k
  end

  # false: never promote a fast refresh to slow because of red on the panel
  # (faster browsing; leaves faint red ghosts until the next colour refresh).
  def self.promote=(v : Bool) : Nil
    @@promote = v
  end

  # While abortable, request_abort (e.g. from the button poll) makes the
  # current BUSY wait return early; the refresh then fails and the COG is
  # powered down, leaving a partly driven image.
  def self.abortable=(v : Bool) : Nil
    @@abortable = v
    @@abort = false
  end

  def self.abortable? : Bool
    @@abortable
  end

  def self.request_abort : Nil
    @@abort = true if @@abortable
  end

  def self.aborted? : Bool
    @@abort
  end

  def self.raw=(v : Bool) : Nil
    @@raw = v
  end

  def self.prev_has_red=(v : Bool) : Nil
    @@prev_has_red = v
  end

  # ---- partial window (upstream lib/epd.py update_partial, PARTIAL_WINDOW) ---

  WIN_Y_UNIT   = 4 # gate lines per DRFW y step (full screen = 0..0xA9)
  WIN_PAD_ROWS = 8
  WIN_PAD_COLS = 1 # bytes

  # Streams rows y0..y1, bytes x0..x1 of one COG's half of `plane` (null =
  # zeros) after index idx, double-buffered through the DMA buffers.
  def self.send_box(target : Int32, idx : UInt8, plane : UInt8*, x0 : Int32, x1 : Int32, y0 : Int32, y1 : Int32) : Nil
    half = target == RIGHT ? 1 : 0
    w = x1 &- x0 &+ 1
    if w < 1 || w > HALF_BYTES || x0 < 0 || y0 < 0 || y1 < y0 || y1 >= HEIGHT
      spi_error("EPD: send_box bad window (w)", w)
      return
    end
    rows_per = (MAX_CHUNK_ROWS &* HALF_BYTES).unsafe_div(w)
    index(target, idx)
    cs_lo(target)
    row = y0
    pending = 0
    use1 = false
    while row <= y1 && !@@spi_fail
      n = y1 &- row &+ 1
      n = rows_per if n > rows_per
      buf = use1 ? @@dma1 : @@dma0
      t = use1 ? pointerof(@@t1) : pointerof(@@t0)
      if pending == 2
        reap
        pending = 1
      end
      k = 0
      r = 0
      while r < n
        if plane.null?
          c = 0
          while c < w
            buf[k] = 0_u8
            k = k &+ 1
            c = c &+ 1
          end
        else
          src = plane + ((row &+ r) &* ROW_BYTES &+ half &* HALF_BYTES &+ x0).to_i64!
          c = 0
          while c < w
            buf[k] = src[c]
            k = k &+ 1
            c = c &+ 1
          end
        end
        r = r &+ 1
      end
      zero(t.as(UInt8*), sizeof(LibIDF::SpiTransaction))
      t.value.length = (k &* 8).to_u32!
      t.value.tx_buffer = buf.as(Void*)
      break unless queue(t)
      pending = pending &+ 1
      use1 = !use1
      row = row &+ n
    end
    while pending > 0 # only transactions that were actually queued
      reap
      pending = pending &- 1
    end
    cs_hi
  end

  # Fast refresh of only the box rows r0..r1, frame byte columns c0..c1
  # (padded and 4-row aligned): DUW (0x13) and DRFW (0x90) set to the same
  # box on each COG and only that box uploaded (raw planes). Needs an open
  # session with the fast LUT already latched; otherwise does a normal fast
  # refresh with `kind`. Returns panel busy ms (or -1).
  def self.refresh_window(c0 : Int32, c1 : Int32, r0 : Int32, r1 : Int32, kind : Int32) : Int32
    refresh_window2(r0, r1, c0, c1, r0, r1, c0, c1, kind)
  end

  # x part of one COG's window: frame bytes b0..b1 padded and clipped to
  # half `t`, written to w[0], w[1] (bytes within the half). A COG with
  # nothing in its box gets a 1-byte slice at its left edge: it re-drives
  # what is already shown there. Returns false for that idle case.
  def self.win_x(t : Int32, empty : Bool, b0 : Int32, b1 : Int32, w : Int32*) : Bool
    lo = t == LEFT ? 0 : HALF_BYTES
    hi = lo &+ HALF_BYTES &- 1
    b0 = b0 &- WIN_PAD_COLS
    b0 = 0 if b0 < 0
    b1 = b1 &+ WIN_PAD_COLS
    b1 = ROW_BYTES &- 1 if b1 > ROW_BYTES &- 1
    if empty || b1 < lo || b0 > hi
      w[0] = 0
      w[1] = 0
      return false
    end
    w[0] = (b0 > lo ? b0 : lo) &- lo
    w[1] = (b1 < hi ? b1 : hi) &- lo
    true # 0 <= w[0] <= w[1] <= HALF_BYTES - 1 by construction
  end

  # Window refresh with a separate box per COG half: left rows lr0..lr1,
  # frame bytes lc0..lc1; right likewise (empty box: lr1 < lr0).
  # wmode (DIAG calibration): 0 = DUW and DRFW both set to the box (normal);
  # 1 = DUW box + box upload, DRFW full screen (shows where RAM writes land);
  # 2 = DUW full + full upload, DRFW box (shows where the refresh window lands).
  def self.refresh_window2(lr0 : Int32, lr1 : Int32, lc0 : Int32, lc1 : Int32,
                           rr0 : Int32, rr1 : Int32, rc0 : Int32, rc1 : Int32, kind : Int32,
                           wmode : Int32 = 0) : Int32
    @@spi_fail = false
    unless @@session_open && @@lut_latched && @@latched_fast && @@latched_kind == kind && @@probe < 0
      @@raw = true
      refresh(true, kind)
      @@raw = false
      return @@panel_ms
    end
    u = WIN_Y_UNIT
    w = @@small.as(Int32*) + 4_i64 # 4 ints scratch after the command bytes
    # The gate (row) scan is shared by the two COGs (measured: an idle window
    # on one COG drove its rows across the whole width, and a COG whose rows
    # differed from the master's drew nothing). So both COGs get the SAME
    # rows: the union of the two boxes, padded and 4-row aligned.
    # Clip both axes first; an empty or inverted box (rows or columns) means
    # "nothing for this COG" and never reaches the padding below.
    lr0 = 0 if lr0 < 0
    rr0 = 0 if rr0 < 0
    lr1 = HEIGHT &- 1 if lr1 > HEIGHT &- 1
    rr1 = HEIGHT &- 1 if rr1 > HEIGHT &- 1
    lc0 = 0 if lc0 < 0
    rc0 = 0 if rc0 < 0
    lc1 = ROW_BYTES &- 1 if lc1 > ROW_BYTES &- 1
    rc1 = ROW_BYTES &- 1 if rc1 > ROW_BYTES &- 1
    l_empty = lr1 < lr0 || lc1 < lc0
    r_empty = rr1 < rr0 || rc1 < rc0
    if l_empty && r_empty
      return 0
    end
    a0 = l_empty ? rr0 : (r_empty ? lr0 : (lr0 < rr0 ? lr0 : rr0))
    a1 = l_empty ? rr1 : (r_empty ? lr1 : (lr1 > rr1 ? lr1 : rr1))
    a0 = a0 &- WIN_PAD_ROWS
    a0 = 0 if a0 < 0
    a0 = a0.unsafe_div(u) &* u
    a1 = (a1 &+ WIN_PAD_ROWS).unsafe_div(u) &* u &+ u
    a1 = HEIGHT if a1 > HEIGHT
    a1 = a1 &- 1
    t_up = millis
    t = LEFT
    rows_total = 0
    while t <= RIGHT
      if t == LEFT
        win_x(t, l_empty, lc0, lc1, w)
      else
        win_x(t, r_empty, rc0, rc1, w)
      end
      x0 = w[0]
      x1 = w[1]
      y0 = a0
      y1 = a1
      rows_total = rows_total &+ (y1 &- y0 &+ 1)
      log2("EPD: window x0 x1 (bytes in half)", x0, x1)
      log2("EPD: window y0 y1 (rows)", y0, y1)
      if wmode == 2
        send_otp_to(t, 0x13_u8, 0x16, 6) # DUW full
      else
        cmd(t, 0x13_u8, 6, x0.to_u8!, x1.to_u8!, (y0 & 0xFF).to_u8!, y0.unsafe_shr(8).to_u8!,
          (y1 & 0xFF).to_u8!, y1.unsafe_shr(8).to_u8!)
      end
      if wmode == 1
        send_otp_to(t, 0x90_u8, 0x0C, 4) # DRFW full
      else
        cmd(t, 0x90_u8, 4, x0.to_u8!, x1.to_u8!, y0.unsafe_div(u).to_u8!, y1.unsafe_div(u).to_u8!)
      end
      if wmode == 2
        send_otp_to(t, 0x12_u8, 0x13, 3)
        send_plane(t, 0x10_u8, @@black, Pointer(UInt8).null)
        send_otp_to(t, 0x12_u8, 0x13, 3)
        send_plane(t, 0x11_u8, @@red, Pointer(UInt8).null)
        @@red_zero = false
      else
        send_otp_to(t, 0x12_u8, 0x13, 3)
        send_box(t, 0x10_u8, @@black, x0, x1, y0, y1)
        zero_box = red_box_zero?(t == LEFT ? 0 : 1, x0, x1, y0, y1)
        unless SKIP_ZERO_RED && zero_box && @@red_zero
          send_otp_to(t, 0x12_u8, 0x13, 3)
          send_box(t, 0x11_u8, @@red, x0, x1, y0, y1)
          @@red_zero = false unless zero_box
        end
      end
      t = t &+ 1
    end
    @@upload_ms = millis &- t_up
    if @@spi_fail
      log("EPD: window upload failed, frame dropped", 0)
      cog_stop
      return -1
    end
    rc = 0
    pulls = 0
    while rc >= 0 && pulls < @@fast_pulls
      r = trigger(false, FAST_TIMEOUT_MS)
      rc = r < 0 ? r : rc &+ r
      pulls = pulls &+ 1
    end
    @@panel_ms = rc
    log2("EPD: window rows (both COGs) / panel ms", rows_total, rc)
    if rc < 0 || @@spi_fail
      log("EPD: window refresh failed, COG powered down", rc)
      cog_stop # also clears session_open / lut_latched
      return -1
    end
    rc
  end

  # ---- refresh -----------------------------------------------------------------

  def self.busy? : Bool
    LibIDF.gpio_get_level(BUSY1) == 0 || LibIDF.gpio_get_level(BUSY2) == 0
  end

  # Wait until BUSY is idle (want_idle) or asserted; ms waited or -1.
  def self.wait_busy(want_idle : Bool, timeout_ms : Int32) : Int32
    t0 = millis
    while true
      idle = !busy?
      return millis &- t0 if idle == want_idle
      return -1 if millis &- t0 > timeout_ms
      if @@abort
        log("EPD: refresh aborted", millis &- t0)
        return -2
      end
      delay_ms(@@busy_poll_ms)
    end
    0
  end

  def self.write_planes(fast_ink_red : Bool, draw_red : Bool) : Nil
    cmd1(0x01_u8, @@otp[0x10]) if @@driver_b # DCTL before the windows on driver B
    send_otp(0x13_u8, 0x16, 6)              # DUW
    send_otp(0x90_u8, 0x0C, 4)              # DRFW
    t = LEFT
    while t <= RIGHT
      send_otp_to(t, 0x12_u8, 0x13, 3) # RAM_RW
      send_plane(t, 0x10_u8, @@black, fast_ink_red ? @@red : Pointer(UInt8).null)
      unless SKIP_ZERO_RED && !draw_red && @@red_zero
        send_otp_to(t, 0x12_u8, 0x13, 3)
        send_plane(t, 0x11_u8, draw_red ? @@red : Pointer(UInt8).null, Pointer(UInt8).null)
      end
      t = t &+ 1
    end
    @@red_zero = !draw_red
  end

  # True if rows y0..y1, bytes x0..x1 of one half of the red plane are zero.
  def self.red_box_zero?(half : Int32, x0 : Int32, x1 : Int32, y0 : Int32, y1 : Int32) : Bool
    row = y0
    while row <= y1
      p = @@red + (row &* ROW_BYTES &+ half &* HALF_BYTES).to_i64!
      c = x0
      while c <= x1
        return false if p[c] != 0_u8
        c = c &+ 1
      end
      row = row &+ 1
    end
    true
  end

  def self.send_otp_to(target : Int32, idx : UInt8, off : Int32, n : Int32) : Nil
    i = 0
    while i < n
      @@small[8 &+ i] = @@otp[off &+ i]
      i = i &+ 1
    end
    send(target, idx, @@small + 8_i64, n)
  end

  def self.stage_delay(d : UInt8) : Nil
    if (d & 0x80_u8) != 0
      ms = (d & 0x7F_u8).to_i32!
      delay_ms(ms == 0 ? 1 : ms)
    else
      LibIDF.esp_rom_delay_us(10_u32 &* (d & 0x7F_u8).to_u32!)
    end
  end

  # Vendor DC/DC ramp, driven verbatim by the OTP.
  def self.dcdc_soft_start : Nil
    stage = 0
    while stage < 4
      off = 0x20 &+ 8 &* stage
      rep = (@@otp[off] & 0x7F_u8).to_i32!
      if (@@otp[off] & 0x80_u8) != 0
        ph0 = @@otp[off &+ 1]
        ph1 = @@otp[off &+ 2]
        i = 0
        while i < rep
          cmd1(0x09_u8, @@otp[off &+ 5])
          ph0 = ph0 &+ @@otp[off &+ 3]
          ph1 = ph1 &+ @@otp[off &+ 4]
          cmd(BOTH, 0x51_u8, 2, ph0, ph1)
          cmd1(0x09_u8, @@otp[off &+ 6])
          stage_delay(@@otp[off &+ 7])
          i = i &+ 1
        end
      else
        i = 0
        while i < rep
          cmd1(0x09_u8, @@otp[off &+ 1])
          stage_delay(@@otp[off &+ 3])
          cmd1(0x09_u8, @@otp[off &+ 2])
          stage_delay(@@otp[off &+ 4])
          i = i &+ 1
        end
      end
      stage = stage &+ 1
    end
  end

  # The vendor update register sequence (k_upd in epd97.cpp).
  def self.update_registers : Nil
    b = @@driver_b
    cmd1(0x05_u8, 0x7D_u8); delay_ms(200)
    cmd1(0x05_u8, 0x00_u8); delay_ms(10)
    cmd1(0xC2_u8, 0x3F_u8) unless b
    cmd1(0xD8_u8, @@otp[0x1D])
    cmd1(0xD6_u8, @@otp[0x1E])
    cmd1(0xA7_u8, 0x10_u8); delay_ms(100)
    cmd1(0xA7_u8, 0x00_u8); delay_ms(100)
    cmd(BOTH, 0x03_u8, 2, 0x00_u8, @@otp[0x12]) unless b # OSC, driver 8 only
    cmd1(0x44_u8, 0x00_u8)
    cmd1(0x45_u8, 0x80_u8)
    cmd1(0xA7_u8, 0x10_u8); delay_ms(100)
    cmd1(0xA7_u8, 0x00_u8); delay_ms(100)
    cmd1(0x44_u8, 0x06_u8)
    cmd1(0x45_u8, b ? REG45_B1 : REG45_084) # waveform bank
    cmd1(0xA7_u8, 0x10_u8); delay_ms(100)
    cmd1(0xA7_u8, 0x00_u8); delay_ms(T_PRE_SS)
    cmd1(0x60_u8, @@otp[0x0B]) # TCON
    cmd1(0x61_u8, @@otp[0x1C]) # STV_DIR
    cmd1(0x01_u8, @@otp[0x10]) unless b # DCTL
    cmd1(0x02_u8, @@otp[0x11]) # VCOM
  end

  # 0x15 and wait for the waveform; returns panel ms or -1. `watch` keeps
  # looking for a second BUSY pass (epd97.cpp does this after every first
  # refresh; it costs EPD_SECOND_PASS_MS and has not fired on this panel).
  def self.trigger(watch : Bool, timeout_ms : Int32) : Int32
    cmd1(0x15_u8, 0x3C_u8)
    return -1 if @@spi_fail
    if wait_busy(false, 2000) < 0
      log("EPD: BUSY never went low after 0x15", 0)
      return -1
    end
    w = wait_busy(true, timeout_ms)
    log("EPD: BUSY timeout / aborted (ms limit)", timeout_ms) if w < 0
    return -1 if w < 0
    # Some panels drop BUSY again for a second pass; watch for it.
    if watch && @@second_pass_ms > 0
      t0 = millis
      while millis &- t0 < @@second_pass_ms
        delay_ms(10)
        if busy?
          again = wait_busy(true, timeout_ms)
          log("EPD: second waveform pass ms", again)
          return -1 if again < 0
          w = w &+ again
          break
        end
      end
    end
    w
  end

  # Full sequence for the first image of a session; returns panel ms or -1.
  def self.do_refresh(fast : Bool) : Int32
    delay_ms(T_PRE_UPD)
    update_registers
    return -1 if @@spi_fail
    if fast
      if @@driver_b
        if @@probe >= 0
          build_probe(@@probe)
        else
          build_lutb(@@lut_kind)
        end
        send(BOTH, 0xB0_u8, @@lut, LUTB_BYTES)
      else
        build_lut8
        send(BOTH, 0xB0_u8, @@lut, LUT8_BYTES)
      end
    end
    return -1 if @@spi_fail
    dcdc_soft_start
    return -1 if @@spi_fail
    delay_ms(100)
    if busy?
      r = wait_busy(true, 10_000)
      log("EPD: booster ready after soft start ms (-1 = timeout)", r)
      return -1 if r < 0 # epd97.cpp goes on anyway; we stop and power down
    end
    # The slow (OTP) waveform is where a second pass could occur.
    trigger(!fast, fast ? FAST_TIMEOUT_MS : SLOW_TIMEOUT_MS)
  end

  # Push the frame buffers to the panel. Fast = short waveform (red drawn as
  # ink). Returns true on success; logs the phase timings.
  # clean = false uses the no-shake fast LUT (driver B), for game frames.
  def self.refresh(fast_req : Bool, kind : Int32 = LUT_BASE) : Bool
    @@lut_kind = @@driver_b ? kind : LUT_BASE
    t_start = millis
    have_red = has_red?
    draw_red = have_red && (!fast_req || @@raw)
    fast = fast_req
    if fast && @@prev_has_red && !@@raw && @@promote
      log("EPD: red on the panel - this fast refresh runs slow to clear it", 0)
      fast = false
    end

    @@spi_fail = false
    if @@session_open && @@lut_latched && REWRITE_LUT_IN_SESSION && fast && @@latched_fast &&
       @@driver_b && @@probe < 0 && @@latched_probe < 0 && @@lut_kind != @@latched_kind
      # Untested: swap the fast table without restarting the COG.
      build_lutb(@@lut_kind)
      send(BOTH, 0xB0_u8, @@lut, LUTB_BYTES)
      @@latched_kind = @@lut_kind
      log("EPD: LUT rewritten in session, kind", @@lut_kind)
    end
    if @@session_open && @@lut_latched && (fast != @@latched_fast || (fast && (@@lut_kind != @@latched_kind || @@probe != @@latched_probe)))
      cog_stop
    end
    t_init = millis
    if !@@session_open
      cog_initial
      @@session_open = true
      @@lut_latched = false
    end
    t_up = millis
    write_planes(have_red && !draw_red, draw_red)
    t_up_end = millis
    @@upload_ms = t_up_end &- t_up
    if @@spi_fail
      log("EPD: upload failed, frame dropped", 0)
      cog_stop
      return false
    end

    first = !@@lut_latched
    rc = first ? do_refresh(fast) : trigger(false, fast ? FAST_TIMEOUT_MS : SLOW_TIMEOUT_MS)
    t_ref_end = millis
    pulls = 1
    if rc >= 0 && fast && @@driver_b
      while rc >= 0 && pulls < @@fast_pulls
        r = trigger(false, FAST_TIMEOUT_MS)
        rc = r < 0 ? r : rc &+ r
        pulls = pulls &+ 1
      end
    end
    t_busy_end = millis
    rc = -1 if @@spi_fail # any SPI error after the upload fails the frame
    @@panel_ms = rc
    @@latched_fast = fast
    @@latched_kind = @@lut_kind
    @@latched_probe = @@probe
    @@lut_latched = rc >= 0 && fast
    @@prev_has_red = draw_red if rc >= 0
    keep = @@keep_awake && @@lut_latched
    cog_stop unless keep
    t_end = millis

    log2("EPD: refresh fast? / first-of-session?", fast ? 1 : 0, first ? 1 : 0)
    log2("EPD:   lut kind / pulls", @@lut_kind, pulls)
    log("EPD:   power-up + reset ms", t_up &- t_init)
    log("EPD:   upload ms", t_up_end &- t_up)
    log("EPD:   registers+soft start+waveform (pull 1) ms", t_ref_end &- t_up_end)
    log2("EPD:   panel busy ms / pulls", rc, pulls)
    log("EPD:   upload start -> BUSY released ms", t_busy_end &- t_up)
    log("EPD:   cog_stop ms (0 = session kept)", t_end &- t_busy_end)
    log("EPD:   total ms", t_end &- t_start)
    rc >= 0
  end
end
