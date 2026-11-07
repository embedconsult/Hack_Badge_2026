// Radar model: see radar.h. Pure C.
#include <stdio.h>
#include <string.h>
#include <math.h>
#include "radar.h"
#include "apps_gfx.h"

float radar_metres(float db) { return powf(10.0f, (RADAR_RSSI_1M - db) / (10.0f * RADAR_N)); }

void radar_init(radar_t *r, const uint8_t me[6], const char *my_name)
{
    memset(r, 0, sizeof *r);
    memcpy(r->me, me, 6);
    snprintf(r->my_name, sizeof r->my_name, "%s", my_name ? my_name : "");
}

static bool zero(const uint8_t *m) { return !m[0] && !m[1] && !m[2] && !m[3] && !m[4] && !m[5]; }

static radar_edge_t *edge(radar_t *r, const uint8_t *a, const uint8_t *b, bool add)
{
    if (!memcmp(a, b, 6)) return NULL;
    if (memcmp(a, b, 6) > 0) { const uint8_t *t = a; a = b; b = t; }
    int old = 0;
    for (int i = 0; i < r->ne; i++) {
        if (!memcmp(r->e[i].a, a, 6) && !memcmp(r->e[i].b, b, 6)) return &r->e[i];
        if (r->e[i].seen < r->e[old].seen) old = i;
    }
    if (!add) return NULL;
    radar_edge_t *e = r->ne < RADAR_EDGES ? &r->e[r->ne++] : &r->e[old];
    memset(e, 0, sizeof *e);
    memcpy(e->a, a, 6);
    memcpy(e->b, b, 6);
    e->db = NAN;
    e->cm = -1;
    return e;
}

// One RSSI (and/or FTM) sample for the link a-b.
static void sample(radar_t *r, const uint8_t *a, const uint8_t *b, float db, int cm)
{
    if (zero(a) || zero(b)) return;
    bool have_db = !isnan(db) && db < 0 && db > -110;
    if (!have_db && cm < 0) return;
    radar_edge_t *e = edge(r, a, b, true);
    if (!e) return;
    if (have_db) {
        bool fresh = isnan(e->db) || r->now - e->seen > RADAR_FORGET_MS;
        e->db = fresh ? db : e->db + RADAR_ALPHA * (db - e->db);
    }
    if (cm >= 0) e->cm = (int16_t)cm;
    e->seen = r->now;
}

// Metres between a and b, -1 unknown. FTM wins over RSSI.
static float dist(const radar_t *r, const uint8_t *a, const uint8_t *b)
{
    radar_edge_t *e = edge((radar_t *)r, a, b, false);
    if (!e || r->now - e->seen > RADAR_FORGET_MS) return -1;
    if (e->cm >= 0) return e->cm / 100.0f;
    return isnan(e->db) ? -1 : radar_metres(e->db);
}

float radar_stress(const radar_t *r)
{
    float s = 0;
    for (int i = 0; i < r->nn; i++)
        for (int j = i + 1; j < r->nn; j++)
            if (r->d[i][j] >= 0) {
                float e = hypotf(r->n[i].x - r->n[j].x, r->n[i].y - r->n[j].y) - r->d[i][j];
                s += e * e;
            }
    return s;
}

// Majorization: each badge (not me, pinned at 0, 0) moves to the mean of
// where each of its known distances alone would put it.
static void relax(radar_node_t *n, int nn, float d[RADAR_NODES][RADAR_NODES], int iters)
{
    for (int it = 0; it < iters; it++)
        for (int i = 1; i < nn; i++) {
            float sx = 0, sy = 0;
            int k = 0;
            for (int j = 0; j < nn; j++) {
                if (j == i || d[i][j] < 0) continue;
                float dx = n[i].x - n[j].x, dy = n[i].y - n[j].y, l = hypotf(dx, dy);
                if (l < 1e-3f) dx = 0.01f * (i - j), dy = 0.013f * (i + 1), l = hypotf(dx, dy);
                sx += n[j].x + d[i][j] * dx / l;
                sy += n[j].y + d[i][j] * dy / l;
                k++;
            }
            if (k) n[i].x = sx / k, n[i].y = sy / k;
        }
}

static float mac_angle(const uint8_t *m) { return (m[5] * 256 + m[4]) * 6.2831853f / 65536; }

