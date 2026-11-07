// Settings app, C side (src/apps/settings.cr): the badge opens its own
// WPA2 access point "Badge-XXXX" with a fresh random password and serves a
// settings page at http://192.168.4.1/ (esp_http_server):
//   - nametag text, two lines of up to 12 characters (net.c cr_name_set,
//     NVS net/name "first|last")
//   - Wi-Fi the badge joins for OTA and network mode (NVS ota/ssid, ota/pass;
//     ota/wifi_off cleared, like the shell's `wifi <ssid> <pass>`)
//   - network mode on/off (NVS net/on), applied when Settings is left.
//   - /robots: the ROBOTS app's robot slots (main/robots.c): paste a robot
//     in the crystal-robots language, it is parsed and checked on the badge
//     (cr_robot_check, src/apps/robot_store.cr) and saved to a slot.
// One radio: network mode is paused while the AP is up (cr_net_pause) and
// restarted from NVS afterwards (cr_net_boot). The AP itself is ota.c's
// cr_wifi_ap_start / cr_wifi_ap_stop (also used by `net ap on`).
// After badge os's Settings app (yigitabi5444); our own implementation.
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_http_server.h"
#include "esp_mac.h"
#include "esp_random.h"
#include "nvs.h"
#include "nvs_flash.h"

bool cr_wifi_ap_start(const char *ssid, const char *pass, int32_t ch); // main/ota.c
void cr_wifi_ap_stop(void);
int32_t cr_wifi_ap_clients(void);
bool cr_net_pause(void);                                               // main/net.c
void cr_net_boot(void);
int32_t cr_name_len(int32_t i);
const uint8_t *cr_name_ptr(int32_t i);
void cr_name_set(const uint8_t *s, int32_t n);
int32_t cr_robot_slots(void);                                          // main/robots.c
int32_t cr_robot_max(void);
int32_t cr_robot_len(int32_t k);
int32_t cr_robot_read(int32_t k, uint8_t *buf, int32_t max);
bool cr_robot_write(int32_t k, const uint8_t *src, int32_t n, const char *name);
bool cr_robot_name(int32_t k, char *out);
int32_t cr_robot_check(const uint8_t *src, int32_t n, uint8_t *msg, int32_t max); // src/apps/robot_store.cr

#define AP_CHANNEL 6
#define BODY_MAX 512
#define TAG_MAX 12

static httpd_handle_t s_http;
static char s_ssid[16], s_pass[12];
static volatile uint32_t s_saves; // bumped on every save (Crystal redraws)
static char s_msg[48] = "";

const char *cr_settings_ssid(void) { return s_ssid; }
const char *cr_settings_pass(void) { return s_pass; }
uint32_t cr_settings_saves(void) { return s_saves; }
const char *cr_settings_msg(void) { return s_msg; }
int32_t cr_settings_clients(void) { return s_http ? cr_wifi_ap_clients() : 0; }

// ---- NVS --------------------------------------------------------------------

static bool nv_get_str(const char *ns, const char *key, char *out, size_t n)
{
    nvs_handle_t h;
    out[0] = 0;
    if (nvs_open(ns, NVS_READONLY, &h) != ESP_OK) return false;
    size_t len = n;
    bool ok = nvs_get_str(h, key, out, &len) == ESP_OK;
    nvs_close(h);
    if (!ok) out[0] = 0;
    return ok;
}

static uint8_t nv_get_u8(const char *ns, const char *key, uint8_t dflt)
{
    nvs_handle_t h;
    uint8_t v = dflt;
    if (nvs_open(ns, NVS_READONLY, &h) != ESP_OK) return dflt;
    if (nvs_get_u8(h, key, &v) != ESP_OK) v = dflt;
    nvs_close(h);
    return v;
}

// ---- HTML -------------------------------------------------------------------

// Appends s HTML-escaped (only printable ASCII kept).
static void put_esc(httpd_req_t *r, const char *s)
{
    char b[64];
    int n = 0;
    for (; *s; s++) {
        const char *e = NULL;
        char one[2] = {*s, 0};
        switch (*s) {
        case '&': e = "&amp;"; break;
        case '<': e = "&lt;"; break;
        case '>': e = "&gt;"; break;
        case '"': e = "&quot;"; break;
        case '\'': e = "&#39;"; break;
        default: e = (*s >= 0x20 && *s <= 0x7E) ? one : ""; break;
        }
        size_t k = strlen(e);
        if (n + k >= sizeof b) { httpd_resp_send_chunk(r, b, n); n = 0; }
        memcpy(b + n, e, k);
        n += k;
    }
    if (n) httpd_resp_send_chunk(r, b, n);
}

