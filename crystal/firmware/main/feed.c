// RSS reader model: see feed.h. Pure C; the badge glue is main/apps_net.c.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <math.h>
#include "feed.h"
#include "apps_gfx.h"
#include "stb_image.h"

enum { X_TEXT, X_TAG, X_CDATA, X_COMMENT, X_ENT };
enum { H_TEXT, H_TAG, H_ENT };
enum { F_NONE, F_TITLE, F_AUTHOR, F_DATE, F_DESC, F_CONTENT };

int fd_site_of(const char *url)
{
    if (strstr(url, "hackaday.com")) return FD_SITE_HACKADAY;
    if (strstr(url, "bbc.co")) return FD_SITE_BBC;
    return FD_SITE_OTHER;
}

void fd_init(feed_t *f, int site)
{
    memset(f, 0, sizeof *f);
    f->site = site;
    f->open_post = -1;
}

void fd_free_bits(feed_t *f)
{
    for (int i = 0; i < FD_MAXI; i++) {
        if (f->imgs[i].bits) fd_free(f->imgs[i].bits);
        f->imgs[i].bits = NULL;
    }
}

void fd_reset(feed_t *f)
{
    int site = f->site;
    fd_free_bits(f);
    fd_init(f, site);
}

// ---- text output (HTML layer) ------------------------------------------------

static const char latin1[] = "AAAAAAACEEEEIIIIDNOOOOOxOUUUUYPsaaaaaaaceeeeiiiidnooooo/ouuuuypy"; // U+00C0..U+00FF

static void out_raw(fd_parser_t *p, char c)
{
    if (p->on < p->omax - 1) p->out[p->on++] = c;
}

// One code point to 7-bit ASCII; whitespace collapsed, no empty paragraphs.
static void put(fd_parser_t *p, uint32_t cp)
{
    char c[2] = {0, 0};
    const char *s = c;
    if (p->skip) return;
    if (cp >= 0x20 && cp < 0x7F) c[0] = (char)cp;
    else if (cp == '\n') c[0] = p->html ? '\n' : ' ';
    else if (cp == '\t' || cp == '\r' || cp == 0xA0 || cp == 0x2009 || cp == 0x200A || cp == 0x202F) c[0] = ' ';
    else if (cp == 0x2018 || cp == 0x2019 || cp == 0x2032 || cp == 0x201A) c[0] = '\'';
    else if (cp == 0x201C || cp == 0x201D || cp == 0x2033 || cp == 0x201E) c[0] = '"';
    else if (cp >= 0x2010 && cp <= 0x2015) c[0] = '-';
    else if (cp == 0x2026) s = "...";
    else if (cp == 0x2022 || cp == 0xB7) c[0] = '*';
    else if (cp == 0xD7) c[0] = 'x';
    else if (cp == 0xB0) s = " deg";
    else if (cp == 0xA9) s = "(c)";
    else if (cp == 0x20AC) s = "EUR";
    else if (cp == 0xA3) s = "GBP";
    else if (cp >= 0xC0 && cp <= 0xFF) c[0] = latin1[cp - 0xC0];
    // anything else (emoji, CJK, zero-width) is dropped
    for (; *s; s++) {
        char ch = *s;
        if (ch == ' ' && (p->on == 0 || p->out[p->on - 1] == ' ' || p->out[p->on - 1] == '\n')) continue;
        if (ch == '\n') {
            while (p->on && p->out[p->on - 1] == ' ') p->on--;
            if (p->on == 0 || p->out[p->on - 1] == '\n') continue;
        }
        out_raw(p, ch);
    }
}

static void utf8(fd_parser_t *p, unsigned char c)
{
    if (p->more && (c & 0xC0) == 0x80) {
        p->cp = p->cp << 6 | (c & 0x3F);
        if (--p->more == 0) put(p, p->cp);
        return;
    }
    p->more = 0;
    if (c < 0x80) put(p, c);
    else if (c >= 0xF0) p->cp = c & 0x07, p->more = 3;
    else if (c >= 0xE0) p->cp = c & 0x0F, p->more = 2;
    else if (c >= 0xC0) p->cp = c & 0x1F, p->more = 1;
}

