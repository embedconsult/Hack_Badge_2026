// SNAKES arena, badge side: the saved bots (NVS namespace "snakes", blob
// "cfg"), the `snakes` shell command, and the referee's network worker.
// The game itself (rules, house snake, screen) is Crystal: src/apps/snakes.cr
// with src/games/snakes_rules.cr / snakes_house.cr.
//
// One worker task ("snakes", started on demand) makes all bot calls: it
// takes the Wi-Fi station (cr_wifi_acquire, shared with OTA and the
// content apps; power save off while it holds it, for short reply times),
// resolves the bot hosts once per game, then runs each job the main task
// posts: GET / of the saved bots (lobby), POST /start, one /move per turn
// (all bots at once, one 500 ms deadline: main/snakes.c), /end. It gives
// Wi-Fi back 10 s after the last job when no game is on. https:// bots go
// through esp_http_client (one kept-alive connection per bot and game).
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_http_client.h"
#include "esp_crt_bundle.h"
#include "esp_heap_caps.h"
#include "esp_wifi.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "snakes.h"

bool cr_wifi_acquire(void); // main/ota.c
void cr_wifi_unacquire(void);
bool cr_net_on(void);       // main/net.c
void cr_notify_main(void);  // main/main.c

#define SNAP_MAX 1024
#define IDLE_MS 10000
#define START_MS 3000 // /start and GET /: a first TLS handshake fits
#define END_MS 1000
#define WORKER_STACK 16384 // as netapps: TLS handshakes for https bots

enum { J_NONE = 0, J_PING, J_START, J_MOVE, J_END };
enum { NET_OK = 0, NET_JOINING = 1, NET_FAIL = 2 };

static snk_cfg_t s_cfg;
static bool s_cfg_loaded;
static snk_session_t s_game; // the game's entries (bots and house snakes)
static snk_session_t s_lobby; // all saved bots, for GET /
static int32_t s_snap[SNAP_MAX];
static int s_nsnap;
static volatile int s_job;
static volatile bool s_busy;   // a posted job is not done yet
static volatile bool s_worker;
static volatile bool s_in_game;
static volatile int s_net;
static volatile int s_lobby_state[SNK_BOTS]; // 0 unknown, 1 checking, 2 online, 3 offline
static uint32_t s_sig;
static esp_http_client_handle_t s_tls[SNK_BOTS];

static void *ps_alloc(int n)
{
    void *p = heap_caps_calloc(1, n, MALLOC_CAP_SPIRAM);
    return p ? p : heap_caps_calloc(1, n, MALLOC_CAP_DEFAULT);
}

// ---- saved bots ------------------------------------------------------------------

static void cfg_load(void)
{
    if (s_cfg_loaded) return;
    s_cfg_loaded = true;
    memset(&s_cfg, 0, sizeof s_cfg);
    nvs_handle_t h;
    nvs_flash_init();
    if (nvs_open("snakes", NVS_READONLY, &h) != ESP_OK) return;
    size_t n = sizeof s_cfg;
    if (nvs_get_blob(h, "cfg", &s_cfg, &n) != ESP_OK || n != sizeof s_cfg || s_cfg.n < 0 || s_cfg.n > SNK_BOTS)
        memset(&s_cfg, 0, sizeof s_cfg);
    for (int i = 0; i < s_cfg.n; i++) {
        s_cfg.bot[i].name[SNK_NAME - 1] = 0;
        s_cfg.bot[i].url[SNK_URL - 1] = 0;
    }
    nvs_close(h);
}

static void cfg_save(void)
{
    nvs_handle_t h;
    if (nvs_open("snakes", NVS_READWRITE, &h) != ESP_OK) return;
    nvs_set_blob(h, "cfg", &s_cfg, sizeof s_cfg);
    nvs_commit(h);
    nvs_close(h);
}

// ---- https (esp_http_client) ----------------------------------------------------

static void tls_drop(int i)
{
    if (s_tls[i]) esp_http_client_cleanup(s_tls[i]);
    s_tls[i] = NULL;
}

