// Weather model: see weather.h.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <math.h>
#include "cJSON.h"
#include "weather.h"
#include "apps_gfx.h"

void wx_default(wx_cfg_t *c)
{
    memset(c, 0, sizeof *c);
    snprintf(c->lat, sizeof c->lat, "34.1478");
    snprintf(c->lon, sizeof c->lon, "-118.1445");
    snprintf(c->place, sizeof c->place, "Pasadena, CA");
    c->imperial = true;
}

int wx_url(const wx_cfg_t *c, char *buf, int n)
{
    return snprintf(buf, n,
        "https://api.open-meteo.com/v1/forecast?latitude=%s&longitude=%s&timezone=auto&forecast_days=%d"
        "&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,"
        "wind_direction_10m,is_day"
        "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max%s",
        c->lat, c->lon, WX_DAYS, c->imperial ? "&temperature_unit=fahrenheit&wind_speed_unit=mph" : "");
}

int wx_geo_url(const char *city, char *buf, int n)
{
    int k = snprintf(buf, n, "https://geocoding-api.open-meteo.com/v1/search?count=1&language=en&name=");
    for (const unsigned char *s = (const unsigned char *)city; *s && k < n - 4; s++)
        k += isalnum(*s) || strchr("-_.~", *s) ? snprintf(buf + k, n - k, "%c", *s) : snprintf(buf + k, n - k, "%%%02X", *s);
    return k;
}

static double num(const cJSON *o, const char *k, double dflt)
{
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, k);
    return cJSON_IsNumber(v) ? v->valuedouble : dflt;
}

static bool arr(const cJSON *o, const char *k, int *out)
{
    const cJSON *a = cJSON_GetObjectItemCaseSensitive(o, k);
    if (!cJSON_IsArray(a)) return false;
    for (int i = 0; i < WX_DAYS; i++) {
        const cJSON *v = cJSON_GetArrayItem(a, i);
        out[i] = cJSON_IsNumber(v) ? (int)lround(v->valuedouble) : -999;
    }
    return true;
}

bool wx_parse(const char *json, wx_t *w)
{
    memset(w, 0, sizeof *w);
    cJSON *r = cJSON_Parse(json);
    if (!r) return false;
    const cJSON *cur = cJSON_GetObjectItemCaseSensitive(r, "current");
    const cJSON *day = cJSON_GetObjectItemCaseSensitive(r, "daily");
    bool ok = cJSON_IsObject(cur) && cJSON_IsObject(day);
    if (ok) {
        w->temp = (float)num(cur, "temperature_2m", NAN);
        w->feels = (float)num(cur, "apparent_temperature", NAN);
        w->wind = (float)num(cur, "wind_speed_10m", NAN);
        w->rh = (int)num(cur, "relative_humidity_2m", -1);
        w->code = (int)num(cur, "weather_code", -1);
        w->wdir = (int)num(cur, "wind_direction_10m", -1);
        w->is_day = (int)num(cur, "is_day", 1);
        const cJSON *t = cJSON_GetObjectItemCaseSensitive(cur, "time");
        if (cJSON_IsString(t)) snprintf(w->time, sizeof w->time, "%s", t->valuestring);
        ok = !isnan(w->temp) && w->code >= 0 && arr(day, "weather_code", w->dcode) &&
             arr(day, "temperature_2m_max", w->hi) && arr(day, "temperature_2m_min", w->lo);
        if (!arr(day, "precipitation_probability_max", w->pop))
            for (int i = 0; i < WX_DAYS; i++) w->pop[i] = -999;
        const cJSON *ts = cJSON_GetObjectItemCaseSensitive(day, "time");
        for (int i = 0; i < WX_DAYS; i++) {
            const cJSON *v = cJSON_GetArrayItem(ts, i);
            if (cJSON_IsString(v)) snprintf(w->day[i], sizeof w->day[i], "%s", v->valuestring);
        }
        const cJSON *tz = cJSON_GetObjectItemCaseSensitive(r, "timezone_abbreviation");
        if (cJSON_IsString(tz)) snprintf(w->tz, sizeof w->tz, "%s", tz->valuestring);
    }
    cJSON_Delete(r);
    w->ok = ok;
    return ok;
}

