// See apps_gfx.h.
#include <string.h>
#include <stdlib.h>
#include "apps_gfx.h"
#include "font5x7.h"

void g_clear(uint8_t *p) { memset(p, 0, G_PLANE); }

void g_px(uint8_t *p, int x, int y, bool ink)
{
    if ((unsigned)x >= G_W || (unsigned)y >= G_H) return;
    uint8_t m = 0x80 >> (x & 7);
    if (ink) p[y * G_ROW + (x >> 3)] |= m;
    else p[y * G_ROW + (x >> 3)] &= ~m;
}

void g_rect(uint8_t *p, int x, int y, int w, int h, bool ink)
{
    if (x < 0) w += x, x = 0;
    if (y < 0) h += y, y = 0;
    if (x + w > G_W) w = G_W - x;
    if (y + h > G_H) h = G_H - y;
    if (w <= 0 || h <= 0) return;
    for (int r = y; r < y + h; r++) {
        uint8_t *row = p + r * G_ROW;
        int c = x;
        while (c < x + w && (c & 7)) g_px(p, c++, r, ink);
        while (c + 8 <= x + w) row[c >> 3] = ink ? 0xFF : 0x00, c += 8;
        while (c < x + w) g_px(p, c++, r, ink);
    }
}

void g_frame(uint8_t *p, int x, int y, int w, int h, int t)
{
    g_rect(p, x, y, w, t, true);
    g_rect(p, x, y + h - t, w, t, true);
    g_rect(p, x, y, t, h, true);
    g_rect(p, x + w - t, y, t, h, true);
}

void g_hline_dotted(uint8_t *p, int x, int y, int w, int gap)
{
    for (int i = 0; i < w; i += gap) g_rect(p, x + i, y, 2, 2, true);
}

void g_line(uint8_t *p, int x0, int y0, int x1, int y1, int t)
{
    int dx = abs(x1 - x0), dy = -abs(y1 - y0), sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1, e = dx + dy;
    for (;;) {
        g_rect(p, x0 - t / 2, y0 - t / 2, t, t, true);
        if (x0 == x1 && y0 == y1) break;
        int e2 = 2 * e;
        if (e2 >= dy) e += dy, x0 += sx;
        if (e2 <= dx) e += dx, y0 += sy;
    }
}

void g_disc(uint8_t *p, int cx, int cy, int r, bool ink)
{
    for (int y = -r; y <= r; y++) {
        int w = 0;
        while ((w + 1) * (w + 1) + y * y <= r * r) w++;
        g_rect(p, cx - w, cy + y, 2 * w + 1, 1, ink);
    }
}

void g_ring(uint8_t *p, int cx, int cy, int r, int t)
{
    int ri = r - t;
    for (int y = -r; y <= r; y++)
        for (int x = -r; x <= r; x++) {
            int d = x * x + y * y;
            if (d <= r * r && d > ri * ri) g_px(p, cx + x, cy + y, true);
        }
}

void g_ring_dotted(uint8_t *p, int cx, int cy, int r, int dot)
{
    // ~one dot every 10 px of circumference, by integer octant stepping
    int x = r, y = 0, err = 1 - r, k = 0;
    while (x >= y) {
        if (k++ % 5 == 0) {
            int pts[8][2] = {{x, y}, {y, x}, {-y, x}, {-x, y}, {-x, -y}, {-y, -x}, {y, -x}, {x, -y}};
            for (int i = 0; i < 8; i++) g_rect(p, cx + pts[i][0] - dot / 2, cy + pts[i][1] - dot / 2, dot, dot, true);
        }
        y++;
        if (err < 0) err += 2 * y + 1;
        else x--, err += 2 * (y - x) + 1;
    }
}

int g_text_w(int scale, int n) { return n <= 0 ? 0 : (n * 6 - 1) * scale; }

int g_text_n(uint8_t *p, int x, int y, int scale, const char *s, int n, bool ink)
{
    for (int i = 0; i < n; i++) {
        int ch = (unsigned char)s[i];
        if (ch < 0x20 || ch > 0x7E) ch = '?';
        const uint8_t *g = k_font5x7[ch - 0x20];
        for (int c = 0; c < 5; c++)
            for (int r = 0; r < 7; r++)
                if (g[c] >> r & 1) g_rect(p, x + c * scale, y + r * scale, scale, scale, ink);
        x += 6 * scale;
    }
    return x;
}

int g_text(uint8_t *p, int x, int y, int scale, const char *s, bool ink)
{
    return g_text_n(p, x, y, scale, s, (int)strlen(s), ink);
}

int g_cut(const char *s, int cols, const char **next)
{
    int n = (int)strcspn(s, "\n");
    if (n > cols) {
        int k = cols;
        while (k > 0 && s[k] != ' ') k--;
        n = k ? k : cols; // one long word: hard break
    }
    const char *t = s + n;
    while (*t == ' ') t++;
    *next = t;
    return n;
}

int g_wrap(uint8_t *p, int x, int y, int w, int scale, int lh, int maxl, const char *s, bool ink)
{
    int cols = (w + scale) / (6 * scale);
    if (cols < 4) return y;
    while (*s && maxl-- > 0) {
        const char *t;
        int n = g_cut(s, cols, &t);
        if (*t == '\n') t++;
        if (!maxl && *t) { // last allowed line and more text: ellipsis
            if (n > cols - 3) n = cols - 3;
            int e = g_text_n(p, x, y, scale, s, n, ink);
            g_text(p, e, y, scale, "...", ink);
        } else {
            g_text_n(p, x, y, scale, s, n, ink);
        }
        y += lh;
        s = t;
    }
    return y;
}

void g_blit(uint8_t *p, int x, int y, const uint8_t *bits, int w, int h)
{
    int st = (w + 7) / 8;
    for (int r = 0; r < h; r++) {
        int yy = y + r;
        if ((unsigned)yy >= G_H) continue;
        const uint8_t *src = bits + r * st;
        for (int c = 0; c < w; c++)
            if (src[c >> 3] & (0x80 >> (c & 7))) g_px(p, x + c, yy, true);
    }
}

void g_hint(uint8_t *p, const char *s, const char *info)
{
    g_rect(p, 0, G_H - 26, G_W, 2, true);
    if (s) g_text(p, 16, G_H - 19, 2, s, true);
    if (info && *info) g_text(p, G_W - 16 - g_text_w(2, (int)strlen(info)), G_H - 19, 2, info, true);
}