static uint32_t entity(const char *e, int n)
{
    static const struct { const char *n; uint32_t cp; } t[] = {
        {"amp", '&'}, {"lt", '<'}, {"gt", '>'}, {"quot", '"'}, {"apos", '\''}, {"nbsp", ' '},
        {"hellip", 0x2026}, {"ndash", '-'}, {"mdash", '-'}, {"rsquo", '\''}, {"lsquo", '\''},
        {"rdquo", '"'}, {"ldquo", '"'}, {"deg", 0xB0}, {"times", 0xD7}, {"copy", 0xA9}, {"bull", 0x2022},
        {"euro", 0x20AC}, {"pound", 0xA3}, {"middot", 0xB7}};
    if (n > 1 && e[0] == '#') return e[1] == 'x' || e[1] == 'X' ? strtoul(e + 2, NULL, 16) : strtoul(e + 1, NULL, 10);
    for (unsigned i = 0; i < sizeof t / sizeof *t; i++)
        if ((int)strlen(t[i].n) == n && !strncmp(e, t[i].n, n)) return t[i].cp;
    return 0;
}

// In place: "&amp;" -> "&" (URLs in attributes).
static void unamp(char *s)
{
    char *o = s;
    for (; *s; s++) {
        *o++ = *s;
        if (!strncmp(s, "&amp;", 5)) s += 4;
    }
    *o = 0;
}

// The value of name="..." (or '...') in tag text t; false if absent.
static bool attr(const char *t, const char *name, char *o, int max)
{
    int kl = (int)strlen(name);
    for (const char *s = t; (s = strstr(s, name)); s++) {
        if (s > t && s[-1] != ' ' && s[-1] != '\t' && s[-1] != '\n') continue;
        if (s[kl] != '=' || (s[kl + 1] != '"' && s[kl + 1] != '\'')) continue;
        char q = s[kl + 1];
        const char *v = s + kl + 2, *e = strchr(v, q);
        if (!e) return false;
        snprintf(o, max, "%.*s", (int)(e - v), v);
        unamp(o);
        return true;
    }
    return false;
}

// An image of post pi from tag text t (URL in attribute u); its index, -1 if not taken.
static int add_img(feed_t *f, int pi, const char *t, const char *u)
{
    char src[FD_URL], v[16];
    int w = 0, h = 0, k = 0;
    for (int i = 0; i < f->nimg; i++) k += f->imgs[i].post == pi;
    if (f->nimg >= FD_MAXI || k >= FD_PERP || !attr(t, u, src, sizeof src)) return -1;
    if (strlen(src) > FD_URL - 40 || strncmp(src, "http", 4)) return -1; // data: URIs, relative, too long
    if (strstr(t, "wp-smiley") || strstr(t, "emoji")) return -1;
    if (attr(t, "width", v, sizeof v)) w = atoi(v);
    if (attr(t, "height", v, sizeof v)) h = atoi(v);
    if ((w && w < 64) || (h && h < 48)) return -1; // icons, avatars
    char *q = strchr(src, '?'), *end = q ? q : src + strlen(src);
    static const char *skip[] = {".gif", ".svg", ".webp", ".GIF", ".SVG"};
    for (unsigned i = 0; i < sizeof skip / sizeof *skip; i++) {
        int sl = (int)strlen(skip[i]);
        if (end - src > sl && !strncmp(end - sl, skip[i], sl)) return -1;
    }
    int pl = (int)(end - src);
    for (int i = 0; i < f->nimg; i++) // WordPress repeats the featured image in the post: once is enough
        if (f->imgs[i].post == pi && !strncmp(f->imgs[i].url, src, pl) && strchr("?", f->imgs[i].url[pl])) return -1;
    fd_img_t *m = &f->imgs[f->nimg];
    memset(m, 0, sizeof *m);
    int bw = k ? FD_PIC_W : FD_COVER_W, bh = k ? FD_PIC_H : FD_COVER_H;
    if (w <= 0 || h <= 0) w = 16, h = 9; // unknown: assume a wide picture
    if ((long)w * bh > (long)h * bw) m->bw = bw, m->bh = (int16_t)((long)bw * h / w);
    else m->bh = bh, m->bw = (int16_t)((long)bh * w / h);
    if (m->bw < 16) m->bw = 16;
    if (m->bh < 16) m->bh = 16;
    char *bbc = strstr(src, "/standard/");
    if (strstr(src, "/wp-content/uploads/")) { // WordPress (Photon) resizes on its own server
        if (q) *q = 0;
        snprintf(m->url, sizeof m->url, "%.280s?w=%d&quality=60", src, m->bw);
    } else if (bbc && f->site == FD_SITE_BBC) { // BBC: /standard/<width>/..., a sharper size
        const char *rest = strchr(bbc + 10, '/');
        if (rest) snprintf(m->url, sizeof m->url, "%.*s/standard/800%s", (int)(bbc - src), src, rest);
        else snprintf(m->url, sizeof m->url, "%s", src);
    } else {
        snprintf(m->url, sizeof m->url, "%s", src);
    }
    m->post = (int16_t)pi;
    m->state = 0;
    if (f->posts[pi].cover < 0) f->posts[pi].cover = (int16_t)f->nimg;
    return f->nimg++;
}