static void put(httpd_req_t *r, const char *s) { httpd_resp_send_chunk(r, s, HTTPD_RESP_USE_STRLEN); }

// HTML-escaped text for a <textarea> (keeps newlines and tabs).
static void put_text(httpd_req_t *r, const char *s, int n)
{
    char b[128];
    int k = 0;
    for (int i = 0; i < n; i++) {
        char c = s[i];
        const char *e = NULL;
        char one[2] = {c, 0};
        if (c == '&') e = "&amp;";
        else if (c == '<') e = "&lt;";
        else if (c == '>') e = "&gt;";
        else e = (c == '\n' || c == '\t' || (c >= 0x20 && c <= 0x7E)) ? one : "";
        size_t m = strlen(e);
        if (k + m >= sizeof b) { httpd_resp_send_chunk(r, b, k); k = 0; }
        memcpy(b + k, e, m);
        k += m;
    }
    if (k) httpd_resp_send_chunk(r, b, k);
}

static const char k_head[] =
    "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
    "<title>Badge settings</title><style>body{font:16px system-ui,sans-serif;max-width:32em;margin:auto;padding:1em}"
    "fieldset{border:1px solid #bbb;border-radius:8px;margin:0 0 1em}input{font:inherit;width:100%;box-sizing:border-box;"
    "padding:.4em;margin:.2em 0 .6em}input[type=checkbox]{width:auto}button{font:inherit;background:#b00;color:#fff;"
    "border:0;border-radius:8px;padding:.7em 1.4em}small{color:#666}</style><h2>Badge settings</h2>";

static void name_line(int i, char *out)
{
    int n = cr_name_len(i);
    if (n > TAG_MAX) n = TAG_MAX;
    memcpy(out, cr_name_ptr(i), n);
    out[n] = 0;
}

static esp_err_t h_root(httpd_req_t *r)
{
    char l0[TAG_MAX + 1], l1[TAG_MAX + 1], ssid[33];
    name_line(0, l0);
    name_line(1, l1);
    nv_get_str("ota", "ssid", ssid, sizeof ssid);
    bool net = nv_get_u8("net", "on", 0);
    httpd_resp_set_type(r, "text/html");
    httpd_resp_set_hdr(r, "Cache-Control", "no-store");
    put(r, k_head);
    if (s_msg[0]) { put(r, "<p><b>"); put_esc(r, s_msg); put(r, "</b></p>"); }
    put(r, "<form method=post action=/save><fieldset><legend>Nametag</legend>Line 1<input name=n1 maxlength=12 value=\"");
    put_esc(r, l0);
    put(r, "\">Line 2<input name=n2 maxlength=12 value=\"");
    put_esc(r, l1);
    put(r, "\"><small>Up to 12 characters each (A-Z, digits, punctuation).</small></fieldset>"
           "<fieldset><legend>Wi-Fi the badge joins</legend><small>Used by online update and network mode.</small><br>"
           "SSID<input name=ssid maxlength=32 value=\"");
    put_esc(r, ssid);
    put(r, "\">Password<input name=pass type=password maxlength=63 autocomplete=off placeholder='");
    put(r, ssid[0] ? "(unchanged if empty)" : "");
    put(r, "'><label><input type=checkbox name=open value=1> Open network (no password)</label></fieldset>"
           "<fieldset><legend>Network mode</legend><label><input type=checkbox name=net value=1");
    if (net) put(r, " checked");
    put(r, "> Badge link on (UDP + ESP-NOW; starts when you leave Settings)</label></fieldset>"
           "<button>Save</button></form>");
    put(r, "<p><a href=/robots>Robots</a>: battle robots for the ROBOTS app</p>");
    put(r, NULL);
    return ESP_OK;
}

