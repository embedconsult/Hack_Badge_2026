// Host test: radar distance model, smoothing, map fit, screen (main/radar.c).
#include <string.h>
#include <math.h>
#include "host.h"
#include "../../main/radar.h"
#include "../../main/apps_gfx.h"

static uint8_t plane[G_PLANE];
static radar_t R;

static int8_t rssi_for(float m) { return (int8_t)lroundf(RADAR_RSSI_1M - 10 * RADAR_N * log10f(m)); }

// badges at (x, y) metres, badge 0 = me; every badge hears every other
static int make(radar_peer_t *pe, int nb, const float (*pos)[2], float noise, unsigned *seed)
{
    for (int i = 1; i < nb; i++) {
        radar_peer_t *p = &pe[i - 1];
        memset(p, 0, sizeof *p);
        p->mac[0] = 0x24, p->mac[5] = (uint8_t)(0x10 + i);
        snprintf(p->name, sizeof p->name, "BADGE%d", i & 7);
        p->kind = 2;
        p->cm = -1;
        float d = hypotf(pos[i][0] - pos[0][0], pos[i][1] - pos[0][1]);
        *seed = *seed * 1103515245 + 12345;
        p->rssi = rssi_for(d) + (int)((*seed >> 16) % 100 / 100.0f * 2 * noise - noise);
        p->their = rssi_for(d);
        for (int j = 1; j < nb; j++) {
            if (j == i) continue;
            radar_heard_t *h = &p->h[p->nh++];
            memset(h->mac, 0, 6);
            h->mac[0] = 0x24, h->mac[5] = (uint8_t)(0x10 + j);
            h->rssi = rssi_for(hypotf(pos[i][0] - pos[j][0], pos[i][1] - pos[j][1]));
            h->cm = -1;
        }
        // and me, as the others hear me
        radar_heard_t *h = &p->h[p->nh++];
        h->mac[0] = 0x24, h->mac[5] = 0x10;
        h->rssi = rssi_for(d);
        h->cm = -1;
    }
    return nb - 1;
}

static float fit_error(const float (*pos)[2], int nb)
{
    float worst = 0;
    for (int i = 0; i < R.nn; i++)
        for (int j = i + 1; j < R.nn; j++) {
            int a = i ? R.n[i].mac[5] - 0x10 : 0, b = j ? R.n[j].mac[5] - 0x10 : 0;
            float want = hypotf(pos[a][0] - pos[b][0], pos[a][1] - pos[b][1]);
            float got = hypotf(R.n[i].x - R.n[j].x, R.n[i].y - R.n[j].y);
            worst = fmaxf(worst, fabsf(got - want));
        }
    return worst;
}

int main(void)
{
    uint8_t me[6] = {0x24, 0, 0, 0, 0, 0x10};
    radar_peer_t pe[RADAR_PEERS];
    unsigned seed = 1;
    // model round trip
    CHECK(fabsf(radar_metres(-45) - 1) < 0.01f && fabsf(radar_metres(-70) - 10) < 0.1f);
    // off
    radar_init(&R, me, "Jason");
    radar_draw(&R, plane);
    write_pbm("out/radar_off.pbm", plane);
    R.net_on = true;
    // one badge: list only
    const float one[][2] = {{0, 0}, {2, 0}};
    int n = make(pe, 2, one, 0, &seed);
    radar_update(&R, pe, n, 1000);
    CHECK(R.np == 1 && fabsf(R.p[0].m - 2) < 0.2f && R.nn == 2);
    radar_draw(&R, plane);
    write_pbm("out/radar_one.pbm", plane);
    // five badges, exact RSSI: the map matches up to rotation/mirror
    radar_init(&R, me, "Jason");
    R.net_on = true;
    const float five[][2] = {{0, 0}, {3, 0}, {0, 4}, {-2, -2}, {5, 5}, {1.5f, -4}};
    for (int t = 0; t < 5; t++) {
        n = make(pe, 6, five, 0, &seed);
        radar_update(&R, pe, n, 2000 + t * 1000);
    }
    printf("radar: %d nodes, stress %.3f, worst error %.2f m\n", R.nn, radar_stress(&R), fit_error(five, 6));
    CHECK(R.nn == 6 && !R.partial);
    CHECK(fit_error(five, 6) < 0.6f); // RSSI is rounded to whole dB
    for (int i = 1; i < R.np; i++) CHECK(R.p[i - 1].m <= R.p[i].m);
    uint32_t sig = radar_signature(&R);
    n = make(pe, 6, five, 0, &seed);
    radar_update(&R, pe, n, 8000);
    CHECK(radar_signature(&R) == sig); // steady: same input, same screen
    radar_draw(&R, plane);
    write_pbm("out/radar_map.pbm", plane);
    // noisy RSSI (+-4 dB on my side): smoothing keeps it sane, layout stays put
    float x1 = R.n[1].x, y1 = R.n[1].y;
    for (int t = 0; t < 20; t++) {
        n = make(pe, 6, five, 4, &seed);
        radar_update(&R, pe, n, 9000 + t * 1000);
    }
    printf("radar noisy: worst error %.2f m, badge 1 moved %.2f m\n", fit_error(five, 6), hypotf(R.n[1].x - x1, R.n[1].y - y1));
    CHECK(fit_error(five, 6) < 3.0f);
    // badge-to-badge unknown (no heard lists): partial, still drawn
    radar_init(&R, me, "");
    R.net_on = true;
    n = make(pe, 4, five, 0, &seed);
    for (int i = 0; i < n; i++) pe[i].nh = 0;
    radar_update(&R, pe, n, 1000);
    CHECK(R.nn == 4 && R.partial);
    radar_draw(&R, plane);
    write_pbm("out/radar_partial.pbm", plane);
    printf(s_fail ? "radar: %d FAILED\n" : "radar: ok\n", s_fail);
    return s_fail != 0;
}
