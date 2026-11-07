// Host test: Open-Meteo reply, geocoding, shell command, screen (main/weather.c).
#include <string.h>
#include <math.h>
#include "host.h"
#include "../../main/weather.h"
#include "../../main/apps_gfx.h"

static uint8_t plane[G_PLANE];

int main(void)
{
    int n;
    char *js = slurp("fixtures/wx.json", &n);
    wx_t w;
    wx_cfg_t c;
    wx_default(&c);
    CHECK(wx_parse(js, &w));
    CHECK(fabsf(w.temp - 18.0f) < 0.01f && w.code == 0 && w.rh == 29 && w.wdir == 11);
    CHECK(w.hi[1] == 32 && w.lo[2] == 22 && w.dcode[2] == 3 && w.pop[5] == 9);
    CHECK(!strcmp(w.day[0], "2026-11-07") && !strcmp(w.time, "2026-11-07T00:00"));
    CHECK(!wx_parse("{\"current\":{}}", &w) && !wx_parse("garbage", &w));
    char url[512], msg[160];
    wx_url(&c, url, sizeof url);
    printf("%s\n", url);
    CHECK(strstr(url, "latitude=34.1478&longitude=-118.1445") && strstr(url, "fahrenheit"));
    wx_geo_url("San José, CA", url, sizeof url);
    printf("%s\n", url);
    CHECK(strstr(url, "name=San%20Jos%C3%A9%2C%20CA"));
    CHECK(wx_parse_geo("{\"results\":[{\"name\":\"Istanbul\",\"latitude\":41.01384,\"longitude\":28.94966,\"country_code\":\"TR\"}]}", &c));
    CHECK(!strcmp(c.lat, "41.0138") && !strcmp(c.place, "Istanbul, TR"));
    CHECK(!wx_parse_geo("{\"generationtime_ms\":0.1}", &c));
    // shell
    CHECK(wx_cmd("52.52 13.405 c Berlin Mitte", &c, msg, sizeof msg) == 1);
    printf("%s", msg);
    CHECK(!strcmp(c.lat, "52.52") && !strcmp(c.lon, "13.405") && !c.imperial && !strcmp(c.place, "Berlin Mitte"));
    CHECK(wx_cmd("units f", &c, msg, sizeof msg) == 1 && c.imperial);
    CHECK(wx_cmd("1.5 200", &c, msg, sizeof msg) == -1);
    CHECK(wx_cmd("place  New York ", &c, msg, sizeof msg) == 1 && !strcmp(c.city, "New York") && !c.lat[0]);
    CHECK(wx_cmd("", &c, msg, sizeof msg) == 0);
    CHECK(wx_cmd("-33.86 151.21", &c, msg, sizeof msg) == 1 && !strcmp(c.place, "-33.86, 151.21") && c.imperial);
    // screens: all codes render
    wx_default(&c);
    wx_parse(js, &w);
    wx_draw(&w, &c, "", plane);
    write_pbm("out/weather.pbm", plane);
    int codes[] = {2, 45, 53, 63, 73, 95};
    for (int i = 0; i < 6; i++) w.dcode[i] = codes[i];
    w.code = 61;
    c.imperial = false;
    wx_draw(&w, &c, "UPDATING...", plane);
    write_pbm("out/weather_codes.pbm", plane);
    w.ok = false;
    wx_draw(&w, &c, "Could not join the Wi-Fi.", plane);
    write_pbm("out/weather_error.pbm", plane);
    printf(s_fail ? "weather: %d FAILED\n" : "weather: ok\n", s_fail);
    return s_fail != 0;
}
