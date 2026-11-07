// Drawing into a 960x672 1-bit plane (120 bytes per row, MSB = leftmost
// pixel, 1 = black ink), for the content apps (Hackaday, News, Weather,
// Radar). Pure C, no ESP-IDF: the host tests (test/apps/) render screens with
// it to PNG.
#pragma once
#include <stdint.h>
#include <stdbool.h>

#define G_W 960
#define G_H 672
#define G_ROW 120
#define G_PLANE (G_ROW * G_H)

void g_clear(uint8_t *p);
void g_px(uint8_t *p, int x, int y, bool ink);
void g_rect(uint8_t *p, int x, int y, int w, int h, bool ink);
void g_frame(uint8_t *p, int x, int y, int w, int h, int t);
void g_hline_dotted(uint8_t *p, int x, int y, int w, int gap);
void g_line(uint8_t *p, int x0, int y0, int x1, int y1, int t);
void g_disc(uint8_t *p, int cx, int cy, int r, bool ink);
void g_ring(uint8_t *p, int cx, int cy, int r, int t);
void g_ring_dotted(uint8_t *p, int cx, int cy, int r, int dot);
// 5x7 font (6x8 cell) scaled: n bytes (printable ASCII; others drawn as '?').
// Returns the x after the text.
int g_text_n(uint8_t *p, int x, int y, int scale, const char *s, int n, bool ink);
int g_text(uint8_t *p, int x, int y, int scale, const char *s, bool ink);
int g_text_w(int scale, int n); // width of n characters
// Word-wrapped text in [x, x + w): at most maxl lines, lh px apart, "..." when
// cut. Returns the y below the last line drawn.
int g_wrap(uint8_t *p, int x, int y, int w, int scale, int lh, int maxl, const char *s, bool ink);
// How much of s (up to its end or '\n') fits a line of cols characters,
// broken at a space; *next = where the next line starts.
int g_cut(const char *s, int cols, const char **next);
// 1-bit bitmap (rows of (w + 7) / 8 bytes, MSB first, 1 = ink) at x, y.
void g_blit(uint8_t *p, int x, int y, const uint8_t *bits, int w, int h);
// Rows 0..G_BAR-1 belong to the registry's top bar (src/apps/app.cr TopBar,
// drawn by the Crystal side after the C content).
#define G_BAR 48
// Bottom line: help text left, info (position, status) right.
void g_hint(uint8_t *p, const char *s, const char *info);
