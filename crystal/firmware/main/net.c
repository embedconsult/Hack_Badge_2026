// Network mode: badge link protocol (crystal/net/PROTOCOL.md) over UDP on the
// Wi-Fi network, plus ESP-NOW in yigitabi5444's badge os formats, and a Pong
// peer that plays badge os's game (link.h / app_pong.c, same packets and rules).
//
// Everything runs on one task (net_task); the Wi-Fi callbacks only queue. The
// Crystal side (src/net.cr) reads status text and Pong state, feeds knob and
// button samples, and the shell task executes the remote command lines this
// module queues (so only the main task ever touches the e-paper).
//
// NVS namespace "net": on (u8), name (str "first|last").
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "esp_wifi.h"
#include "esp_now.h"
#include "esp_mac.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "lwip/sockets.h"

bool cr_wifi_hold(void);               // main/ota.c
void cr_wifi_release(void);
bool cr_wifi_connected(void);
const char *cr_wifi_ip(void);
int32_t cr_wifi_channel(void);
int32_t cr_wifi_rssi(void);
void cr_notify_main(void);             // main/main.c

#define PORT 4626
#define HELLO_MS 1000
#define PEERS 12
#define STALE_MS 15000
#define RSSI_WIN_MS 4000
#define LINES 8
#define NLINE_MAX 124

// screens (src/main.cr SCR_*)
#define SCR_NAMETAG 0
#define SCR_SKETCH 2
#define SCR_PONG 7

enum { K_BEAGLE = 1, K_CRYSTAL = 2, K_BADGEOS = 3 };
enum { CAP_REMOTE = 1, CAP_PONG = 2, CAP_BRIDGE = 4, CAP_SKETCH = 8 };

// ---- Pong: badge os's link.h and app_pong.c rules ---------------------------
#define W 960
#define CH (672 - 48)
#define STEP_MS 15
#define BALL_V 2
#define BALL_DY 3
#define PAD_V 4
#define PAUSE_MS 2500
#define BALL 24
#define PADW 16
#define PADH 120
#define PADX 24
#define WIN 4
#define LINK_WINDOW 500
#define LINK_DECIDE 600
#define LINK_GIVEUP 1500
#define LINK_TIMEOUT 1000
#define LINK_PAIR_MS 50
#define LINK_GAME_MS 100
enum { L_FREE, L_SEEK, L_PAIRED };
enum { P_PAIR = 1, P_GAME = 2 };

typedef struct __attribute__((packed)) {
    int16_t bx, by;
    int8_t dx, dy;
    int16_t py[2];
    uint8_t score[2];
} game_t;

typedef struct __attribute__((packed)) {
    char magic[4]; // "PONG"
    uint8_t type;
    uint16_t age;
    uint8_t peer[6];
    game_t g;
} pkt_t;
_Static_assert(sizeof(pkt_t) == 25, "pkt_t as in badge os");

typedef struct __attribute__((packed)) {
    char magic[4]; // "BOSR"
    uint8_t ap[6];
    uint8_t n;
    struct __attribute__((packed)) { uint8_t mac[6]; int16_t cm; } r[8];
} bosr_t;

typedef struct __attribute__((packed)) {
    char magic[3]; // "BLK"
    uint8_t ver, type, seq;
    uint8_t src[6];
} hdr_t;

typedef struct {
    uint8_t mac[6], via[6];
    uint8_t kind, caps, screen, flags;
    char name[13];
    uint32_t ip;           // network order, 0 = ESP-NOW only
    int8_t rssi;           // what I hear from it (max over RSSI_WIN_MS), 127 unknown
    int8_t their;          // what it hears from me (its heard list), 127 unknown
    int16_t cm;
    int64_t seen, rssi_at;
} peer_t;

static peer_t s_peer[PEERS];
static uint8_t s_me[6];
static volatile bool s_run, s_task_alive;
static volatile int32_t s_screen;
static volatile uint32_t s_ver;  // status text changes
static int s_sock = -1;
static uint8_t s_seq;
static bool s_espnow;
static char s_name[2][13] = {"Jason", "Kridner"};
static char s_state[40] = "off";
static portMUX_TYPE s_mux = portMUX_INITIALIZER_UNLOCKED;

// remote command lines for the shell task
static char s_lines[LINES][NLINE_MAX];
static volatile int s_lh, s_lt;

