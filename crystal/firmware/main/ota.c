// Over-the-air update and Wi-Fi station support (C side of src/ota.cr).
//
// Everything that touches NVS, Wi-Fi or TLS runs on one short-lived worker
// task (OTA_STACK bytes), never on the small shell stack or the main task:
// the shell and the DIAG screen only queue a job with cr_ota_cmd() and the
// main task polls cr_ota_state() / cr_ota_pct() / cr_ota_msg() for the
// on-screen status. Wi-Fi is brought up only for an update check and shut
// down (esp_wifi_deinit, netif destroyed) right after, so it costs no RAM or
// power the rest of the time.
//
// NVS namespace "ota": ssid, pass (strings), url (string, optional),
// wifi_off (u8). Credentials are only ever entered from the USB shell.
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/event_groups.h"
#include "esp_err.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "esp_http_client.h"
#include "esp_https_ota.h"
#include "esp_crt_bundle.h"
#include "esp_ota_ops.h"
#include "esp_app_desc.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "esp_system.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "sdkconfig.h"
#include "version.h"

#if !CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE
#error "CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE must be set (sdkconfig.defaults)"
#endif
#if !CONFIG_MBEDTLS_CERTIFICATE_BUNDLE
#error "CONFIG_MBEDTLS_CERTIFICATE_BUNDLE must be set (sdkconfig.defaults)"
#endif

#define OTA_DEFAULT_URL "https://github.com/embedconsult/Hack_Badge_2026/releases/latest/download/badge-app.bin"
#define OTA_PROJECT     "crystal_blink"     // refuse images of another project
#define OTA_STACK       10240               // worker task stack (internal RAM)
#define OTA_MIN_INTERNAL (72 * 1024)        // free internal heap needed to start Wi-Fi + TLS
#define OTA_MIN_BLOCK    (24 * 1024)        // largest free internal block needed
#define BOOT_GUARD_MS    90000              // pending image not confirmed by then -> roll back
#define URL_MAX 256

// Jobs (cr_ota_cmd); keep in sync with src/ota.cr.
enum {
    JOB_UPDATE = 1,       // check badge-version.txt, update if different
    JOB_FORCE = 2,        // update without the version check
    JOB_WIFI_SET = 3,     // a = ssid, b = password
    JOB_WIFI_OFF = 4,
    JOB_WIFI_STATUS = 5,
    JOB_WIFI_FORGET = 6,
    JOB_URL_SET = 7,      // a = url ("default" resets)
    JOB_STATUS = 8,       // ota status: url, partitions, last result
};

// Status for the UI; keep in sync with src/ota.cr.
enum {
    ST_IDLE = 0,
    ST_CONNECTING = 1,
    ST_CHECKING = 2,
    ST_DOWNLOADING = 3,
    ST_UP_TO_DATE = 4,
    ST_FAILED = 5,
    ST_REBOOTING = 6,
};

static volatile uint32_t s_busy;        // a job is running (atomic)
static volatile int32_t s_state;
static volatile int32_t s_pct;
static volatile bool s_update_job;      // the running job is an update (UI shows it)
static char s_msg[72];                  // failure reason / detail for the UI
static int s_job;
static char s_a[URL_MAX];
static char s_b[72];
static char s_last_ip[16];
static int s_last_rssi;

static bool s_net_inited;
static EventGroupHandle_t s_eg;
static esp_netif_t *s_netif;
static esp_event_handler_instance_t s_h_wifi, s_h_ip;
static int s_retries;
static volatile bool s_hold;            // network mode (main/net.c) keeps Wi-Fi up
static volatile int s_apps;             // content apps (main/apps_net.c) using the station
static uint8_t s_channel;
#define BIT_UP   BIT0
#define BIT_FAIL BIT1

void cr_wifi_unacquire(void);

static void set_state(int32_t st, const char *msg)
{
    if (msg && msg != s_msg) {
        strncpy(s_msg, msg, sizeof s_msg - 1);
        s_msg[sizeof s_msg - 1] = 0;
    }
    s_state = st;
}

static void fail(const char *why)
{
    printf("ota: failed: %s\n", why);
    set_state(ST_FAILED, why);
}

// ---- NVS ---------------------------------------------------------------