bool wx_parse_geo(const char *json, wx_cfg_t *c)
{
    cJSON *r = cJSON_Parse(json);
    if (!r) return false;
    const cJSON *res = cJSON_GetArrayItem(cJSON_GetObjectItemCaseSensitive(r, "results"), 0);
    double la = num(res, "latitude", NAN), lo = num(res, "longitude", NAN);
    bool ok = res && !isnan(la) && !isnan(lo);
    if (ok) {
        snprintf(c->lat, sizeof c->lat, "%.4f", la);
        snprintf(c->lon, sizeof c->lon, "%.4f", lo);
        const cJSON *nm = cJSON_GetObjectItemCaseSensitive(res, "name");
        const cJSON *cc = cJSON_GetObjectItemCaseSensitive(res, "country_code");
        snprintf(c->place, sizeof c->place, "%.36s%s%.4s", cJSON_IsString(nm) ? nm->valuestring : c->city,
                 cJSON_IsString(cc) ? ", " : "", cJSON_IsString(cc) ? cc->valuestring : "");
        c->city[0] = 0;
    }
    cJSON_Delete(r);
    return ok;
}

const char *wx_words(int c)
{
    static const struct { int c; const char *s; } w[] = {
        {0, "Clear"}, {1, "Mainly clear"}, {2, "Partly cloudy"}, {3, "Overcast"}, {48, "Fog"}, {55, "Drizzle"},
        {57, "Freezing drizzle"}, {65, "Rain"}, {67, "Freezing rain"}, {77, "Snow"}, {82, "Showers"},
        {86, "Snow showers"}, {99, "Thunderstorm"}};
    for (unsigned i = 0; i < sizeof w / sizeof *w; i++)
        if (c <= w[i].c) return w[i].s;
    return "?";
}

static bool is_coord(const char *s, double lim)
{
    char *e;
    double v = strtod(s, &e);
    return e != s && !*e && v >= -lim && v <= lim;
}

int wx_cmd(const char *args, wx_cfg_t *c, char *msg, int n)
{
    char a[4][48] = {{0}};
    const char *rest = NULL;
    int k = 0;
    for (const char *s = args; *s && k < 4;) {
        while (*s == ' ') s++;
        if (!*s) break;
        if (k == 1 && !strncmp(a[0], "place", 6)) rest = s;
        int l = (int)strcspn(s, " ");
        snprintf(a[k++], sizeof a[0], "%.*s", l < 47 ? l : 47, s);
        s += l;
    }
    if (k == 0) {
        snprintf(msg, n, "weather: %s (%s, %s), %s\n", c->place[0] ? c->place : "?", c->lat[0] ? c->lat : "-",
                 c->lon[0] ? c->lon : "-", c->imperial ? "F, mph" : "C, km/h");
        return 0;
    }
    if (!strcmp(a[0], "units") && k == 2) {
        bool f = a[1][0] == 'f' || a[1][0] == 'F' || a[1][0] == 'i';
        bool m = a[1][0] == 'c' || a[1][0] == 'C' || a[1][0] == 'm';
        if (!f && !m) return snprintf(msg, n, "weather units <c|f>\n"), -1;
        c->imperial = f;
        snprintf(msg, n, "weather: units %s\n", f ? "F, mph" : "C, km/h");
        return 1;
    }
    if (!strcmp(a[0], "place") && rest && *rest) {
        snprintf(c->city, sizeof c->city, "%.47s", rest);
        int l = (int)strlen(c->city);
        while (l && c->city[l - 1] == ' ') c->city[--l] = 0;
        c->lat[0] = c->lon[0] = 0;
        snprintf(c->place, sizeof c->place, "%s", c->city);
        snprintf(msg, n, "weather: place \"%s\" (looked up on the next update)\n", c->city);
        return 1;
    }
    if (k >= 2 && is_coord(a[0], 90) && is_coord(a[1], 180)) {
        snprintf(c->lat, sizeof c->lat, "%.15s", a[0]);
        snprintf(c->lon, sizeof c->lon, "%.15s", a[1]);
        c->city[0] = 0;
        int i = 2;
        if (k > 2 && (!strcmp(a[2], "c") || !strcmp(a[2], "C") || !strcmp(a[2], "metric"))) c->imperial = false, i++;
        else if (k > 2 && (!strcmp(a[2], "f") || !strcmp(a[2], "F") || !strcmp(a[2], "imperial"))) c->imperial = true, i++;
        // the rest of the line names the place
        const char *s = args;
        for (int j = 0; j < i && s; j++) {
            while (*s == ' ') s++;
            s += strcspn(s, " ");
        }
        while (s && *s == ' ') s++;
        snprintf(c->place, sizeof c->place, "%s", s && *s ? s : "");
        if (!c->place[0]) snprintf(c->place, sizeof c->place, "%s, %s", c->lat, c->lon);
        snprintf(msg, n, "weather: %s (%s, %s), %s\n", c->place, c->lat, c->lon, c->imperial ? "F, mph" : "C, km/h");
        return 1;
    }
    snprintf(msg, n, "weather <lat> <lon> [c|f] [name] | weather place <city> | weather units <c|f> | weather\n");
    return -1;
}

