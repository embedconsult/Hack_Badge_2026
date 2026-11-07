// C entry point and tiny shims for the Crystal firmware (src/*.cr).
// Logic lives in Crystal; this file only has what Crystal can't express
// under --prelude=empty: macros, printf, task creation, layout checks.
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stddef.h>
#include "freertos/FreeRTOS.h"
#include "sdkconfig.h"

// Settings the Crystal code relies on. build.sh regenerates sdkconfig when
// sdkconfig.defaults changes; these catch a stale one.
#if CONFIG_FREERTOS_HZ != 1000
#error "CONFIG_FREERTOS_HZ must be 1000: src/epd.cr treats 1 tick as 1 ms"
#endif
#if CONFIG_ESP_MAIN_TASK_STACK_SIZE < 8192
#error "CONFIG_ESP_MAIN_TASK_STACK_SIZE must be >= 8192 (smaller overflowed silently and killed USB)"
#endif
#if !CONFIG_SPIRAM
#warning "PSRAM disabled: frame buffers fall back to internal RAM"
#endif
#include "freertos/task.h"
#include "driver/spi_master.h"
#include "driver/rmt_tx.h"
#include "hal/usb_serial_jtag_ll.h"
#include "esp_heap_caps.h"
#include "font5x7.h"   // from 2026-Billboard_Badge/firmware/esp32s3-itc97
#include "version.h"   // written by build.sh: git describe + build time

// Tick rate exported for Crystal (configTICK_RATE_HZ is a macro).
const uint32_t crystal_tick_rate_hz = configTICK_RATE_HZ;

void crystal_app_main(void);           // src/main.cr: EPD demo
void crystal_knob_task(void *arg);     // src/main.cr: LED blink + knob log
void crystal_shell_task(void *arg);    // src/shell.cr: debug shell on the console
void cr_ota_boot_guard(void);          // main/ota.c: roll back an unconfirmed new image
void cr_net_boot(void);                // main/net.c: network mode, if saved on

void cr_log(const char *msg, int32_t v) { printf("%s: %ld\n", msg, (long)v); }
void cr_log2(const char *msg, int32_t a, int32_t b) { printf("%s: %ld %ld\n", msg, (long)a, (long)b); }
void cr_hex(const char *msg, const uint8_t *d, int32_t n)
{
    printf("%s:", msg);
    for (int32_t i = 0; i < n; i++) printf("%s%02X", (i % 16) ? " " : "\n  ", d[i]);
    printf("\n");
}

// The Crystal side declares these structs by hand (src/epd.cr). Check the
// sizes at build time and the field offsets that matter...
_Static_assert(sizeof(spi_bus_config_t) == 56, "spi_bus_config_t");
_Static_assert(offsetof(spi_bus_config_t, max_transfer_sz) == 40, "max_transfer_sz");
_Static_assert(sizeof(spi_device_interface_config_t) == 48, "spi_device_interface_config_t");
_Static_assert(offsetof(spi_device_interface_config_t, clock_speed_hz) == 16, "clock_speed_hz");
_Static_assert(offsetof(spi_device_interface_config_t, spics_io_num) == 28, "spics_io_num");
_Static_assert(offsetof(spi_device_interface_config_t, queue_size) == 36, "queue_size");
_Static_assert(sizeof(spi_transaction_t) == 40, "spi_transaction_t");
_Static_assert(offsetof(spi_transaction_t, length) == 16, "length");
_Static_assert(offsetof(spi_transaction_t, tx_buffer) == 28, "tx_buffer");

_Static_assert(sizeof(rmt_tx_channel_config_t) == 28, "rmt_tx_channel_config_t");
_Static_assert(sizeof(rmt_bytes_encoder_config_t) == 12, "rmt_bytes_encoder_config_t");
_Static_assert(sizeof(rmt_transmit_config_t) == 8, "rmt_transmit_config_t");
_Static_assert(RMT_CLK_SRC_DEFAULT == 4, "RMT_CLK_SRC_DEFAULT");

// ...and at run time that Crystal computed the same sizes.
int32_t cr_check_layout(int32_t bus, int32_t dev, int32_t trans)
{
    int bad = bus != (int32_t)sizeof(spi_bus_config_t) ||
              dev != (int32_t)sizeof(spi_device_interface_config_t) ||
              trans != (int32_t)sizeof(spi_transaction_t);
    if (bad) printf("layout: crystal %ld/%ld/%ld, C %u/%u/%u\n", (long)bus, (long)dev, (long)trans,
                    (unsigned)sizeof(spi_bus_config_t), (unsigned)sizeof(spi_device_interface_config_t),
                    (unsigned)sizeof(spi_transaction_t));
    return bad;
}

