// Weather app model (src/apps/weather.cr, glue in main/apps_net.c): the
// Open-Meteo request, its JSON reply (cJSON), place / units settings and the
// screen. Pure C apart from cJSON: test/apps/ runs it on the host.
//
// After yigitabi5444's badge os Weather (main/app_weather.c): Open-Meteo
// current + daily forecast, geocoding for a typed place. Our own code.
#pragma once
#include <stdint.h>
#include <stdbool.h>

#define WX_DAYS 6

typedef struct {
    char lat[16], lon[16]; // decimal degrees as text ("" = not set)
    char place[48];        // shown name
    char city[48];         // to look up (geocoding) when lat/lon are not set
    bool imperial;         // F + mph, else C + km/h
} wx_cfg_t;

typedef struct {
    bool ok;
    float temp, feels, wind;
    int rh, code, wdir, is_day;
    char time[20];         // "2026-11-07T00:00", the place's local time
    int dcode[WX_DAYS], hi[WX_DAYS], lo[WX_DAYS], pop[WX_DAYS];
    char day[WX_DAYS][11]; // "2026-11-07"
    char tz[12];
} wx_t;

void wx_default(wx_cfg_t *c);   // Pasadena (Supercon), imperial
int wx_url(const wx_cfg_t *c, char *buf, int n);
int wx_geo_url(const char *city, char *buf, int n);
bool wx_parse(const char *json, wx_t *w);
bool wx_parse_geo(const char *json, wx_cfg_t *c);   // fills lat, lon, place
const char *wx_words(int code);
// Shell `weather ...` (the words after "weather"): updates c. Returns 1 if
// c changed (save it), 0 if not, -1 on bad syntax; msg = what to print.
int wx_cmd(const char *args, wx_cfg_t *c, char *msg, int n);
// Screen below the top bar. status: "" or what is going on / went wrong.
void wx_draw(const wx_t *w, const wx_cfg_t *c, const char *status, uint8_t *plane);
