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

// ROBOTS (main/robots.c): slots in memory.
static char s_rsrc[8][8192], s_rname[8][17];
static int s_rlen[8] = {-1, -1, -1, -1, -1, -1, -1, -1};
int32_t cr_robot_slots(void) { return 8; }
int32_t cr_robot_max(void) { return 8160; }
int32_t cr_robot_len(int32_t k) { return s_rlen[k]; }
int32_t cr_robot_read(int32_t k, uint8_t *b, int32_t max) {
    if (s_rlen[k] < 0) return -1;
    memcpy(b, s_rsrc[k], s_rlen[k]);
    return s_rlen[k];
}
bool cr_robot_write(int32_t k, const uint8_t *s, int32_t n, const char *name) {
    s_rlen[k] = n > 0 ? n : -1;
    if (n > 0) memcpy(s_rsrc[k], s, n);
    snprintf(s_rname[k], 17, "%s", name ? name : "");
    return true;
}
bool cr_robot_name(int32_t k, char *out) { strcpy(out, s_rname[k]); return s_rlen[k] >= 0; }
static uint8_t s_tbl[2][2048];
static int s_tbl_n[2] = {-1, -1};
bool cr_robot_tbl_save(int32_t w, const uint8_t *p, int32_t n) {
    memcpy(s_tbl[w], p, n);
    s_tbl_n[w] = n;
    printf("stub: standings %d saved, %d bytes\n", w, n);
    return true;
}
int32_t cr_robot_tbl_load(int32_t w, uint8_t *p, int32_t max) {
    if (s_tbl_n[w] < 0) return -1;
    memcpy(p, s_tbl[w], s_tbl_n[w] < max ? s_tbl_n[w] : max);
    return s_tbl_n[w];
}
void cr_robot_tbl_print(int32_t w) { printf("stub: standings %d printed\n", w); }
uint32_t cr_atomic_xchg(uint32_t *p, uint32_t v) { uint32_t o = *p; *p = v; return o; }
void vTaskDelay(uint32_t t) {}
void cr_print(const char *s) { fputs(s, stdout); }
void cr_notify_main(void) {}

// Badge-to-badge battles (main/robonet.c via net.c): a two-entry cache;
// stub_rn_offer() makes the next cr_rn_take_match return a match of them.
static char s_rn[2][8192];
static int s_rn_len[2], s_rn_n, s_rn_offer, s_rn_state;
int32_t cr_rn_add(const uint8_t *s, int32_t n) {
    if (s_rn_n >= 2) return -1;
    memcpy(s_rn[s_rn_n], s, n);
    s_rn_len[s_rn_n] = n;
    return s_rn_n++;
}
int32_t cr_rn_read(int32_t i, uint8_t *b, int32_t max) { memcpy(b, s_rn[i], s_rn_len[i]); return s_rn_len[i]; }
int32_t cr_rn_challenge(const uint8_t *nm, int32_t nl, const int32_t *idx, int32_t n, uint32_t seed, uint32_t limit) { return -4; }
void stub_rn_offer(void) { s_rn_offer = 1; }
int32_t cr_rn_take_match(uint32_t *id, uint32_t *seed, uint32_t *limit, int32_t *n, int32_t *idx) {
    if (!s_rn_offer) return 0;
    s_rn_offer = 0, s_rn_state = 1;
    *id = 0x1234, *seed = 42, *limit = 500000, *n = 2, idx[0] = 0, idx[1] = 1;
    return 1;
}
void cr_rn_result(uint32_t id, uint32_t cycles, int32_t winner, int32_t n, const uint8_t *dmg, uint32_t hash) {
    printf("stub: result sent: cycles %u winner %d hash %08x\n", cycles, winner, hash);
    s_rn_state = 2;
}
int32_t cr_rn_status(char *buf, int32_t max) {
    snprintf(buf, max, s_rn_state == 2 ? "SimBeagle got the same result" : s_rn_state ? "battle with SimBeagle" : "");
    return s_rn_state == 2 ? 4 : s_rn_state ? 2 : 0;
}