static void marker(fd_parser_t *p, int img)
{
    if (p->on > p->omax - 4) return;
    put(p, '\n');
    out_raw(p, (char)(0x80 + img));
    out_raw(p, '\n');
}

static void html_tag(feed_t *f, fd_parser_t *p)
{
    p->htag[p->hn] = 0;
    const char *t = p->htag;
    bool closing = t[0] == '/';
    char name[16];
    int k = 0;
    for (int i = closing; k < 15 && (isalnum((unsigned char)t[i])); i++) name[k++] = (char)tolower((unsigned char)t[i]);
    name[k] = 0;
    if (!strcmp(name, "script") || !strcmp(name, "style")) {
        p->skip = !closing;
        return;
    }
    if (!p->html) return;
    if (!strcmp(name, "img") && !closing) {
        if (p->field == F_CONTENT) {
            int m = add_img(f, f->nposts, t, "src");
            if (m >= 0) marker(p, m);
        } else if (p->field == F_DESC && !p->has_desc_img) {
            snprintf(p->desc_img, sizeof p->desc_img, "%s", t);
            p->has_desc_img = true;
        }
    } else if (!strcmp(name, "iframe") && !closing) {
        put(p, '\n');
        for (const char *c = "[video]"; *c; c++) put(p, *c);
        put(p, '\n');
    } else if (!strcmp(name, "li") && !closing) {
        put(p, '\n');
        put(p, '-');
        put(p, ' ');
    } else if (k) {
        char key[20];
        snprintf(key, sizeof key, " %s ", name);
        if (strstr(" p br div h1 h2 h3 h4 h5 h6 ul ol figure figcaption blockquote pre tr table hr ", key)) put(p, '\n');
    }
}

static void html_byte(feed_t *f, fd_parser_t *p, unsigned char c)
{
    if (!p->out) return;
    if (p->hs == H_TAG) {
        if (c == '>') {
            p->hs = H_TEXT;
            html_tag(f, p);
        } else if (p->hn < FD_TAG - 1) {
            p->htag[p->hn++] = (char)c;
        }
        return;
    }
    if (p->hs == H_ENT) {
        if (c == ';') {
            p->hs = H_TEXT;
            uint32_t cp = entity(p->hent, p->hen);
            if (cp == '<' || cp == '>' || cp == '&') put(p, cp); // a literal, not markup
            else if (cp) put(p, cp);
            return;
        }
        if ((isalnum(c) || c == '#') && p->hen < 10) {
            p->hent[p->hen++] = (char)c;
            return;
        }
        p->hs = H_TEXT; // not an entity: the text as it was
        put(p, '&');
        for (int i = 0; i < p->hen; i++) put(p, (unsigned char)p->hent[i]);
        // fall through with c
    }
    if (c == '<') p->hs = H_TAG, p->hn = 0;
    else if (c == '&') p->hs = H_ENT, p->hen = 0;
    else utf8(p, c);
}

// ---- XML layer ---------------------------------------------------------------