// Fresh start: the first badge on +x, the second by trilateration, the
// others from the two nearest placed ones (or on their ring).
static void fresh(radar_t *r, radar_node_t *n)
{
    memcpy(n, r->n, sizeof r->n);
    for (int i = 1; i < r->nn; i++) {
        float d0 = r->d[0][i];
        n[i].x = d0 * cosf(mac_angle(n[i].mac));
        n[i].y = d0 * sinf(mac_angle(n[i].mac));
        if (i == 1) n[i].x = d0, n[i].y = 0;
        else if (r->d[1][i] >= 0 && r->d[0][1] > 0) {
            float a = r->d[0][1], x = (d0 * d0 + a * a - r->d[1][i] * r->d[1][i]) / (2 * a);
            float y2 = d0 * d0 - x * x;
            n[i].x = x;
            n[i].y = y2 > 0 ? sqrtf(y2) : 0;
            // the third and later: the side that fits badge 2 better
            if (i > 2 && r->d[2][i] >= 0) {
                float e1 = fabsf(hypotf(x - n[2].x, n[i].y - n[2].y) - r->d[2][i]);
                float e2 = fabsf(hypotf(x - n[2].x, -n[i].y - n[2].y) - r->d[2][i]);
                if (e2 < e1) n[i].y = -n[i].y;
            }
        }
    }
}

// Rotate/mirror about me (origin) to best match the previous layout (2-D
// Procrustes over the badges placed both times), or a canonical pose: the
// lowest-MAC badge straight up, the next one to its right.
static void orient(radar_t *r, const radar_node_t *old)
{
    float a[2] = {0, 0}, b[2] = {0, 0};
    int common = 0;
    for (int i = 1; i < r->nn; i++)
        for (int j = 1; j < RADAR_NODES; j++)
            if (old[j].placed && !memcmp(r->n[i].mac, old[j].mac, 6)) {
                for (int m = 0; m < 2; m++) {
                    float x = r->n[i].x, y = m ? -r->n[i].y : r->n[i].y;
                    a[m] += x * old[j].x + y * old[j].y;
                    b[m] += x * old[j].y - y * old[j].x;
                }
                common++;
            }
    if (common >= 2) {
        int m = hypotf(a[1], b[1]) > hypotf(a[0], b[0]) * 1.05f;
        float th = atan2f(b[m], a[m]), c = cosf(th), sn = sinf(th);
        for (int i = 1; i < r->nn; i++) {
            float x = r->n[i].x, y = m ? -r->n[i].y : r->n[i].y;
            r->n[i].x = x * c - y * sn;
            r->n[i].y = x * sn + y * c;
        }
        return;
    }
    int lo = 1, lo2 = -1;
    for (int i = 2; i < r->nn; i++) if (memcmp(r->n[i].mac, r->n[lo].mac, 6) < 0) lo = i;
    for (int i = 1; i < r->nn; i++)
        if (i != lo && (lo2 < 0 || memcmp(r->n[i].mac, r->n[lo2].mac, 6) < 0)) lo2 = i;
    float th = -1.5707963f - atan2f(r->n[lo].y, r->n[lo].x), c = cosf(th), sn = sinf(th); // screen "up" = -y
    for (int i = 1; i < r->nn; i++) {
        float x = r->n[i].x, y = r->n[i].y;
        r->n[i].x = x * c - y * sn;
        r->n[i].y = x * sn + y * c;
    }
    if (lo2 > 0 && r->n[lo2].x < 0)
        for (int i = 1; i < r->nn; i++) r->n[i].x = -r->n[i].x;
}

void radar_fit(radar_t *r)
{
    radar_node_t old[RADAR_NODES], keep[RADAR_NODES], a[RADAR_NODES];
    memcpy(old, r->n, sizeof old); // positions carried over by radar_update (placed)
    fresh(r, a);
    for (int i = 1; i < r->nn; i++)
        if (!r->n[i].placed) r->n[i].x = a[i].x, r->n[i].y = a[i].y;
    relax(r->n, r->nn, r->d, 150);
    // other starts (fresh trilateration, shuffled rings) against folds; the
    // carried-over layout stays unless one is clearly better: a steady map
    for (int t = 0; t <= 6; t++) {
        memcpy(keep, r->n, sizeof keep);
        float sk = radar_stress(r);
        if (t == 0) memcpy(r->n, a, sizeof a);
        else
            for (int i = 1; i < r->nn; i++) {
                float an = mac_angle(r->n[i].mac) + t * i * 2.39996f;
                r->n[i].x = r->d[0][i] * cosf(an);
                r->n[i].y = r->d[0][i] * sinf(an);
            }
        relax(r->n, r->nn, r->d, 150);
        if (!(radar_stress(r) < 0.7f * sk - 0.01f)) memcpy(r->n, keep, sizeof keep);
    }
    orient(r, old);
    for (int i = 0; i < r->nn; i++) r->n[i].placed = true;
}