static int hexv(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

// Value of key in an urlencoded body, decoded into out (at most max
// characters; longer input is rejected). Returns length, -1 if missing,
// -2 if too long.
static int form_get(const char *body, const char *key, char *out, int max)
{
    size_t kl = strlen(key);
    const char *p = body;
    while (*p) {
        const char *amp = strchr(p, '&');
        const char *end = amp ? amp : p + strlen(p);
        if ((size_t)(end - p) > kl && !strncmp(p, key, kl) && p[kl] == '=') {
            int n = 0;
            for (const char *s = p + kl + 1; s < end; s++) {
                int c = (unsigned char)*s;
                if (c == '+') c = ' ';
                else if (c == '%' && s + 2 < end && hexv(s[1]) >= 0 && hexv(s[2]) >= 0) {
                    c = hexv(s[1]) * 16 + hexv(s[2]);
                    s += 2;
                }
                if (n >= max) return -2;
                out[n++] = (char)c;
            }
            out[n] = 0;
            return n;
        }
        if (!amp) break;
        p = amp + 1;
    }
    out[0] = 0;
    return -1;
}

static bool printable(const char *s, bool allow_bar)
{
    for (; *s; s++)
        if (*s < 0x20 || *s > 0x7E || (!allow_bar && *s == '|')) return false;
    return true;
}

static esp_err_t reply(httpd_req_t *r, const char *msg)
{
    snprintf(s_msg, sizeof s_msg, "%s", msg);
    s_saves++;
    httpd_resp_set_status(r, "303 See Other");
    httpd_resp_set_hdr(r, "Location", "/");
    httpd_resp_send(r, NULL, 0);
    return ESP_OK;
}

static esp_err_t h_save(httpd_req_t *r)
{
    static char body[BODY_MAX + 1];
    if (r->content_len > BODY_MAX) return reply(r, "Not saved: form too long");
    int got = 0;
    while (got < (int)r->content_len) {
        int k = httpd_req_recv(r, body + got, r->content_len - got);
        if (k <= 0) return reply(r, "Not saved: receive error");
        got += k;
    }
    body[got] = 0;
    char n1[TAG_MAX + 1], n2[TAG_MAX + 1], ssid[33], pass[64], tmp[4];
    int a = form_get(body, "n1", n1, TAG_MAX), b = form_get(body, "n2", n2, TAG_MAX);
    int s = form_get(body, "ssid", ssid, 32), p = form_get(body, "pass", pass, 63);
    bool open = form_get(body, "open", tmp, 3) > 0;
    bool net = form_get(body, "net", tmp, 3) > 0;
    if (a == -2 || b == -2) return reply(r, "Not saved: nametag lines are 12 characters max");
    if (s == -2 || p == -2) return reply(r, "Not saved: SSID 32 / password 63 characters max");
    if (!printable(n1, false) || !printable(n2, false)) return reply(r, "Not saved: nametag uses plain ASCII, no '|'");
    if (!printable(ssid, true) || !printable(pass, true)) return reply(r, "Not saved: Wi-Fi uses plain ASCII");
    if (p > 0 && p < 8) return reply(r, "Not saved: WPA2 password is 8+ characters");
    if (a >= 0 || b >= 0) {
        char line[2 * TAG_MAX + 2];
        int n = snprintf(line, sizeof line, "%s%s%s", n1, n2[0] ? "|" : "", n2);
        if (n > 0 && n1[0]) cr_name_set((const uint8_t *)line, n);
    }
    nvs_handle_t h;
    if (s > 0 && nvs_open("ota", NVS_READWRITE, &h) == ESP_OK) {
        char old[33];
        nv_get_str("ota", "ssid", old, sizeof old);
        nvs_set_str(h, "ssid", ssid);
        if (p > 0) nvs_set_str(h, "pass", pass);
        else if (open || strcmp(old, ssid) != 0) nvs_set_str(h, "pass", ""); // new network, no password given: open
        nvs_set_u8(h, "wifi_off", 0);
        nvs_commit(h);
        nvs_close(h);
    }
    memset(pass, 0, sizeof pass);
    memset(body, 0, sizeof body);
    if (nvs_open("net", NVS_READWRITE, &h) == ESP_OK) {
        nvs_set_u8(h, "on", net);
        nvs_commit(h);
        nvs_close(h);
    }
    printf("settings: saved (name, wifi %s, net %d)\n", s > 0 ? "set" : "kept", net);
    return reply(r, "Saved.");
}

// ---- robots (ROBOTS app) -----------------------------------------------------

static const char k_rhead[] =
    "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
    "<title>Badge robots</title><style>body{font:16px system-ui,sans-serif;max-width:48em;margin:auto;padding:1em}"
    "textarea{width:100%;box-sizing:border-box;height:28em;font:14px ui-monospace,monospace}"
    "select,button{font:inherit;margin:.3em 0}button{background:#b00;color:#fff;border:0;border-radius:8px;"
    "padding:.6em 1.2em}td{padding:.1em .6em}small{color:#666}</style><h2>Robots</h2>"
    "<p><small>Robots in the <a href='https://jkridner.beagleboard.io/crystal-robots/'>crystal-robots</a> language "
    "(same as the website). Saved robots join the ROBOTS app's line-ups; the shell's "
    "<code>robot run</code> picks a battle.</small></p>";

#define ROBOT_BODY_MAX 30000

// The robots page: slot list, then the editor (src[0, n]) for `slot`.
static void robots_page(httpd_req_t *r, int slot, const char *src, int n, const char *msg)
{
    char name[17], line[96];
    httpd_resp_set_type(r, "text/html");
    httpd_resp_set_hdr(r, "Cache-Control", "no-store");
    put(r, k_rhead);
    if (msg && msg[0]) { put(r, "<p><b>"); put_esc(r, msg); put(r, "</b></p>"); }
    put(r, "<table>");
    for (int k = 0; k < cr_robot_slots(); k++) {
        int len = cr_robot_len(k);
        if (len >= 0) cr_robot_name(k, name);
        snprintf(line, sizeof line, "<tr><td>Slot %d<td>", k);
        put(r, line);
        if (len < 0) put(r, "<i>empty</i>");
        else { put_esc(r, name[0] ? name : "(no name)"); snprintf(line, sizeof line, " <small>%d bytes</small>", len); put(r, line); }
        snprintf(line, sizeof line, "<td><a href='/robots?slot=%d'>%s</a>", k, len < 0 ? "write" : "edit");
        put(r, line);
    }
    put(r, "</table><form method=post action=/robots>Slot <select name=slot>");
    for (int k = 0; k < cr_robot_slots(); k++) {
        snprintf(line, sizeof line, "<option value=%d%s>%d</option>", k, k == slot ? " selected" : "", k);
        put(r, line);
    }
    put(r, "</select><textarea name=src spellcheck=false placeholder='main(\"Name\") do&#10;  drive(rand(360), 50)&#10;end'>");
    if (src && n > 0) put_text(r, src, n);
    put(r, "</textarea><button>Check and save</button> <small>An empty editor empties the slot.</small></form>"
           "<p><a href=/>Settings</a></p>");
    put(r, NULL);
}

static esp_err_t h_robots(httpd_req_t *r)
{
    char q[32], v[8];
    int slot = 0;
    if (httpd_req_get_url_query_str(r, q, sizeof q) == ESP_OK && httpd_query_key_value(q, "slot", v, sizeof v) == ESP_OK)
        slot = atoi(v);
    if (slot < 0 || slot >= cr_robot_slots()) slot = 0;
    int max = cr_robot_max();
    uint8_t *src = malloc(max + 1);
    if (!src) return httpd_resp_send_err(r, HTTPD_500_INTERNAL_SERVER_ERROR, "out of memory");
    int n = cr_robot_read(slot, src, max);
    robots_page(r, slot, (const char *)src, n < 0 ? 0 : n, NULL);
    free(src);
    return ESP_OK;
}

static esp_err_t h_robots_save(httpd_req_t *r)
{
    char msg[160], v[8];
    if (r->content_len > ROBOT_BODY_MAX) {
        robots_page(r, 0, NULL, 0, "Not saved: too long");
        return ESP_OK;
    }
    int max = cr_robot_max();
    char *body = malloc(r->content_len + 1);
    char *src = malloc(max + 1);
    if (!body || !src) {
        free(body);
        free(src);
        return httpd_resp_send_err(r, HTTPD_500_INTERNAL_SERVER_ERROR, "out of memory");
    }
    int got = 0;
    while (got < (int)r->content_len) {
        int k = httpd_req_recv(r, body + got, r->content_len - got);
        if (k <= 0) break;
        got += k;
    }
    body[got] = 0;
    int slot = form_get(body, "slot", v, 3) > 0 ? atoi(v) : -1;
    int n = form_get(body, "src", src, max);
    free(body);
    if (slot < 0 || slot >= cr_robot_slots()) slot = 0;
    if (got < (int)r->content_len) snprintf(msg, sizeof msg, "Not saved: receive error");
    else if (n == -2) snprintf(msg, sizeof msg, "Not saved: a robot is %d bytes at most", max);
    else if (n <= 0 || strspn(src, " \t\r\n") == (size_t)n) {
        n = 0;
        snprintf(msg, sizeof msg, cr_robot_write(slot, NULL, 0, NULL) ? "Slot %d emptied." : "Slot %d: flash error", slot);
    } else {
        // the browser sends CRLF; the language takes LF (and ignores CR) either way
        uint8_t m[128];
        if (cr_robot_check((const uint8_t *)src, n, m, sizeof m) != 0)
            snprintf(msg, sizeof msg, "Not saved: %s", (const char *)m);
        else if (cr_robot_write(slot, (const uint8_t *)src, n, (const char *)m))
            snprintf(msg, sizeof msg, "Saved \"%s\" to slot %d.", (const char *)m, slot);
        else
            snprintf(msg, sizeof msg, "Not saved: flash error");
    }
    robots_page(r, slot, src, n < 0 ? 0 : n, msg);
    free(src);
    return ESP_OK;
}

// Phones probe these to detect a captive portal: answer with the page.
static esp_err_t h_any(httpd_req_t *r)
{
    httpd_resp_set_status(r, "302 Found");
    httpd_resp_set_hdr(r, "Location", "http://192.168.4.1/");
    httpd_resp_send(r, NULL, 0);
    return ESP_OK;
}

// 0 ok, 1 radio busy (online update running), 2 AP failed, 3 HTTP server failed.
int32_t cr_settings_start(void)
{
    if (s_http) return 0;
    cr_net_pause();
    uint8_t m[6];
    esp_read_mac(m, ESP_MAC_WIFI_SOFTAP);
    snprintf(s_ssid, sizeof s_ssid, "Badge-%02X%02X", m[4], m[5]);
    static const char abc[] = "abcdefghjkmnpqrstuvwxyz23456789"; // no 0/o, 1/l/i
    for (int i = 0; i < 8; i++) s_pass[i] = abc[esp_random() % (sizeof abc - 1)];
    s_pass[8] = 0;
    s_msg[0] = 0;
    if (!cr_wifi_ap_start(s_ssid, s_pass, AP_CHANNEL)) {
        cr_net_boot();
        return 1;
    }
    httpd_config_t cfg = HTTPD_DEFAULT_CONFIG();
    cfg.stack_size = 12288; // /robots parses and checks robots on this task
    cfg.max_uri_handlers = 6;
    cfg.uri_match_fn = httpd_uri_match_wildcard;
    cfg.lru_purge_enable = true;
    if (httpd_start(&s_http, &cfg) != ESP_OK) {
        s_http = NULL;
        cr_wifi_ap_stop();
        cr_net_boot();
        return 3;
    }
    httpd_uri_t u_root = {.uri = "/", .method = HTTP_GET, .handler = h_root};
    httpd_uri_t u_save = {.uri = "/save", .method = HTTP_POST, .handler = h_save};
    httpd_uri_t u_any = {.uri = "/*", .method = HTTP_GET, .handler = h_any};
    httpd_uri_t u_robots = {.uri = "/robots", .method = HTTP_GET, .handler = h_robots};
    httpd_uri_t u_robots_save = {.uri = "/robots", .method = HTTP_POST, .handler = h_robots_save};
    httpd_register_uri_handler(s_http, &u_root);
    httpd_register_uri_handler(s_http, &u_save);
    httpd_register_uri_handler(s_http, &u_robots);
    httpd_register_uri_handler(s_http, &u_robots_save);
    httpd_register_uri_handler(s_http, &u_any);
    printf("settings: AP %s up, http://192.168.4.1/\n", s_ssid);
    return 0;
}

void cr_settings_stop(void)
{
    if (!s_http) return;
    httpd_stop(s_http);
    s_http = NULL;
    cr_wifi_ap_stop();
    memset(s_pass, 0, sizeof s_pass);
    printf("settings: AP down\n");
    cr_net_boot(); // network mode back as saved (maybe just changed)
}

int32_t cr_qr_encode(const uint8_t *text, int32_t len, uint8_t *out); // main/qr.c

// QR modules (size * size, 1 = dark) for the join code (which = 0:
// "WIFI:T:WPA;S:<ssid>;P:<pass>;;") or the page URL (which = 1).
int32_t cr_settings_qr(int32_t which, uint8_t *out)
{
    char t[96];
    if (which == 0) snprintf(t, sizeof t, "WIFI:T:WPA;S:%s;P:%s;;", s_ssid, s_pass);
    else snprintf(t, sizeof t, "http://192.168.4.1/");
    return cr_qr_encode((const uint8_t *)t, (int32_t)strlen(t), out);
}
