// Network content apps, badge side: Hackaday + News (RSS reader, feed.c),
// Weather (Open-Meteo, weather.c) and Radar (badge link peers, radar.c).
// The Crystal modules (src/apps/reader.cr, weather.cr, radar.cr) handle
// buttons and the panel; this file owns the downloads.
//
// One worker task ("netapps", started on demand) does all HTTPS work for
// the app on screen: it takes the Wi-Fi station (cr_wifi_acquire, shared
// with network mode and OTA in ota.c), streams the feed through the parser
// (never holding it whole), then the images (stb_image, dithered to 1 bit,
// all in PSRAM), or the weather; it gives Wi-Fi back 3 s after it runs out
// of work. A mutex keeps the main task's drawing and the worker's writes
// apart. Download sizes are capped (feed 2 MB streamed, image 512 KB,
// weather 16 KB).
//
// Inspired by yigitabi5444's badge os apps (app_hackaday.c, app_news.c,
// app_weather.c, app_radar.c): same feeds, the image-size tricks in the
// URLs, Open-Meteo. Our own implementation.
//
// NVS namespace "wx": lat, lon, place, city (str), imp (u8).
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_http_client.h"
#include "esp_crt_bundle.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "feed.h"
#include "weather.h"
#include "radar.h"
#include "apps_gfx.h"

bool cr_wifi_acquire(void);           // main/ota.c
void cr_wifi_unacquire(void);
bool cr_net_on(void);                 // main/net.c
int32_t cr_net_peers(radar_peer_t *out, int32_t max);
void cr_net_me(uint8_t *mac);
const uint8_t *cr_name_ptr(int32_t i);
void cr_notify_main(void);            // main/main.c

// keep in sync with src/apps/netapps.cr
enum { APP_NONE = 0, APP_HACKADAY = 1, APP_NEWS = 2, APP_WEATHER = 3, APP_RADAR = 4 };
enum { ST_NONE = 0, ST_JOIN = 1, ST_LOAD = 2, ST_READY = 3, ST_FAIL = 4 };

#define FEED_CAP (2 * 1024 * 1024)
#define IMG_CAP (512 * 1024)
#define WX_CAP (16 * 1024)
#define FEED_STALE_MS (30 * 60 * 1000)
#define WX_EVERY_MS (30 * 60 * 1000)
#define WX_RETRY_MS (5 * 60 * 1000)
#define IDLE_MS 3000
#define WORKER_STACK 16384

typedef struct {
    feed_t *f;
    const char *url, *name;
    volatile int stage;
    volatile int bytes;
    char err[80];
    int64_t loaded_at;
    volatile bool reload;
    volatile int cur_post;   // what the reader shows (image priority)
    volatile bool reading;
} slot_t;

static slot_t s_feed[2] = {
    {.url = "https://hackaday.com/blog/feed/", .name = "HACKADAY"},
    {.url = "https://feeds.bbci.co.uk/news/world/rss.xml", .name = "NEWS"},
};

static SemaphoreHandle_t s_lock;
static volatile int s_active;
static volatile bool s_worker;
static uint8_t *s_buf;            // image / weather download (PSRAM)
static int s_buf_n;

static wx_cfg_t s_wcfg;
static wx_t s_wx;
static char s_wstat[80];
static volatile int s_wstage;
static int64_t s_wx_at, s_wx_fail_at;
static volatile bool s_wx_want;

static radar_t *s_radar;

static int64_t now_ms(void) { return esp_timer_get_time() / 1000; }
static void lock(void) { xSemaphoreTake(s_lock, portMAX_DELAY); }
static void unlock(void) { xSemaphoreGive(s_lock); }

void *fd_alloc(int n)
{
    void *p = heap_caps_malloc(n, MALLOC_CAP_SPIRAM);
    return p ? p : heap_caps_malloc(n, MALLOC_CAP_DEFAULT);
}
void fd_free(void *p) { heap_caps_free(p); }

// ---- weather settings (NVS "wx") ---------------------------------------------------

