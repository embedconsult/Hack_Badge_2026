// Renders the Settings web pages (main/settings_html.c) on the host into
// <dir>/root.html, robots.html (8 full slots, long names with characters
// that need escaping, a long robot in the editor, a message),
// robots_empty.html and compete.html; test/apps/settings_pages.py checks them.
//   settings_pages <dir>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "settings_html.h"

int32_t cr_robot_slots(void) { return 8; }
int32_t cr_robot_len(int32_t k) { return getenv("EMPTY") ? -1 : 8000 - 7 * k; }
bool cr_robot_name(int32_t k, char *out)
{
    // 16 bytes, no terminator room to spare: as main/robots.c reads them
    static const char *names[] = {"Sniper<&>\"Quote'", "WWWWWWWWWWWWWWWW", "Rook", "Counter-Strike_9",
                                  "a&b&c&d&e&f&g&h&", "<script>alert(1)", "Zed", "LastSlotLongName"};
    memcpy(out, names[k & 7], 16);
    out[16] = 0;
    return true;
}

static void *grow(void *old, size_t n) { return realloc(old, n); }

static void save(const char *dir, const char *file, const char *p, int n)
{
    char path[512];
    snprintf(path, sizeof path, "%s/%s", dir, file);
    FILE *f = fopen(path, "wb");
    fwrite(p, 1, n, f);
    fclose(f);
}

int main(int argc, char **argv)
{
    const char *dir = argc > 1 ? argv[1] : ".";
    html_t h;
    html_root_t v = {"Saved.", "Jason<", "Kridner&Co", "my \"wifi\"", true, true};
    html_init(&h, grow);
    html_root(&h, &v);
    save(dir, "root.html", h.p, h.n);
    free(h.p);

    static char src[8200];
    int n = 0;
    while (n < 8000) n += snprintf(src + n, sizeof src - n, "x = 1 < 2 && 3 > 2 # line %d\n", n);
    html_init(&h, grow);
    html_robots(&h, 7, src, n, "Saved \"LastSlotLongName\" to slot 7.");
    save(dir, "robots.html", h.p, h.n);
    printf("robots.html: %d bytes%s\n", h.n, h.oom ? " (OUT OF MEMORY)" : "");
    free(h.p);

    setenv("EMPTY", "1", 1);
    html_init(&h, grow);
    html_robots(&h, 0, NULL, 0, NULL);
    save(dir, "robots_empty.html", h.p, h.n);
    free(h.p);

    save(dir, "compete.html", html_compete, html_compete_len);
    return 0;
}