static int https_call(int slot, const snk_url_t *u, const char *method, const char *path, const char *body, int blen,
                      char *resp, int rcap, int timeout_ms)
{
    char url[SNK_URL + 32];
    snprintf(url, sizeof url, "https://%s:%d%s", u->host, u->port, path);
    for (int attempt = 0; attempt < 2; attempt++) {
        esp_http_client_handle_t h = s_tls[slot];
        if (!h) {
            esp_http_client_config_t c = {.url = url, .crt_bundle_attach = esp_crt_bundle_attach, .timeout_ms = timeout_ms,
                                          .user_agent = "Hack_Badge_2026-snakes", .buffer_size = 2048,
                                          .buffer_size_tx = 1024, .keep_alive_enable = true};
            h = s_tls[slot] = esp_http_client_init(&c);
            if (!h) return -SNK_E_IO;
        } else {
            esp_http_client_set_url(h, url);
            esp_http_client_set_timeout_ms(h, timeout_ms);
        }
        esp_http_client_set_method(h, body ? HTTP_METHOD_POST : HTTP_METHOD_GET);
        esp_http_client_set_header(h, "Content-Type", "application/json");
        if (esp_http_client_open(h, body ? blen : 0) != ESP_OK) {
            tls_drop(slot);
            continue; // a stale kept-alive connection: once more
        }
        if (body && esp_http_client_write(h, body, blen) != blen) {
            tls_drop(slot);
            return -SNK_E_IO;
        }
        if (esp_http_client_fetch_headers(h) < 0) {
            tls_drop(slot);
            return -SNK_E_TIMEOUT;
        }
        int st = esp_http_client_get_status_code(h), k = 0, r;
        while (k < rcap - 1 && (r = esp_http_client_read(h, resp + k, rcap - 1 - k)) > 0) k += r;
        resp[k] = 0;
        if (!esp_http_client_is_complete_data_received(h)) esp_http_client_close(h);
        return st;
    }
    return -SNK_E_CONNECT;
}

// ---- worker ---------------------------------------------------------------------------

static void lobby_sig(void)
{
    uint32_t h = 2166136261u;
    for (int i = 0; i < SNK_BOTS; i++) h = (h ^ (uint32_t)s_lobby_state[i]) * 16777619u;
    h = (h ^ (uint32_t)s_net) * 16777619u;
    h = (h ^ (uint32_t)s_cfg.n) * 16777619u;
    s_sig = h;
}

static void job_ping(void)
{
    snk_session_t *s = &s_lobby;
    snk_session_reset(s, s_cfg.n, 0);
    for (int i = 0; i < s_cfg.n; i++) {
        snk_session_set(s, i, s_cfg.bot[i].name, s_cfg.bot[i].url);
        s_lobby_state[i] = 1;
    }
    lobby_sig();
    cr_notify_main();
    snk_session_resolve(s);
    snk_session_info(s, START_MS);
    for (int i = 0; i < s_cfg.n; i++) {
        s_lobby_state[i] = s->err[i] == SNK_E_NONE ? 2 : 3;
        printf("snakes: %s %s: %s, %d ms%s%s\n", s->name[i], s_cfg.bot[i].url, snk_err_name(s->err[i]), s->ms[i],
               s->author[i][0] ? ", author " : "", s->author[i]);
    }
    for (int i = 0; i < SNK_BOTS; i++) tls_drop(i);
    lobby_sig();
}