static void wx_load(void)
{
    nvs_handle_t h;
    wx_default(&s_wcfg);
    nvs_flash_init();
    if (nvs_open("wx", NVS_READONLY, &h) != ESP_OK) return;
    size_t n;
    n = sizeof s_wcfg.lat; if (nvs_get_str(h, "lat", s_wcfg.lat, &n) != ESP_OK) s_wcfg.lat[0] = 0;
    n = sizeof s_wcfg.lon; if (nvs_get_str(h, "lon", s_wcfg.lon, &n) != ESP_OK) s_wcfg.lon[0] = 0;
    n = sizeof s_wcfg.place; if (nvs_get_str(h, "place", s_wcfg.place, &n) != ESP_OK) s_wcfg.place[0] = 0;
    n = sizeof s_wcfg.city; if (nvs_get_str(h, "city", s_wcfg.city, &n) != ESP_OK) s_wcfg.city[0] = 0;
    uint8_t imp = 1;
    nvs_get_u8(h, "imp", &imp);
    s_wcfg.imperial = imp;
    nvs_close(h);
    if (!s_wcfg.city[0] && (!s_wcfg.lat[0] || !s_wcfg.lon[0])) { // nothing usable saved
        bool i = s_wcfg.imperial;
        wx_default(&s_wcfg);
        s_wcfg.imperial = i;
    }
}

static void wx_save(void)
{
    nvs_handle_t h;
    if (nvs_open("wx", NVS_READWRITE, &h) != ESP_OK) return;
    nvs_set_str(h, "lat", s_wcfg.lat);
    nvs_set_str(h, "lon", s_wcfg.lon);
    nvs_set_str(h, "place", s_wcfg.place);
    nvs_set_str(h, "city", s_wcfg.city);
    nvs_set_u8(h, "imp", s_wcfg.imperial);
    nvs_commit(h);
    nvs_close(h);
}

// ---- HTTP ------------------------------------------------------------------------

typedef int (*sink_fn)(void *ctx, const char *d, int n); // 1 = enough, stop

static esp_http_client_handle_t s_http;

static void http_drop(void)
{
    if (s_http) esp_http_client_cleanup(s_http);
    s_http = NULL;
}

// GET url, the body streamed to sink, at most cap bytes. Reuses the
// connection (keep-alive) when the host stays the same. 0 ok, else -1 with err.
static int http_get(const char *url, sink_fn sink, void *ctx, int cap, char *err, int errn)
{
    static char chunk[2048];
    for (int attempt = 0; attempt < 2; attempt++) {
        if (!s_http) {
            esp_http_client_config_t c = {
                .url = url, .crt_bundle_attach = esp_crt_bundle_attach, .timeout_ms = 15000,
                .user_agent = "Hack_Badge_2026 Crystal badge (ESP32-S3)", .buffer_size = 4096,
                .buffer_size_tx = 1024, .keep_alive_enable = true, .disable_auto_redirect = true};
            s_http = esp_http_client_init(&c);
            if (!s_http) { snprintf(err, errn, "No memory for HTTPS."); return -1; }
        } else {
            esp_http_client_set_url(s_http, url);
        }
        int code = 0;
        esp_err_t e = ESP_OK;
        for (int redir = 0; redir < 4; redir++) {
            e = esp_http_client_open(s_http, 0);
            if (e != ESP_OK) break;
            if (esp_http_client_fetch_headers(s_http) < 0) { e = ESP_FAIL; break; }
            code = esp_http_client_get_status_code(s_http);
            if (code != 301 && code != 302 && code != 303 && code != 307 && code != 308) break;
            esp_http_client_flush_response(s_http, NULL);
            if (esp_http_client_set_redirection(s_http) != ESP_OK) break;
        }
        if (e != ESP_OK) { // a stale kept-alive connection: once more on a fresh one
            http_drop();
            snprintf(err, errn, "Connection failed (%s).", esp_err_to_name(e));
            continue;
        }
        if (code != 200) {
            esp_http_client_close(s_http);
            snprintf(err, errn, "HTTP %d.", code);
            return -1;
        }
        int total = 0, n;
        bool stop = false;
        while (!stop && (n = esp_http_client_read(s_http, chunk, sizeof chunk)) > 0) {
            total += n;
            if (total > cap) { snprintf(err, errn, "Too big (> %d KB).", cap / 1024); stop = true; break; }
            if (sink(ctx, chunk, n)) stop = true;
        }
        if (total > cap) { http_drop(); return -1; }
        if (stop || !esp_http_client_is_complete_data_received(s_http)) esp_http_client_close(s_http);
        if (n < 0 && !stop) { http_drop(); snprintf(err, errn, "Read failed."); return -1; }
        return 0;
    }
    return -1;
}

