// The Settings web pages as HTML (main/settings.c serves them), portable C
// so the host can render them (test/apps/settings_pages.py). Every page is
// built whole in memory and sent with one httpd_resp_send (Content-Length):
// the old page-by-many-chunks code lost the end of /robots on the badge.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    char *p;
    int n, cap;
    bool oom; // an allocation failed: the page is incomplete, send an error
    void *(*grow)(void *old, size_t n); // realloc
} html_t;

void html_init(html_t *h, void *(*grow)(void *old, size_t n));
void html_put(html_t *h, const char *s);
void html_putn(html_t *h, const char *s, int n);
void html_printf(html_t *h, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
// s escaped for text and attribute values (only printable ASCII kept)
void html_esc(html_t *h, const char *s);
// s[0, n] escaped for a <textarea> (keeps newlines and tabs)
void html_text(html_t *h, const char *s, int n);

// Pages. The robot slots come from main/robots.c's cr_robot_* (the host
// test provides its own).
typedef struct {
    const char *msg;          // "" none
    const char *line1, *line2; // nametag
    const char *ssid;
    bool net, autojoin;
} html_root_t;
void html_root(html_t *h, const html_root_t *v);
// slot list, then the editor with src[0, n] for `slot`
void html_robots(html_t *h, int slot, const char *src, int n, const char *msg);
extern const char html_compete[];
extern const int html_compete_len;
