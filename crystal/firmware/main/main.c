// C entry point for the Crystal blink firmware.
#include <stdint.h>
#include "freertos/FreeRTOS.h"

// Tick rate exported for Crystal (configTICK_RATE_HZ is a macro).
const uint32_t crystal_tick_rate_hz = configTICK_RATE_HZ;

void crystal_app_main(void); // src/main.cr

void app_main(void)
{
    crystal_app_main();
}
