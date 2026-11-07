// RSS reader model for the Hackaday and News apps: a streaming RSS 2.0
// parser (bounded memory: the feed is never held whole), image decode +
// dither to 1 bit, text layout and screen rendering. Pure C (no ESP-IDF):
// test/apps/ runs it on the host against saved feeds.
//
// Inspired by yigitabi5444's badge os RSS reader (main/app_hackaday.c): one
// post per screen with its featured image, open to read it with its
// pictures, WordPress / BBC image resizing in the URL. Our own code.
#pragma once
#include <stdint.h>
#include <stdbool.h>

#define FD_MAXP 10          // posts kept
#define FD_MAXI 32          // images in all
#define FD_PERP 5           // images per post (the first is the featured one)
#define FD_TITLE 200
#define FD_BODY 24576       // cleaned text per post (bytes)
#define FD_SUMMARY 1024
#define FD_URL 320
#define FD_TAG 1024         // longest HTML tag kept (an <img> with srcset)
#define FD_MAXL 1600        // laid-out lines of the open post

// Image boxes (px): featured images on the browser card, pictures in a post.
#define FD_COVER_W 960
#define FD_COVER_H 500
#define FD_PIC_W 720
#define FD_PIC_H 420

enum { FD_SITE_OTHER = 0, FD_SITE_HACKADAY = 1, FD_SITE_BBC = 2 };

typedef struct {
    char url[FD_URL];
    int16_t post;
    int16_t bw, bh;           // the box it is scaled into
    int16_t w, h;             // decoded size (state 1)
    uint8_t *bits;            // (w + 7) / 8 bytes per row, 1 = ink
    volatile int8_t state;    // 0 to fetch, 1 ready, -1 failed
} fd_img_t;

typedef struct {
    char title[FD_TITLE];
    char author[48];
    char date[40];
    char *body;               // ASCII; '\n' = paragraph; byte 0x80 + i alone on a line = image i
    int body_n;
    int16_t cover;            // featured image index, -1 none
} fd_post_t;

// Streaming parser state (XML layer + HTML layer of the current field).
typedef struct {
    int xs;                   // XML state
    char tag[FD_TAG];         // XML tag being read
    int tn;
    char ent[12];
    int en;
    int brackets;             // ']' run inside CDATA
    int field;                // which field of the item gets the text
    bool in_item;
    // HTML layer
    int hs;
    char htag[FD_TAG];
    int hn;
    char hent[12];
    int hen;
    uint32_t cp;
    int more;                 // UTF-8 continuation bytes expected
    bool skip;                // inside <script> / <style>
    char *out;                // current output buffer
    int on, omax;
    bool html;                // the field holds HTML (body / summary) vs plain
    // description: text and its first image, used when there is no content:encoded
    char summary[FD_SUMMARY];
    int sn;
    char desc_img[FD_TAG];
    bool has_desc_img;
    bool done;
} fd_parser_t;

typedef struct {
    int site;
    fd_post_t posts[FD_MAXP];
    volatile int nposts;      // complete posts (the reader may show them)
    fd_img_t imgs[FD_MAXI];
    volatile int nimg;
    fd_parser_t ps;
    char body_store[FD_MAXP][FD_BODY];
    // layout of the open post
    struct { const char *s; int16_t n, h; int8_t scale, img; } lines[FD_MAXL];
    int nl, open_post;
    int page_top[256];
    int npages;
} feed_t;

void fd_init(feed_t *f, int site);
void fd_reset(feed_t *f);             // drop posts (images' bits are freed with fd_free_bits)
// Feeds n bytes of the HTTP body; returns true once FD_MAXP posts are in (stop reading).
bool fd_parse(feed_t *f, const char *data, int n);
int fd_site_of(const char *url);

// Image: decodes JPEG/PNG data (stb_image), fits it into the image's box,
// dithers it (Atkinson) into m->bits (allocated with fd_alloc). false if not.
bool fd_decode(fd_img_t *m, const uint8_t *data, int n);
// Allocation hooks: PSRAM on the badge, malloc on the host.
void *fd_alloc(int n);
void fd_free(void *p);
void fd_free_bits(feed_t *f);

// Layout of post i for reading; returns the number of pages.
int fd_layout(feed_t *f, int i);
// Screens. info: shown top right (e.g. a status); status: NULL when ready.
void fd_draw_card(feed_t *f, uint8_t *plane, const char *name, int i);
void fd_draw_page(feed_t *f, uint8_t *plane, const char *name, int i, int page);
void fd_draw_message(uint8_t *plane, const char *name, const char *big, const char *small);