// ---- screen --------------------------------------------------------------------

enum { SUN, FEW, CLOUD, FOG, DRIZZLE, RAIN, SNOW, STORM };

static int kind(int c)
{
    return c == 0 ? SUN : c <= 2 ? FEW : c == 3 ? CLOUD : c < 50 ? FOG : c < 60 ? DRIZZLE
        : (c >= 71 && c <= 77) || c == 85 || c == 86 ? SNOW : c >= 95 ? STORM : RAIN;
}

// Cloud in a w x h box at x, y (s = w / 100): white body, black outline.
static void cloud(uint8_t *p, int x, int y, int s100, int t)
{
#define S(v) ((v) * s100 / 100)
    int cx[] = {S(30), S(52), S(74)}, cy[] = {S(40), S(28), S(42)}, r[] = {S(20), S(26), S(18)};
    for (int i = 0; i < 3; i++) g_disc(p, x + cx[i], y + cy[i], r[i] + t, true);
    g_rect(p, x + S(10) - t, y + S(40), S(80) + 2 * t, S(20) + t, true);
    for (int i = 0; i < 3; i++) g_disc(p, x + cx[i], y + cy[i], r[i], false);
    g_rect(p, x + S(10), y + S(40), S(80), S(20), false);
#undef S
}

static void sun(uint8_t *p, int cx, int cy, int r, int t)
{
    g_disc(p, cx, cy, r, true);
    for (int a = 0; a < 8; a++) {
        float an = a * 3.14159265f / 4;
        g_line(p, cx + (int)((r + r / 3) * cosf(an)), cy + (int)((r + r / 3) * sinf(an)),
               cx + (int)((r + r * 3 / 4) * cosf(an)), cy + (int)((r + r * 3 / 4) * sinf(an)), t);
    }
}

// Weather icon in a size x size square (size ~ 80..220).
static void icon(uint8_t *p, int x, int y, int size, int code, bool day)
{
    int k = kind(code), t = size >= 150 ? 6 : 3;
    if (k == SUN) {
        if (day) sun(p, x + size / 2, y + size / 2, size / 5, t);
        else { g_disc(p, x + size / 2, y + size / 2, size / 4, true); g_disc(p, x + size / 2 + size / 8, y + size / 2 - size / 10, size / 4, false); }
        return;
    }
    if (k == FEW) sun(p, x + size * 2 / 3, y + size / 3, size / 7, t > 3 ? 4 : 2);
    if (k == FOG) {
        for (int i = 0; i < 4; i++) g_rect(p, x + size / 8 + (i & 1) * size / 10, y + size / 4 + i * size / 7, size * 3 / 4 - size / 10, t + 1, true);
        return;
    }
    int cy = k == FEW ? y + size / 4 : y + size / 8;
    cloud(p, x, cy, size, t);
    int by = cy + size * 66 / 100;
    if (k == DRIZZLE || k == RAIN)
        for (int i = 0; i < (k == RAIN ? 4 : 3); i++) {
            int lx = x + size / 4 + i * size / 6;
            g_line(p, lx, by, lx - size / 14, by + (k == RAIN ? size / 5 : size / 9), t);
        }
    if (k == SNOW)
        for (int i = 0; i < 3; i++) {
            int sx = x + size / 4 + i * size / 4, sy = by + size / 10, r = size / 14;
            g_line(p, sx - r, sy, sx + r, sy, t > 3 ? 3 : 2);
            g_line(p, sx - r / 2, sy - r, sx + r / 2, sy + r, t > 3 ? 3 : 2);
            g_line(p, sx + r / 2, sy - r, sx - r / 2, sy + r, t > 3 ? 3 : 2);
        }
    if (k == STORM) {
        int bx = x + size / 2;
        g_line(p, bx, by - size / 20, bx - size / 10, by + size / 8, t);
        g_line(p, bx - size / 10, by + size / 8, bx + size / 20, by + size / 8, t);
        g_line(p, bx + size / 20, by + size / 8, bx - size / 20, by + size / 4, t);
    }
}

