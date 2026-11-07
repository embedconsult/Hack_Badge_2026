// SNAKES arena, portable part: see snakes.h. Our own code; the JSON shapes
// follow the open snake-bot move API so existing bots work unchanged.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdarg.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>
#include "cJSON.h"
#include "snakes.h"

#ifdef ESP_PLATFORM
#include "esp_timer.h"
int64_t snk_now_ms(void) { return esp_timer_get_time() / 1000; }
#else
#include <time.h>
int64_t snk_now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
#endif

// ---- bot list / shell ----------------------------------------------------------

static bool name_ok(const char *s, int n)
{
    if (n < 1 || n >= SNK_NAME) return false;
    for (int i = 0; i < n; i++) {
        char c = s[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.'))
            return false;
    }
    return true;
}

static int find(const snk_cfg_t *c, const char *name, int n)
{
    for (int i = 0; i < c->n; i++)
        if ((int)strlen(c->bot[i].name) == n && !strncasecmp(c->bot[i].name, name, n)) return i;
    return -1;
}

static int word(const char **p, const char **w)
{
    while (**p == ' ') (*p)++;
    *w = *p;
    while (**p && **p != ' ') (*p)++;
    return (int)(*p - *w);
}

static bool is(const char *w, int n, const char *s) { return (int)strlen(s) == n && !strncasecmp(w, s, n); }

#define USAGE "usage: snakes list | snakes add <name> <http://host:port[/path]> | snakes rm <name|#> | snakes play\n" \
              "       snakes league [games] | snakes league show | snakes league reset\n"

int snk_cmd(const char *args, snk_cfg_t *c, char *msg, int n)
{
    const char *p = args, *w, *a, *b;
    int wn = word(&p, &w);
    msg[0] = 0;
    if (wn == 0 || is(w, wn, "list") || is(w, wn, "ls")) {
        int k = snprintf(msg, n, "snakes: %d bot%s saved (of %d), plus the house snake\n", c->n, c->n == 1 ? "" : "s", SNK_BOTS);
        for (int i = 0; i < c->n && k < n; i++)
            k += snprintf(msg + k, n - k, "  %d %-15s %s\n", i + 1, c->bot[i].name, c->bot[i].url);
        return 0;
    }
    if (is(w, wn, "add")) {
        int an = word(&p, &a), bn = word(&p, &b);
        snk_url_t u;
        char url[SNK_URL];
        if (!name_ok(a, an) || bn < 8 || bn >= SNK_URL) {
            snprintf(msg, n, "snakes add <name> <url>: name 1..%d of A-Z a-z 0-9 - _ ., url up to %d chars\n", SNK_NAME - 1, SNK_URL - 1);
            return -1;
        }
        memcpy(url, b, bn);
        url[bn] = 0;
        if (!snk_parse_url(url, &u)) {
            snprintf(msg, n, "snakes: not a bot URL: %s (http://host:port[/path] or https://...)\n", url);
            return -1;
        }
        if (is(a, an, "house")) {
            snprintf(msg, n, "snakes: \"house\" is the built-in snake's name\n");
            return -1;
        }
        int i = find(c, a, an);
        if (i < 0) {
            if (c->n >= SNK_BOTS) {
                snprintf(msg, n, "snakes: %d bots saved already (snakes rm <name> first)\n", SNK_BOTS);
                return -1;
            }
            i = c->n++;
        }
        memcpy(c->bot[i].name, a, an);
        c->bot[i].name[an] = 0;
        snprintf(c->bot[i].url, SNK_URL, "%s", url);
        snprintf(msg, n, "snakes: %s = %s (saved)\n", c->bot[i].name, c->bot[i].url);
        return 1;
    }
    if (is(w, wn, "rm") || is(w, wn, "del") || is(w, wn, "remove")) {
        int an = word(&p, &a);
        int i = find(c, a, an);
        if (i < 0 && an > 0 && an < 3) {
            int k = atoi(a);
            if (k >= 1 && k <= c->n) i = k - 1;
        }
        if (i < 0) {
            snprintf(msg, n, "snakes: no bot \"%.*s\" (snakes list)\n", an > 20 ? 20 : an, a);
            return -1;
        }
        snprintf(msg, n, "snakes: removed %s (saved)\n", c->bot[i].name);
        memmove(&c->bot[i], &c->bot[i + 1], (c->n - i - 1) * sizeof c->bot[0]);
        c->n--;
        memset(&c->bot[c->n], 0, sizeof c->bot[0]);
        return 1;
    }
    if (is(w, wn, "play") || is(w, wn, "start")) {
        snprintf(msg, n, "snakes: starting a game\n");
        return 2;
    }
    if (is(w, wn, "league")) {
        int an = word(&p, &a);
        if (an && is(a, an, "reset")) {
            snprintf(msg, n, "snakes: league table cleared\n");
            return 4;
        }
        if (an && (is(a, an, "show") || is(a, an, "table"))) return 5;
        int g = an ? atoi(a) : 5;
        if (g < 1 || g > 100) {
            snprintf(msg, n, "snakes league [games 1..100]\n");
            return -1;
        }
        snprintf(msg, n, "snakes: league of %d games: every saved bot and the house snake\n", g);
        return 3;
    }
    snprintf(msg, n, USAGE);
    return is(w, wn, "help") ? 0 : -1;
}

int snk_cmd_league(const char *args, int *games)
{
    const char *p = args, *w, *a;
    int wn = word(&p, &w);
    int an = word(&p, &a);
    *games = 5;
    if (!is(w, wn, "league")) return -1;
    if (an && is(a, an, "reset")) return 4;
    if (an && (is(a, an, "show") || is(a, an, "table"))) return 5;
    *games = an ? atoi(a) : 5;
    return *games >= 1 && *games <= 100 ? 3 : -1;
}

// ---- league -----------------------------------------------------------------------

void snk_league_reset(snk_league_t *L)
{
    memset(L, 0, sizeof *L);
    L->magic = SNK_LG_MAGIC;
}

static int lg_find(snk_league_t *L, const char *name)
{
    for (int i = 0; i < L->n; i++)
        if (!strcmp(L->e[i].name, name)) return i;
    int i = L->n;
    if (i >= SNK_LG) { // full: the entry with the fewest games goes
        i = 0;
        for (int k = 1; k < SNK_LG; k++)
            if (L->e[k].games < L->e[i].games) i = k;
    } else {
        L->n++;
    }
    memset(&L->e[i], 0, sizeof L->e[i]);
    snprintf(L->e[i].name, SNK_NAME, "%s", name);
    L->e[i].elo = SNK_ELO0;
    return i;
}

// 400-point logistic expectation without libm: 1 / (1 + 10^(d / 400)).
static double expect(double d)
{
    double x = d / 400.0 * 2.302585092994046; // ln 10
    if (x > 30) x = 30;
    if (x < -30) x = -30;
    double e = 1, t = 1; // exp(x), series on x / 32 then squared 5 times
    double y = x / 32;
    for (int k = 1; k < 12; k++) t *= y / k, e += t;
    for (int k = 0; k < 5; k++) e *= e;
    return 1 / (1 + e);
}

void snk_league_game(snk_league_t *L, int n, const char *const *name, const int *score)
{
    if (L->magic != SNK_LG_MAGIC) snk_league_reset(L);
    if (n < 2 || n > SNK_SLOTS) return;
    int ix[SNK_SLOTS];
    for (int i = 0; i < n; i++) ix[i] = lg_find(L, name[i]);
    double delta[SNK_SLOTS] = {0};
    double k = 32.0 / (n - 1);
    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++) {
            if (i == j) continue;
            double s = score[i] > score[j] ? 1 : score[i] == score[j] ? 0.5 : 0;
            delta[i] += k * (s - expect(L->e[ix[j]].elo - L->e[ix[i]].elo));
        }
    for (int i = 0; i < n; i++) {
        snk_lg_ent_t *e = &L->e[ix[i]];
        e->elo += (int32_t)(delta[i] + (delta[i] >= 0 ? 0.5 : -0.5));
        e->games++;
        bool top = true;
        for (int j = 0; j < n; j++) {
            if (j == i) continue;
            if (score[j] >= score[i]) top = false;
            if (score[i] > score[j]) e->points++;
        }
        if (top) e->wins++;
    }
    L->games++;
}