static const char *kind_name(int k) { return k == 1 ? "BEAGLE" : k == 2 ? "CRYSTAL" : k == 3 ? "BADGE OS" : "?"; }

void radar_update(radar_t *r, const radar_peer_t *pe, int n, int32_t now)
{
    r->now = now;
    for (int i = 0; i < n; i++) {
        const radar_peer_t *p = &pe[i];
        // me <-> p: what I hear and what it hears from me, averaged in dB
        float s = 0;
        int k = 0;
        if (p->rssi != 127) s += p->rssi, k++;
        if (p->their != 127) s += p->their, k++;
        sample(r, r->me, p->mac, k ? s / k : NAN, p->cm);
        for (int j = 0; j < p->nh && j < RADAR_HEARD; j++)
            if (memcmp(p->h[j].mac, r->me, 6)) // about me: already in their
                sample(r, p->mac, p->h[j].mac, p->h[j].rssi == 127 ? NAN : (float)p->h[j].rssi, p->h[j].cm);
    }
    // list, nearest first (unknown last)
    r->np = 0;
    for (int i = 0; i < n && r->np < RADAR_PEERS; i++) {
        const radar_peer_t *p = &pe[i];
        int k = r->np++;
        memcpy(r->p[k].mac, p->mac, 6);
        memcpy(r->p[k].name, p->name, 13);
        r->p[k].name[12] = 0;
        r->p[k].kind = p->kind;
        r->p[k].m = dist(r, r->me, p->mac);
        r->p[k].rssi = p->rssi;
        r->p[k].age_ms = p->age_ms;
        for (; k > 0; k--) {
            float a = r->p[k - 1].m < 0 ? 1e9f : r->p[k - 1].m, b = r->p[k].m < 0 ? 1e9f : r->p[k].m;
            if (a <= b) break;
            __typeof__(r->p[0]) t = r->p[k];
            r->p[k] = r->p[k - 1];
            r->p[k - 1] = t;
        }
    }
    // map nodes: me + measured badges, nearest first
    radar_node_t prev[RADAR_NODES];
    memcpy(prev, r->n, sizeof prev);
    int pn = r->nn;
    memset(r->n, 0, sizeof r->n);
    memcpy(r->n[0].mac, r->me, 6);
    snprintf(r->n[0].name, sizeof r->n[0].name, "%s", r->my_name);
    r->nn = 1;
    for (int i = 0; i < r->np && r->nn < RADAR_NODES; i++) {
        if (r->p[i].m < 0) continue;
        radar_node_t *q = &r->n[r->nn++];
        memcpy(q->mac, r->p[i].mac, 6);
        memcpy(q->name, r->p[i].name, 13);
        q->kind = r->p[i].kind;
        for (int j = 1; j < pn; j++) // keep last positions (radar_fit reuses them)
            if (!memcmp(prev[j].mac, q->mac, 6)) q->x = prev[j].x, q->y = prev[j].y, q->placed = prev[j].placed;
    }
    r->partial = false;
    for (int i = 0; i < r->nn; i++)
        for (int j = 0; j < r->nn; j++) {
            r->d[i][j] = i == j ? 0 : dist(r, r->n[i].mac, r->n[j].mac);
            if (r->d[i][j] < 0) r->partial = true;
        }
    if (r->nn >= 3) radar_fit(r);
}

uint32_t radar_signature(const radar_t *r)
{
    uint32_t h = 2166136261u;
#define MIX(v) (h = (h ^ (uint32_t)(v)) * 16777619u)
    MIX(r->net_on);
    MIX(r->np);
    for (int i = 0; i < r->np; i++) {
        for (int k = 0; k < 6; k++) MIX(r->p[i].mac[k]);
        for (int k = 0; r->p[i].name[k]; k++) MIX(r->p[i].name[k]);
        MIX(r->p[i].m < 0 ? -1 : (int)lroundf(r->p[i].m * 2)); // 0.5 m steps
        MIX(r->p[i].age_ms > 10000);
    }
    MIX(r->nn);
    for (int i = 1; i < r->nn; i++) MIX((int)lroundf(r->n[i].x * 2)), MIX((int)lroundf(r->n[i].y * 2));
#undef MIX
    return h;
}

static void label(const uint8_t *mac, const char *name, char *o, int n)
{
    if (name && name[0]) snprintf(o, n, "%.12s", name);
    else snprintf(o, n, "%02X%02X", mac[4], mac[5]);
}