// ESP-NOW and promiscuous RX -> net task
typedef struct { uint8_t src[6]; int8_t rssi; uint8_t len; uint8_t d[200]; } enow_t;
static QueueHandle_t s_rxq;
#define PROMISC_N 8
static uint8_t s_pm_mac[PROMISC_N][6]; // MACs the promiscuous callback watches (UDP peers)
static volatile int8_t s_pm_rssi[PROMISC_N];
static volatile uint32_t s_pm_cnt[PROMISC_N];
static volatile int s_pm_n;

// Pong
static struct {
    int state;
    uint8_t peer[6];
    int64_t press, last_rx, next_tx, next_step, serve_at, red_until;
    struct { uint8_t mac[6]; int64_t press; } heard[4];
    bool host, tunnel_peer;   // peer over ESP-NOW (else UDP)
    int8_t sdx;
    game_t g;
    uint32_t frames;
} P;
static volatile int32_t s_in_l = -1, s_in_btn; // knob task samples
static int32_t s_knob_last = -1, s_knob_acc;
static uint32_t s_btn_prev;
static const uint8_t zero6[6], bcast6[6] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};

static int64_t now_ms(void) { return esp_timer_get_time() / 1000; }

// ---- NVS ---------------------------------------------------------------------

static bool nv(nvs_handle_t *h, bool rw)
{
    nvs_flash_init();
    return nvs_open("net", rw ? NVS_READWRITE : NVS_READONLY, h) == ESP_OK;
}

static void load_name(void)
{
    nvs_handle_t h;
    char buf[28];
    size_t n = sizeof buf;
    if (!nv(&h, false)) return;
    if (nvs_get_str(h, "name", buf, &n) == ESP_OK) {
        char *bar = strchr(buf, '|');
        if (bar) *bar = 0;
        snprintf(s_name[0], sizeof s_name[0], "%.12s", buf);
        snprintf(s_name[1], sizeof s_name[1], "%.12s", bar ? bar + 1 : "");
    }
    nvs_close(h);
}

// Nametag lines (Crystal draw_name)
int32_t cr_name_len(int32_t i) { return (int32_t)strlen(s_name[i & 1]); }
const uint8_t *cr_name_ptr(int32_t i) { return (const uint8_t *)s_name[i & 1]; }

// "first|last" (or one line); saved in NVS.
void cr_name_set(const uint8_t *s, int32_t n)
{
    char buf[28];
    if (n < 0) n = 0;
    if (n > 26) n = 26;
    memcpy(buf, s, n);
    buf[n] = 0;
    for (int i = 0; i < n; i++)
        if (buf[i] < 0x20 || buf[i] > 0x7E) buf[i] = '?';
    char *bar = strchr(buf, '|');
    if (bar) *bar = 0;
    snprintf(s_name[0], sizeof s_name[0], "%.12s", buf);
    snprintf(s_name[1], sizeof s_name[1], "%.12s", bar ? bar + 1 : "");
    if (bar) *bar = '|';
    nvs_handle_t h;
    if (nv(&h, true)) { nvs_set_str(h, "name", buf); nvs_commit(h); nvs_close(h); }
    s_ver++;
}

// ---- command lines -> shell task -------------------------------------------

static bool push_line(const char *s, int n)
{
    bool ok = false;
    taskENTER_CRITICAL(&s_mux);
    int nh = (s_lh + 1) % LINES;
    if (nh != s_lt) {
        if (n > NLINE_MAX - 1) n = NLINE_MAX - 1;
        memcpy(s_lines[s_lh], s, n);
        s_lines[s_lh][n] = 0;
        s_lh = nh;
        ok = true;
    }
    taskEXIT_CRITICAL(&s_mux);
    return ok;
}

// Shell task: next queued remote line into buf (no newline); 0 = none.
int32_t cr_net_take_line(uint8_t *buf, int32_t max)
{
    int32_t n = 0;
    taskENTER_CRITICAL(&s_mux);
    if (s_lt != s_lh) {
        n = (int32_t)strlen(s_lines[s_lt]);
        if (n > max) n = max;
        memcpy(buf, s_lines[s_lt], n);
        s_lt = (s_lt + 1) % LINES;
    }
    taskEXIT_CRITICAL(&s_mux);
    return n;
}

// ---- peers -------------------------------------------------------------------