int snk_league_order(const snk_league_t *L, int *order)
{
    int n = L->magic == SNK_LG_MAGIC ? L->n : 0;
    for (int i = 0; i < n; i++) order[i] = i;
    for (int i = 1; i < n; i++)
        for (int j = i; j > 0; j--) {
            const snk_lg_ent_t *a = &L->e[order[j]], *b = &L->e[order[j - 1]];
            bool better = a->elo != b->elo ? a->elo > b->elo : a->wins != b->wins ? a->wins > b->wins : a->games > b->games;
            if (!better) break;
            int t = order[j];
            order[j] = order[j - 1], order[j - 1] = t;
        }
    return n;
}

int snk_league_text(const snk_league_t *L, char *out, int n)
{
    int order[SNK_LG];
    int m = snk_league_order(L, order);
    int k = snprintf(out, n, "snakes league: %d games\n  #  bot              elo  games  wins  points\n",
                     L->magic == SNK_LG_MAGIC ? (int)L->games : 0);
    for (int i = 0; i < m && k < n; i++) {
        const snk_lg_ent_t *e = &L->e[order[i]];
        k += snprintf(out + k, n - k, "%3d  %-15s %5d %6d %5d %7d\n", i + 1, e->name, (int)e->elo, e->games, e->wins,
                      e->points);
    }
    return k < n ? k : n - 1;
}