static const char *bucket(float m)
{
    return m < 0 ? "" : m < 1 ? "HERE" : m < 3 ? "NEAR" : m < 8 ? "ROOM" : "FAR";
}

#define MAP_X 400

void radar_draw(const radar_t *r, uint8_t *p)
{
    char s[64], id[16];
    g_clear(p);
    if (!r->net_on) {
        g_wrap(p, 48, G_BAR + 120, G_W - 96, 5, 54, 2, "The badge link is off.", true);
        g_wrap(p, 48, G_BAR + 260, G_W - 96, 3, 34, 4,
               "Radar lists badges heard over the link (UDP + ESP-NOW) with their distance from signal strength. "
               "Press A to turn the network on (Wi-Fi from `wifi <ssid> <pass>`).", true);
        g_hint(p, "A: NETWORK ON", "RADAR");
        return;
    }
    // list
    label(r->me, r->my_name, id, sizeof id);
    snprintf(s, sizeof s, "ME: %s", id);
    g_text(p, 16, G_BAR + 10, 3, s, true);
    g_rect(p, 16, G_BAR + 40, MAP_X - 32, 2, true);
    int y = G_BAR + 52;
    for (int i = 0; i < r->np && y < G_H - 90; i++, y += 64) {
        label(r->p[i].mac, r->p[i].name, id, sizeof id);
        g_text(p, 16, y, 3, id, true);
        if (r->p[i].m < 0) snprintf(s, sizeof s, "--   %s", kind_name(r->p[i].kind));
        else if (r->p[i].m < 10) snprintf(s, sizeof s, "%.1f M %s  %s", r->p[i].m, bucket(r->p[i].m), kind_name(r->p[i].kind));
        else snprintf(s, sizeof s, "%d M %s  %s", (int)lroundf(r->p[i].m), bucket(r->p[i].m), kind_name(r->p[i].kind));
        g_text(p, 40, y + 28, 2, s, true);
        if (r->p[i].age_ms > 10000) g_text(p, MAP_X - 60, y + 4, 2, "OLD", true);
    }
    if (!r->np) g_wrap(p, 16, G_BAR + 70, MAP_X - 32, 3, 32, 6, "Listening... no badges heard yet.", true);
    g_rect(p, MAP_X, G_BAR, 2, G_H - 26 - G_BAR, true);
    // map
    int cx = MAP_X + (G_W - MAP_X) / 2, cy = G_BAR + (G_H - 26 - G_BAR) / 2, R = 250;
    if (r->nn < 3) {
        snprintf(s, sizeof s, "MAP: NEEDS 3+ BADGES");
        g_text(p, cx - g_text_w(3, (int)strlen(s)) / 2, cy - 30, 3, s, true);
        snprintf(s, sizeof s, "(%d MORE WITH A DISTANCE)", 3 - r->nn);
        g_text(p, cx - g_text_w(2, (int)strlen(s)) / 2, cy + 10, 2, s, true);
    } else {
        float far = 0;
        for (int i = 1; i < r->nn; i++) far = fmaxf(far, hypotf(r->n[i].x, r->n[i].y));
        static const float steps[] = {0.5f, 1, 2, 3, 5, 10, 20, 50, 100};
        float step = 100;
        for (int i = 0; i < 9; i++)
            if (3 * steps[i] >= far) { step = steps[i]; break; }
        float px = R / (3 * step);
        for (int k = 1; k <= 3; k++) {
            g_ring_dotted(p, cx, cy, R * k / 3, 3);
            snprintf(s, sizeof s, "%g M", step * k);
            g_text(p, cx + 4, cy - R * k / 3 - 18, 2, s, true);
        }
        g_rect(p, cx - 9, cy - 9, 18, 18, true);
        g_text(p, cx + 14, cy + 4, 2, "ME", true);
        for (int i = 1; i < r->nn; i++) {
            int x = cx + (int)lroundf(r->n[i].x * px), yy = cy + (int)lroundf(r->n[i].y * px);
            g_disc(p, x, yy, 9, true);
            label(r->n[i].mac, r->n[i].name, id, sizeof id);
            int tx = x + 14;
            if (tx + g_text_w(2, (int)strlen(id)) > G_W - 4) tx = x - 14 - g_text_w(2, (int)strlen(id));
            g_text(p, tx, yy - 7, 2, id, true);
        }
        g_text(p, MAP_X + 12, G_H - 50, 2, r->partial ? "SOME DISTANCES UNKNOWN: ROUGH" : "ROTATION/MIRROR UNKNOWN", true);
    }
    g_hint(p, "A: CLEAN   B: NETWORK OFF", "DISTANCE FROM RSSI, ROUGH");
}