static bool nv_open(nvs_handle_t *h, bool rw)
{
    nvs_flash_init(); // no-op when already initialised; never erases
    return nvs_open("ota", rw ? NVS_READWRITE : NVS_READONLY, h) == ESP_OK;
}

static bool nv_str(const char *key, char *out, size_t n)
{
    nvs_handle_t h;
    out[0] = 0;
    if (!nv_open(&h, false)) return false;
    size_t len = n;
    esp_err_t e = nvs_get_str(h, key, out, &len);
    nvs_close(h);
    if (e != ESP_OK) out[0] = 0;
    return e == ESP_OK;
}

static uint8_t nv_u8(const char *key, uint8_t dflt)
{
    nvs_handle_t h;
    uint8_t v = dflt;
    if (!nv_open(&h, false)) return dflt;
    if (nvs_get_u8(h, key, &v) != ESP_OK) v = dflt;
    nvs_close(h);
    return v;
}

static void get_url(char *out, size_t n)
{
    if (!nv_str("url", out, n) || !out[0]) {
        strncpy(out, OTA_DEFAULT_URL, n - 1);
        out[n - 1] = 0;
    }
}

// ---- Wi-Fi station -----------------------------------------------------

static void on_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        wifi_event_sta_disconnected_t *d = data;
        if (s_eg) xEventGroupClearBits(s_eg, BIT_UP);
        if (s_hold || ++s_retries <= 4) { // network mode: retry forever
            printf("wifi: disconnected (reason %d), retry %d\n", d->reason, s_retries);
            esp_wifi_connect();
        } else {
            snprintf(s_msg, sizeof s_msg, "wifi: no connection (reason %d)", d->reason);
            xEventGroupSetBits(s_eg, BIT_FAIL);
        }
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *e = data;
        snprintf(s_last_ip, sizeof s_last_ip, IPSTR, IP2STR(&e->ip_info.ip));
        wifi_second_chan_t sc;
        esp_wifi_get_channel(&s_channel, &sc);
        s_retries = 0;
        xEventGroupSetBits(s_eg, BIT_UP);
    }
}