static peer_t *peer_find(const uint8_t *mac, bool add)
{
    int old = 0;
    for (int i = 0; i < PEERS; i++) {
        if (s_peer[i].seen && !memcmp(s_peer[i].mac, mac, 6)) return &s_peer[i];
        if (s_peer[i].seen < s_peer[old].seen) old = i;
    }
    if (!add) return NULL;
    peer_t *p = &s_peer[old];
    memset(p, 0, sizeof *p);
    memcpy(p->mac, mac, 6);
    p->rssi = p->their = 127;
    p->cm = -1;
    p->screen = 255;
    s_ver++;
    return p;
}

static void peer_rssi(peer_t *p, int rssi, int64_t now)
{
    if (rssi >= 0 || rssi < -110) return;
    if (p->rssi == 127 || rssi >= p->rssi || now - p->rssi_at > RSSI_WIN_MS) {
        if (p->rssi != rssi) s_ver++;
        p->rssi = rssi, p->rssi_at = now;
    }
}

static void promisc_sync(void)
{
    int n = 0;
    for (int i = 0; i < PEERS && n < PROMISC_N; i++)
        if (s_peer[i].seen && s_peer[i].ip) memcpy(s_pm_mac[n++], s_peer[i].mac, 6);
    s_pm_n = n;
}


static void promisc_cb(void *buf, wifi_promiscuous_pkt_type_t type)
{
    const wifi_promiscuous_pkt_t *pk = buf;
    if (pk->rx_ctrl.sig_len < 24) return;
    const uint8_t *ta = pk->payload + 10; // addr2: transmitter
    int n = s_pm_n;
    for (int i = 0; i < n; i++)
        if (!memcmp(ta, s_pm_mac[i], 6)) {
            s_pm_rssi[i] = pk->rx_ctrl.rssi;
            s_pm_cnt[i]++;
            return;
        }
}

static void espnow_cb(const esp_now_recv_info_t *info, const uint8_t *d, int len)
{
    enow_t r;
    if (len < 4 || len > (int)sizeof r.d || !s_rxq) return;
    if (memcmp(d, "BOSR", 4) && memcmp(d, "PONG", 4)) return;
    memcpy(r.src, info->src_addr, 6);
    r.rssi = info->rx_ctrl ? info->rx_ctrl->rssi : 127;
    r.len = len;
    memcpy(r.d, d, len);
    xQueueSend(s_rxq, &r, 0);
}

// ---- UDP send ----------------------------------------------------------------

static void udp_send(uint32_t ip, char type, const void *body, int n)
{
    if (s_sock < 0) return;
    uint8_t buf[sizeof(hdr_t) + 220];
    hdr_t *h = (hdr_t *)buf;
    if (n > 220) return;
    memcpy(h->magic, "BLK", 3);
    h->ver = 1, h->type = type, h->seq = s_seq++;
    memcpy(h->src, s_me, 6);
    memcpy(buf + sizeof *h, body, n);
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(PORT), .sin_addr.s_addr = ip};
    sendto(s_sock, buf, sizeof *h + n, 0, (struct sockaddr *)&a, sizeof a);
}

// as udp_send, with a given identity (announces on behalf of bridged badges)
static void udp_send_as(const uint8_t *src, char type, const void *body, int n)
{
    uint8_t keep[6];
    memcpy(keep, s_me, 6);
    memcpy(s_me, src, 6);
    udp_send(0xFFFFFFFF, type, body, n);
    memcpy(s_me, keep, 6);
}

static void espnow_to(const uint8_t *mac, const void *d, int n)
{
    if (!s_espnow) return;
    if (!esp_now_is_peer_exist(mac)) {
        esp_now_peer_info_t pi = {.ifidx = WIFI_IF_STA, .channel = 0};
        memcpy(pi.peer_addr, mac, 6);
        esp_now_add_peer(&pi);
    }
    esp_now_send(mac, d, n);
}