static void field_begin(feed_t *f, fd_parser_t *p, int field)
{
    fd_post_t *po = &f->posts[f->nposts];
    p->field = field;
    p->hs = H_TEXT;
    p->more = 0;
    p->skip = false;
    p->html = field == F_DESC || field == F_CONTENT;
    switch (field) {
    case F_TITLE: p->out = po->title, p->omax = sizeof po->title; break;
    case F_AUTHOR: p->out = po->author, p->omax = sizeof po->author; break;
    case F_DATE: p->out = po->date, p->omax = sizeof po->date; break;
    case F_DESC: p->out = p->summary, p->omax = sizeof p->summary; break;
    case F_CONTENT: p->out = po->body, p->omax = FD_BODY; break;
    default: p->out = NULL; return;
    }
    p->on = 0;
}

static void field_end(feed_t *f, fd_parser_t *p)
{
    if (!p->out) {
        p->field = F_NONE;
        return;
    }
    while (p->on && (p->out[p->on - 1] == ' ' || p->out[p->on - 1] == '\n')) p->on--;
    p->out[p->on] = 0;
    fd_post_t *po = &f->posts[f->nposts];
    if (p->field == F_DESC) p->sn = p->on;
    if (p->field == F_CONTENT) {
        if (p->on >= p->omax - 2) { // cut at FD_BODY: say so
            p->on = p->omax - 8;
            memcpy(p->out + p->on, " [...]", 7);
            p->on += 6;
        }
        po->body_n = p->on;
    }
    p->out = NULL;
    p->field = F_NONE;
}

static void item_begin(feed_t *f, fd_parser_t *p)
{
    if (f->nposts >= FD_MAXP) {
        p->done = true;
        return;
    }
    fd_post_t *po = &f->posts[f->nposts];
    memset(po, 0, sizeof *po);
    po->body = f->body_store[f->nposts];
    po->body[0] = 0;
    po->cover = -1;
    p->in_item = true;
    p->sn = 0;
    p->summary[0] = 0;
    p->has_desc_img = false;
}

static void item_end(feed_t *f, fd_parser_t *p)
{
    fd_post_t *po = &f->posts[f->nposts];
    p->in_item = false;
    if (!po->body_n && p->sn) { // no full text: the description
        char *rm = strstr(p->summary, "...read more"); // Hackaday's excerpts end in a link
        if (rm) strcpy(rm, "...");
        snprintf(po->body, FD_BODY, "%s", p->summary);
        po->body_n = (int)strlen(po->body);
    }
    if (po->cover < 0 && p->has_desc_img) add_img(f, f->nposts, p->desc_img, "src");
    if (po->cover >= 0 && !memchr(po->body, 0x80 + po->cover, po->body_n) && po->body_n < FD_BODY - 3) {
        memmove(po->body + 2, po->body, po->body_n + 1); // the featured image heads the post
        po->body[0] = (char)(0x80 + po->cover);
        po->body[1] = '\n';
        po->body_n += 2;
    }
    if (!po->title[0]) snprintf(po->title, sizeof po->title, "(untitled)");
    po->date[16] = 0; // "Sat, 07 Nov 2026"
    f->nposts++;
    if (f->nposts >= FD_MAXP) p->done = true;
}

static void xml_tag(feed_t *f, fd_parser_t *p)
{
    p->tag[p->tn] = 0;
    const char *t = p->tag;
    if (t[0] == '?' || t[0] == '!') return;
    bool closing = t[0] == '/';
    bool selfc = p->tn && t[p->tn - 1] == '/';
    char name[24];
    int k = 0;
    for (int i = closing; k < 23 && t[i] && !isspace((unsigned char)t[i]) && t[i] != '/'; i++) name[k++] = t[i];
    name[k] = 0;
    if (!strcmp(name, "item") || !strcmp(name, "entry")) {
        if (!closing && !selfc) item_begin(f, p);
        else if (closing && p->in_item) item_end(f, p);
        return;
    }
    if (!p->in_item) return;
    if (!strcmp(name, "media:thumbnail") || (!strcmp(name, "media:content") && strstr(t, "image"))) {
        if (!closing) add_img(f, f->nposts, t, "url");
        return;
    }
    int field = !strcmp(name, "title") ? F_TITLE
        : !strcmp(name, "dc:creator") || !strcmp(name, "author") ? F_AUTHOR
        : !strcmp(name, "pubDate") || !strcmp(name, "published") ? F_DATE
        : !strcmp(name, "description") || !strcmp(name, "summary") ? F_DESC
        : !strcmp(name, "content:encoded") || !strcmp(name, "content") ? F_CONTENT : F_NONE;
    if (field == F_NONE) return;
    if (!closing && !selfc) field_begin(f, p, field);
    else if (closing && p->field == field) field_end(f, p);
}