static void wifi_down(void)
{
    if (!s_netif || s_hold || s_apps) return; // network mode / an app owns the radio now
    esp_wifi_disconnect();
    esp_wifi_stop();
    esp_event_handler_instance_unregister(WIFI_EVENT, ESP_EVENT_ANY_ID, s_h_wifi);
    esp_event_handler_instance_unregister(IP_EVENT, IP_EVENT_STA_GOT_IP, s_h_ip);
    esp_wifi_deinit();
    esp_netif_destroy_default_wifi(s_netif);
    s_netif = NULL;
    if (s_eg) vEventGroupDelete(s_eg);
    s_eg = NULL;
    printf("wifi: off (internal heap free %u)\n", (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
}

void cr_wifi_ap_stop(void);
static esp_netif_t *s_ap_netif;          // `net ap on`: the badge's own access point (main/net.c)

static bool wifi_up(void)
{
    char ssid[33], pass[65];
    if (s_ap_netif) { fail("net ap is on: no station (net ap off)"); return false; }
    if (s_netif) { // already up (network mode): just wait for the link
        EventBits_t b = xEventGroupWaitBits(s_eg, BIT_UP, pdFALSE, pdFALSE, pdMS_TO_TICKS(25000));
        if (!(b & BIT_UP)) { fail("wifi: not connected"); return false; }
        return true;
    }
    if (nv_u8("wifi_off", 0)) { fail("wifi is off (wifi <ssid> <pass>)"); return false; }
    if (!nv_str("ssid", ssid, sizeof ssid) || !ssid[0]) { fail("no wifi set (wifi <ssid> <pass>)"); return false; }
    nv_str("pass", pass, sizeof pass);

    size_t fr = heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
    size_t lb = heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL);
    printf("wifi: internal heap free %u, largest %u\n", (unsigned)fr, (unsigned)lb);
    if (fr < OTA_MIN_INTERNAL || lb < OTA_MIN_BLOCK) {
        snprintf(s_msg, sizeof s_msg, "low memory (%u KB free)", (unsigned)(fr / 1024));
        fail(s_msg);
        return false;
    }
    set_state(ST_CONNECTING, ssid);
    printf("wifi: connecting to \"%s\"\n", ssid);
    if (!s_net_inited) {
        esp_err_t e = esp_netif_init();
        if (e == ESP_OK) e = esp_event_loop_create_default();
        if (e != ESP_OK && e != ESP_ERR_INVALID_STATE) { fail("netif init"); return false; }
        s_net_inited = true;
    }
    s_eg = xEventGroupCreate();
    s_netif = esp_netif_create_default_wifi_sta();
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    esp_err_t e = s_eg && s_netif ? esp_wifi_init(&cfg) : ESP_ERR_NO_MEM;
    if (e != ESP_OK) {
        snprintf(s_msg, sizeof s_msg, "wifi init: %s", esp_err_to_name(e));
        if (s_netif) esp_netif_destroy_default_wifi(s_netif);
        s_netif = NULL;
        if (s_eg) vEventGroupDelete(s_eg);
        s_eg = NULL;
        fail(s_msg);
        return false;
    }
    esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID, on_event, NULL, &s_h_wifi);
    esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP, on_event, NULL, &s_h_ip);
    esp_wifi_set_storage(WIFI_STORAGE_RAM); // credentials live in our "ota" namespace only
    esp_wifi_set_mode(WIFI_MODE_STA);
    wifi_config_t wc = {0};
    memcpy(wc.sta.ssid, ssid, strlen(ssid));
    memcpy(wc.sta.password, pass, strlen(pass));
    wc.sta.threshold.authmode = pass[0] ? WIFI_AUTH_WPA_PSK : WIFI_AUTH_OPEN;
    wc.sta.pmf_cfg.capable = true;
    esp_wifi_set_config(WIFI_IF_STA, &wc);
    memset(pass, 0, sizeof pass);
    memset(&wc, 0, sizeof wc);
    s_retries = 0;
    s_last_ip[0] = 0;
    esp_wifi_start();
    EventBits_t b = xEventGroupWaitBits(s_eg, BIT_UP | BIT_FAIL, pdFALSE, pdFALSE, pdMS_TO_TICKS(25000));
    if (!(b & BIT_UP)) {
        if (!(b & BIT_FAIL)) snprintf(s_msg, sizeof s_msg, "wifi: timeout");
        fail(s_msg);
        wifi_down();
        return false;
    }
    wifi_ap_record_t ap;
    s_last_rssi = esp_wifi_sta_get_ap_info(&ap) == ESP_OK ? ap.rssi : 0;
    printf("wifi: up, ip %s rssi %d\n", s_last_ip, s_last_rssi);
    return true;
}

// ---- network mode (main/net.c) ------------------------------------------

// Brings Wi-Fi up (blocking, up to 25 s) and keeps it up until cr_wifi_release.
// Runs on the net task; the OTA worker then reuses the connection.
bool cr_wifi_hold(void)
{
    s_hold = true;
    if (s_netif) return (xEventGroupGetBits(s_eg) & BIT_UP) != 0;
    s_hold = false; // wifi_up's failure path must be able to tear down
    bool ok = wifi_up();
    if (ok) {
        s_hold = true;
        set_state(ST_IDLE, "");
    }
    return ok;
}

void cr_wifi_release(void)
{
    s_hold = false;
    if (!__atomic_load_n(&s_busy, __ATOMIC_SEQ_CST)) wifi_down(); // an OTA job downs it when done
}

