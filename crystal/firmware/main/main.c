// C entry point and tiny shims for the Crystal firmware (src/*.cr).
// Logic lives in Crystal; this file only has what Crystal can't express
// under --prelude=empty: macros, printf, task creation, layout checks.
#include <stdint.h>
#include <stdio.h>
#include <stddef.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/spi_master.h"

// Tick rate exported for Crystal (configTICK_RATE_HZ is a macro).
const uint32_t crystal_tick_rate_hz = configTICK_RATE_HZ;

void crystal_app_main(void);           // src/main.cr: EPD demo
void crystal_knob_task(void *arg);     // src/main.cr: LED blink + knob log

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

void app_main(void)
{
    xTaskCreatePinnedToCore(crystal_knob_task, "knob", 4096, NULL, 2, NULL, 1);
    crystal_app_main();
}