bool snk_parse_url(const char *url, snk_url_t *u)
{
    memset(u, 0, sizeof *u);
    const char *p;
    if (!strncasecmp(url, "http://", 7)) p = url + 7, u->port = 80;
    else if (!strncasecmp(url, "https://", 8)) p = url + 8, u->port = 443, u->https = true;
    else return false;
    const char *h = p;
    while (*p && *p != ':' && *p != '/') p++;
    int hn = (int)(p - h);
    if (hn < 1 || hn >= (int)sizeof u->host) return false;
    memcpy(u->host, h, hn);
    if (*p == ':') {
        p++;
        int port = 0, digits = 0;
        while (*p >= '0' && *p <= '9') port = port * 10 + (*p++ - '0'), digits++;
        if (!digits || port < 1 || port > 65535) return false;
        u->port = port;
    }
    if (*p && *p != '/') return false;
    int pn = (int)strlen(p);
    while (pn > 0 && p[pn - 1] == '/') pn--;
    if (pn >= (int)sizeof u->path) return false;
    for (int i = 0; i < pn; i++)
        if (p[i] <= ' ' || p[i] > '~') return false;
    memcpy(u->path, p, pn);
    return true;
}

void snk_path(const snk_url_t *u, const char *ep, char *out, int n)
{
    snprintf(out, n, "%s/%s", u->path, ep);
}

// ---- JSON --------------------------------------------------------------------------

typedef struct {
    char *p;
    int n, k;
} out_t;