// Images embedded with EMBED_FILES (main/CMakeLists.txt).
extern const uint8_t hello_png_start[] asm("_binary_hello_i_am_blank_png_start");
extern const uint8_t hello_png_end[] asm("_binary_hello_i_am_blank_png_end");
const uint8_t *cr_hello_png(void) { return hello_png_start; }
int32_t cr_hello_png_size(void) { return (int32_t)(hello_png_end - hello_png_start); }
extern const uint8_t portrait_png_start[] asm("_binary_portrait_png_start");
extern const uint8_t portrait_png_end[] asm("_binary_portrait_png_end");
const uint8_t *cr_portrait_png(void) { return portrait_png_start; }
int32_t cr_portrait_png_size(void) { return (int32_t)(portrait_png_end - portrait_png_start); }
extern const uint8_t sketch_png_start[] asm("_binary_sketch_frame_png_start");
extern const uint8_t sketch_png_end[] asm("_binary_sketch_frame_png_end");
const uint8_t *cr_sketch_png(void) { return sketch_png_start; }
int32_t cr_sketch_png_size(void) { return (int32_t)(sketch_png_end - sketch_png_start); }
extern const uint8_t etch_png_start[] asm("_binary_EtchASketch_png_start");
extern const uint8_t etch_png_end[] asm("_binary_EtchASketch_png_end");
const uint8_t *cr_etch_png(void) { return etch_png_start; }
int32_t cr_etch_png_size(void) { return (int32_t)(etch_png_end - etch_png_start); }

// 5x7 font, ASCII 0x20..0x7E, 5 column bytes per glyph (LSB = top row).
const uint8_t *cr_font5x7(void) { return &k_font5x7[0][0]; }

// Atomic helpers for state shared between the knob task and the main task.
uint32_t cr_atomic_or(uint32_t *p, uint32_t v) { return __atomic_fetch_or(p, v, __ATOMIC_SEQ_CST); }
uint32_t cr_atomic_xchg(uint32_t *p, uint32_t v) { return __atomic_exchange_n(p, v, __ATOMIC_SEQ_CST); }

// Knob task -> main task wake-up (xTaskNotifyGive / ulTaskNotifyTake are macros).
static TaskHandle_t s_main_task;
void cr_notify_main(void) { if (s_main_task) xTaskNotifyGive(s_main_task); }
uint32_t cr_wait_notify(uint32_t ms) { return ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(ms)); }

// Debug shell I/O (src/shell.cr): poll the USB-Serial/JTAG RX FIFO directly
// (no driver install, so the console output path is unchanged).
int32_t cr_console_read(uint8_t *buf, int32_t max)
{
    if (!usb_serial_jtag_ll_rxfifo_data_available()) return 0;
    return (int32_t)usb_serial_jtag_ll_read_rxfifo(buf, (uint32_t)max);
}
void cr_print(const char *s) { fputs(s, stdout); fflush(stdout); }
void cr_log3(const char *msg, int32_t a, int32_t b, int32_t c) { printf("%s: %ld %ld %ld\n", msg, (long)a, (long)b, (long)c); }
int32_t cr_heap_free(uint32_t caps) { return (int32_t)heap_caps_get_free_size(caps); }
uint32_t cr_stack_free_self(void) { return (uint32_t)uxTaskGetStackHighWaterMark(NULL); }

// Stack high-water marks (bytes never used) for the knob task (the caller)
// and the main task; logged every 10 s by the knob task.
uint32_t cr_stack_free(bool main_task)
{
    return (uint32_t)uxTaskGetStackHighWaterMark(main_task ? s_main_task : NULL);
}

// "<git describe> <HH:MM>" of this build.
const char *cr_version(void) { return CR_VERSION; }

void app_main(void)
{
    printf("crystal firmware %s\n", CR_VERSION);
    s_main_task = xTaskGetCurrentTaskHandle();
    cr_ota_boot_guard();
    // Give the Mac's RFC2217 bridge time to come back after a flash/reset,
    // so the start-up log is not lost.
    vTaskDelay(pdMS_TO_TICKS(4000));
    printf("app_main: starting tasks\n");
    xTaskCreatePinnedToCore(crystal_knob_task, "knob", 12288, NULL, 2, NULL, 1);
    xTaskCreatePinnedToCore(crystal_shell_task, "shell", 12288, NULL, 1, NULL, 1); // `robot put` parses robots here
    cr_net_boot();
    crystal_app_main();
}