// `net ap on`: an access point on `ch` (badge os uses channel 1), DHCP server
// 192.168.4.1/24. No station meanwhile (an ESP32 radio is on one channel).
bool cr_wifi_ap_start(const char *ssid, const char *pass, int32_t ch)
{
    if (s_netif || s_ap_netif) return false;
    if (!s_net_inited) {
        esp_err_t e = esp_netif_init();
        if (e == ESP_OK) e = esp_event_loop_create_default();
        if (e != ESP_OK && e != ESP_ERR_INVALID_STATE) return false;
        s_net_inited = true;
    }
    s_ap_netif = esp_netif_create_default_wifi_ap();
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    if (!s_ap_netif || esp_wifi_init(&cfg) != ESP_OK) {
        if (s_ap_netif) esp_netif_destroy_default_wifi(s_ap_netif);
        s_ap_netif = NULL;
        return false;
    }
    esp_wifi_set_storage(WIFI_STORAGE_RAM);
    esp_wifi_set_mode(WIFI_MODE_AP);
    wifi_config_t wc = {0};
    size_t n = strlen(ssid) > 32 ? 32 : strlen(ssid);
    memcpy(wc.ap.ssid, ssid, n);
    wc.ap.ssid_len = n;
    memcpy(wc.ap.password, pass, strlen(pass) > 63 ? 63 : strlen(pass));
    wc.ap.channel = ch;
    wc.ap.authmode = strlen(pass) >= 8 ? WIFI_AUTH_WPA2_PSK : WIFI_AUTH_OPEN;
    wc.ap.max_connection = 4;
    wc.ap.beacon_interval = 100;
    esp_wifi_set_config(WIFI_IF_AP, &wc);
    if (esp_wifi_start() != ESP_OK) { cr_wifi_ap_stop(); return false; }
    s_channel = ch;
    snprintf(s_last_ip, sizeof s_last_ip, "192.168.4.1");
    printf("wifi: access point \"%s\" on channel %ld\n", ssid, (long)ch);
    return true;
}

void cr_wifi_ap_stop(void)
{
    if (!s_ap_netif) return;
    esp_wifi_stop();
    esp_wifi_deinit();
    esp_netif_destroy_default_wifi(s_ap_netif);
    s_ap_netif = NULL;
    s_last_ip[0] = 0;
}

bool cr_wifi_ap_on(void) { return s_ap_netif != NULL; }

int32_t cr_wifi_ap_clients(void)
{
    wifi_sta_list_t l;
    return s_ap_netif && esp_wifi_ap_get_sta_list(&l) == ESP_OK ? l.num : 0;
}

bool cr_wifi_connected(void) { return s_ap_netif || (s_netif && s_eg && (xEventGroupGetBits(s_eg) & BIT_UP)); }
// ---- content apps (main/apps_net.c) ---------------------------------------
// Like cr_wifi_hold, but counted and independent of network mode: the
// station stays up while network mode holds it or any app uses it.
// Blocking (up to 25 s); call from a worker task, never the main task.
bool cr_wifi_acquire(void)
{
    // An OTA job may be bringing Wi-Fi up or down right now: wait for it.
    for (int i = 0; i < 300 && __atomic_load_n(&s_busy, __ATOMIC_SEQ_CST) && !s_netif; i++)
        vTaskDelay(pdMS_TO_TICKS(100));
    if (s_netif) { // up already (network mode or another app): wait for the link
        __atomic_add_fetch(&s_apps, 1, __ATOMIC_SEQ_CST);
        EventBits_t b = s_eg ? xEventGroupWaitBits(s_eg, BIT_UP, pdFALSE, pdFALSE, pdMS_TO_TICKS(20000)) : 0;
        if (b & BIT_UP) return true;
        cr_wifi_unacquire();
        return false;
    }
    bool ok = wifi_up(); // s_apps is 0 here, so its failure path tears down
    if (ok) {
        __atomic_add_fetch(&s_apps, 1, __ATOMIC_SEQ_CST);
        set_state(ST_IDLE, "");
    }
    return ok;
}

void cr_wifi_unacquire(void)
{
    if (__atomic_sub_fetch(&s_apps, 1, __ATOMIC_SEQ_CST) <= 0) {
        s_apps = 0;
        if (!s_hold && !__atomic_load_n(&s_busy, __ATOMIC_SEQ_CST)) wifi_down();
    }
}

const char *cr_wifi_ip(void) { return s_last_ip; }
int32_t cr_wifi_channel(void) { return s_channel; }
int32_t cr_wifi_rssi(void)
{
    wifi_ap_record_t ap;
    return cr_wifi_connected() && esp_wifi_sta_get_ap_info(&ap) == ESP_OK ? ap.rssi : 0;
}

// ---- version check -------------------------------------------------------

typedef struct { char buf[64]; int len; } vbuf_t;

