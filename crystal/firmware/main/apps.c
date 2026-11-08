// C helpers for the app registry (src/apps/): battery level.
#include <stdint.h>
#include <stdbool.h>
#include "esp_adc/adc_oneshot.h"
#include "esp_adc/adc_cali.h"
#include "esp_adc/adc_cali_scheme.h"

// Battery: GPIO14 (BAT_SENS) sees half the LDO input through a 10k/10k
// divider: the LiPo voltage on battery, about VBUS - 0.3 V on USB (the
// power path cuts the cell off). Method after badge os (yigitabi5444).
// ADC2 is shared with Wi-Fi; a failed read returns the last good value.
// Returns 0..100, -1 on USB power, -2 unknown.
int32_t cr_battery_pct(void)
{
    static adc_oneshot_unit_handle_t adc;
    static adc_cali_handle_t cali;
    static adc_channel_t ch;
    static int32_t last = -2;
    static bool tried;
    if (!tried) {
        tried = true;
        adc_unit_t unit;
        if (adc_oneshot_io_to_channel(14, &unit, &ch) != ESP_OK) return last;
        adc_oneshot_unit_init_cfg_t uc = {.unit_id = unit};
        if (adc_oneshot_new_unit(&uc, &adc) != ESP_OK) { adc = NULL; return last; }
        adc_oneshot_chan_cfg_t cc = {.atten = ADC_ATTEN_DB_12, .bitwidth = ADC_BITWIDTH_DEFAULT};
        adc_oneshot_config_channel(adc, ch, &cc);
        adc_cali_curve_fitting_config_t kc = {.unit_id = unit, .chan = ch, .atten = ADC_ATTEN_DB_12,
                                              .bitwidth = ADC_BITWIDTH_DEFAULT};
        if (adc_cali_create_scheme_curve_fitting(&kc, &cali) != ESP_OK) cali = NULL;
    }
    if (!adc || !cali) return last;
    int sum = 0;
    for (int k = 0; k < 8; k++) {
        int mv;
        if (adc_oneshot_get_calibrated_result(adc, cali, ch, &mv) != ESP_OK) return last;
        sum += mv;
    }
    int vin = sum / 8 * 2;
    if (vin > 4400) return last = -1;
    // typical LiPo rest-voltage curve (not measured on this cell; ~10 %)
    static const int v[] = {3300, 3500, 3600, 3700, 3800, 3900, 4000, 4100, 4200};
    static const int p[] = {0, 3, 10, 25, 45, 62, 77, 90, 100};
    if (vin <= v[0]) return last = 0;
    for (int i = 1; i < 9; i++)
        if (vin < v[i]) return last = p[i - 1] + (p[i] - p[i - 1]) * (vin - v[i - 1]) / (v[i] - v[i - 1]);
    return last = 100;
}

// ---- Schedule app (src/apps/schedule.cr) -------------------------------------
#include <time.h>
#include <stdlib.h>
#include "esp_sntp.h"

// data/schedule.csv, embedded (EMBED_FILES); the Crystal side parses it.
extern const uint8_t sched_csv_start[] asm("_binary_schedule_csv_start");
extern const uint8_t sched_csv_end[] asm("_binary_schedule_csv_end");
const uint8_t *cr_schedule_csv(void) { return sched_csv_start; }
int32_t cr_schedule_csv_size(void) { return (int32_t)(sched_csv_end - sched_csv_start); }

// ---- Slides app (src/apps/slides.cr) ------------------------------------------
// main/slides.bin, embedded (EMBED_FILES): the packed deck from slides/convert.cr.
extern const uint8_t slides_bin_start[] asm("_binary_slides_bin_start");
extern const uint8_t slides_bin_end[] asm("_binary_slides_bin_end");
const uint8_t *cr_slides_bin(void) { return slides_bin_start; }
int32_t cr_slides_bin_size(void) { return (int32_t)(slides_bin_end - slides_bin_start); }

bool cr_wifi_connected(void); // main/ota.c

// Local time at Supercon (Pasadena). Starts SNTP once Wi-Fi is up (network
// mode). Fills v[0..4] = year, month (1-12), day, hour, minute and returns
// true once the clock has been set.
bool cr_time_local(int32_t *v)
{
    static bool tz, sntp;
    if (!tz) {
        setenv("TZ", "PST8PDT,M3.2.0,M11.1.0", 1);
        tzset();
        tz = true;
    }
    if (!sntp && cr_wifi_connected()) {
        esp_sntp_setoperatingmode(ESP_SNTP_OPMODE_POLL);
        esp_sntp_setservername(0, "pool.ntp.org");
        esp_sntp_init();
        sntp = true;
    }
    time_t now = time(NULL);
    if (now < 1700000000) return false;
    struct tm t;
    localtime_r(&now, &t);
    v[0] = t.tm_year + 1900, v[1] = t.tm_mon + 1, v[2] = t.tm_mday, v[3] = t.tm_hour, v[4] = t.tm_min;
    return true;
}

// Shell `clock Y M D h m`: set the clock by hand (local time), for testing
// the Schedule app's now/next marks without Wi-Fi.
#include <sys/time.h>
void cr_time_set(int32_t y, int32_t mo, int32_t d, int32_t h, int32_t mi)
{
    int32_t v[5];
    cr_time_local(v); // sets TZ
    struct tm t = {.tm_year = y - 1900, .tm_mon = mo - 1, .tm_mday = d, .tm_hour = h, .tm_min = mi, .tm_isdst = -1};
    struct timeval tv = {.tv_sec = mktime(&t)};
    settimeofday(&tv, NULL);
}