// Number with a degree ring; returns x after it.
static int degrees(uint8_t *p, int x, int y, int scale, int v)
{
    char s[12];
    snprintf(s, sizeof s, "%d", v);
    x = g_text(p, x, y, scale, s, true);
    int r = scale * 2 > 3 ? scale * 2 : 3;
    g_ring(p, x + r, y + r, r, scale > 2 ? scale / 2 + 1 : 2);
    return x + 2 * r + scale * 2;
}

static const char *weekday(const char *d) // "YYYY-MM-DD" (Sakamoto)
{
    static const char *n[] = {"SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"};
    static const int t[] = {0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4};
    int y = atoi(d), m = atoi(d + 5), dd = atoi(d + 8);
    if (m < 1 || m > 12) return "?";
    y -= m < 3;
    return n[(y + y / 4 - y / 100 + y / 400 + t[m - 1] + dd) % 7];
}

static const char *compass(int deg)
{
    static const char *c[] = {"N", "NE", "E", "SE", "S", "SW", "W", "NW"};
    return deg < 0 ? "" : c[((deg * 2 + 45) / 90) % 8];
}

void wx_draw(const wx_t *w, const wx_cfg_t *c, const char *status, uint8_t *p)
{
    char s[96];
    g_clear(p);
    g_text(p, 24, G_BAR + 12, 4, c->place[0] ? c->place : "?", true);
    if (!w->ok) {
        g_wrap(p, 48, G_BAR + 160, G_W - 96, 4, 44, 4, status && *status ? status : "No weather yet.", true);
        g_hint(p, "A: UPDATE   B: C/F", c->imperial ? "F, MPH" : "C, KM/H");
        return;
    }
    // now: icon, temperature, words, details
    int y0 = G_BAR + 56;
    icon(p, 24, y0, 210, w->code, w->is_day);
    int x = degrees(p, 270, y0 + 10, 14, (int)lroundf(w->temp));
    g_text(p, x + 4, y0 + 10, 7, c->imperial ? "F" : "C", true);
    g_text(p, 270, y0 + 124, 4, wx_words(w->code), true);
    int fl = isnan(w->feels) ? (int)lroundf(w->temp) : (int)lroundf(w->feels);
    x = g_text(p, 270, y0 + 172, 3, "FEELS ", true);
    x = degrees(p, x, y0 + 172, 3, fl);
    snprintf(s, sizeof s, " HUMIDITY %d%%", w->rh);
    g_text(p, x, y0 + 172, 3, s, true);
    snprintf(s, sizeof s, "WIND %d %s %s   HIGH", (int)lroundf(w->wind), c->imperial ? "MPH" : "KM/H", compass(w->wdir));
    x = g_text(p, 270, y0 + 206, 3, s, true);
    x = degrees(p, x + 18, y0 + 206, 3, w->hi[0]);
    x = g_text(p, x, y0 + 206, 3, " LOW", true);
    degrees(p, x + 18, y0 + 206, 3, w->lo[0]);
    // the next five days
    int top = G_BAR + 312, cw = G_W / 5;
    g_rect(p, 0, top - 14, G_W, 2, true);
    for (int i = 1; i < WX_DAYS; i++) {
        int cx = (i - 1) * cw;
        if (i > 1) g_rect(p, cx, top, 2, 270, true);
        const char *wd = w->day[i][0] ? weekday(w->day[i]) : "?";
        g_text(p, cx + (cw - g_text_w(3, (int)strlen(wd))) / 2, top + 6, 3, wd, true);
        icon(p, cx + (cw - 110) / 2, top + 40, 110, w->dcode[i], true);
        int hx = cx + 26;
        hx = degrees(p, hx, top + 168, 3, w->hi[i]);
        g_text(p, hx, top + 168, 3, "/", true);
        degrees(p, hx + 18, top + 168, 3, w->lo[i]);
        if (w->pop[i] > -999) {
            snprintf(s, sizeof s, "RAIN %d%%", w->pop[i]);
            g_text(p, cx + (cw - g_text_w(2, (int)strlen(s))) / 2, top + 208, 2, s, true);
        }
    }
    // "2026-11-07T00:00" -> "UPDATED 00:00"
    snprintf(s, sizeof s, "%s%s%s%s", status && *status ? status : "UPDATED ", status && *status ? "" : w->time[0] ? w->time + 11 : "?",
             w->tz[0] && !(status && *status) ? " " : "", status && *status ? "" : w->tz);
    g_hint(p, "A: UPDATE   B: C/F", s);
}