static void send_hello(int64_t now)
{
    uint8_t b[23 + 1 + 9 * 8];
    memset(b, 0, sizeof b);
    b[0] = K_CRYSTAL;
    b[1] = CAP_REMOTE | CAP_PONG | CAP_BRIDGE | CAP_SKETCH;
    b[2] = (uint8_t)s_screen;
    b[3] = P.state == L_PAIRED ? 1 : 0;
    memcpy(b + 10, s_name[0], strlen(s_name[0]));
    int n = 0;
    uint8_t *e = b + 23;
    for (int i = 0; i < PEERS && n < 8; i++) {
        peer_t *p = &s_peer[i];
        if (!p->seen || now - p->seen > STALE_MS || p->rssi == 127) continue;
        memcpy(e, p->mac, 6);
        e[6] = (uint8_t)p->rssi;
        e[7] = p->cm & 0xFF, e[8] = (p->cm >> 8) & 0xFF;
        e += 9, n++;
    }
    b[22] = n;
    udp_send(0xFFFFFFFF, 'H', b, 23 + 9 * n);
    // on behalf of the badge os badges heard over ESP-NOW
    for (int i = 0; i < PEERS; i++) {
        peer_t *p = &s_peer[i];
        if (!p->seen || p->kind != K_BADGEOS || now - p->seen > STALE_MS) continue;
        uint8_t o[23 + 9];
        memset(o, 0, sizeof o);
        o[0] = K_BADGEOS, o[1] = CAP_PONG, o[2] = 255;
        memcpy(o + 4, s_me, 6);
        memcpy(o + 10, p->name, strlen(p->name));
        o[22] = 1;
        memcpy(o + 23, s_me, 6);
        o[29] = (uint8_t)p->rssi;
        o[30] = p->cm & 0xFF, o[31] = (p->cm >> 8) & 0xFF;
        udp_send_as(p->mac, 'H', o, sizeof o);
    }
    // badge os ranging beacon, so its Radar lists this badge
    if (s_espnow) {
        uint8_t m[11 + 12];
        memset(m, 0, sizeof m);
        memcpy(m, "BOSR", 4);
        esp_wifi_get_mac(WIFI_IF_AP, m + 4);
        m[10] = 0;
        memcpy(m + 11, s_name[0], strlen(s_name[0]));
        esp_now_send(bcast6, m, sizeof m);
    }
}

// ---- Pong (badge os rules) ------------------------------------------------------

static int fold_y(int y)
{
    int span = CH - BALL, v = abs(y) % (2 * span);
    return v > span ? 2 * span - v : v;
}

static void pong_step(game_t *g, int64_t now, uint32_t rnd)
{
    if (P.serve_at) {
        if (now < P.serve_at) return;
        if (g->score[0] == WIN || g->score[1] == WIN) g->score[0] = g->score[1] = 0;
        g->dx = P.sdx, g->dy = (1 + rnd / 2 % BALL_DY) * (rnd & 1 ? 1 : -1), P.serve_at = 0;
    }
    g->bx += g->dx;
    g->by += g->dy;
    if (g->by < 0 || g->by > CH - BALL) g->by = fold_y(g->by), g->dy = -g->dy;
    int p = g->dx > 0, face = p ? W - PADX - PADW - BALL : PADX + PADW;
    bool crossed = p ? g->bx >= face && g->bx - g->dx < face : g->bx <= face && g->bx - g->dx > face;
    int off = g->by + BALL / 2 - (g->py[p] + PADH / 2);
    if (crossed && abs(off) < (PADH + BALL) / 2) {
        g->bx = 2 * face - g->bx, g->dx = -g->dx;
        int dy = off * BALL_DY / ((PADH + BALL) / 2) + (int)(rnd >> 8 & 3) % 3 - 1;
        dy = dy < -BALL_DY ? -BALL_DY : dy > BALL_DY ? BALL_DY : dy;
        g->dy = dy ? dy : (rnd >> 10 & 1 ? 1 : -1);
    } else if (g->bx < -BALL || g->bx > W) {
        g->score[!p]++;
        P.sdx = p ? BALL_V : -BALL_V;
        g->bx = (W - BALL) / 2, g->by = (CH - BALL) / 2, g->dx = g->dy = 0;
        P.serve_at = now + PAUSE_MS;
    }
}

static void pong_paired(const uint8_t *peer, bool tunnel, int64_t now)
{
    memcpy(P.peer, peer, 6);
    P.state = L_PAIRED;
    P.tunnel_peer = tunnel;
    P.last_rx = now;
    P.host = memcmp(s_me, peer, 6) < 0;
    memset(&P.g, 0, sizeof P.g);
    P.g.bx = (W - BALL) / 2, P.g.by = (CH - BALL) / 2;
    P.g.py[0] = P.g.py[1] = (CH - PADH) / 2;
    P.sdx = esp_random() & 1 ? BALL_V : -BALL_V;
    P.serve_at = now + PAUSE_MS;
    P.next_step = now;
    printf("net: pong paired with " MACSTR " (%s, %s)\n", MAC2STR(peer), P.host ? "host" : "guest",
           tunnel ? "esp-now" : "udp");
    s_ver++;
}