static int sink_buf(void *ctx, const char *d, int n)
{
    int cap = *(int *)ctx;
    if (s_buf_n + n > cap - 1) n = cap - 1 - s_buf_n;
    memcpy(s_buf + s_buf_n, d, n);
    s_buf_n += n;
    s_buf[s_buf_n] = 0;
    return 0;
}

static int sink_feed(void *ctx, const char *d, int n)
{
    slot_t *s = ctx;
    lock();
    bool done = fd_parse(s->f, d, n);
    unlock();
    int kb = s->bytes / 4096;
    s->bytes += n;
    if (s->bytes / 4096 != kb) cr_notify_main();
    return done;
}

// ---- jobs ---------------------------------------------------------------------------

enum { J_NONE, J_FEED, J_IMG, J_WX };

static int pick(int a, int *img)
{
    int64_t now = now_ms();
    if (a == APP_HACKADAY || a == APP_NEWS) {
        slot_t *s = &s_feed[a - 1];
        if (!s->f) return J_NONE;
        if (s->reload || s->stage == ST_NONE) return J_FEED;
        if (s->stage == ST_READY && now - s->loaded_at > FEED_STALE_MS && !s->reading) return J_FEED;
        if (s->stage != ST_READY) return J_NONE;
        int best = -1, rank = 1 << 30, cp = s->cur_post, np = s->f->nposts;
        for (int k = 0; k < s->f->nimg; k++) {
            fd_img_t *m = &s->f->imgs[k];
            if (m->state || m->post >= np) continue;
            int p = m->post, cover = s->f->posts[p].cover == k;
            int r = p == cp && cover ? 0 : p == cp && s->reading ? 1 : cover ? 2 + (p - cp + np) % np : 100 + k;
            if (r < rank) rank = r, best = k;
        }
        *img = best;
        return best >= 0 ? J_IMG : J_NONE;
    }
    if (a == APP_WEATHER) {
        if (s_wx_want) return J_WX;
        if (s_wstage == ST_FAIL) return now - s_wx_fail_at > WX_RETRY_MS ? J_WX : J_NONE;
        if (!s_wx.ok || now - s_wx_at > WX_EVERY_MS) return J_WX;
    }
    return J_NONE;
}

static void job_feed(slot_t *s)
{
    char err[80] = "";
    lock();
    s->reload = false;
    s->stage = ST_LOAD;
    s->bytes = 0;
    fd_reset(s->f);
    s->f->site = fd_site_of(s->url);
    unlock();
    cr_notify_main();
    int64_t t0 = now_ms();
    int r = http_get(s->url, sink_feed, s, FEED_CAP, err, sizeof err);
    lock();
    if (s->f->nposts > 0) { // even a cut feed: what came in complete is kept
        s->stage = ST_READY;
        s->loaded_at = now_ms();
        if (s->cur_post >= s->f->nposts) s->cur_post = 0;
    } else {
        s->stage = ST_FAIL;
        snprintf(s->err, sizeof s->err, "%s", r ? err : "No posts in the feed.");
    }
    unlock();
    printf("netapps: %s feed %d bytes, %d posts, %d images, %lld ms%s%s\n", s->name, s->bytes, s->f->nposts,
           s->f->nimg, now_ms() - t0, r ? ", " : "", r ? err : "");
    cr_notify_main();
}