static void worker(void *arg)
{
    bool wifi = false;
    int64_t idle = 0;
    for (;;) {
        int j = s_job;
        if (j == J_NONE) {
            if (!idle) idle = snk_now_ms();
            if (!s_in_game && snk_now_ms() - idle > IDLE_MS) break;
            vTaskDelay(pdMS_TO_TICKS(5));
            continue;
        }
        idle = 0;
        bool need = j == J_PING ? s_cfg.n > 0 : false;
        for (int i = 0; i < s_game.n && !need; i++) need = s_game.bot[i];
        if (need && !wifi) {
            s_net = NET_JOINING;
            lobby_sig();
            cr_notify_main();
            wifi = cr_wifi_acquire();
            s_net = wifi ? NET_OK : NET_FAIL;
            if (wifi) esp_wifi_set_ps(WIFI_PS_NONE);
            lobby_sig();
        }
        if (!need || wifi) {
            if (j == J_PING) job_ping();
            else if (j == J_START) {
                snk_session_resolve(&s_game);
                snk_session_call(&s_game, "start", s_snap, s_nsnap, START_MS);
                for (int i = 0; i < s_game.n; i++)
                    if (s_game.bot[i])
                        printf("snakes: /start %s: %s, %d ms\n", s_game.name[i], snk_err_name(s_game.err[i]), s_game.ms[i]);
            } else if (j == J_MOVE) {
                snk_session_call(&s_game, "move", s_snap, s_nsnap, s_game.timeout_ms);
            } else if (j == J_END) {
                snk_session_call(&s_game, "end", s_snap, s_nsnap, END_MS);
                for (int i = 0; i < SNK_BOTS; i++) tls_drop(i);
                s_in_game = false;
            }
        } else if (j == J_END) {
            s_in_game = false;
        }
        s_job = J_NONE;
        s_busy = false;
        cr_notify_main();
        if (!wifi && need) break; // no Wi-Fi: the main task sees NET_FAIL
    }
    for (int i = 0; i < SNK_BOTS; i++) tls_drop(i);
    if (wifi) {
        if (!cr_net_on()) esp_wifi_set_ps(WIFI_PS_MIN_MODEM);
        cr_wifi_unacquire();
    }
    printf("snakes: worker done%s\n", wifi ? " (wifi released)" : "");
    s_worker = false;
    vTaskDelete(NULL);
}

static bool init(void)
{
    cfg_load();
    s_game.https = https_call;
    s_lobby.https = https_call;
    return snk_session_alloc(&s_game, ps_alloc) && snk_session_alloc(&s_lobby, ps_alloc);
}

static void post(int job)
{
    s_busy = true;
    s_job = job;
    if (s_worker) return;
    s_worker = true;
    // internal RAM stack: TLS and Wi-Fi calls must not run on a PSRAM stack
    if (xTaskCreatePinnedToCore(worker, "snakes", WORKER_STACK, NULL, 4, NULL, 0) != pdPASS) {
        s_worker = false;
        s_job = J_NONE;
        s_busy = false;
        s_net = NET_FAIL;
    }
}

static void take_snap(const int32_t *snap, int32_t n)
{
    if (n > SNAP_MAX) n = SNAP_MAX;
    memcpy(s_snap, snap, n * sizeof *snap);
    s_nsnap = n;
}

// ---- Crystal API (src/apps/snakes.cr) ---------------------------------------------------

// Shell `snakes ...` (the whole line). Prints the result; 2 = play.
int32_t cr_snk_cmd(const uint8_t *line, int32_t n)
{
    char buf[200], msg[1024];
    cfg_load();
    if (n > (int32_t)sizeof buf - 1) n = sizeof buf - 1;
    memcpy(buf, line, n);
    buf[n] = 0;
    const char *args = buf;
    while (*args == ' ') args++;
    args += strcspn(args, " "); // past "snakes"
    if (s_busy && strncmp(args, " list", 5) && strncmp(args, " play", 5) && *args) {
        printf("snakes: busy with a game or a bot check, try again in a moment\n");
        return 0;
    }
    int r = snk_cmd(args, &s_cfg, msg, sizeof msg);
    if (r == 1) {
        cfg_save();
        for (int i = 0; i < SNK_BOTS; i++) s_lobby_state[i] = 0;
        lobby_sig();
        cr_notify_main();
    }
    fputs(msg, stdout);
    return r;
}

int32_t cr_snk_bots(void)
{
    cfg_load();
    return s_cfg.n;
}