static void pong_press(int64_t now)
{
    if (P.state == L_PAIRED) return;
    P.state = L_SEEK;
    P.press = now;
    memset(P.peer, 0, 6);
    s_ver++;
}

static void pong_rx(const uint8_t *src, const pkt_t *p, bool tunnel, int64_t now)
{
    if (memcmp(p->magic, "PONG", 4)) return;
    if (p->type == P_PAIR && P.state != L_PAIRED) {
        int k = 0;
        for (int i = 0; i < 4; i++) {
            if (!memcmp(P.heard[i].mac, src, 6)) { k = i; break; }
            if (P.heard[i].press < P.heard[k].press) k = i;
        }
        memcpy(P.heard[k].mac, src, 6);
        P.heard[k].press = now - p->age;
    }
    bool mutual = !memcmp(src, P.peer, 6) && !memcmp(p->peer, s_me, 6);
    if (P.state == L_SEEK && memcmp(P.peer, zero6, 6) && mutual) pong_paired(src, tunnel, now);
    if (P.state == L_PAIRED && mutual) {
        P.last_rx = now;
        if (p->type == P_GAME) {
            if (P.host) {
                int y = p->g.py[1];
                P.g.py[1] = y < 0 ? 0 : y > CH - PADH ? CH - PADH : y;
            } else {
                int16_t mine = P.g.py[1];
                P.g = p->g;
                P.g.py[1] = mine;
            }
        }
    }
}

static void pong_send(const pkt_t *p, const uint8_t *to)
{
    if (!memcmp(to, bcast6, 6)) {
        espnow_to(bcast6, p, sizeof *p);
        udp_send(0xFFFFFFFF, 'P', p, sizeof *p);
        return;
    }
    if (P.tunnel_peer) { espnow_to(to, p, sizeof *p); return; }
    peer_t *q = peer_find(to, false);
    if (q && q->ip) udp_send(q->ip, 'P', p, sizeof *p);
}

static void pong_tick(int64_t now)
{
    bool active = s_screen == SCR_PONG;
    uint32_t btn = s_in_btn;
    if (active && (btn & 1) && !(s_btn_prev & 1)) pong_press(now); // User A: pair
    s_btn_prev = btn;
    if (P.state == L_SEEK && now - P.press >= LINK_GIVEUP) P.state = L_FREE, P.red_until = now + 500, s_ver++;
    if (P.state == L_SEEK && now - P.press >= LINK_DECIDE && !memcmp(P.peer, zero6, 6)) {
        int n = 0, k = 0;
        for (int i = 0; i < 4; i++)
            if (memcmp(P.heard[i].mac, zero6, 6) && llabs(P.heard[i].press - P.press) <= LINK_WINDOW) n++, k = i;
        if (n == 1) {
            memcpy(P.peer, P.heard[k].mac, 6);
            peer_t *q = peer_find(P.peer, false);
            P.tunnel_peer = !(q && q->ip);
        } else {
            P.state = L_FREE, P.red_until = now + 500;
        }
        s_ver++;
    }
    if (P.state == L_PAIRED && now - P.last_rx > LINK_TIMEOUT) {
        printf("net: pong peer gone\n");
        P.state = L_FREE, P.red_until = now + 500;
        s_ver++;
    }
    if (P.state != L_PAIRED) P.next_step = now;
    for (; P.state == L_PAIRED && now >= P.next_step; P.next_step += STEP_MS) {
        int v = 0;
        int k = s_in_l;
        if (k >= 0 && s_knob_last >= 0) s_knob_acc += (k - s_knob_last) * 3 * (CH - PADH) / 2;
        s_knob_last = k;
        if (btn & 1) v -= PAD_V; // A up
        if (btn & 2) v += PAD_V; // B down
        v += s_knob_acc / 2300;  // left knob: ~1.5 court heights over its 2.3 V range
        s_knob_acc %= 2300;
        int me = !P.host, y = P.g.py[me] + v;
        P.g.py[me] = y < 0 ? 0 : y > CH - PADH ? CH - PADH : y;
        if (P.host) pong_step(&P.g, now, esp_random());
        P.frames++;
    }
    if (P.state == L_FREE || now < P.next_tx) return;
    pkt_t p;
    memcpy(p.magic, "PONG", 4);
    p.type = P.state == L_SEEK ? P_PAIR : P_GAME;
    p.age = P.state == L_SEEK ? now - P.press : 0;
    memcpy(p.peer, P.peer, 6);
    p.g = P.g;
    pong_send(&p, P.state == L_SEEK ? bcast6 : P.peer);
    P.next_tx = now + (P.state == L_SEEK ? LINK_PAIR_MS : LINK_GAME_MS);
}