static esp_err_t ver_event(esp_http_client_event_t *evt)
{
    vbuf_t *v = evt->user_data;
    // Only the final 200 response's body (redirect bodies are skipped).
    if (evt->event_id == HTTP_EVENT_ON_DATA && esp_http_client_get_status_code(evt->client) == 200) {
        int n = evt->data_len;
        if (n > (int)sizeof v->buf - 1 - v->len) n = (int)sizeof v->buf - 1 - v->len;
        if (n > 0) { memcpy(v->buf + v->len, evt->data, n); v->len += n; }
    }
    return ESP_OK;
}

static void base_config(esp_http_client_config_t *c, const char *url)
{
    memset(c, 0, sizeof *c);
    c->url = url;
    c->crt_bundle_attach = esp_crt_bundle_attach;
    c->timeout_ms = 20000;
    c->max_redirection_count = 8;
    c->buffer_size = 4096;     // GitHub's redirect responses have long headers
    c->buffer_size_tx = 2048;  // and long signed Location URLs
    c->keep_alive_enable = true;
}

// Fetches badge-version.txt next to the image URL into out (trimmed).
static bool fetch_version(const char *img_url, char *out, size_t n)
{
    char vurl[URL_MAX + 24];
    const char *slash = strrchr(img_url, '/');
    if (!slash) return false;
    int base = (int)(slash - img_url) + 1;
    snprintf(vurl, sizeof vurl, "%.*sbadge-version.txt", base, img_url);
    vbuf_t v = {0};
    esp_http_client_config_t c;
    base_config(&c, vurl);
    c.event_handler = ver_event;
    c.user_data = &v;
    esp_http_client_handle_t h = esp_http_client_init(&c);
    if (!h) return false;
    esp_err_t e = esp_http_client_perform(h);
    int code = esp_http_client_get_status_code(h);
    esp_http_client_cleanup(h);
    if (e != ESP_OK || code != 200) {
        snprintf(s_msg, sizeof s_msg, "version: %s http %d", esp_err_to_name(e), code);
        return false;
    }
    v.buf[v.len] = 0;
    char *p = v.buf;
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
    int l = (int)strlen(p);
    while (l > 0 && (p[l - 1] == ' ' || p[l - 1] == '\t' || p[l - 1] == '\r' || p[l - 1] == '\n')) p[--l] = 0;
    strncpy(out, p, n - 1);
    out[n - 1] = 0;
    return out[0] != 0;
}

// CR_VERSION is "<git describe> <HH:MM>": compare the describe part.
static bool same_version(const char *v)
{
    const char *cur = CR_VERSION;
    size_t cl = strcspn(cur, " ");
    return strlen(v) == cl && strncmp(v, cur, cl) == 0;
}

// ---- update --------------------------------------------------------------

static void do_update(bool force)
{
    char url[URL_MAX];
    get_url(url, sizeof url);
    s_pct = 0;
    if (!wifi_up()) return;

    set_state(ST_CHECKING, "");
    if (!force) {
        char ver[48];
        printf("ota: checking version (running %s)\n", CR_VERSION);
        if (!fetch_version(url, ver, sizeof ver)) { fail(s_msg[0] ? s_msg : "version check"); wifi_down(); return; }
        printf("ota: latest %s\n", ver);
        if (same_version(ver)) {
            printf("ota: up to date\n");
            set_state(ST_UP_TO_DATE, ver);
            wifi_down();
            return;
        }
        snprintf(s_msg, sizeof s_msg, "%s", ver);
    }

    printf("ota: downloading %s\n", url);
    set_state(ST_DOWNLOADING, NULL);
    esp_http_client_config_t hc;
    base_config(&hc, url);
    esp_https_ota_config_t oc = { .http_config = &hc };
    esp_https_ota_handle_t h = NULL;
    esp_err_t e = esp_https_ota_begin(&oc, &h);
    if (e != ESP_OK) {
        snprintf(s_msg, sizeof s_msg, "download: %s", esp_err_to_name(e));
        fail(s_msg);
        wifi_down();
        return;
    }
    esp_app_desc_t d;
    if (esp_https_ota_get_img_desc(h, &d) != ESP_OK || strncmp(d.project_name, OTA_PROJECT, sizeof d.project_name) != 0) {
        esp_https_ota_abort(h);
        fail("not a badge image");
        wifi_down();
        return;
    }
    printf("ota: image %s %s\n", d.project_name, d.version);
    int last = -10;
    while ((e = esp_https_ota_perform(h)) == ESP_ERR_HTTPS_OTA_IN_PROGRESS) {
        int size = esp_https_ota_get_image_size(h);
        int got = esp_https_ota_get_image_len_read(h);
        int pct = size > 0 ? (int)((int64_t)got * 100 / size) : 0;
        s_pct = pct;
        if (pct >= last + 10) {
            printf("ota: %d%% (%d / %d bytes)\n", pct, got, size);
            last = pct - pct % 10;
        }
    }
    if (e == ESP_OK && !esp_https_ota_is_complete_data_received(h)) e = ESP_ERR_INVALID_SIZE;
    if (e != ESP_OK) {
        esp_https_ota_abort(h);
        snprintf(s_msg, sizeof s_msg, "download: %s", esp_err_to_name(e));
        fail(s_msg);
        wifi_down();
        return;
    }
    e = esp_https_ota_finish(h); // validates the image, sets the boot partition
    wifi_down();
    if (e != ESP_OK) {
        snprintf(s_msg, sizeof s_msg, "verify: %s", esp_err_to_name(e));
        fail(s_msg);
        return;
    }
    s_pct = 100;
    printf("ota: done, rebooting into the new image\n");
    set_state(ST_REBOOTING, NULL);
    vTaskDelay(pdMS_TO_TICKS(4000)); // let the UI show it
    esp_restart();
}