static void put(out_t *o, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void put(out_t *o, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    int r = o->k < o->n ? vsnprintf(o->p + o->k, o->n - o->k, fmt, ap) : 0;
    va_end(ap);
    o->k += r > 0 ? r : 0;
}

// a string with only safe characters (names are checked, shouts filtered)
static const char *safe(const char *s) { return s ? s : ""; }

static void put_snake(out_t *o, const snk_game_t *g, int i, const int32_t *s)
{
    int hp = s[1], len = s[2];
    const int32_t *b = s + 3;
    put(o, "{\"id\":\"snake-%d\",\"name\":\"%s\",\"health\":%d,\"body\":[", i + 1, safe(g->name[i]), (int)hp);
    for (int k = 0; k < len; k++) put(o, "%s{\"x\":%d,\"y\":%d}", k ? "," : "", (int)b[2 * k], (int)b[2 * k + 1]);
    put(o, "],\"latency\":\"%d\",\"head\":{\"x\":%d,\"y\":%d},\"length\":%d,\"shout\":\"%s\",\"squad\":\"\","
           "\"customizations\":{\"color\":\"#000000\",\"head\":\"default\",\"tail\":\"default\"}}",
        g->latency[i], len ? (int)b[0] : 0, len ? (int)b[1] : 0, (int)len, safe(g->shout[i]));
}

int snk_json_turn(const snk_game_t *g, const int32_t *snap, int nsnap, char *out, int n, int *you_off, int *you_len)
{
    if (nsnap < 3) return -1;
    int turn = snap[0], ns = snap[1], nf = snap[2];
    if (ns > SNK_SLOTS || 3 + 2 * nf > nsnap) return -1;
    out_t o = {out, n, 0};
    put(&o, "{\"game\":{\"id\":\"%s\",\"ruleset\":{\"name\":\"standard\",\"version\":\"badge-1\",\"settings\":"
            "{\"foodSpawnChance\":15,\"minimumFood\":1,\"hazardDamagePerTurn\":0}},\"map\":\"standard\","
            "\"timeout\":%d,\"source\":\"custom\"},\"turn\":%d,\"board\":{\"height\":11,\"width\":11,\"food\":[",
        safe(g->game_id), g->timeout_ms, turn);
    for (int k = 0; k < nf; k++) put(&o, "%s{\"x\":%d,\"y\":%d}", k ? "," : "", (int)snap[3 + 2 * k], (int)snap[4 + 2 * k]);
    put(&o, "],\"hazards\":[],\"snakes\":[");
    // where each snake's record starts
    const int32_t *rec[SNK_SLOTS];
    int p = 3 + 2 * nf;
    for (int i = 0; i < ns; i++) {
        if (p + 3 > nsnap || p + 3 + 2 * snap[p + 2] > nsnap) return -1;
        rec[i] = snap + p;
        p += 3 + 2 * snap[p + 2];
    }
    bool first = true;
    for (int i = 0; i < ns; i++) {
        if (!rec[i][0]) continue; // eliminated: off the board
        if (!first) put(&o, ",");
        first = false;
        you_off[i] = o.k;
        put_snake(&o, g, i, rec[i]);
        you_len[i] = o.k - you_off[i];
    }
    put(&o, "]}");
    int common = o.k;
    for (int i = 0; i < ns; i++) {
        if (rec[i][0]) continue;
        you_off[i] = o.k;
        put_snake(&o, g, i, rec[i]);
        you_len[i] = o.k - you_off[i];
    }
    if (o.k >= n) return -1;
    return common;
}

int snk_json_body(const char *turn_json, int common, int you_off, int you_len, char *dst, int n)
{
    int need = common + 7 + you_len + 1;
    if (need >= n) return -1;
    memcpy(dst, turn_json, common);
    memcpy(dst + common, ",\"you\":", 7);
    memcpy(dst + common + 7, turn_json + you_off, you_len);
    dst[need - 1] = '}';
    dst[need] = 0;
    return need;
}

int snk_parse_move(const char *body, char *shout, int n)
{
    if (shout && n > 0) shout[0] = 0;
    cJSON *j = cJSON_Parse(body);
    if (!j) return -1;
    int d = -1;
    cJSON *m = cJSON_GetObjectItemCaseSensitive(j, "move");
    if (cJSON_IsString(m)) {
        const char *s = m->valuestring;
        if (!strcasecmp(s, "up")) d = 0;
        else if (!strcasecmp(s, "down")) d = 1;
        else if (!strcasecmp(s, "left")) d = 2;
        else if (!strcasecmp(s, "right")) d = 3;
    }
    cJSON *sh = cJSON_GetObjectItemCaseSensitive(j, "shout");
    if (shout && n > 0 && cJSON_IsString(sh)) {
        int k = 0;
        for (const char *s = sh->valuestring; *s && k < n - 1; s++)
            if (*s >= ' ' && *s <= '~' && *s != '"' && *s != '\\') shout[k++] = *s;
        shout[k] = 0;
    }
    cJSON_Delete(j);
    return d;
}

static void copy_str(cJSON *j, const char *key, char *out, int n)
{
    if (!out || n <= 0) return;
    out[0] = 0;
    cJSON *v = cJSON_GetObjectItemCaseSensitive(j, key);
    if (!cJSON_IsString(v)) return;
    int k = 0;
    for (const char *s = v->valuestring; *s && k < n - 1; s++)
        if (*s >= ' ' && *s <= '~') out[k++] = *s;
    out[k] = 0;
}

bool snk_parse_info(const char *body, char *author, int an, char *version, int vn)
{
    cJSON *j = cJSON_Parse(body);
    if (!j || !cJSON_IsObject(j)) {
        cJSON_Delete(j);
        return false;
    }
    copy_str(j, "author", author, an);
    copy_str(j, "version", version, vn);
    cJSON_Delete(j);
    return true;
}

// ---- HTTP ----------------------------------------------------------------------------

const char *snk_err_name(int e)
{
    switch (e) {
    case SNK_E_NONE: return "ok";
    case SNK_E_RESOLVE: return "unknown host";
    case SNK_E_CONNECT: return "refused";
    case SNK_E_TIMEOUT: return "timeout";
    case SNK_E_IO: return "i/o error";
    case SNK_E_HTTP: return "bad reply";
    case SNK_E_TOOBIG: return "reply too big";
    }
    return "?";
}

bool snk_resolve(const char *host, uint32_t *ip)
{
    struct in_addr a;
    if (inet_aton(host, &a)) {
        *ip = a.s_addr;
        return true;
    }
    struct addrinfo hints = {.ai_family = AF_INET, .ai_socktype = SOCK_STREAM}, *res = NULL;
    if (getaddrinfo(host, NULL, &hints, &res) != 0 || !res) return false;
    *ip = ((struct sockaddr_in *)res->ai_addr)->sin_addr.s_addr;
    freeaddrinfo(res);
    return true;
}

enum { RS_IDLE, RS_CONNECT, RS_SEND, RS_READ, RS_DONE };

static void finish(snk_req_t *r, int err, int64_t t0)
{
    if (r->fd >= 0) close(r->fd);
    r->fd = -1;
    r->err = err;
    r->ms = (int)(snk_now_ms() - t0);
    r->state = RS_DONE;
}

static int ci_find(const char *h, int n, const char *key) // header line offset after "key:", or -1
{
    int kn = (int)strlen(key);
    for (int i = 0; i + kn < n; i++) {
        if ((i == 0 || h[i - 1] == '\n') && !strncasecmp(h + i, key, kn)) {
            i += kn;
            while (i < n && h[i] == ' ') i++;
            return i;
        }
    }
    return -1;
}

// Headers in raw[0, hdr_end): status, Content-Length, chunked?
static bool parse_head(snk_req_t *r, int *chunked)
{
    if (strncmp(r->raw, "HTTP/1.", 7) || r->hdr_end < 12) return false;
    r->status = atoi(r->raw + 9);
    int i = ci_find(r->raw, r->hdr_end, "content-length:");
    r->clen = i >= 0 ? atoi(r->raw + i) : -1;
    i = ci_find(r->raw, r->hdr_end, "transfer-encoding:");
    *chunked = i >= 0 && !strncasecmp(r->raw + i, "chunked", 7);
    return true;
}

// raw body -> resp; true when the body is complete
static bool take_body(snk_req_t *r, bool chunked, bool eof)
{
    const char *b = r->raw + r->hdr_end;
    int bn = r->len - r->hdr_end;
    if (!chunked) {
        if (r->clen >= 0 && bn < r->clen && !eof) return false;
        if (r->clen < 0 && !eof) return false;
        if (r->clen >= 0 && bn > r->clen) bn = r->clen;
        memcpy(r->resp, b, bn);
        r->rn = bn;
        r->resp[bn] = 0;
        return true;
    }
    int k = 0, i = 0;
    for (;;) {
        int e = i;
        while (e + 1 < bn && !(b[e] == '\r' && b[e + 1] == '\n')) e++;
        if (e + 1 >= bn) return eof;
        int sz = (int)strtol(b + i, NULL, 16);
        i = e + 2;
        if (sz == 0) break;
        if (i + sz > bn) return eof;
        memcpy(r->resp + k, b + i, sz);
        k += sz;
        i += sz + 2;
    }
    r->rn = k;
    r->resp[k] = 0;
    return true;
}

void snk_http_batch(snk_req_t **rs, int n, int timeout_ms)
{
    int64_t t0 = snk_now_ms(), end = t0 + timeout_ms;
    for (int i = 0; i < n; i++) {
        snk_req_t *r = rs[i];
        r->status = 0, r->err = 0, r->chunked = 0, r->rn = 0, r->resp[0] = 0, r->len = 0, r->hdr_end = 0, r->off = 0;
        r->fd = -1;
        r->state = RS_CONNECT;
        int hn = snprintf(r->req, r->reqcap,
                          "%s %s HTTP/1.1\r\nHost: %s:%d\r\nUser-Agent: Hack_Badge_2026-snakes\r\n"
                          "Accept: application/json\r\nConnection: close\r\n",
                          r->method, r->path[0] ? r->path : "/", r->host, r->port);
        if (r->body)
            hn += snprintf(r->req + hn, r->reqcap - hn, "Content-Type: application/json\r\nContent-Length: %d\r\n", r->blen);
        hn += snprintf(r->req + hn, r->reqcap - hn, "\r\n");
        if (hn + (r->body ? r->blen : 0) > r->reqcap) { finish(r, SNK_E_TOOBIG, t0); continue; }
        if (r->body) memcpy(r->req + hn, r->body, r->blen), hn += r->blen;
        r->len = hn; // request length while sending
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) { finish(r, SNK_E_IO, t0); continue; }
        r->fd = fd;
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        struct sockaddr_in sa = {.sin_family = AF_INET, .sin_port = htons(r->port)};
        sa.sin_addr.s_addr = r->ip;
        if (connect(fd, (struct sockaddr *)&sa, sizeof sa) == 0) r->state = RS_SEND;
        else if (errno != EINPROGRESS) finish(r, SNK_E_CONNECT, t0);
    }
    for (;;) {
        fd_set rd, wr;
        FD_ZERO(&rd);
        FD_ZERO(&wr);
        int maxfd = -1, live = 0;
        for (int i = 0; i < n; i++) {
            snk_req_t *r = rs[i];
            if (r->state == RS_DONE || r->fd < 0) continue;
            live++;
            if (r->state == RS_READ) FD_SET(r->fd, &rd);
            else FD_SET(r->fd, &wr);
            if (r->fd > maxfd) maxfd = r->fd;
        }
        if (!live) return;
        int64_t left = end - snk_now_ms();
        if (left <= 0) break;
        struct timeval tv = {.tv_sec = left / 1000, .tv_usec = (left % 1000) * 1000};
        int k = select(maxfd + 1, &rd, &wr, NULL, &tv);
        if (k < 0 && errno != EINTR) break;
        if (k <= 0) continue;
        for (int i = 0; i < n; i++) {
            snk_req_t *r = rs[i];
            if (r->state == RS_DONE || r->fd < 0) continue;
            if (r->state == RS_CONNECT && FD_ISSET(r->fd, &wr)) {
                int e = 0;
                socklen_t el = sizeof e;
                getsockopt(r->fd, SOL_SOCKET, SO_ERROR, &e, &el);
                if (e) { finish(r, SNK_E_CONNECT, t0); continue; }
                r->state = RS_SEND;
            }
            if (r->state == RS_SEND && FD_ISSET(r->fd, &wr)) {
                int w = send(r->fd, r->req + r->off, r->len - r->off, 0);
                if (w < 0 && errno != EAGAIN && errno != EWOULDBLOCK) { finish(r, SNK_E_IO, t0); continue; }
                if (w > 0) r->off += w;
                if (r->off >= r->len) r->state = RS_READ, r->len = 0;
                continue;
            }
            if (r->state == RS_READ && FD_ISSET(r->fd, &rd)) {
                int room = SNK_RESP_MAX - 1 - r->len;
                if (room <= 0) { finish(r, SNK_E_TOOBIG, t0); continue; }
                int got = recv(r->fd, r->raw + r->len, room, 0);
                if (got < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) continue;
                bool eof = got <= 0;
                if (got > 0) r->len += got;
                r->raw[r->len] = 0;
                if (!r->hdr_end) {
                    char *h = strstr(r->raw, "\r\n\r\n");
                    if (h) {
                        r->hdr_end = (int)(h - r->raw) + 4;
                        if (!parse_head(r, &r->chunked)) { finish(r, SNK_E_HTTP, t0); continue; }
                    } else if (eof) {
                        finish(r, r->len ? SNK_E_HTTP : SNK_E_IO, t0);
                        continue;
                    }
                }
                if (r->hdr_end && take_body(r, r->chunked, eof)) {
                    finish(r, r->status >= 200 && r->status < 300 ? SNK_E_NONE : SNK_E_HTTP, t0);
                    continue;
                }
                if (eof) finish(r, SNK_E_HTTP, t0);
            }
        }
    }
    for (int i = 0; i < n; i++)
        if (rs[i]->state != RS_DONE) finish(rs[i], SNK_E_TIMEOUT, t0);
}