// Crystal PONG screen: v[0] state (0 free 1 seek 2 paired, 3 = failed just now),
// v[1] host, v[2..3] ball x y, v[4..5] paddles, v[6..7] scores, v[8] frames (low 16 bits)
int32_t cr_pong_get(int16_t *v)
{
    int64_t now = now_ms();
    game_t g = P.g;
    v[0] = P.state == L_FREE && now < P.red_until ? 3 : P.state;
    v[1] = P.host;
    v[2] = g.bx, v[3] = g.by, v[4] = g.py[0], v[5] = g.py[1];
    v[6] = g.score[0], v[7] = g.score[1];
    v[8] = (int16_t)P.frames;
    v[9] = P.serve_at != 0;
    return v[0];
}

// ---- receive -------------------------------------------------------------------

static const char *allowed[] = {"mode", "press", "hold", "colour", "color", "knob", "stroke", "text", "status", "clean", "sketch", NULL};

static void on_command(const hdr_t *h, uint32_t ip, const char *line, int n, int64_t now)
{
    char buf[NLINE_MAX];
    if (n > NLINE_MAX - 1) n = NLINE_MAX - 1;
    memcpy(buf, line, n);
    buf[n] = 0;
    uint8_t r[2 + 40] = {0, h->seq};
    int w = strcspn(buf, " ");
    bool ok = false;
    if (w == 4 && !strncmp(buf, "pong", 4)) {
        pong_paired(h->src, false, now);
        ok = push_line("mode pong", 9);
    } else {
        for (int i = 0; allowed[i]; i++)
            if ((int)strlen(allowed[i]) == w && !strncmp(buf, allowed[i], w)) ok = true;
        if (!ok) r[0] = 1;
        else if (!push_line(buf, n)) r[0] = 2, ok = false;
    }
    if (r[0] == 0 && !ok) r[0] = 2;
    printf("net: command from " MACSTR ": \"%s\" -> %d\n", MAC2STR(h->src), buf, r[0]);
    cr_notify_main();
    udp_send(ip, 'R', r, 2);
}

static void on_udp(const uint8_t *b, int n, uint32_t ip, int64_t now)
{
    if (n < (int)sizeof(hdr_t)) return;
    const hdr_t *h = (const hdr_t *)b;
    if (memcmp(h->magic, "BLK", 3) || h->ver != 1 || !memcmp(h->src, s_me, 6)) return;
    const uint8_t *d = b + sizeof *h;
    n -= sizeof *h;
    if (h->type == 'H' && n >= 23) {
        if (d[0] == K_BADGEOS && !memcmp(d + 4, s_me, 6)) return; // my own bridged announces
        peer_t *p = peer_find(h->src, true);
        bool fresh = !p->seen;
        p->kind = d[0], p->caps = d[1], p->screen = d[2], p->flags = d[3];
        memcpy(p->via, d + 4, 6);
        if (memcmp(p->name, d + 10, 12)) s_ver++;
        memcpy(p->name, d + 10, 12);
        p->name[12] = 0;
        p->ip = d[0] == K_BADGEOS ? 0 : ip; // bridged ones are reached through their bridge
        p->seen = now;
        int m = d[22];
        for (int i = 0; i < m && 23 + 9 * (i + 1) <= n; i++)
            if (!memcmp(d + 23 + 9 * i, s_me, 6)) p->their = (int8_t)d[23 + 9 * i + 6];
        if (fresh) promisc_sync();
    } else if (h->type == 'C' && n > 0) {
        on_command(h, ip, (const char *)d, n, now);
    } else if (h->type == 'P' && n >= (int)sizeof(pkt_t)) {
        peer_t *p = peer_find(h->src, false);
        if (p) p->seen = now;
        pong_rx(h->src, (const pkt_t *)d, false, now);
    } else if (h->type == 'E' && n > 7) {
        espnow_to(d, d + 7, n - 7); // tunnel: UDP -> ESP-NOW, sent with my MAC
    }
}