static void xml_text(feed_t *f, fd_parser_t *p, unsigned char c)
{
    if (p->field != F_NONE) html_byte(f, p, c);
}

// Code point -> UTF-8 into the HTML layer (an XML entity's value).
static void xml_cp(feed_t *f, fd_parser_t *p, uint32_t cp)
{
    if (cp < 0x80) xml_text(f, p, (unsigned char)cp);
    else if (cp < 0x800) xml_text(f, p, 0xC0 | cp >> 6), xml_text(f, p, 0x80 | (cp & 0x3F));
    else if (cp < 0x10000)
        xml_text(f, p, 0xE0 | cp >> 12), xml_text(f, p, 0x80 | (cp >> 6 & 0x3F)), xml_text(f, p, 0x80 | (cp & 0x3F));
    else
        xml_text(f, p, 0xF0 | cp >> 18), xml_text(f, p, 0x80 | (cp >> 12 & 0x3F)),
            xml_text(f, p, 0x80 | (cp >> 6 & 0x3F)), xml_text(f, p, 0x80 | (cp & 0x3F));
}

bool fd_parse(feed_t *f, const char *data, int n)
{
    fd_parser_t *p = &f->ps;
    for (int i = 0; i < n && !p->done; i++) {
        unsigned char c = (unsigned char)data[i];
        switch (p->xs) {
        case X_TEXT:
            if (c == '<') p->xs = X_TAG, p->tn = 0;
            else if (c == '&') p->xs = X_ENT, p->en = 0;
            else xml_text(f, p, c);
            break;
        case X_ENT:
            if (c == ';') {
                p->xs = X_TEXT;
                p->ent[p->en] = 0;
                uint32_t cp = entity(p->ent, p->en);
                if (cp == '&') { // "&amp;" stays an escape for the HTML layer: "&amp;lt;" is a literal "<"
                    for (const char *s = "&amp;"; *s; s++) xml_text(f, p, (unsigned char)*s);
                } else if (cp) {
                    xml_cp(f, p, cp);
                }
            } else if (p->en < 10) {
                p->ent[p->en++] = (char)c;
            } else {
                p->xs = X_TEXT;
            }
            break;
        case X_TAG:
            if (c == '>') {
                p->xs = X_TEXT;
                xml_tag(f, p);
                break;
            }
            if (p->tn < FD_TAG - 1) p->tag[p->tn++] = (char)c;
            if (p->tn == 8 && !memcmp(p->tag, "![CDATA[", 8)) p->xs = X_CDATA, p->brackets = 0;
            else if (p->tn == 3 && !memcmp(p->tag, "!--", 3)) p->xs = X_COMMENT, p->brackets = 0;
            break;
        case X_CDATA:
            if (c == ']') {
                if (++p->brackets > 2) xml_text(f, p, ']'), p->brackets = 2;
            } else if (c == '>' && p->brackets == 2) {
                p->xs = X_TEXT;
            } else {
                for (; p->brackets; p->brackets--) xml_text(f, p, ']');
                xml_text(f, p, c);
            }
            break;
        case X_COMMENT:
            if (c == '-') p->brackets++;
            else if (c == '>' && p->brackets >= 2) p->xs = X_TEXT;
            else p->brackets = 0;
            break;
        }
    }
    return p->done;
}

// ---- images ----------------------------------------------------------------------