// ---- sessions ------------------------------------------------------------------------

#define SNK_JSON_MAX 12288

bool snk_session_alloc(snk_session_t *s, void *(*alloc)(int))
{
    if (!s->json) s->json = alloc(SNK_JSON_MAX);
    if (!s->body) s->body = alloc(SNK_REQ_MAX * SNK_BOTS);
    if (!s->req) {
        s->req = alloc(sizeof(snk_req_t) * SNK_BOTS);
        if (s->req) memset(s->req, 0, sizeof(snk_req_t) * SNK_BOTS);
    }
    if (!s->json || !s->body || !s->req) return false;
    for (int i = 0; i < SNK_BOTS; i++) {
        if (!s->req[i].req) s->req[i].req = alloc(SNK_REQ_MAX + 512);
        if (!s->req[i].req) return false;
        s->req[i].reqcap = SNK_REQ_MAX + 512;
        s->req[i].fd = -1;
    }
    return true;
}

void snk_session_reset(snk_session_t *s, int n, uint32_t seed)
{
    if (n > SNK_BOTS) n = SNK_BOTS;
    s->n = n;
    snprintf(s->game_id, sizeof s->game_id, "badge-%08x", (unsigned)seed);
    if (!s->timeout_ms) s->timeout_ms = 500;
    for (int i = 0; i < SNK_BOTS; i++) {
        s->bot[i] = false;
        s->resolved[i] = false;
        s->name[i][0] = 0;
        s->move[i] = -1;
        s->err[i] = 0;
        s->status[i] = 0;
        s->ms[i] = 0;
        s->shout[i][0] = 0;
        s->author[i][0] = 0;
        s->timeouts[i] = 0;
    }
}