static void on_espnow(const enow_t *r, int64_t now)
{
    if (!memcmp(r->d, "BOSR", 4) && r->len >= 11) {
        const bosr_t *m = (const bosr_t *)r->d;
        peer_t *p = peer_find(r->src, true);
        if (!p->kind) p->kind = K_BADGEOS;
        p->seen = now;
        peer_rssi(p, r->rssi, now);
        int tail = 11 + m->n * 8;
        if (m->n <= 8 && r->len >= tail + 12) {
            if (memcmp(p->name, r->d + tail, 12)) s_ver++;
            memcpy(p->name, r->d + tail, 12), p->name[12] = 0;
        }
    }
    bool mine = s_screen == SCR_PONG && !memcmp(r->d, "PONG", 4) && r->len == sizeof(pkt_t);
    if (mine) {
        peer_t *p = peer_find(r->src, false);
        if (p) peer_rssi(p, r->rssi, now);
        pong_rx(r->src, (const pkt_t *)r->d, true, now);
        return;
    }
    // bridge: everything else goes to the UDP side
    uint8_t b[7 + 200];
    memcpy(b, r->src, 6);
    b[6] = (uint8_t)r->rssi;
    memcpy(b + 7, r->d, r->len);
    udp_send(0xFFFFFFFF, 'E', b, 7 + r->len);
}

// ---- task ---------------------------------------------------------------------

static void net_task(void *arg)
{
    snprintf(s_state, sizeof s_state, "joining wifi");
    s_ver++;
    while (s_run && !cr_wifi_hold()) {
        snprintf(s_state, sizeof s_state, "no wifi, retrying");
        s_ver++;
        for (int i = 0; i < 100 && s_run; i++) vTaskDelay(pdMS_TO_TICKS(100));
    }
    if (!s_run) goto out;
    esp_wifi_set_ps(WIFI_PS_NONE);
    esp_read_mac(s_me, ESP_MAC_WIFI_STA);
    s_rxq = xQueueCreate(8, sizeof(enow_t));
    s_espnow = esp_now_init() == ESP_OK;
    if (s_espnow) {
        esp_now_register_recv_cb(espnow_cb);
        esp_now_peer_info_t bc = {.ifidx = WIFI_IF_STA, .channel = 0};
        memcpy(bc.peer_addr, bcast6, 6);
        esp_now_add_peer(&bc);
    }
    wifi_promiscuous_filter_t f = {.filter_mask = WIFI_PROMIS_FILTER_MASK_MGMT | WIFI_PROMIS_FILTER_MASK_DATA};
    esp_wifi_set_promiscuous_filter(&f);
    esp_wifi_set_promiscuous_rx_cb(promisc_cb);
    esp_wifi_set_promiscuous(true);

    s_sock = socket(AF_INET, SOCK_DGRAM, 0);
    int one = 1;
    setsockopt(s_sock, SOL_SOCKET, SO_BROADCAST, &one, sizeof one);
    struct timeval tv = {.tv_sec = 0, .tv_usec = 10000};
    setsockopt(s_sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(PORT), .sin_addr.s_addr = htonl(INADDR_ANY)};
    if (bind(s_sock, (struct sockaddr *)&a, sizeof a) < 0) printf("net: bind failed\n");
    printf("net: up, ip %s channel %ld, me " MACSTR ", esp-now %d\n", cr_wifi_ip(), (long)cr_wifi_channel(),
           MAC2STR(s_me), s_espnow);
    snprintf(s_state, sizeof s_state, "on");
    s_ver++;

    int64_t next_hello = 0;
    static uint8_t buf[300];
    uint32_t pm_seen[PROMISC_N] = {0};
    while (s_run) {
        struct sockaddr_in from;
        socklen_t fl = sizeof from;
        int n = recvfrom(s_sock, buf, sizeof buf, 0, (struct sockaddr *)&from, &fl);
        int64_t now = now_ms();
        if (n > 0) on_udp(buf, n, from.sin_addr.s_addr, now);
        enow_t r;
        while (xQueueReceive(s_rxq, &r, 0)) on_espnow(&r, now);
        for (int i = 0; i < s_pm_n; i++)
            if (s_pm_cnt[i] != pm_seen[i]) {
                pm_seen[i] = s_pm_cnt[i];
                peer_t *p = peer_find(s_pm_mac[i], false);
                if (p) peer_rssi(p, s_pm_rssi[i], now);
            }
        pong_tick(now);
        if (now >= next_hello) {
            for (int i = 0; i < PEERS; i++)
                if (s_peer[i].seen && now - s_peer[i].seen > 60000) s_peer[i].seen = 0, s_ver++, promisc_sync();
            send_hello(now);
            next_hello = now + HELLO_MS + esp_random() % 250;
            s_ver++; // ages on the LINK screen
        }
    }
    esp_wifi_set_promiscuous(false);
    if (s_espnow) esp_now_deinit();
    s_espnow = false;
    close(s_sock);
    s_sock = -1;
    vQueueDelete(s_rxq);
    s_rxq = NULL;
out:
    cr_wifi_release();
    P.state = L_FREE;
    snprintf(s_state, sizeof s_state, "off");
    s_ver++;
    s_task_alive = false;
    vTaskDelete(NULL);
}

