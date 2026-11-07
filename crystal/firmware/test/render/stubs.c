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

// SNAKES (main/snakes_net.c): two saved bots that answer "keep going"
static const char *k_bn[] = {"alice", "zigzag-9000"}, *k_bu[] = {"http://192.168.1.20:8000", "https://zz.example.com/snake"};
int32_t cr_snk_cmd(const uint8_t *l, int32_t n) { return 0; }
int32_t cr_snk_bots(void) { return 2; }
const uint8_t *cr_snk_bot_name(int32_t i) { return (const uint8_t *)k_bn[i & 1]; }
const uint8_t *cr_snk_bot_url(int32_t i) { return (const uint8_t *)k_bu[i & 1]; }
int32_t cr_snk_bot_state(int32_t i) { return i == 0 ? 2 : 3; }
int32_t cr_snk_bot_ms(int32_t i) { return 14; }
const uint8_t *cr_snk_bot_author(int32_t i) { return (const uint8_t *)"jkridner"; }
uint32_t cr_snk_sig(void) { return 1; }
int32_t cr_snk_net(void) { return 0; }
int32_t cr_snk_busy(void) { return 0; }
void cr_snk_ping(void) {}
static int32_t s_who[4];
void cr_snk_begin(int32_t n, const int32_t *who, uint32_t seed, const int32_t *snap, int32_t nsnap) { memcpy(s_who, who, n * 4); }
void cr_snk_turn(const int32_t *snap, int32_t n) {}
void cr_snk_end(const int32_t *snap, int32_t n) {}
int32_t cr_snk_move(int32_t i) { return -1; } // every bot move missed: auto moves
int32_t cr_snk_err(int32_t i) { return i == 3 ? 3 : 0; }
int32_t cr_snk_ms(int32_t i) { return 20 + 7 * i; }
int32_t cr_snk_misses(int32_t i) { return i == 3 ? 2 : 0; }
const uint8_t *cr_snk_name(int32_t i) { return s_who[i] < 0 ? (const uint8_t *)"house-1" : cr_snk_bot_name(s_who[i]); }
const uint8_t *cr_snk_shout(int32_t i) { return (const uint8_t *)"turn 12: up"; }
const uint8_t *cr_snk_err_name(int32_t e) { return (const uint8_t *)"timeout"; }
uint32_t esp_random(void) { return 12345; }