void snk_session_set(snk_session_t *s, int i, const char *name, const char *url)
{
    if (i < 0 || i >= SNK_BOTS) return;
    snprintf(s->name[i], SNK_NAME, "%s", name);
    s->bot[i] = url && snk_parse_url(url, &s->url[i]);
    if (url && !s->bot[i]) s->err[i] = SNK_E_RESOLVE;
}

void snk_session_resolve(snk_session_t *s)
{
    for (int i = 0; i < s->n; i++)
        if (s->bot[i] && !s->url[i].https && !s->resolved[i]) {
            s->resolved[i] = snk_resolve(s->url[i].host, &s->ip[i]);
            s->err[i] = s->resolved[i] ? SNK_E_NONE : SNK_E_RESOLVE;
        }
}

// Snake i's alive flag in a snapshot (false if missing).
static bool snap_alive(const int32_t *snap, int nsnap, int i)
{
    if (nsnap < 3 || i >= snap[1]) return false;
    int p = 3 + 2 * snap[2];
    for (int k = 0; k < i; k++) {
        if (p + 3 > nsnap) return false;
        p += 3 + 2 * snap[p + 2];
    }
    return p + 3 <= nsnap && snap[p];
}

// Sends method <ep> to every slot with ask[i]: plain http all at once,
// then https ones (badge only) one by one. Bodies in s->body slot by slot.
static void run(snk_session_t *s, const bool *ask, const char *method, const char *ep, const int *blen, int timeout_ms)
{
    static char path[SNK_BOTS][112];
    snk_req_t *batch[SNK_BOTS];
    int nb = 0;
    for (int i = 0; i < s->n; i++) {
        if (!ask[i]) continue;
        snk_path(&s->url[i], ep, path[i], sizeof path[i]);
        if (s->url[i].https) continue;
        if (!s->resolved[i]) {
            s->err[i] = SNK_E_RESOLVE;
            s->status[i] = 0;
            s->req[i].rn = 0;
            s->req[i].resp[0] = 0;
            continue;
        }
        snk_req_t *r = &s->req[i];
        r->ip = s->ip[i];
        r->port = s->url[i].port;
        r->host = s->url[i].host;
        r->path = path[i];
        r->method = method;
        r->body = blen ? s->body + i * SNK_REQ_MAX : NULL;
        r->blen = blen ? blen[i] : 0;
        batch[nb++] = r;
    }
    if (nb) snk_http_batch(batch, nb, timeout_ms);
    for (int i = 0; i < s->n; i++) {
        if (!ask[i]) continue;
        snk_req_t *r = &s->req[i];
        if (s->url[i].https) {
            int64_t t0 = snk_now_ms();
            int st = s->https ? s->https(i, &s->url[i], method, path[i], blen ? s->body + i * SNK_REQ_MAX : NULL,
                                         blen ? blen[i] : 0, r->resp, SNK_RESP_MAX, timeout_ms)
                              : -SNK_E_CONNECT;
            r->ms = (int)(snk_now_ms() - t0);
            r->status = st > 0 ? st : 0;
            r->err = st < 0 ? -st : (st >= 200 && st < 300 ? SNK_E_NONE : SNK_E_HTTP);
            if (st <= 0) r->resp[0] = 0;
        } else if (!s->resolved[i]) {
            continue;
        }
        s->err[i] = r->err;
        s->status[i] = r->status;
        s->ms[i] = r->ms;
    }
}

