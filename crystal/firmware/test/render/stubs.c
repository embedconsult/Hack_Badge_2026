// Host stubs for test/render/render_apps.cr (renders app screens to PBM).
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../../main/font5x7.h"
const uint8_t *cr_font5x7(void) { return &k_font5x7[0][0]; }
const char *cr_version(void) { return "v0.1-host 12:00"; }
int32_t cr_battery_pct(void) { return 87; }
void *heap_caps_malloc(uint32_t n, uint32_t caps) { return calloc(1, n); }
void heap_caps_free(void *p) { free(p); }
void cr_log(const char *m, int32_t v) { printf("%s: %d\n", m, v); }
static uint8_t *s_csv; static int s_csv_n;
const uint8_t *cr_schedule_csv(void) {
    if (!s_csv) { FILE *f = fopen("../../main/schedule.csv", "rb"); s_csv = malloc(65536); s_csv_n = fread(s_csv, 1, 65536, f); fclose(f); }
    return s_csv;
}
int32_t cr_schedule_csv_size(void) { cr_schedule_csv(); return s_csv_n; }
int32_t g_time[5] = {0};
bool cr_time_local(int32_t *v) { if (!g_time[0]) return false; memcpy(v, g_time, sizeof g_time); return true; }
void set_time(int32_t y, int32_t mo, int32_t d, int32_t h, int32_t mi) { g_time[0]=y; g_time[1]=mo; g_time[2]=d; g_time[3]=h; g_time[4]=mi; }
int32_t cr_settings_start(void) { return 0; }
void cr_settings_stop(void) {}
const char *cr_settings_ssid(void) { return "Badge-1A2B"; }
const char *cr_settings_pass(void) { return "k7xq3mzp"; }
uint32_t cr_settings_saves(void) { return 0; }
const char *cr_settings_msg(void) { return "Saved."; }
int32_t cr_settings_clients(void) { return 1; }
int32_t cr_qr_encode(const uint8_t *t, int32_t n, uint8_t *o);
int32_t cr_settings_qr(int32_t which, uint8_t *out) {
    const char *t = which == 0 ? "WIFI:T:WPA;S:Badge-1A2B;P:k7xq3mzp;;" : "http://192.168.4.1/";
    return cr_qr_encode((const uint8_t *)t, strlen(t), out);
}