static void start(void)
{
    if (s_task_alive) return;
    s_run = true;
    s_task_alive = true;
    if (xTaskCreatePinnedToCore(net_task, "net", 6144, NULL, 4, NULL, 0) != pdPASS) {
        s_run = s_task_alive = false;
        snprintf(s_state, sizeof s_state, "no memory for task");
    }
}

bool cr_net_on(void) { return s_run; }

void cr_net_set(bool on)
{
    nvs_handle_t h;
    if (nv(&h, true)) { nvs_set_u8(h, "on", on); nvs_commit(h); nvs_close(h); }
    if (on) start();
    else s_run = false;
    s_ver++;
}

void cr_net_boot(void)
{
    nvs_handle_t h;
    uint8_t on = 0;
    load_name();
    if (nv(&h, false)) { nvs_get_u8(h, "on", &on); nvs_close(h); }
    if (on) start();
}

// knob task, every 15 ms
void cr_net_input(int32_t mv_l, int32_t mv_r, uint32_t btns)
{
    s_in_l = mv_l;
    s_in_btn = btns;
}

void cr_net_screen(int32_t scr)
{
    if (scr != s_screen) s_ver++;
    s_screen = scr;
}

uint32_t cr_net_version(void) { return s_ver; }

static const char *kind_name(int k)
{
    return k == K_BEAGLE ? "BEAGLE" : k == K_CRYSTAL ? "CRYSTAL" : k == K_BADGEOS ? "BADGE OS" : "?";
}

// LINK screen text: lines separated by '\n'. Returns the length.
int32_t cr_net_status_text(char *buf, int32_t max)
{
    int64_t now = now_ms();
    int n = snprintf(buf, max, "NET %s%s\n", s_run ? "ON: " : "OFF", s_run ? s_state : "  (A: TURN ON)");
    if (s_run && cr_wifi_connected())
        n += snprintf(buf + n, max - n, "IP %s CH %ld RSSI %ld\n", cr_wifi_ip(), (long)cr_wifi_channel(),
                      (long)cr_wifi_rssi());
    n += snprintf(buf + n, max - n, "ME %02X%02X  NAME %s\n", s_me[4], s_me[5], s_name[0]);
    int shown = 0;
    for (int i = 0; i < PEERS && n < max - 48; i++) {
        peer_t *p = &s_peer[i];
        if (!p->seen) continue;
        int age = (int)((now - p->seen) / 1000);
        char rs[8] = "--";
        if (p->rssi != 127) snprintf(rs, sizeof rs, "%d", p->rssi);
        n += snprintf(buf + n, max - n, "%-8s %-12s %4s DBM %3dS\n", kind_name(p->kind), p->name[0] ? p->name : "-", rs,
                      age > 999 ? 999 : age);
        shown++;
    }
    if (!shown) n += snprintf(buf + n, max - n, "NO BADGES HEARD YET\n");
    if (n > max) n = max;
    return n;
}

void cr_net_print_status(void)
{
    static char b[640];
    int n = cr_net_status_text(b, sizeof b);
    fwrite(b, 1, n, stdout);
    printf("net: pong state %d host %d peer " MACSTR "\n", P.state, P.host, MAC2STR(P.peer));
}