void snk_session_info(snk_session_t *s, int timeout_ms)
{
    bool ask[SNK_BOTS] = {0};
    for (int i = 0; i < s->n; i++) ask[i] = s->bot[i];
    run(s, ask, "GET", "", NULL, timeout_ms);
    for (int i = 0; i < s->n; i++) {
        if (!ask[i]) continue;
        s->author[i][0] = 0;
        if (s->err[i] == SNK_E_NONE && !snk_parse_info(s->req[i].resp, s->author[i], sizeof s->author[i], NULL, 0))
            s->err[i] = SNK_E_HTTP;
    }
}

int snk_session_call(snk_session_t *s, const char *ep, const int32_t *snap, int nsnap, int timeout_ms)
{
    bool move = !strcmp(ep, "move");
    snk_game_t g = {.game_id = s->game_id, .timeout_ms = s->timeout_ms};
    for (int i = 0; i < s->n && i < SNK_SLOTS; i++) {
        g.name[i] = s->name[i];
        g.shout[i] = s->shout[i];
        g.latency[i] = s->bot[i] ? s->ms[i] : 0;
    }
    int off[SNK_SLOTS] = {0}, len[SNK_SLOTS] = {0}, blen[SNK_BOTS] = {0};
    int common = snk_json_turn(&g, snap, nsnap, s->json, SNK_JSON_MAX, off, len);
    if (common < 0) return 0;
    bool ask[SNK_BOTS] = {0};
    int asked = 0;
    for (int i = 0; i < s->n && i < SNK_SLOTS; i++) {
        if (move) s->move[i] = -1;
        if (!s->bot[i] || (move && !snap_alive(snap, nsnap, i))) continue;
        blen[i] = snk_json_body(s->json, common, off[i], len[i], s->body + i * SNK_REQ_MAX, SNK_REQ_MAX);
        if (blen[i] < 0) continue;
        ask[i] = true;
        asked++;
    }
    run(s, ask, "POST", ep, blen, timeout_ms);
    if (move)
        for (int i = 0; i < s->n && i < SNK_SLOTS; i++) {
            if (!ask[i]) continue;
            if (s->err[i] == SNK_E_NONE) s->move[i] = snk_parse_move(s->req[i].resp, s->shout[i], SNK_SHOUT);
            if (s->move[i] < 0) s->timeouts[i]++;
        }
    return asked;
}

// accessors for bindings that do not mirror the struct (host Crystal test)
int snk_host_size(void) { return sizeof(snk_session_t); }
int snk_host_move(const snk_session_t *s, int i) { return s->move[i]; }
int snk_host_err(const snk_session_t *s, int i) { return s->err[i]; }
int snk_host_ms(const snk_session_t *s, int i) { return s->ms[i]; }