bool fd_decode(fd_img_t *m, const uint8_t *data, int n)
{
    int sw, sh, ch;
    if (!stbi_info_from_memory(data, n, &sw, &sh, &ch)) return false;
    if (sw <= 0 || sh <= 0 || (long)sw * sh > 4L * 1024 * 1024) return false; // too big to decode
    uint8_t *src = stbi_load_from_memory(data, n, &sw, &sh, &ch, 1);
    if (!src) return false;
    // fit into the box, at most 1.5x up
    int w = m->bw, h = (int)((long)sh * m->bw / sw);
    if (h > m->bh) h = m->bh, w = (int)((long)sw * m->bh / sh);
    if (w > sw * 3 / 2) w = sw * 3 / 2, h = sh * 3 / 2;
    if (w < 1) w = 1;
    if (h < 1) h = 1;
    int16_t *g = fd_alloc(w * h * 2);
    int st = (w + 7) / 8;
    uint8_t *bits = fd_alloc(st * h);
    if (!g || !bits) {
        fd_free(g);
        fd_free(bits);
        stbi_image_free(src);
        return false;
    }
    memset(bits, 0, st * h);
    for (int y = 0; y < h; y++) {
        int y0 = (int)((long)y * sh / h), y1 = (int)((long)(y + 1) * sh / h);
        if (y1 <= y0) y1 = y0 + 1;
        for (int x = 0; x < w; x++) {
            int x0 = (int)((long)x * sw / w), x1 = (int)((long)(x + 1) * sw / w);
            if (x1 <= x0) x1 = x0 + 1;
            int sum = 0, k = 0;
            for (int yy = y0; yy < y1; yy++)
                for (int xx = x0; xx < x1; xx++) sum += src[yy * sw + xx], k++;
            g[y * w + x] = (int16_t)(sum / k);
        }
    }
    stbi_image_free(src);
    // lift the shadows (gamma 0.7): dithered photos come out dark on e-paper
    static uint8_t lut[256];
    if (!lut[255])
        for (int i = 0; i < 256; i++) lut[i] = (uint8_t)(255.0f * powf(i / 255.0f, 0.7f) + 0.5f);
    for (int i = 0; i < w * h; i++) g[i] = lut[g[i]];
    // Atkinson dither (3/4 of the error spread: crisp on e-paper)
    static const int8_t dx[] = {1, 2, -1, 0, 1, 0}, dy[] = {0, 0, 1, 1, 1, 2};
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            int16_t *q = &g[y * w + x];
            int v = *q < 128 ? 0 : 255, er = (*q - v) / 8;
            if (!v) bits[y * st + x / 8] |= 0x80 >> (x & 7);
            for (int k = 0; k < 6; k++)
                if (x + dx[k] >= 0 && x + dx[k] < w && y + dy[k] < h) q[dy[k] * w + dx[k]] += er;
        }
    fd_free(g);
    m->w = (int16_t)w;
    m->h = (int16_t)h;
    m->bits = bits;
    return true;
}

// ---- layout and screens -----------------------------------------------------------

#define X0 24
#define X1 (G_W - 24)
#define PAGE_Y0 (G_BAR + 10)
#define PAGE_Y1 (G_H - 30)

static void add_line(feed_t *f, const char *s, int n, int h, int scale, int img)
{
    if (f->nl >= FD_MAXL) return;
    f->lines[f->nl].s = s;
    f->lines[f->nl].n = (int16_t)n;
    f->lines[f->nl].h = (int16_t)h;
    f->lines[f->nl].scale = (int8_t)scale;
    f->lines[f->nl].img = (int8_t)img;
    f->nl++;
}

static void meta(char *o, int n, const fd_post_t *p)
{
    snprintf(o, n, "%s%s%s", p->author, p->author[0] && p->date[0] ? ", " : "", p->date);
}

static char s_head[96];

int fd_layout(feed_t *f, int i)
{
    const char *t;
    fd_post_t *po = &f->posts[i];
    f->nl = 0;
    f->open_post = i;
    int cols3 = (X1 - X0 + 3) / 18, cols2 = (X1 - X0 + 2) / 12;
    for (const char *s = po->title; *s; s = t) {
        add_line(f, s, g_cut(s, cols3, &t), 30, 3, -1);
        if (*t == '\n') t++;
    }
    meta(s_head, sizeof s_head, po);
    if (s_head[0]) add_line(f, s_head, (int)strlen(s_head), 30, 2, -1);
    add_line(f, NULL, 0, 8, 0, -1);
    for (const char *s = po->body; *s; s = t) {
        unsigned char c = (unsigned char)*s;
        if (c >= 0x80) { // an image
            int k = c - 0x80;
            if (k < f->nimg) add_line(f, NULL, 0, f->imgs[k].bh + 14, 0, k);
            t = s + 1;
            if (*t == '\n') t++;
            continue;
        }
        int n = g_cut(s, cols2, &t);
        add_line(f, s, n, 22, 2, -1);
        if (*t == '\n') {
            t++;
            add_line(f, NULL, 0, 10, 0, -1); // paragraph gap
        }
    }
    // pages
    f->npages = 0;
    int top = 0;
    while (top < f->nl && f->npages < (int)(sizeof f->page_top / sizeof *f->page_top)) {
        f->page_top[f->npages++] = top;
        int y = PAGE_Y0, k = top;
        while (k < f->nl && y + f->lines[k].h <= PAGE_Y1) y += f->lines[k++].h;
        if (k == top) k++; // taller than a page: alone
        while (k < f->nl && f->lines[k].s == NULL && f->lines[k].img < 0) k++; // no gaps at a page top
        top = k;
    }
    if (!f->npages) f->page_top[f->npages++] = 0;
    return f->npages;
}