static void job_img(slot_t *s, int k)
{
    char err[80] = "";
    fd_img_t m;
    lock();
    m = s->f->imgs[k];
    unlock();
    int cap = IMG_CAP;
    s_buf_n = 0;
    int64_t t0 = now_ms();
    int r = http_get(m.url, sink_buf, &cap, cap, err, sizeof err);
    bool ok = !r && fd_decode(&m, s_buf, s_buf_n);
    lock();
    fd_img_t *dst = &s->f->imgs[k];
    if (ok && !strcmp(dst->url, m.url)) {
        dst->w = m.w, dst->h = m.h, dst->bits = m.bits;
        dst->state = 1;
    } else {
        if (ok) fd_free(m.bits); // the feed was reloaded meanwhile
        if (!strcmp(dst->url, m.url)) dst->state = -1;
    }
    unlock();
    printf("netapps: %s image %d: %d bytes, %s, %lld ms (internal heap %u)\n", s->name, k, s_buf_n,
           ok ? "ok" : (r ? err : "decode failed"), now_ms() - t0,
           (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
    cr_notify_main();
}

static void job_wx(void)
{
    char err[80] = "", url[512];
    int cap = WX_CAP;
    wx_cfg_t c;
    lock();
    c = s_wcfg;
    s_wx_want = false;
    s_wstage = ST_LOAD;
    snprintf(s_wstat, sizeof s_wstat, "UPDATING...");
    unlock();
    cr_notify_main();
    if (!c.lat[0] && c.city[0]) { // look the place up once
        wx_geo_url(c.city, url, sizeof url);
        s_buf_n = 0;
        if (http_get(url, sink_buf, &cap, cap, err, sizeof err) == 0 && !wx_parse_geo((char *)s_buf, &c))
            snprintf(err, sizeof err, "No place called \"%.30s\".", c.city);
        if (!err[0]) {
            lock();
            s_wcfg = c;
            wx_save();
            unlock();
        }
    }
    wx_t w;
    if (!err[0]) {
        wx_url(&c, url, sizeof url);
        s_buf_n = 0;
        if (http_get(url, sink_buf, &cap, cap, err, sizeof err) == 0 && !wx_parse((char *)s_buf, &w))
            snprintf(err, sizeof err, "Could not read the reply.");
    }
    lock();
    if (!err[0]) {
        s_wx = w;
        s_wx_at = now_ms();
        s_wstage = ST_READY;
        s_wstat[0] = 0;
    } else {
        s_wstage = ST_FAIL;
        s_wx_fail_at = now_ms();
        snprintf(s_wstat, sizeof s_wstat, "%s", err);
    }
    unlock();
    printf("netapps: weather %s\n", err[0] ? err : "ok");
    cr_notify_main();
}

static void fail_all(const char *why)
{
    lock();
    int a = s_active;
    if (a == APP_HACKADAY || a == APP_NEWS) {
        slot_t *s = &s_feed[a - 1];
        if (s->stage != ST_READY) s->stage = ST_FAIL;
        else s->loaded_at = now_ms(); // keep the old posts; no retry before they are stale again
        s->reload = false;
        snprintf(s->err, sizeof s->err, "%s", why);
    } else if (a == APP_WEATHER) {
        s_wstage = ST_FAIL;
        s_wx_want = false;
        s_wx_fail_at = now_ms();
        snprintf(s_wstat, sizeof s_wstat, "%s", why);
    }
    unlock();
    cr_notify_main();
}

static void worker(void *arg)
{
    bool wifi = false;
    int64_t idle = 0;
    for (;;) {
        int img = -1, a = s_active, j = pick(a, &img);
        if (j == J_NONE) {
            if (!idle) idle = now_ms();
            if (now_ms() - idle > IDLE_MS) break;
            vTaskDelay(pdMS_TO_TICKS(100));
            continue;
        }
        idle = 0;
        if (!wifi) {
            if (a == APP_HACKADAY || a == APP_NEWS) s_feed[a - 1].stage = s_feed[a - 1].stage == ST_READY ? ST_READY : ST_JOIN;
            cr_notify_main();
            wifi = cr_wifi_acquire();
            if (!wifi) {
                fail_all("Could not join the Wi-Fi (shell: wifi <ssid> <password>).");
                break;
            }
        }
        if (j == J_FEED) job_feed(&s_feed[a - 1]);
        else if (j == J_IMG) job_img(&s_feed[a - 1], img);
        else if (j == J_WX) job_wx();
    }
    http_drop();
    if (wifi) cr_wifi_unacquire();
    printf("netapps: worker done (wifi released)\n");
    s_worker = false;
    vTaskDelete(NULL);
}

static void kick(void)
{
    int img;
    if (s_worker || pick(s_active, &img) == J_NONE) return;
    s_worker = true;
    // internal RAM stack: TLS and Wi-Fi calls must not run on a PSRAM stack
    if (xTaskCreatePinnedToCore(worker, "netapps", WORKER_STACK, NULL, 3, NULL, 0) != pdPASS) {
        s_worker = false;
        fail_all("No memory for the network task.");
    }
}

static bool init(void)
{
    if (!s_lock) {
        s_lock = xSemaphoreCreateMutex();
        wx_load();
    }
    if (!s_buf) s_buf = heap_caps_malloc(IMG_CAP + 1, MALLOC_CAP_SPIRAM);
    return s_lock && s_buf;
}

// ---- Crystal API (src/apps/netapps.cr) -----------------------------------------------

void cr_app_enter(int32_t app)
{
    if (!init()) return;
    if (app == APP_HACKADAY || app == APP_NEWS) {
        slot_t *s = &s_feed[app - 1];
        if (!s->f) {
            s->f = heap_caps_calloc(1, sizeof(feed_t), MALLOC_CAP_SPIRAM);
            if (s->f) fd_init(s->f, fd_site_of(s->url));
            else snprintf(s->err, sizeof s->err, "No memory."), s->stage = ST_FAIL;
        }
        if (s->stage == ST_FAIL) s->reload = true; // try again on every visit
    }
    if (app == APP_WEATHER && s_wstage == ST_FAIL) s_wx_want = true;
    if (app == APP_RADAR && !s_radar) {
        s_radar = heap_caps_calloc(1, sizeof(radar_t), MALLOC_CAP_SPIRAM);
        uint8_t me[6];
        cr_net_me(me);
        if (s_radar) radar_init(s_radar, me, (const char *)cr_name_ptr(0));
    }
    s_active = app;
    kick();
}

void cr_app_leave(void) { s_active = APP_NONE; } // the worker winds down, Wi-Fi goes back

void cr_app_tick(void) { kick(); }

void cr_app_reload(int32_t app)
{
    if (app == APP_HACKADAY || app == APP_NEWS) s_feed[app - 1].reload = true;
    if (app == APP_WEATHER) s_wx_want = true;
    kick();
}

// ---- reader --

static slot_t *slot(int32_t app) { return app == APP_HACKADAY || app == APP_NEWS ? &s_feed[app - 1] : NULL; }

// 0 loading, 1 ready, 2 failed
int32_t cr_reader_state(int32_t app)
{
    slot_t *s = slot(app);
    if (!s || !s->f) return 2;
    return s->stage == ST_READY ? 1 : s->stage == ST_FAIL ? 2 : 0;
}

int32_t cr_reader_count(int32_t app)
{
    slot_t *s = slot(app);
    return s && s->f && s->stage == ST_READY ? s->f->nposts : 0;
}

// What is on screen: post (page < 0 = the browser card). Returns its page count.
int32_t cr_reader_view(int32_t app, int32_t post, int32_t page)
{
    slot_t *s = slot(app);
    if (!s || !s->f || s->stage != ST_READY || post < 0 || post >= s->f->nposts) return 1;
    s->cur_post = post;
    s->reading = page >= 0;
    lock();
    int n = s->f->open_post == post ? s->f->npages : fd_layout(s->f, post);
    unlock();
    kick();
    return n;
}

// A hash of what that view shows (images arriving change it).
uint32_t cr_reader_sig(int32_t app, int32_t post, int32_t page)
{
    slot_t *s = slot(app);
    if (!s || !s->f) return 0;
    uint32_t h = 2166136261u;
#define MIX(v) (h = (h ^ (uint32_t)(v)) * 16777619u)
    MIX(s->stage);
    if (s->stage != ST_READY) {
        MIX(s->bytes / 16384);
        MIX(s->err[0]);
        return h;
    }
    lock();
    feed_t *f = s->f;
    MIX(f->nposts);
    if (post >= 0 && post < f->nposts) {
        if (page < 0) {
            if (f->posts[post].cover >= 0) MIX(f->imgs[f->posts[post].cover].state);
        } else if (f->open_post == post && page < f->npages) {
            int top = f->page_top[page], end = page + 1 < f->npages ? f->page_top[page + 1] : f->nl;
            for (int k = top; k < end; k++)
                if (f->lines[k].img >= 0) MIX(f->imgs[f->lines[k].img].state);
        }
    }
    unlock();
#undef MIX
    return h;
}

void cr_reader_draw(int32_t app, uint8_t *plane, int32_t post, int32_t page)
{
    slot_t *s = slot(app);
    char msg[96];
    if (!s) return;
    if (!s->f || s->stage != ST_READY) {
        if (!s->f || s->stage == ST_FAIL) {
            fd_draw_message(plane, s->name, "Could not load the feed.", s->err[0] ? s->err : "Out of memory?");
            g_text(plane, 48, G_H - 70, 3, "A: TRY AGAIN", true);
        } else if (s->stage == ST_LOAD) {
            snprintf(msg, sizeof msg, "Downloading the feed: %d KB", s->bytes / 1024);
            fd_draw_message(plane, s->name, "Loading...", msg);
        } else {
            fd_draw_message(plane, s->name, "Loading...", "Joining the Wi-Fi...");
        }
        return;
    }
    lock();
    if (post < 0 || post >= s->f->nposts) post = 0;
    if (page < 0) fd_draw_card(s->f, plane, s->name, post);
    else fd_draw_page(s->f, plane, s->name, post, page);
    unlock();
}

// ---- weather --

void cr_weather_draw(uint8_t *plane)
{
    if (!init()) return;
    lock();
    wx_t w = s_wx;
    wx_cfg_t c = s_wcfg;
    char st[80];
    snprintf(st, sizeof st, "%s", s_wstage == ST_NONE && !w.ok ? "JOINING THE WI-FI..." : s_wstat);
    unlock();
    wx_draw(&w, &c, st, plane);
}

uint32_t cr_weather_sig(void)
{
    uint32_t h = 2166136261u;
    for (const char *p = s_wstat; *p; p++) h = (h ^ (uint8_t)*p) * 16777619u;
    h = (h ^ (uint32_t)s_wx_at) * 16777619u;
    h = (h ^ (uint32_t)s_wcfg.imperial) * 16777619u;
    return (h ^ (uint32_t)s_wstage) * 16777619u;
}

void cr_weather_toggle_units(void)
{
    if (!init()) return;
    lock();
    s_wcfg.imperial = !s_wcfg.imperial;
    s_wx.ok = false; // numbers in the old units: fetch again
    wx_save();
    unlock();
    cr_app_reload(APP_WEATHER);
}

// Shell: `weather ...` (the whole line). Prints the result.
void cr_weather_cmd(const uint8_t *line, int32_t n)
{
    char buf[160], msg[200];
    if (!init()) return;
    if (n > (int32_t)sizeof buf - 1) n = sizeof buf - 1;
    memcpy(buf, line, n);
    buf[n] = 0;
    const char *args = buf;
    while (*args == ' ') args++;
    args += strcspn(args, " "); // past "weather"
    lock();
    int r = wx_cmd(args, &s_wcfg, msg, sizeof msg);
    if (r == 1) {
        wx_save();
        s_wx.ok = false;
        s_wx_want = true;
    }
    unlock();
    fputs(msg, stdout);
    if (r == 1) {
        cr_notify_main();
        kick();
    }
}

// ---- radar --

// One update (main task, ~1 Hz); returns a signature of what the screen shows.
uint32_t cr_radar_update(void)
{
    static radar_peer_t pe[RADAR_PEERS];
    if (!s_radar) return 0;
    s_radar->net_on = cr_net_on();
    snprintf(s_radar->my_name, sizeof s_radar->my_name, "%s", (const char *)cr_name_ptr(0));
    uint8_t me[6];
    cr_net_me(me);
    memcpy(s_radar->me, me, 6);
    int n = s_radar->net_on ? cr_net_peers(pe, RADAR_PEERS) : 0;
    radar_update(s_radar, pe, n, (int32_t)now_ms());
    return radar_signature(s_radar);
}

void cr_radar_draw(uint8_t *plane)
{
    if (s_radar) radar_draw(s_radar, plane);
}