// ---- shell jobs ----------------------------------------------------------

static void print_status(void)
{
    char url[URL_MAX];
    get_url(url, sizeof url);
    const esp_partition_t *run = esp_ota_get_running_partition();
    const esp_partition_t *nxt = esp_ota_get_next_update_partition(NULL);
    esp_ota_img_states_t st = ESP_OTA_IMG_UNDEFINED;
    if (run) esp_ota_get_state_partition(run, &st);
    printf("ota: version %s\n", CR_VERSION);
    printf("ota: url %s\n", url);
    printf("ota: running %s (state %d), next %s (0x%lx bytes)\n", run ? run->label : "?", (int)st,
           nxt ? nxt->label : "none", nxt ? (unsigned long)nxt->size : 0UL);
    printf("ota: last state %ld %s\n", (long)s_state, s_msg);
}

static void worker(void *arg)
{
    nvs_handle_t h;
    switch (s_job) {
    case JOB_UPDATE:
    case JOB_FORCE:
        do_update(s_job == JOB_FORCE);
        break;
    case JOB_WIFI_SET:
        if (strlen(s_a) > 32 || strlen(s_b) > 63 || (s_b[0] && strlen(s_b) < 8)) {
            printf("wifi: ssid must be <= 32 chars, password 8..63 (or none)\n");
        } else if (nv_open(&h, true)) {
            nvs_set_str(h, "ssid", s_a);
            nvs_set_str(h, "pass", s_b);
            nvs_set_u8(h, "wifi_off", 0);
            printf("wifi: saved \"%s\" (%s), used for ota\n", s_a, s_b[0] ? "with password" : "open");
            nvs_commit(h);
            nvs_close(h);
        }
        break;
    case JOB_WIFI_OFF:
        if (nv_open(&h, true)) { nvs_set_u8(h, "wifi_off", 1); nvs_commit(h); nvs_close(h); }
        printf("wifi: off (credentials kept; wifi <ssid> <pass> turns it on)\n");
        break;
    case JOB_WIFI_FORGET:
        if (nv_open(&h, true)) { nvs_erase_key(h, "ssid"); nvs_erase_key(h, "pass"); nvs_commit(h); nvs_close(h); }
        printf("wifi: credentials erased\n");
        break;
    case JOB_WIFI_STATUS: {
        char ssid[33];
        bool have = nv_str("ssid", ssid, sizeof ssid) && ssid[0];
        printf("wifi: %s, ssid %s%s%s\n", nv_u8("wifi_off", 0) ? "off" : "on (only during ota)",
               have ? "\"" : "", have ? ssid : "(none)", have ? "\"" : "");
        printf("wifi: radio %s; last ip %s rssi %d\n", s_netif ? "up" : "down",
               s_last_ip[0] ? s_last_ip : "-", s_last_rssi);
        printf("wifi: internal heap free %u, largest block %u\n",
               (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
               (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL));
        break;
    }
    case JOB_URL_SET:
        if (nv_open(&h, true)) {
            if (strcmp(s_a, "default") == 0) nvs_erase_key(h, "url");
            else nvs_set_str(h, "url", s_a);
            nvs_commit(h);
            nvs_close(h);
        }
        get_url(s_a, sizeof s_a);
        printf("ota: url %s\n", s_a);
        break;
    case JOB_STATUS:
        print_status();
        break;
    }
    memset(s_b, 0, sizeof s_b);
    printf("> ");
    fflush(stdout);
    s_update_job = false;
    __atomic_store_n(&s_busy, 0, __ATOMIC_SEQ_CST);
    vTaskDelete(NULL);
}

static void copy_arg(char *dst, size_t n, const uint8_t *src, int32_t len)
{
    if (!src || len < 0) len = 0;
    if ((size_t)len > n - 1) len = (int32_t)(n - 1);
    if (len) memcpy(dst, src, (size_t)len);
    dst[len] = 0;
}

// Starts a job on the worker task. Returns 0 if started, 1 if a job is
// already running, 2 if the task could not be created.
int32_t cr_ota_cmd(int32_t job, const uint8_t *a, int32_t alen, const uint8_t *b, int32_t blen)
{
    if (__atomic_exchange_n(&s_busy, 1, __ATOMIC_SEQ_CST)) return 1;
    s_job = job;
    copy_arg(s_a, sizeof s_a, a, alen);
    copy_arg(s_b, sizeof s_b, b, blen);
    if (job == JOB_UPDATE || job == JOB_FORCE) {
        s_msg[0] = 0;
        s_pct = 0;
        s_state = ST_CONNECTING;
        s_update_job = true;
    }
    if (xTaskCreatePinnedToCore(worker, "ota", OTA_STACK, NULL, 3, NULL, 0) != pdPASS) {
        s_update_job = false;
        if (job == JOB_UPDATE || job == JOB_FORCE) set_state(ST_FAILED, "no memory for task");
        __atomic_store_n(&s_busy, 0, __ATOMIC_SEQ_CST);
        return 2;
    }
    return 0;
}

bool cr_ota_running(void) { return s_update_job; }
int32_t cr_ota_state(void) { return s_state; }
int32_t cr_ota_pct(void) { return s_pct; }
const char *cr_ota_msg(void) { return s_msg; }

// ---- rollback ------------------------------------------------------------

static bool pending_verify(void)
{
    esp_ota_img_states_t st;
    const esp_partition_t *run = esp_ota_get_running_partition();
    return run && esp_ota_get_state_partition(run, &st) == ESP_OK && st == ESP_OTA_IMG_PENDING_VERIFY;
}

static esp_timer_handle_t s_guard;

static void guard_cb(void *arg)
{
    if (pending_verify()) {
        printf("ota: new image not confirmed in %d s, rolling back\n", BOOT_GUARD_MS / 1000);
        esp_ota_mark_app_invalid_rollback_and_reboot();
    }
}

// app_main: a freshly updated image must confirm itself (cr_ota_boot_ok,
// after the display came up) within BOOT_GUARD_MS, else it is rolled back.
// A crash or reset before that rolls back in the bootloader.
void cr_ota_boot_guard(void)
{
    if (!pending_verify()) return;
    printf("ota: first boot of a new image, waiting for the display\n");
    esp_timer_create_args_t a = { .callback = guard_cb, .name = "ota_guard" };
    if (esp_timer_create(&a, &s_guard) == ESP_OK) esp_timer_start_once(s_guard, (uint64_t)BOOT_GUARD_MS * 1000);
}

int cr_ota_boot_ok(void)
{
    if (!pending_verify()) return 0;
    esp_ota_mark_app_valid_cancel_rollback();
    if (s_guard) esp_timer_stop(s_guard);
    printf("ota: new image marked valid\n");
    return 1;
}

void cr_ota_boot_failed(void)
{
    if (!pending_verify()) return;
    printf("ota: display init failed on a new image, rolling back\n");
    esp_ota_mark_app_invalid_rollback_and_reboot();
}