// Image k at y, centred in the column; a placeholder while it is not in.
static void picture(feed_t *f, uint8_t *pl, int k, int y)
{
    fd_img_t *m = &f->imgs[k];
    if (m->state > 0 && m->bits) {
        g_blit(pl, (G_W - m->w) / 2, y, m->bits, m->w, m->h);
        return;
    }
    int x = (G_W - m->bw) / 2;
    g_frame(pl, x, y, m->bw, m->bh, 2);
    g_text(pl, x + 16, y + 16, 2, m->state < 0 ? "(no image)" : "(image loading)", true);
}

void fd_draw_page(feed_t *f, uint8_t *pl, const char *name, int i, int page)
{
    char info[48];
    if (f->open_post != i) fd_layout(f, i);
    if (page >= f->npages) page = f->npages - 1;
    if (page < 0) page = 0;
    g_clear(pl);
    snprintf(info, sizeof info, "POST %d/%d  PAGE %d/%d", i + 1, f->nposts, page + 1, f->npages);
    int top = f->page_top[page], end = page + 1 < f->npages ? f->page_top[page + 1] : f->nl;
    int y = PAGE_Y0;
    for (int k = top; k < end; y += f->lines[k++].h) {
        if (f->lines[k].s) g_text_n(pl, X0, y, f->lines[k].scale, f->lines[k].s, f->lines[k].n, true);
        else if (f->lines[k].img >= 0) picture(f, pl, f->lines[k].img, y + 2);
    }
    if (f->npages > 1) { // scroll bar
        int sh = PAGE_Y1 - PAGE_Y0;
        g_rect(pl, G_W - 12, PAGE_Y0 + sh * top / f->nl, 6, sh * (end - top) / f->nl + 1, true);
    }
    g_hint(pl, "KNOB OR MENU -/+: SCROLL", info);
}

void fd_draw_card(feed_t *f, uint8_t *pl, const char *name, int i)
{
    char s[128];
    fd_post_t *po = &f->posts[i];
    g_clear(pl);
    int y = G_BAR + 4;
    if (po->cover >= 0) {
        fd_img_t *m = &f->imgs[po->cover];
        picture(f, pl, po->cover, y);
        y += (m->state > 0 ? m->h : m->bh) + 10;
        y = g_wrap(pl, X0, y, X1 - X0, 3, 30, 2, po->title, true);
    } else {
        y = g_wrap(pl, X0, y + 30, X1 - X0, 5, 48, 5, po->title, true) + 16;
        // a few lines of the text instead of a picture
        const char *b = po->body;
        y = g_wrap(pl, X0, y, X1 - X0, 2, 24, (G_H - 70 - y) / 24, b, true);
    }
    meta(s, sizeof s, po);
    g_text(pl, X0, y + 2, 2, s, true);
    snprintf(s, sizeof s, "%s  %d/%d", name, i + 1, f->nposts);
    g_hint(pl, "KNOB OR MENU -/+: BROWSE", s);
}

void fd_draw_message(uint8_t *pl, const char *name, const char *big, const char *small)
{
    g_clear(pl);
    g_wrap(pl, 48, G_BAR + 80, G_W - 96, 5, 50, 3, big, true);
    if (small) g_wrap(pl, 48, G_BAR + 260, G_W - 96, 3, 32, 8, small, true);
    g_hint(pl, NULL, name);
}
