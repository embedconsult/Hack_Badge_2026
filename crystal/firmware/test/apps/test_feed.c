// Host test: RSS parser, image decode, layout and screens (main/feed.c).
#include <string.h>
#include "host.h"
#include "../../main/feed.h"
#include "../../main/apps_gfx.h"

void *fd_alloc(int n) { return malloc(n); }
void fd_free(void *p) { free(p); }

static uint8_t plane[G_PLANE];

static void parse_chunked(feed_t *f, const char *b, int n, int chunk)
{
    for (int i = 0; i < n; i += chunk)
        if (fd_parse(f, b + i, n - i < chunk ? n - i : chunk)) break;
}

static void check_feed(const char *path, int site, const char *tag, const char *jpg)
{
    int n;
    char *b = slurp(path, &n);
    static feed_t f1, f2;
    fd_init(&f1, site);
    parse_chunked(&f1, b, n, n); // whole
    fd_init(&f2, site);
    parse_chunked(&f2, b, n, 7); // tiny chunks: same result
    CHECK(f1.nposts > 3);
    CHECK(f1.nposts == f2.nposts && f1.nimg == f2.nimg);
    for (int i = 0; i < f1.nposts; i++) {
        CHECK(!strcmp(f1.posts[i].title, f2.posts[i].title));
        CHECK(f1.posts[i].body_n == f2.posts[i].body_n && !memcmp(f1.posts[i].body, f2.posts[i].body, f1.posts[i].body_n));
        for (const char *c = f1.posts[i].title; *c; c++) CHECK(*c >= 0x20 && *c < 0x7F);
        printf("%s post %d: \"%s\" by \"%s\" on \"%s\", %d bytes, cover %d\n", tag, i, f1.posts[i].title,
               f1.posts[i].author, f1.posts[i].date, f1.posts[i].body_n, f1.posts[i].cover);
    }
    for (int i = 0; i < f1.nimg; i++) printf("  img %d post %d box %dx%d %s\n", i, f1.imgs[i].post, f1.imgs[i].bw, f1.imgs[i].bh, f1.imgs[i].url);
    CHECK(f1.posts[0].cover >= 0);
    CHECK(strstr(f1.posts[0].body, "<") == NULL && strstr(f1.posts[0].body, "&#") == NULL && strstr(f1.posts[0].body, "CDATA") == NULL);
    // the fixture image as post 0's cover
    int jn;
    char *j = slurp(jpg, &jn);
    fd_img_t *m = &f1.imgs[f1.posts[0].cover];
    CHECK(fd_decode(m, (uint8_t *)j, jn));
    m->state = 1;
    printf("%s cover decoded %dx%d (box %dx%d)\n", tag, m->w, m->h, m->bw, m->bh);
    CHECK(m->w <= m->bw && m->h <= m->bh && m->w > 100);
    char out[256];
    fd_draw_card(&f1, plane, tag, 0);
    snprintf(out, sizeof out, "out/%s_card0.pbm", tag);
    write_pbm(out, plane);
    fd_draw_card(&f1, plane, tag, 1); // cover not loaded: placeholder
    snprintf(out, sizeof out, "out/%s_card1.pbm", tag);
    write_pbm(out, plane);
    int pages = fd_layout(&f1, 0);
    printf("%s post 0: %d lines, %d pages\n", tag, f1.nl, pages);
    CHECK(pages >= 1);
    for (int p = 0; p < pages && p < 3; p++) {
        fd_draw_page(&f1, plane, tag, 0, p);
        snprintf(out, sizeof out, "out/%s_post0_page%d.pbm", tag, p);
        write_pbm(out, plane);
    }
    // the longest post pages through without overflow
    int longest = 0;
    for (int i = 0; i < f1.nposts; i++) if (f1.posts[i].body_n > f1.posts[longest].body_n) longest = i;
    pages = fd_layout(&f1, longest);
    printf("%s longest post %d: %d bytes, %d pages\n", tag, longest, f1.posts[longest].body_n, pages);
    fd_draw_page(&f1, plane, tag, longest, pages - 1);
    snprintf(out, sizeof out, "out/%s_longest_last.pbm", tag);
    write_pbm(out, plane);
    fd_free_bits(&f1);
    free(b);
    free(j);
}

int main(void)
{
    check_feed("fixtures/had.xml", FD_SITE_HACKADAY, "HACKADAY", "fixtures/had1.jpg");
    check_feed("fixtures/bbc.xml", FD_SITE_BBC, "NEWS", "fixtures/bbc1.jpg");
    // truncated feed: what is complete is kept
    int n;
    char *b = slurp("fixtures/had.xml", &n);
    static feed_t f;
    fd_init(&f, FD_SITE_HACKADAY);
    fd_parse(&f, b, n / 2);
    printf("half feed: %d posts\n", f.nposts);
    CHECK(f.nposts >= 1);
    printf(s_fail ? "feed: %d FAILED\n" : "feed: ok\n", s_fail);
    return s_fail != 0;
}