const uint8_t *cr_snk_bot_name(int32_t i) { return (const uint8_t *)(i >= 0 && i < s_cfg.n ? s_cfg.bot[i].name : ""); }
const uint8_t *cr_snk_bot_url(int32_t i) { return (const uint8_t *)(i >= 0 && i < s_cfg.n ? s_cfg.bot[i].url : ""); }
int32_t cr_snk_bot_state(int32_t i) { return i >= 0 && i < SNK_BOTS ? s_lobby_state[i] : 0; }
int32_t cr_snk_bot_ms(int32_t i) { return i >= 0 && i < SNK_BOTS ? s_lobby.ms[i] : 0; }
const uint8_t *cr_snk_bot_author(int32_t i) { return (const uint8_t *)(i >= 0 && i < SNK_BOTS ? s_lobby.author[i] : ""); }
uint32_t cr_snk_sig(void) { return s_sig; }
int32_t cr_snk_net(void) { return s_net; }
int32_t cr_snk_busy(void) { return s_busy; }

// GET / of every saved bot (lobby). Ignored while busy.
void cr_snk_ping(void)
{
    if (!init() || s_busy || s_cfg.n == 0) return;
    s_net = NET_OK;
    post(J_PING);
}

// A new game: n entries, who[i] = -1 the house snake, else a saved bot;
// snap = the starting board. Posts /start to the bots.
void cr_snk_begin(int32_t n, const int32_t *who, uint32_t seed, const int32_t *snap, int32_t nsnap)
{
    if (!init()) return;
    while (s_busy) vTaskDelay(pdMS_TO_TICKS(10)); // a lobby check still running
    snk_session_reset(&s_game, n, seed);
    s_game.timeout_ms = 500;
    int houses = 0;
    for (int i = 0; i < n; i++) {
        if (who[i] >= 0 && who[i] < s_cfg.n) {
            snk_session_set(&s_game, i, s_cfg.bot[who[i]].name, s_cfg.bot[who[i]].url);
        } else {
            char nm[SNK_NAME];
            snprintf(nm, sizeof nm, "house-%c", (char)('0' + (++houses & 7)));
            snk_session_set(&s_game, i, nm, NULL);
        }
    }
    s_net = NET_OK;
    s_in_game = true;
    take_snap(snap, nsnap);
    post(J_START);
}

void cr_snk_turn(const int32_t *snap, int32_t nsnap)
{
    if (s_busy) return;
    take_snap(snap, nsnap);
    post(J_MOVE);
}

void cr_snk_end(const int32_t *snap, int32_t nsnap)
{
    while (s_busy) vTaskDelay(pdMS_TO_TICKS(10));
    if (s_net == NET_FAIL || !s_in_game) { // no Wi-Fi: nobody to tell
        s_in_game = false;
        return;
    }
    take_snap(snap, nsnap);
    post(J_END);
}

// Results of the last turn, per game entry.
int32_t cr_snk_move(int32_t i) { return i >= 0 && i < SNK_SLOTS ? s_game.move[i] : -1; }
int32_t cr_snk_err(int32_t i) { return i >= 0 && i < SNK_SLOTS ? s_game.err[i] : 0; }
int32_t cr_snk_ms(int32_t i) { return i >= 0 && i < SNK_SLOTS ? s_game.ms[i] : 0; }
int32_t cr_snk_misses(int32_t i) { return i >= 0 && i < SNK_SLOTS ? s_game.timeouts[i] : 0; }
const uint8_t *cr_snk_name(int32_t i) { return (const uint8_t *)(i >= 0 && i < SNK_SLOTS ? s_game.name[i] : ""); }
const uint8_t *cr_snk_shout(int32_t i) { return (const uint8_t *)(i >= 0 && i < SNK_SLOTS ? s_game.shout[i] : ""); }
const uint8_t *cr_snk_err_name(int32_t e) { return (const uint8_t *)snk_err_name(e); }
