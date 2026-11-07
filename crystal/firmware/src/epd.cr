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

def log3(msg : String, a : Int32, b : Int32, c : Int32) : Nil
  LibIDF.cr_log3(msg.to_unsafe, a, b, c)
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
  SESSION_IMAGES  = 20     # epd97_config.h EPD_SESSION_IMAGES
  COLLAPSED_MS    = 300    # a full-screen fast pull shorter than this drove nothing
  # Quick session open for fast (0xB0) sessions, from yigitabi5444's
  # supercon26-badge-os (measured on this badge: open 348 ms instead of
  # 2443 ms, 0xB0 still latches): panel supply left on between fast sessions,
  # reset 2/4/20 ms, 05 7D 50 ms, 05 00 1 ms, load strobes 2/10 ms, no 660 ms
  # pre-update wait. Slow (OTP waveform) sessions keep the reference waits.
  QUICK_OPEN      = true # default; runtime: @@quick_open (shell: flag QUICK_OPEN)
  FAST_TIMEOUT_MS = 5_000   # BUSY wait for a fast waveform (~1.2 s per pull)
  SLOW_TIMEOUT_MS = 180_000 # BUSY wait for the OTP waveform (~33 s)

  # Skip uploading an all-zero red plane (0x11) when the last red upload in
  # this open session was all zeros too (~33 ms per frame). Assumes the COG
  # keeps its RAM between refreshes: NEEDS A HARDWARE CHECK; set false if
  # red ghosts appear after fast frames.
  SKIP_ZERO_RED = false # default; runtime: @@skip_zero_red
  # Experiment (red-copy corruption): PDi's RAM_RW 3B 00 14 with bit-reversed
  # bytes, as PDi's GU_large / Wide_Large drivers and supercon26-badge-os use
  # for this CoG, instead of the OTP's 00 00 10 with MSB-first bytes.
  PDI_RAM_ORDER = false

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
  @@rev = Pointer(UInt8).null # bit-reversal table (PDI_RAM_ORDER)
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
  @@quick_open = true    # = QUICK_OPEN, switchable at run time
  @@skip_zero_red = false # = SKIP_ZERO_RED, switchable at run time
  @@session_images = 0
  @@collapsed = 0        # collapsed fast pulls detected and redone
  @@quick = false        # current session opened with the quick waits
  @@powered = false      # panel supply (GPIO48) is on
  @@stop_pending = false # a refresh was aborted: wait for BUSY, then close
  @@restart_ms = 0 # last refresh: COG power-up + register/soft-start setup (0 = session reused)
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

  def self.restart_ms : Int32
    @@restart_ms
  end

  # ---- run-time flags and status (debug shell) ----
  def self.quick_open=(v : Bool) : Nil
    @@quick_open = v
  end

  def self.quick_open? : Bool
    @@quick_open
  end

  def self.skip_zero_red=(v : Bool) : Nil
    @@skip_zero_red = v
  end

  def self.skip_zero_red? : Bool
    @@skip_zero_red
  end

  def self.latched_kind : Int32
    @@latched_kind
  end

  def self.fast_pulls : Int32
    @@fast_pulls
  end

  def self.session_images : Int32
    @@session_images
  end

  def self.session_open? : Bool
    @@session_open
  end

  def self.quick? : Bool
    @@quick
  end

  def self.collapsed : Int32
    @@collapsed
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
    # The gate floats during the ESP32 reset, so the COG may have stayed
    # powered (and kept register state) across the reboot. Hold the supply
    # off long enough for the rails to bleed (EPD_T_OFF_MIN) before the probe.
    delay_ms(T_OFF_MIN &+ 500)
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
    cmd(BOTH, 0x70_u8, 2, 0x71_u8, 0x36_u8) if @@driver_b # after every reset (errata 9)
    @@session_open = true
    @@lut_latched = false
    @@quick = @@quick_open # the supply is settled: closing this session keeps it on
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
      if o.null? && PDI_RAM_ORDER
        rv = rev_table
        while c < HALF_BYTES
          dst[k] = rv[src[c].to_i32!]
          k = k &+ 1
          c = c &+ 1
        end
      elsif o.null?
        while c < HALF_BYTES
          dst[k] = src[c]
          k = k &+ 1
          c = c &+ 1
        end
      else
        while c < HALF_BYTES
          v = src[c] | o[c]
          dst[k] = PDI_RAM_ORDER ? rev_table[v.to_i32!] : v
          k = k &+ 1
          c = c &+ 1
        end
        o = o + ROW_BYTES.to_i64!
      end
      src = src + ROW_BYTES.to_i64!
      r = r &+ 1
    end
  end

  def self.rev_table : UInt8*
    if @@rev.null?
      t = dma_alloc(256)
      b = 0
      while b < 256
        v = b.to_u8!
        v = (v & 0xF0_u8).unsafe_shr(4) | (v & 0x0F_u8).unsafe_shl(4)
        v = (v & 0xCC_u8).unsafe_shr(2) | (v & 0x33_u8).unsafe_shl(2)
        v = (v & 0xAA_u8).unsafe_shr(1) | (v & 0x55_u8).unsafe_shl(1)
        t[b] = v
        b = b &+ 1
      end
      @@rev = t
    end
    @@rev
  end

  # RAM_RW before a full-plane upload.
  def self.ram_rw_full(t : Int32) : Nil
    if PDI_RAM_ORDER
      cmd(t, 0x12_u8, 3, 0x3B_u8, 0x00_u8, 0x14_u8)
    else
      send_otp_to(t, 0x12_u8, 0x13, 3)
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
    @@powered = true
  end

  def self.power_off : Nil
    @@powered = false
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
  def self.cog_initial(quick : Bool = false) : Nil
    @@red_zero = false # new session: COG RAM contents unknown
    @@session_images = 0
    @@quick = quick && @@powered
    if @@quick
      # Quick reset (PDi Wide_Large waits); the supply never went off.
      LibIDF.gpio_set_level(RST, 1_u32)
      delay_ms(2)
      LibIDF.gpio_set_level(RST, 0_u32)
      delay_ms(4)
      LibIDF.gpio_set_level(RST, 1_u32)
      delay_ms(20)
      cs_hi
      delay_ms(5)
    else
      power_on
      delay_ms(T_RST_PWR)
      second_reset
    end
    # B1 booster setting after EVERY reset: without it a refresh draws ~2 A
    # (badge team errata 9, via supercon26-badge-os DEVICE_INFO.md).
    cmd(BOTH, 0x70_u8, 2, 0x71_u8, 0x36_u8) if @@driver_b
  end

  # Closes the session (DC-DC soft shutdown). After a quick (fast) session
  # the panel supply stays on, so the next fast session can open quickly;
  # otherwise (slow sessions, errors) the supply is cut as epd97.cpp does.
  # Never called while BUSY is low (see finish_aborted).
  def self.cog_stop : Nil
    @@red_zero = false
    keep_power = @@quick && @@quick_open && !@@spi_fail
    cmd1(0x09_u8, 0x7F_u8)
    delay_ms(20)
    cmd1(0x05_u8, 0x7D_u8)
    cmd1(0x09_u8, 0x00_u8)
    delay_ms(200)
    if keep_power
      wait_busy(true, 2000)
      LibIDF.gpio_set_level(DC, 0_u32)
      cs_lo(BOTH)
      LibIDF.gpio_set_level(RST, 0_u32)
      cs_hi
      LibIDF.gpio_set_level(RST, 1_u32)
    else
      LibIDF.gpio_set_level(DC, 0_u32)
      cs_lo(BOTH)
      delay_ms(150)
      LibIDF.gpio_set_level(RST, 0_u32)
      power_off
      delay_ms(T_DISCHARGE)
      cs_hi
      LibIDF.gpio_set_level(RST, 1_u32)
    end
    @@session_open = false
    @@lut_latched = false
    @@quick = false
    @@diff_open = false
    @@diff_rows = HEIGHT
    @@ink_win = false
  end

  # After an aborted refresh the COG is still running its waveform: no
  # command may be sent while BUSY is low. Wait for it, then close.
  def self.finish_aborted : Nil
    return unless @@stop_pending
    @@stop_pending = false
    t0 = millis
    wait_busy(true, SLOW_TIMEOUT_MS)
    log("EPD: aborted waveform finished, waited ms", millis &- t0)
    cog_stop
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
  # HALF60 (panel-speed branch, 885d589): 0x44 ink / 0xAA paper in all 10
  # groups, 1/1/1 x1 in every table. A group lasts as long as its shortest
  # table (VCOM included), so this is as long as one BASE pull but turns
  # white solid black in ONE pull. Red tables ground.
  LUT_HALF60          = 6
  # WFAST (window ink only), after yigitabi5444/supercon26-badge-os
  # (main.c part_table, panel_lab experiments 05-10). Group bytes are
  # [levels a|b|c|d, TPa, TPb, SRab, TPc, TPd, SRcd, RP]; every group runs
  # only phases c and d (SRab 0) for 1 frame each: 10 groups x 2 = 20
  # frames, the shortest pull this CoG runs (~475 ms full screen vs ~1160
  # for our 45/1/1 x3 tables). Table 1 (new pixel black, as 0x11 = 0 in the
  # window rows) gets VDH for the first @@wf_frames frames, then GND; every
  # other table and VCOM GND: pixels only move towards black (no lightening).
  # A zero TP, RP 0 or SRab = SRcd = 0 hangs the CoG (their findings).
  LUT_WFAST           = 7
  @@wf_frames = 19

  def self.wfast(frames : Int32) : Nil
    frames = 1 if frames < 1
    frames = 19 if frames > 19 # the last frame stays GND
    @@wf_frames = frames
  end

  def self.build_wfast : Nil
    k = 0
    while k < 50
      q = @@lut + (k &* 8).to_i64!
      q[0] = 0_u8; q[1] = 1_u8; q[2] = 1_u8; q[3] = 0_u8
      q[4] = 1_u8; q[5] = 1_u8; q[6] = 1_u8; q[7] = 1_u8
      k = k &+ 1
    end
    f = 0
    while f < @@wf_frames
      g = f.unsafe_div(2)
      shift = (f & 1) == 1 ? 0 : 2 # phase c: bits 3-2, phase d: bits 1-0
      q = @@lut + ((10 &+ g) &* 8).to_i64!
      q[0] = q[0] | 1.unsafe_shl(shift).to_u8!
      f = f &+ 1
    end
  end

  # ---- whole-panel differential update (UPD_DIFF) ---------------------------
  # Port of yigitabi5444/supercon26-badge-os ea76830 main/main.c
  # "panel_lab: calm partial updates" (lines 321-500). The CoG swaps 0x10
  # and 0x11 after every pull, so 0x11 holds what the film shows; the new
  # frame goes into 0x10 and the table index is (old << 1) | new. Table 1
  # (white -> black) VDH and table 2 (black -> white) VDL for the first
  # DIFF_DRIVE frames, then GND; tables 0, 3 and VCOM GND: only changed
  # pixels move, so there are no window edges (DUW/DRFW whole panel).
  # Every group runs phases c and d only: 20 frames per pull (~0.5 s).
  LUT_DIFF   = 8
  DIFF_DRIVE = 10 # main.c:331 PART_DRIVE (10 for the film's health; 6 reads)
  DIFF_SESSION = 60 # main.c:454 a fresh session every 60 pulls
  @@diff_open = false
  @@diff_n = 0
  @@diff_shown = Pointer(UInt8).null # what the film shows (black | red)
  @@diff_rows = HEIGHT # UPD_DIFFWIN: DRFW rows 0 .. this-1 (HEIGHT = whole)

  def self.diff_open? : Bool
    @@diff_open
  end

  def self.diff_n : Int32
    @@diff_n
  end

  def self.diff_shown : UInt8*
    @@diff_shown = LibIDF.heap_caps_malloc(PLANE.to_u32!, 0x404_u32).as(UInt8*) if @@diff_shown.null?
    @@diff_shown
  end

  # The film now shows the planes (after a full refresh): black | red.
  def self.diff_mark_shown : Nil
    d = diff_shown
    i = 0
    while i < PLANE
      d[i] = @@black[i] | @@red[i]
      i = i &+ 1
    end
  end

  # main.c:338-350 part_table.
  def self.build_diff : Nil
    k = 0
    while k < 50
      q = @@lut + (k &* 8).to_i64!
      q[0] = 0_u8; q[1] = 1_u8; q[2] = 1_u8; q[3] = 0_u8
      q[4] = 1_u8; q[5] = 1_u8; q[6] = 1_u8; q[7] = 1_u8
      k = k &+ 1
    end
    f = 0
    while f < DIFF_DRIVE
      g = f.unsafe_div(2)
      shift = (f & 1) == 1 ? 0 : 2 # phase c: bits 3-2, phase d: bits 1-0
      q1 = @@lut + ((10 &+ g) &* 8).to_i64!
      q1[0] = q1[0] | 1.unsafe_shl(shift).to_u8! # VDH
      q2 = @@lut + ((20 &+ g) &* 8).to_i64!
      q2[0] = q2[0] | 2.unsafe_shl(shift).to_u8! # VDL
      f = f &+ 1
    end
  end

  # main.c:207-239 dcdc_on (ms(t) there is t ticks + 1).
  def self.diff_dcdc_on : Nil
    cmd(BOTH, 0x51_u8, 2, 0x50_u8, 0x01_u8)
    v = 1
    while v <= 4
      cmd1(0x09_u8, 0x1F_u8); cmd(BOTH, 0x51_u8, 2, 0x50_u8, v.to_u8!); cmd1(0x09_u8, 0x9F_u8); delay_ms(3)
      v = v &+ 1
    end
    v = 1
    while v <= 10
      cmd1(0x09_u8, 0x1F_u8); cmd(BOTH, 0x51_u8, 2, 0x0A_u8, v.to_u8!); cmd1(0x09_u8, 0x9F_u8); delay_ms(3)
      v = v &+ 1
    end
    v = 3
    while v <= 10
      cmd1(0x09_u8, 0x7F_u8); cmd(BOTH, 0x51_u8, 2, 0x0A_u8, v.to_u8!); cmd1(0x09_u8, 0xFF_u8); delay_ms(3)
      v = v &+ 1
    end
    v = 9
    while v >= 2
      cmd1(0x09_u8, 0x7F_u8); cmd(BOTH, 0x51_u8, 2, v.to_u8!, 0x0A_u8); cmd1(0x09_u8, 0xFF_u8); delay_ms(3)
      v = v &- 1
    end
    cmd1(0x09_u8, 0xFF_u8)
    delay_ms(101)
    r = wait_busy(true, 10_000) # main.c:238 never trigger into a ramping booster
    log("EPD: diff dc-dc on, BUSY wait ms (-1 = timeout)", r)
  end

  # main.c:352-403 part_open: reset, register sequence, table, DC-DC, whole-
  # panel DUW/DRFW, both RAMs = what the film shows.
  # Session timing registers (experiments, shell `reg`): 0x03 OSC second
  # byte and 0x60 TCON, yigitabi's values by default.
  @@x_osc = 0x11
  @@x_tcon = 0x25

  def self.x_regs(osc : Int32, tcon : Int32) : Nil
    @@x_osc = osc
    @@x_tcon = tcon
    cog_stop if @@diff_open && !busy?
  end

  def self.x_osc : Int32
    @@x_osc
  end

  def self.x_tcon : Int32
    @@x_tcon
  end

  def self.diff_open(kind : Int32 = LUT_DIFF) : Bool
    t0 = millis
    cog_stop if @@session_open
    cog_initial(@@quick_open) # main.c:357-366 reset waits + 0x70 71 36
    cmd1(0x05_u8, 0x7D_u8); delay_ms(51)
    cmd1(0x05_u8, 0x00_u8); delay_ms(2)
    cmd1(0xD8_u8, 0x80_u8)
    cmd1(0xD6_u8, 0x00_u8)
    cmd1(0xA7_u8, 0x10_u8); delay_ms(3)
    cmd1(0xA7_u8, 0x00_u8); delay_ms(11)
    cmd(BOTH, 0x03_u8, 2, 0x00_u8, @@x_osc.to_u8!)
    t = LEFT
    while t <= RIGHT
      cmd(t, 0x44_u8, 1, 0x00_u8)
      cmd(t, 0x45_u8, 1, 0x80_u8)
      cmd(t, 0xA7_u8, 1, 0x10_u8); delay_ms(3)
      cmd(t, 0xA7_u8, 1, 0x00_u8); delay_ms(11)
      cmd(t, 0x44_u8, 1, 0x06_u8)
      cmd(t, 0x45_u8, 1, 0x84_u8)
      cmd(t, 0xA7_u8, 1, 0x10_u8); delay_ms(3)
      cmd(t, 0xA7_u8, 1, 0x00_u8); delay_ms(11)
      t = t &+ 1
    end
    cmd1(0x60_u8, @@x_tcon.to_u8!)
    cmd(LEFT, 0x61_u8, 1, 0x01_u8)
    cmd1(0x02_u8, 0x00_u8)
    build_lutb(kind)
    send(BOTH, 0xB0_u8, @@lut, LUTB_BYTES)
    diff_dcdc_on
    cmd(BOTH, 0x13_u8, 6, 0x00_u8, 0x3B_u8, 0x00_u8, 0x00_u8, 0x9F_u8, 0x02_u8) # DUW whole panel
    cmd(BOTH, 0x90_u8, 4, 0x00_u8, 0x3B_u8, 0x00_u8, 0xA9_u8)                 # DRFW whole panel
    # DCTL from the OTP, as write_planes: yigitabi's sequence has no 0x01 and
    # writes RAM bit-reversed from x 0x3B down (PDi order); without it our
    # OTP-order writes land mirrored within each COG half (ink test photo).
    cmd1(0x01_u8, @@otp[0x10]) if @@driver_b
    # Differential: both RAMs = what the film shows. Ink commands: both
    # zero (table 0 = no drive everywhere).
    sh = kind == LUT_DIFF ? diff_shown : Pointer(UInt8).null
    t = LEFT
    while t <= RIGHT
      ram_rw_full(t)
      send_plane(t, 0x10_u8, sh, Pointer(UInt8).null)
      ram_rw_full(t)
      send_plane(t, 0x11_u8, sh, Pointer(UInt8).null)
      t = t &+ 1
    end
    @@red_zero = false
    if @@spi_fail
      cog_stop
      return false
    end
    @@session_open = true
    @@lut_latched = true
    @@latched_fast = true
    @@latched_kind = kind
    @@diff_open = true
    @@diff_n = 0
    @@restart_ms = millis &- t0
    log("EPD: diff session open ms", @@restart_ms)
    true
  end

  # main.c:448-474 epd_partial, with the whole frame (black | red as ink)
  # into 0x10 (the box-only write there is an upload optimisation). rows <
  # HEIGHT: UPD_DIFFWIN, DRFW limited to rows 0..rows-1 (4-aligned).
  # Returns panel ms or -1.
  def self.refresh_diff(rows : Int32 = HEIGHT) : Int32
    finish_aborted
    @@spi_fail = false
    if @@diff_open && (@@diff_n >= DIFF_SESSION || @@latched_kind != LUT_DIFF)
      cog_stop
    end
    unless @@diff_open
      return -1 unless diff_open
    end
    t_up = millis
    t = LEFT
    while t <= RIGHT
      ram_rw_full(t)
      send_plane(t, 0x10_u8, @@black, @@red)
      t = t &+ 1
    end
    rows = HEIGHT if rows > HEIGHT
    rows = WIN_Y_UNIT if rows < WIN_Y_UNIT
    if rows != @@diff_rows
      u = rows.unsafe_div(WIN_Y_UNIT)
      u = u &+ 1 if u &* WIN_Y_UNIT < rows
      cmd(BOTH, 0x90_u8, 4, 0x00_u8, 0x3B_u8, 0x00_u8, rows >= HEIGHT ? 0xA9_u8 : (u &- 1).to_u8!)
      @@diff_rows = rows
    end
    @@upload_ms = millis &- t_up
    if @@spi_fail
      cog_stop
      return -1
    end
    rc = trigger(false, FAST_TIMEOUT_MS)
    @@panel_ms = rc
    if rc < 0 || @@spi_fail
      log("EPD: diff pull failed, COG powered down", rc)
      cog_stop
      return -1
    end
    d = diff_shown
    i = 0
    while i < PLANE
      d[i] = @@black[i] | @@red[i]
      i = i &+ 1
    end
    @@diff_n = @@diff_n &+ 1
    @@session_images = @@session_images &+ 1
    log3("EPD: diff rows scanned / upload ms / panel ms", @@diff_rows, @@upload_ms, rc)
    rc
  end

  # ---- ink commands (UPD_INK, Sketch) ----------------------------------------
  # Same session and 20-frame pull as UPD_DIFF, but both RAMs are written on
  # every update, so the table index (0x11 << 1) | 0x10 is a per-pixel
  # COMMAND chosen by the caller, not old/new: 0 = no drive, 1 = first pass
  # (VDH for INK_F1 frames: light), 3 = another pass (VDH for INK_F3 frames:
  # a step darker), 2 = lighten (VDL for INK_FE frames). Unmarked pixels get
  # no drive, so nothing else on the film ever changes (no seams/shadows).
  LUT_INK = 9
  @@ink_f1 = 2
  @@ink_f3 = 2
  @@ink_fe = 2 # erase of a 1-pass grey (Sketch pen cursor); 19 on black leaves pink

  def self.ink_frames(f1 : Int32, f3 : Int32, fe : Int32) : Nil
    @@ink_f1 = f1 < 1 ? 1 : (f1 > 19 ? 19 : f1)
    @@ink_f3 = f3 < 1 ? 1 : (f3 > 19 ? 19 : f3)
    @@ink_fe = fe < 1 ? 1 : (fe > 19 ? 19 : fe)
    cog_stop if @@diff_open && @@latched_kind == LUT_INK && !busy? # new table: new session
  end

  def self.ink_f1 : Int32
    @@ink_f1
  end

  def self.ink_f3 : Int32
    @@ink_f3
  end

  def self.ink_fe : Int32
    @@ink_fe
  end

  def self.build_ink : Nil
    k = 0
    while k < 50
      q = @@lut + (k &* 8).to_i64!
      q[0] = 0_u8; q[1] = 1_u8; q[2] = 1_u8; q[3] = 0_u8
      q[4] = 1_u8; q[5] = 1_u8; q[6] = 1_u8; q[7] = 1_u8
      k = k &+ 1
    end
    f = 0
    while f < 19
      g = f.unsafe_div(2)
      shift = (f & 1) == 1 ? 0 : 2
      if f < @@ink_f1
        q = @@lut + ((10 &+ g) &* 8).to_i64!
        q[0] = q[0] | 1.unsafe_shl(shift).to_u8! # table 1: VDH
      end
      if f < @@ink_fe
        q = @@lut + ((20 &+ g) &* 8).to_i64!
        q[0] = q[0] | 2.unsafe_shl(shift).to_u8! # table 2: VDL
      end
      if f < @@ink_f3
        q = @@lut + ((30 &+ g) &* 8).to_i64!
        q[0] = q[0] | 1.unsafe_shl(shift).to_u8! # table 3: VDH
      end
      f = f &+ 1
    end
  end

  # One ink pull: cmd_new -> 0x10, cmd_old -> 0x11 (whole planes, both
  # COGs), whole-panel DUW/DRFW. Returns panel ms or -1.
  def self.refresh_ink(cmd_new : UInt8*, cmd_old : UInt8*) : Int32
    finish_aborted
    @@spi_fail = false
    if @@diff_open && (@@diff_n >= DIFF_SESSION || @@latched_kind != LUT_INK)
      cog_stop
    end
    unless @@diff_open
      return -1 unless diff_open(LUT_INK)
    end
    t_up = millis
    if @@ink_win
      # back to the whole panel after windowed pulls
      cmd(BOTH, 0x13_u8, 6, 0x00_u8, 0x3B_u8, 0x00_u8, 0x00_u8, 0x9F_u8, 0x02_u8)
      cmd(BOTH, 0x90_u8, 4, 0x00_u8, 0x3B_u8, 0x00_u8, 0xA9_u8)
      @@ink_win = false
    end
    t = LEFT
    while t <= RIGHT
      ram_rw_full(t)
      send_plane(t, 0x10_u8, cmd_new, Pointer(UInt8).null)
      ram_rw_full(t)
      send_plane(t, 0x11_u8, cmd_old, Pointer(UInt8).null)
      t = t &+ 1
    end
    @@upload_ms = millis &- t_up
    if @@spi_fail
      cog_stop
      return -1
    end
    rc = trigger(false, FAST_TIMEOUT_MS)
    @@panel_ms = rc
    if rc < 0 || @@spi_fail
      log("EPD: ink pull failed, COG powered down", rc)
      cog_stop
      return -1
    end
    @@diff_n = @@diff_n &+ 1
    @@session_images = @@session_images &+ 1
    rc
  end

  # Windowed ink pull: the command planes' rows wy0..wy1 (4-aligned) go to
  # both RAMs through a full-width DUW with RAM_RW at the first row (as the
  # verified window mode 8), and the waveform scans only rows y0..y1
  # (DRFW, 4-aligned, inside wy0..wy1). Every other RAM row must already
  # hold command 0 (the caller rewrites the previous window's rows with
  # zeros via wy0..wy1), so whatever else the scan touches is not driven.
  @@ink_win = false

  def self.refresh_ink_rows(cmd_new : UInt8*, cmd_old : UInt8*, y0 : Int32, y1 : Int32,
                            wy0 : Int32, wy1 : Int32) : Int32
    finish_aborted
    @@spi_fail = false
    if @@diff_open && (@@diff_n >= DIFF_SESSION || @@latched_kind != LUT_INK)
      cog_stop
    end
    unless @@diff_open
      return -1 unless diff_open(LUT_INK)
    end
    t_up = millis
    t = LEFT
    while t <= RIGHT
      cmd(t, 0x13_u8, 6, 0x00_u8, (HALF_BYTES &- 1).to_u8!, (wy0 & 0xFF).to_u8!, wy0.unsafe_shr(8).to_u8!,
        (wy1 & 0xFF).to_u8!, wy1.unsafe_shr(8).to_u8!)
      cmd(t, 0x12_u8, 3, 0x00_u8, (wy0 & 0xFF).to_u8!, (@@otp[0x15] | wy0.unsafe_shr(8).to_u8!))
      send_box(t, 0x10_u8, cmd_new, 0, HALF_BYTES &- 1, wy0, wy1)
      cmd(t, 0x12_u8, 3, 0x00_u8, (wy0 & 0xFF).to_u8!, (@@otp[0x15] | wy0.unsafe_shr(8).to_u8!))
      send_box(t, 0x11_u8, cmd_old, 0, HALF_BYTES &- 1, wy0, wy1)
      cmd(t, 0x90_u8, 4, 0x00_u8, (HALF_BYTES &- 1).to_u8!, y0.unsafe_div(WIN_Y_UNIT).to_u8!, y1.unsafe_div(WIN_Y_UNIT).to_u8!)
      t = t &+ 1
    end
    @@ink_win = true
    @@upload_ms = millis &- t_up
    if @@spi_fail
      cog_stop
      return -1
    end
    rc = trigger(false, FAST_TIMEOUT_MS)
    @@panel_ms = rc
    if rc < 0 || @@spi_fail
      log("EPD: ink window pull failed, COG powered down", rc)
      cog_stop
      return -1
    end
    @@diff_n = @@diff_n &+ 1
    @@session_images = @@session_images &+ 1
    rc
  end

  def self.build_lutb(kind : Int32) : Nil
    if kind == LUT_INK
      build_ink
      return
    end
    if kind == LUT_DIFF
      build_diff
      return
    end
    if kind == LUT_WFAST
      build_wfast
      return
    end
    if kind == LUT_HALF60
      t = 0
      while t < 5
        g = 0
        while g < 10
          q = @@lut + ((t &* 10 &+ g) &* 8).to_i64!
          lvl = t == 1 ? 0x44_u8 : (t == 0 ? 0xAA_u8 : 0x00_u8)
          put_group_b(q, lvl, 1_u8, 1_u8, 1_u8) # put_group_b writes ph2 = 1
          g = g &+ 1
        end
        t = t &+ 1
      end
      return
    end
    shake = kind == LUT_BASE || kind == LUT_BW || kind == LUT_KEEPRED
    bw = kind == LUT_BW || kind == LUT_NOSHAKE_BW
    keepred = kind == LUT_KEEPRED || kind == LUT_NOSHAKE_KEEPRED
    t = 0
    while t < 5
      g = 0
      while g < 10
        q = @@lut + ((t &* 10 &+ g) &* 8).to_i64!
        red_level = g <= 1 ? 0xAA_u8 : 0xFF_u8
        if keepred && (t == 2 || t == 3)
          # Ground (red pixels get no drive) but with table 1's timing for
          # this group: a group only lasts as long as its shortest table, so
          # minimal 1/1/1 x1 groups here collapsed every keep-red pull to
          # ~86 ms (measured), which barely moved the ink.
          src = @@lut + ((1 &* 10 &+ g) &* 8).to_i64!
          k = 0
          while k < 8
            q[k] = src[k]
            k = k &+ 1
          end
          q[0] = 0x00_u8
        elsif t == 4
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
  # Measured (DIAG window tests v1..v3): a RAM write window (DUW) lands at
  # the wrong x, while the refresh window (DRFW) alone lands correctly. So by
  # default the full planes are uploaded (66 ms) and only DRFW is windowed;
  # the waveform time still shrinks with the DRFW rows.
  WIN_FULL_UPLOAD = true
  # Default window mode (see refresh_window2): 4 = full upload, DUW full,
  # DRFW full width x the box rows. Measured (window test v5): the panel then
  # scans from row 0 to the box's last row (~1.72 ms per row and pull), and
  # it is the only mode that drew correctly on both COGs. Modes 0/1/3 write
  # through a DUW window, which lands at the wrong x / on the wrong COG.
  # Mode 4 showed a copy of the top rows inside the refreshed band (label
  # duplicated next to the snake, v6). Mode 5 is the candidate fix; DIAG B
  # (window test v6) compares the two. Set back to 4 if 5 misbehaves.
  WIN_MODE = 5
  # Right COG's DRFW x counted from the other end (test hypothesis, v4).
  @@mirror_right = false

  def self.mirror_right=(v : Bool) : Nil
    @@mirror_right = v
  end
  WIN_PAD_ROWS = 8
  # Seam test (DIAG B v10): DRFW start / end moved by this many 4-row units
  # relative to the DUW rows. 0 / 0 everywhere else.
  @@drfw_d0 = 0
  @@drfw_d1 = 0

  def self.drfw_shift(d0 : Int32, d1 : Int32) : Nil
    @@drfw_d0 = d0
    @@drfw_d1 = d1
  end
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

  # RAM_RW (0x12) before a window upload: the OTP value (modes 0/1/3), or
  # a guess at "start of window" (modes 6/7; DIAG experiments).
  def self.ram_rw(t : Int32, wmode : Int32, x0 : Int32, y0 : Int32) : Nil
    if wmode == 8
      cmd(t, 0x12_u8, 3, 0x00_u8, (y0 & 0xFF).to_u8!, (@@otp[0x15] | y0.unsafe_shr(8).to_u8!))
    elsif wmode == 6
      cmd(t, 0x12_u8, 3, x0.to_u8!, (y0 & 0xFF).to_u8!, @@otp[0x15])
    elsif wmode == 7
      cmd(t, 0x12_u8, 3, x0.to_u8!, y0.unsafe_div(4).to_u8!, @@otp[0x15])
    else
      send_otp_to(t, 0x12_u8, 0x13, 3)
    end
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
  # wmode (DIAG calibration): 0 = DUW and DRFW both set to the box;
  # 1 = DUW box + box upload, DRFW full screen (shows where RAM writes land);
  # 2 = DUW full + full upload, DRFW box (shows where the refresh window lands);
  # 3 = ROWS ONLY: DUW and DRFW full width x the box rows, those rows
  #     uploaded at full width (x windows never land right, and only the
  #     row count affects the waveform time);
  # 4 = DUW full + full upload, DRFW full width x the box rows;
  # 5 = DUW full + full upload, THEN DUW and DRFW set to full width x the
  #     box rows with no further writes (DUW sets where the scan starts);
  # 6 = like 0, with RAM_RW = [x0, y0 & 0xFF, OTP byte 3] (start of window);
  # 7 = like 0, with RAM_RW = [x0, y0 / 4, OTP byte 3];
  # 8 = ROWS ONLY with RAM_RW at the window start: DUW full width x rows,
  #     RAM_RW = [00, y0 & FF, 0x10 | y0 >> 8] (reading OTP 00 00 10 / PDi
  #     3B 00 14 as [x start, y start low, flags | y start high]), only those
  #     rows uploaded at full width, DRFW full width x the same rows.
  #     Measured (window tests v8/v9): correct at rows 120..639 on both
  #     COGs, ~180-230 ms for 96 rows. Do NOT send 0x91 12 (Pervasive Wide
  #     Large): with it, the windows at rows 460/560 landed shifted (v8).
  def self.refresh_window2(lr0 : Int32, lr1 : Int32, lc0 : Int32, lc1 : Int32,
                           rr0 : Int32, rr1 : Int32, rc0 : Int32, rc1 : Int32, kind : Int32,
                           wmode : Int32 = WIN_MODE) : Int32
    finish_aborted
    @@spi_fail = false
    unless @@session_open && @@lut_latched && @@latched_fast && @@latched_kind == kind && @@probe < 0
      # 1 = no session, 2 = LUT not latched / slow, 3 = other kind latched
      why = !@@session_open ? 1 : (!@@lut_latched || !@@latched_fast ? 2 : (@@latched_kind != kind ? 3 : 4))
      log2("EPD: window -> full refresh, reason / kind", why, kind)
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
      if (wmode >= 3 && wmode <= 5) || wmode == 8 # rows only: full width on every COG
        x0 = 0
        x1 = HALF_BYTES &- 1
      end
      y0 = a0
      y1 = a1
      rows_total = rows_total &+ (y1 &- y0 &+ 1)
      # (no per-COG logs here: console output sits in the stroke latency)
      if wmode == 2 || wmode == 4 || wmode == 5
        send_otp_to(t, 0x13_u8, 0x16, 6) # DUW full
      else
        cmd(t, 0x13_u8, 6, x0.to_u8!, x1.to_u8!, (y0 & 0xFF).to_u8!, y0.unsafe_shr(8).to_u8!,
          (y1 & 0xFF).to_u8!, y1.unsafe_shr(8).to_u8!)
      end
      if wmode == 1
        send_otp_to(t, 0x90_u8, 0x0C, 4) # DRFW full
      elsif wmode == 5
        # DRFW (and the DUW rows) are set after the upload, below.
      else
        dx0 = x0
        dx1 = x1
        if t == RIGHT && @@mirror_right
          dx0 = HALF_BYTES &- 1 &- x1
          dx1 = HALF_BYTES &- 1 &- x0
        end
        f0 = y0.unsafe_div(u) &+ @@drfw_d0
        f1 = y1.unsafe_div(u) &+ @@drfw_d1
        f0 = 0 if f0 < 0
        f1 = HEIGHT.unsafe_div(u) &- 1 if f1 > HEIGHT.unsafe_div(u) &- 1
        cmd(t, 0x90_u8, 4, dx0.to_u8!, dx1.to_u8!, f0.to_u8!, f1.to_u8!)
      end
      if wmode == 2 || wmode == 4 || wmode == 5
        ram_rw_full(t)
        send_plane(t, 0x10_u8, @@black, Pointer(UInt8).null)
        ram_rw_full(t)
        send_plane(t, 0x11_u8, @@red, Pointer(UInt8).null)
        @@red_zero = false
        if wmode == 5
          # No more writes: now narrow DUW to the rows (it sets where the
          # scan starts) and DRFW to the same rows, both full width.
          cmd(t, 0x13_u8, 6, 0_u8, (HALF_BYTES &- 1).to_u8!, (y0 & 0xFF).to_u8!, y0.unsafe_shr(8).to_u8!,
            (y1 & 0xFF).to_u8!, y1.unsafe_shr(8).to_u8!)
          cmd(t, 0x90_u8, 4, 0_u8, (HALF_BYTES &- 1).to_u8!, y0.unsafe_div(u).to_u8!, y1.unsafe_div(u).to_u8!)
        end
      else
        ram_rw(t, wmode, x0, y0)
        send_box(t, 0x10_u8, @@black, x0, x1, y0, y1)
        zero_box = red_box_zero?(t == LEFT ? 0 : 1, x0, x1, y0, y1)
        # Keep-red kinds never change red: the COG keeps the red RAM from the
        # colour render. Writing red through a window here put red data
        # ~336 rows off (photo on f618be4, colour mode), so don't.
        keep_red = kind == LUT_KEEPRED || kind == LUT_NOSHAKE_KEEPRED
        unless keep_red || (@@skip_zero_red && zero_box && @@red_zero)
          ram_rw(t, wmode, x0, y0)
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
    log3("EPD: window y0 / rows (both COGs) / panel ms", a0, rows_total, rc)
    if rc < 0 || @@spi_fail
      log("EPD: window refresh failed, COG powered down", rc)
      cog_stop # also clears session_open / lut_latched
      return -1
    end
    # Windows count toward the session cap like full images.
    @@session_images = @@session_images &+ 1
    if @@abort
      @@stop_pending = true # waveform may still run: no commands now
      @@lut_latched = false
    elsif !@@keep_awake || @@session_images >= SESSION_IMAGES
      cog_stop
    end
    rc
  end

  # ---- refresh -----------------------------------------------------------------

  @@hook = false

  # While set, wait_busy calls epd_busy_hook (defined by the firmware) on
  # every poll.
  def self.hook=(v : Bool) : Nil
    @@hook = v
  end

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
      epd_busy_hook if @@hook # main.cr: e.g. Sketch keeps tracking the knobs
      delay_ms(@@busy_poll_ms)
    end
    0
  end

  def self.write_planes(fast_ink_red : Bool, draw_red : Bool) : Nil
    cmd1(0x01_u8, @@otp[0x10]) if @@driver_b # DCTL before the windows on driver B
    # Full-screen DUW and DRFW on every upload, so no window left by a
    # window test (or window mode) can survive into a full refresh: once to
    # both COGs (as epd97.cpp), then to each COG on its own.
    send_otp(0x13_u8, 0x16, 6)              # DUW
    send_otp(0x90_u8, 0x0C, 4)              # DRFW
    send_otp_to(LEFT, 0x13_u8, 0x16, 6)
    send_otp_to(LEFT, 0x90_u8, 0x0C, 4)
    send_otp_to(RIGHT, 0x13_u8, 0x16, 6)
    send_otp_to(RIGHT, 0x90_u8, 0x0C, 4)
    t = LEFT
    while t <= RIGHT
      ram_rw_full(t) # RAM_RW
      send_plane(t, 0x10_u8, @@black, fast_ink_red ? @@red : Pointer(UInt8).null)
      unless @@skip_zero_red && !draw_red && @@red_zero
        ram_rw_full(t)
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
    q = @@quick
    hi = q ? 2 : 100 # load strobe waits (quick: PDi Wide_Large)
    lo = q ? 10 : 100
    cmd1(0x05_u8, 0x7D_u8); delay_ms(q ? 50 : 200)
    cmd1(0x05_u8, 0x00_u8); delay_ms(q ? 1 : 10)
    cmd1(0xC2_u8, 0x3F_u8) unless b
    cmd1(0xD8_u8, @@otp[0x1D])
    cmd1(0xD6_u8, @@otp[0x1E])
    cmd1(0xA7_u8, 0x10_u8); delay_ms(hi)
    cmd1(0xA7_u8, 0x00_u8); delay_ms(lo)
    cmd(BOTH, 0x03_u8, 2, 0x00_u8, @@otp[0x12]) unless b # OSC, driver 8 only
    cmd1(0x44_u8, 0x00_u8)
    cmd1(0x45_u8, 0x80_u8)
    cmd1(0xA7_u8, 0x10_u8); delay_ms(hi)
    cmd1(0xA7_u8, 0x00_u8); delay_ms(lo)
    cmd1(0x44_u8, 0x06_u8)
    cmd1(0x45_u8, b ? REG45_B1 : REG45_084) # temperature: 0x50 + 2 x degC (0x84 = 26 C)
    cmd1(0xA7_u8, 0x10_u8); delay_ms(hi)
    cmd1(0xA7_u8, 0x00_u8); delay_ms(q ? lo : T_PRE_SS) # 0xB0 latches ~10 ms after this strobe
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
    delay_ms(T_PRE_UPD) unless @@quick
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
    finish_aborted
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
      cog_initial(fast && @@quick_open)
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
    # Backstop: a full-screen fast pull is ~1.16 s on driver B. A pull that
    # finishes in < COLLAPSED_MS drove (almost) nothing (seen: 72 ms right
    # after a session open). Close the session with a power cycle, reopen it
    # with the reference waits and redo this image once.
    if fast && @@driver_b && rc >= 0 && rc < COLLAPSED_MS && @@lut_kind != LUT_WFAST
      @@collapsed = @@collapsed &+ 1
      log2("EPD: collapsed pull ms / first-of-session", rc, first ? 1 : 0)
      log2("EPD:   session quick / supply powered", @@quick ? 1 : 0, @@powered ? 1 : 0)
      save_quick = @@quick_open
      @@quick_open = false # the stop powers the supply off; reopen the slow way
      @@quick = false
      cog_stop
      cog_initial(false)
      @@session_open = true
      @@lut_latched = false
      write_planes(have_red && !draw_red, draw_red)
      rc = do_refresh(fast)
      @@quick_open = save_quick
      first = true
      log("EPD: collapsed pull redone, panel ms", rc)
    end
    t_ref_end = millis
    # Restart cost: power-up/reset before the upload plus, for the first image
    # of a session, the register/soft-start time ahead of the first pull.
    @@restart_ms = (t_up &- t_init) &+ (first && rc >= 0 ? (t_ref_end &- t_up_end) &- rc : 0)
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
    diff_mark_shown if rc >= 0
    # Like epd97.cpp (EPD_SESSION_IMAGES), close the session after a bounded
    # number of images so the COG is re-initialised regularly.
    @@session_images = @@session_images &+ 1
    keep = @@keep_awake && @@lut_latched && @@session_images < SESSION_IMAGES
    if @@abort
      # Aborted (Menu): the waveform is still running. Leave the COG alone
      # (no commands while BUSY is low); the next refresh closes it first.
      @@stop_pending = true
      @@lut_latched = false
    else
      cog_stop unless keep
    end
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
