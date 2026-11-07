// Badge-link robot tournaments: see tourney_net.h and crystal/net/PROTOCOL.md (T).
#include <string.h>
#include <stdio.h>
#include "tourney_net.h"

#define RETRY_MS 400
#define ASK_TRIES 50        // 20 s of Q / O retries (a badge may be redrawing its e-paper)
#define FETCH_MS 60000      // sources must arrive within this
#define PLAN_EVERY_MS 1000
#define PLAN_FOR_MS 60000   // a badge that never acks the plan is left out
#define RESULT_MS 900000    // the slowest badge's whole tournament
#define JOIN_MS 120000      // a participant waits this long for the plan
#define W_REPEAT 3
#define PUSH_MAX 4          // B chunks per S request
#define W_MAX (10 + TN_BADGES + 2 + TN_ROBOTS * TN_ENTRY + 2)

enum { R_NONE = 0, R_ASK, R_ORG, R_PART };
enum { S_COLLECT = 1, S_FETCH, S_PLAN, S_DONE, S_FAIL, // organizer
       S_JOINED, S_GET, S_READY, S_RESULT };          // participant (S_DONE / S_FAIL too)

typedef struct {
    rn_addr_t addr;
    uint8_t mac[6];
    char name[13];
    bool e, ack, res, gone;
    uint32_t hash;
    int nmine;
    uint32_t crc[TN_MINE];
    uint16_t len[TN_MINE];
    int tries;
    int64_t next;
} badge_t;

#define HEAR_MS 2500 // asked to organize: listen to announces this long first

static const tn_io_t *s_io;
static struct {
    uint32_t tid;
    int64_t at;
    char name[13];
} s_near; // the last invitation not taken
static struct {
    bool on;
    int64_t at;
    uint32_t seed;
    int seeds;
    tn_peer_t asker;
} s_pend;
static uint8_t s_me[6];
static char s_myname[13];

static struct {
    int role, st;
    uint32_t tid, seed;
    int seeds;
    int nb, me; // badges (0 = organizer), my index
    badge_t b[TN_BADGES];
    int n;
    uint32_t crc[TN_ROBOTS];
    uint16_t len[TN_ROBOTS];
    uint8_t owner[TN_ROBOTS];
    int idx[TN_ROBOTS];
    bool taken, mine_done;
    uint32_t my_hash;
    uint8_t table[TN_ROBOTS * TN_ENTRY + 2];
    int tlen;
    uint8_t w[W_MAX];
    int wlen, w_sent;
    int64_t next, deadline;
    int tries;
    char why[40];
} T;

static void put32(uint8_t *p, uint32_t v) { p[0] = v, p[1] = v >> 8, p[2] = v >> 16, p[3] = v >> 24; }
static void put16(uint8_t *p, uint16_t v) { p[0] = v, p[1] = v >> 8; }
static uint32_t get32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t get16(const uint8_t *p) { return p[0] | p[1] << 8; }

static void event(int what)
{
    if (s_io && s_io->event) s_io->event(what);
}

void tn_set_me(const uint8_t me[6], const char *name)
{
    memcpy(s_me, me, 6);
    snprintf(s_myname, sizeof s_myname, "%s", name ? name : "");
}

static void reset(void)
{
    memset(&T, 0, sizeof T);
    rn_unpin_all();
}

void tn_init(const tn_io_t *io, const uint8_t me[6], const char *name)
{
    s_io = io;
    memset(&s_near, 0, sizeof s_near);
    tn_set_me(me, name);
    reset();
}

bool tn_may_join(bool autojoin, bool home_or_robots, int64_t idle_ms)
{
    return autojoin && (home_or_robots || idle_ms >= TN_IDLE_JOIN_MS);
}

bool tn_nearby(char *name, int max, int64_t now)
{
    if (!s_near.tid || now - s_near.at > TN_NEARBY_MS || (T.role == R_PART && T.tid == s_near.tid)) return false;
    if (name) snprintf(name, max, "%s", s_near.name);
    return true;
}

bool tn_busy(void) { return T.role != R_NONE && T.st != S_DONE && T.st != S_FAIL; }

static void fail(const char *why)
{
    T.st = S_FAIL;
    snprintf(T.why, sizeof T.why, "%s", why);
    rn_unpin_all();
    event(TN_EV_STATUS);
}

static void send_t(rn_addr_t to, char sub, const uint8_t *body, int n)
{
    static uint8_t b[600]; // callers hold the robonet lock
    if (n > (int)sizeof b - 5) return;
    b[0] = sub;
    put32(b + 1, T.tid);
    if (n) memcpy(b + 5, body, n);
    s_io->send(to, 'T', b, 5 + n);
}

static bool full(uint32_t crc, int len) { return rn_find(crc, len) >= 0; }

static int missing(void)
{
    int k = 0;
    for (int i = 0; i < T.n; i++)
        if (!full(T.crc[i], T.len[i])) k++;
    return k;
}

static void pin_plan(void)
{
    for (int i = 0; i < T.n; i++) {
        T.idx[i] = rn_find(T.crc[i], T.len[i]);
        rn_pin(T.idx[i], true);
    }
}

// Ask `to` for the robots still missing (S with the chunks we have).
static void request_missing(rn_addr_t to, int owner)
{
    for (int i = 0; i < T.n; i++) {
        if ((owner >= 0 && T.owner[i] != owner) || full(T.crc[i], T.len[i])) continue;
        uint8_t b[10];
        put32(b, T.crc[i]), put16(b + 4, T.len[i]), put32(b + 6, rn_got(T.crc[i], T.len[i]));
        send_t(to, 'S', b, 10);
    }
}

// ---- organizer ------------------------------------------------------------------

static void add_robot(uint32_t crc, int len, int owner)
{
    if (T.n >= TN_ROBOTS || len <= 0) return;
    for (int i = 0; i < T.n; i++)
        if (T.crc[i] == crc && T.len[i] == len) return; // the same robot twice: the first one counts
    T.crc[T.n] = crc, T.len[T.n] = len, T.owner[T.n] = owner;
    T.n++;
}

// asker: the badge that asked us to organize (O), in even if not heard yet
static void organize(uint32_t seed, int seeds, int64_t now, const tn_peer_t *asker)
{
    tn_peer_t p[TN_PEERS];
    int np = s_io->peers ? s_io->peers(p, TN_PEERS, now) : 0;
    if (asker) {
        int i = 0;
        while (i < np && memcmp(p[i].mac, asker->mac, 6)) i++;
        if (i == np && np < TN_PEERS) p[np++] = *asker;
        else if (i == np) p[np - 1] = *asker;
    }
    reset();
    T.role = R_ORG;
    T.seed = seed ? seed & 0x7FFFFFFFu : (((uint32_t)now * 2654435761u) & 0x7FFFFFFFu) | 1;
    T.seeds = seeds < 1 ? 1 : seeds > 4 ? 4 : seeds;
    T.tid = (T.seed * 2246822519u) ^ (uint32_t)now ^ get32(s_me + 2);
    if (!T.tid) T.tid = 1;
    memcpy(T.b[0].mac, s_me, 6);
    snprintf(T.b[0].name, sizeof T.b[0].name, "%s", s_myname);
    T.b[0].e = true;
    int idx[TN_MINE];
    int m = s_io->mine ? s_io->mine(idx, TN_MINE) : 0;
    for (int k = 0; k < m; k++) {
        int len;
        if (rn_info(idx[k], &T.b[0].crc[T.b[0].nmine], &len)) {
            rn_pin(idx[k], true);
            T.b[0].len[T.b[0].nmine++] = len;
        }
    }
    // the others in MAC order
    for (int i = 0; i < np; i++)
        for (int j = i + 1; j < np; j++)
            if (memcmp(p[j].mac, p[i].mac, 6) < 0) {
                tn_peer_t t = p[i];
                p[i] = p[j], p[j] = t;
            }
    T.nb = 1;
    for (int i = 0; i < np && T.nb < TN_BADGES; i++) {
        badge_t *b = &T.b[T.nb++];
        b->addr = p[i].addr;
        memcpy(b->mac, p[i].mac, 6);
        snprintf(b->name, sizeof b->name, "%s", p[i].name);
    }
    T.st = S_COLLECT;
    T.next = now;
    printf("tourney: organizing %08x with %d other badges, seed %u\n", (unsigned)T.tid, T.nb - 1, (unsigned)T.seed);
    event(TN_EV_STATUS);
}

static void make_plan(int64_t now)
{
    T.n = 0;
    for (int k = 0; k < T.nb; k++)
        for (int i = 0; i < T.b[k].nmine; i++) add_robot(T.b[k].crc[i], T.b[k].len[i], k);
    int idx[TN_ROBOTS];
    int m = s_io->builtins ? s_io->builtins(idx, TN_ROBOTS) : 0;
    for (int k = 0; k < m; k++) {
        uint32_t crc;
        int len;
        if (rn_info(idx[k], &crc, &len)) {
            rn_pin(idx[k], true);
            add_robot(crc, len, 255);
        }
    }
    T.st = S_FETCH;
    T.deadline = now + FETCH_MS;
    T.next = now;
    event(TN_EV_STATUS);
}

static void send_plan(rn_addr_t to)
{
    static uint8_t b[7 + TN_BADGES * 18 + TN_ROBOTS * 7];
    put32(b, T.seed);
    b[4] = T.seeds, b[5] = T.nb, b[6] = T.n;
    uint8_t *q = b + 7;
    for (int k = 0; k < T.nb; k++, q += 18) memcpy(q, T.b[k].mac, 6), memcpy(q + 6, T.b[k].name, 12);
    for (int i = 0; i < T.n; i++, q += 7) put32(q, T.crc[i]), put16(q + 4, T.len[i]), q[6] = T.owner[i];
    send_t(to, 'P', b, q - b);
}

static void start_play(int64_t now)
{
    pin_plan();
    T.st = T.role == R_ORG ? S_PLAN : S_READY;
    T.deadline = now + RESULT_MS;
    T.next = now;
    printf("tourney: %08x: %d robots, playing\n", (unsigned)T.tid, T.n);
    event(TN_EV_RUN);
}

static void build_w(void)
{
    uint8_t *w = T.w;
    w[0] = 'W';
    put32(w + 1, T.tid);
    put32(w + 5, T.my_hash);
    w[9] = T.nb;
    for (int k = 0; k < T.nb; k++) {
        badge_t *b = &T.b[k];
        w[10 + k] = k == 0 ? 1 : !b->res ? 2 : b->hash == T.my_hash ? 1 : 0;
    }
    int o = 10 + T.nb;
    put16(w + o, T.tlen);
    memcpy(w + o + 2, T.table, T.tlen);
    T.wlen = o + 2 + T.tlen;
}

static void send_w(rn_addr_t to)
{
    if (T.wlen) s_io->send(to, 'T', T.w, T.wlen);
}

static void finish_org(void)
{
    build_w();
    T.st = S_DONE;
    T.w_sent = 0;
    for (int k = 1; k < T.nb; k++)
        if (!T.b[k].gone) send_w(T.b[k].addr);
    rn_unpin_all();
    printf("tourney: %08x done\n", (unsigned)T.tid);
    event(TN_EV_DONE);
}

static void check_results(int64_t now)
{
    if (T.role != R_ORG || T.st != S_PLAN || !T.mine_done) return;
    for (int k = 1; k < T.nb; k++)
        if (!T.b[k].gone && !T.b[k].res && now < T.deadline) return;
    finish_org();
}

static void org_tick(int64_t now)
{
    if (T.st == S_COLLECT) {
        bool all = true;
        for (int k = 1; k < T.nb; k++) {
            badge_t *b = &T.b[k];
            if (b->e || b->gone) continue;
            all = false;
            if (now < b->next) continue;
            if (++b->tries > ASK_TRIES) {
                b->gone = true;
                printf("tourney: %s did not answer, left out\n", b->name);
                continue;
            }
            send_t(b->addr, 'Q', NULL, 0);
            b->next = now + RETRY_MS;
        }
        if (all) make_plan(now);
    } else if (T.st == S_FETCH) {
        if (now >= T.deadline) { // leave out what did not come
            int j = 0;
            for (int i = 0; i < T.n; i++)
                if (full(T.crc[i], T.len[i])) T.crc[j] = T.crc[i], T.len[j] = T.len[i], T.owner[j++] = T.owner[i];
            T.n = j;
        }
        if (!missing()) {
            if (T.n < 2) {
                fail("has too few robots");
                return;
            }
            start_play(now);
            for (int k = 1; k < T.nb; k++) T.b[k].next = now;
            return;
        }
        if (now >= T.next) {
            for (int k = 1; k < T.nb; k++)
                if (!T.b[k].gone) request_missing(T.b[k].addr, k);
            T.next = now + RETRY_MS;
        }
    } else if (T.st == S_PLAN) {
        for (int k = 1; k < T.nb; k++) {
            badge_t *b = &T.b[k];
            if (b->gone || b->ack || b->res || now < b->next) continue;
            if (now > T.deadline - RESULT_MS + PLAN_FOR_MS) {
                b->gone = true;
                printf("tourney: %s never took the plan, left out\n", b->name);
                continue;
            }
            send_plan(b->addr);
            b->next = now + PLAN_EVERY_MS;
        }
        check_results(now);
    } else if (T.st == S_DONE && T.w_sent < W_REPEAT && now >= T.next) {
        for (int k = 1; k < T.nb; k++)
            if (!T.b[k].gone && T.b[k].res) send_w(T.b[k].addr);
        T.w_sent++;
        T.next = now + PLAN_EVERY_MS;
    }
}

static badge_t *badge_of(const uint8_t mac[6])
{
    for (int k = 1; k < T.nb; k++)
        if (!memcmp(T.b[k].mac, mac, 6)) return &T.b[k];
    return NULL;
}

static void org_rx(rn_addr_t from, const uint8_t mac[6], char sub, const uint8_t *b, int n, int64_t now)
{
    badge_t *p = badge_of(mac);
    if (!p) return;
    p->addr = from;
    if (sub == 'E' && T.st == S_COLLECT && !p->e && n >= 1) {
        int m = b[0];
        if (m > TN_MINE || n < 1 + 6 * m) return;
        p->e = true;
        p->nmine = m;
        for (int i = 0; i < m; i++) p->crc[i] = get32(b + 1 + 6 * i), p->len[i] = get16(b + 5 + 6 * i);
        printf("tourney: %s brings %d robots\n", p->name, m);
        event(TN_EV_STATUS);
    } else if (sub == 'A' && T.st >= S_PLAN && n >= 1) {
        if (b[0] == 0) p->ack = true;
    } else if (sub == 'R' && (T.st == S_PLAN || T.st == S_DONE) && n >= 4) {
        if (!p->res) {
            p->res = true, p->ack = true;
            p->hash = get32(b);
            printf("tourney: %s's result %08x\n", p->name, (unsigned)p->hash);
            event(TN_EV_STATUS);
        }
        if (T.st == S_DONE) send_w(from); // it lacks the standings
        else check_results(now);
    }
}

// ---- participant ------------------------------------------------------------------

static void join(rn_addr_t from, const uint8_t mac[6], const char *name, uint32_t tid, int64_t now)
{
    reset();
    T.role = R_PART;
    T.tid = tid;
    T.b[0].addr = from;
    memcpy(T.b[0].mac, mac, 6);
    snprintf(T.b[0].name, sizeof T.b[0].name, "%s", name);
    int idx[TN_MINE];
    int m = s_io->mine ? s_io->mine(idx, TN_MINE) : 0;
    for (int k = 0; k < m; k++) {
        int len;
        if (rn_info(idx[k], &T.b[0].crc[T.b[0].nmine], &len)) { // b[0] holds MY robots until the plan
            rn_pin(idx[k], true);
            T.b[0].len[T.b[0].nmine++] = len;
        }
    }
    T.st = S_JOINED;
    T.deadline = now + JOIN_MS;
    printf("tourney: joined %s's tournament %08x with %d robots\n", name, (unsigned)tid, T.b[0].nmine);
    event(TN_EV_STATUS);
}

static void send_e(void)
{
    uint8_t b[1 + 6 * TN_MINE];
    b[0] = T.b[0].nmine;
    for (int i = 0; i < T.b[0].nmine; i++) put32(b + 1 + 6 * i, T.b[0].crc[i]), put16(b + 5 + 6 * i, T.b[0].len[i]);
    send_t(T.b[0].addr, 'E', b, 1 + 6 * T.b[0].nmine);
}

static void send_a(void)
{
    uint8_t m = missing();
    send_t(T.b[0].addr, 'A', &m, 1);
}

static void part_rx(rn_addr_t from, const uint8_t mac[6], char sub, const uint8_t *b, int n, int64_t now)
{
    if (memcmp(mac, T.b[0].mac, 6)) return;
    T.b[0].addr = from;
    if (sub == 'Q') {
        if (T.st == S_JOINED) send_e();
    } else if (sub == 'P' && n >= 7) {
        if (T.st != S_JOINED) { // ours got lost
            send_a();
            return;
        }
        int nb = b[5], cnt = b[6];
        if (nb < 1 || nb > TN_BADGES || cnt < 2 || cnt > TN_ROBOTS || n < 7 + 18 * nb + 7 * cnt) return;
        T.seed = get32(b), T.seeds = b[4], T.nb = nb, T.n = cnt;
        const uint8_t *q = b + 7;
        T.me = -1;
        for (int k = 0; k < nb; k++, q += 18) {
            memcpy(T.b[k].mac, q, 6);
            memcpy(T.b[k].name, q + 6, 12);
            T.b[k].name[12] = 0;
            if (!memcmp(q, s_me, 6)) T.me = k;
        }
        for (int i = 0; i < cnt; i++, q += 7) T.crc[i] = get32(q), T.len[i] = get16(q + 4), T.owner[i] = q[6];
        T.st = S_GET;
        T.deadline = now + FETCH_MS;
        T.next = now;
        if (!missing()) start_play(now);
        send_a();
        event(TN_EV_STATUS);
    } else if (sub == 'W' && (T.st == S_RESULT || T.st == S_READY) && n >= 5) {
        int nb = b[4];
        if (nb != T.nb || n < 7 + nb) return;
        int tl = get16(b + 5 + nb);
        if (tl > (int)sizeof T.table || n < 7 + nb + tl) return;
        T.wlen = 5 + n < (int)sizeof T.w ? 5 + n : (int)sizeof T.w;
        T.w[0] = 'W';
        put32(T.w + 1, T.tid);
        memcpy(T.w + 5, b, T.wlen - 5);
        T.st = S_DONE;
        rn_unpin_all();
        printf("tourney: %08x standings from %s\n", (unsigned)T.tid, T.b[0].name);
        event(TN_EV_DONE);
    }
}

static void part_tick(int64_t now)
{
    if ((T.st == S_JOINED || T.st == S_GET) && now >= T.deadline) {
        fail(T.st == S_JOINED ? "sent no plan" : "robots did not arrive");
    } else if (T.st == S_GET && now >= T.next) {
        if (!missing()) {
            start_play(now);
            send_a();
            return;
        }
        request_missing(T.b[0].addr, -1); // the organizer has them all
        T.next = now + RETRY_MS;
    } else if (T.st == S_RESULT && now >= T.next) {
        if (now >= T.deadline) {
            fail("sent no standings");
            return;
        }
        uint8_t h[4];
        put32(h, T.my_hash);
        send_t(T.b[0].addr, 'R', h, 4);
        T.next = now + PLAN_EVERY_MS;
    }
}

// ---- both ---------------------------------------------------------------------------

static int lowest(const tn_peer_t *p, int n)
{
    int best = -1;
    const uint8_t *m = s_me;
    for (int i = 0; i < n; i++)
        if (memcmp(p[i].mac, m, 6) < 0) best = i, m = p[i].mac;
    return best;
}

int tn_start(uint32_t seed, int seeds, int64_t now)
{
    if (!s_io || tn_busy()) return -1;
    tn_peer_t p[TN_PEERS];
    int np = s_io->peers ? s_io->peers(p, TN_PEERS, now) : 0;
    if (np <= 0) return -2;
    int lo = lowest(p, np);
    if (lo < 0) {
        organize(seed, seeds, now, NULL);
        return 0;
    }
    reset(); // ask the lowest MAC to organize
    T.role = R_ASK;
    T.b[0].addr = p[lo].addr;
    memcpy(T.b[0].mac, p[lo].mac, 6);
    snprintf(T.b[0].name, sizeof T.b[0].name, "%s", p[lo].name);
    T.seed = seed, T.seeds = seeds;
    T.next = now;
    printf("tourney: asking %s to organize\n", T.b[0].name);
    event(TN_EV_STATUS);
    return 0;
}

void tn_rx(rn_addr_t from, const uint8_t mac[6], const char *name, const uint8_t *b, int n, int64_t now)
{
    if (!s_io || n < 5) return;
    char sub = b[0];
    uint32_t tid = get32(b + 1);
    const uint8_t *d = b + 5;
    n -= 5;
    if (sub == 'S') { // anyone may ask for a source we have
        if (n >= 10) rn_push(from, get32(d), get16(d + 4), get32(d + 6), PUSH_MAX);
        return;
    }
    if (sub == 'O') {
        // Being asked to organize switches the screen too: same opt-in as joining.
        if (!tn_busy() && s_io->may_join && !s_io->may_join(now)) {
            // (an O carries no tournament id yet: mark it 1 for the TOURNEY NEARBY hint)
            if (!s_near.tid || now - s_near.at > 10000)
                printf("tourney: %s's tournament nearby, not joining (robot autojoin)\n", name);
            s_near.tid = tid ? tid : 1, s_near.at = now;
            snprintf(s_near.name, sizeof s_near.name, "%s", name);
            event(TN_EV_STATUS);
            return;
        }
        if (!tn_busy() && !s_pend.on && n >= 5) { // in a moment: hear every badge's announce first
            s_pend.on = true;
            s_pend.at = now + HEAR_MS;
            s_pend.seed = get32(d), s_pend.seeds = d[4];
            s_pend.asker.addr = from;
            memcpy(s_pend.asker.mac, mac, 6);
            snprintf(s_pend.asker.name, sizeof s_pend.asker.name, "%s", name);
        }
        return;
    }
    if (sub == 'Q' && (!tn_busy() || T.role == R_ASK) && !(T.role == R_PART && T.tid == tid)) {
        if (T.role != R_ASK && s_io->may_join && !s_io->may_join(now)) { // not now: note it, no screen change
            if (s_near.tid != tid) printf("tourney: %s's tournament nearby, not joining (robot autojoin)\n", name);
            s_near.tid = tid, s_near.at = now;
            snprintf(s_near.name, sizeof s_near.name, "%s", name);
            event(TN_EV_STATUS);
            return;
        }
        join(from, mac, name, tid, now);
        send_e();
        return;
    }
    if (tid != T.tid) return;
    if (T.role == R_ORG) org_rx(from, mac, sub, d, n, now);
    else if (T.role == R_PART) part_rx(from, mac, sub, d, n, now);
}

void tn_tick(int64_t now)
{
    if (!s_io) return;
    if (s_pend.on && now >= s_pend.at) {
        s_pend.on = false;
        if (!tn_busy()) organize(s_pend.seed, s_pend.seeds, now, &s_pend.asker);
    }
    if (T.role == R_ORG) org_tick(now);
    else if (T.role == R_PART) part_tick(now);
    else if (T.role == R_ASK && T.st == 0 && now >= T.next) {
        if (++T.tries > ASK_TRIES) {
            fail("did not organize");
            return;
        }
        uint8_t b[5];
        put32(b, T.seed);
        b[4] = T.seeds;
        uint32_t keep = T.tid;
        T.tid = 0;
        send_t(T.b[0].addr, 'O', b, 5);
        T.tid = keep;
        T.next = now + RETRY_MS;
    }
}

bool tn_take_run(uint32_t *tid, uint32_t *seed, int *seeds, int *n, int idx[TN_ROBOTS], uint8_t owner[TN_ROBOTS])
{
    if (T.taken || !((T.role == R_ORG && T.st == S_PLAN) || (T.role == R_PART && T.st == S_READY))) return false;
    T.taken = true;
    *tid = T.tid, *seed = T.seed, *seeds = T.seeds, *n = T.n;
    for (int i = 0; i < T.n; i++) idx[i] = T.idx[i], owner[i] = T.owner[i];
    return true;
}

void tn_result(uint32_t tid, uint32_t hash, const uint8_t *table, int len, int64_t now)
{
    if (tid != T.tid || T.mine_done || len > (int)sizeof T.table) return;
    T.mine_done = true;
    T.my_hash = hash;
    memcpy(T.table, table, len);
    T.tlen = len;
    printf("tourney: %08x my result %08x\n", (unsigned)tid, (unsigned)hash);
    if (T.role == R_ORG) {
        check_results(now);
    } else if (T.role == R_PART && T.st == S_READY) {
        T.st = S_RESULT;
        T.next = now;
        T.deadline = now + RESULT_MS;
    }
    event(TN_EV_STATUS);
}

int tn_standings(uint32_t *tid, uint32_t *hash, uint8_t *table, int max)
{
    if (T.st != S_DONE || !T.wlen) return 0;
    int nb = T.w[9];
    int tl = get16(T.w + 10 + nb);
    if (tl > max) return 0;
    *tid = T.tid;
    *hash = get32(T.w + 5);
    memcpy(table, T.w + 12 + nb, tl);
    return tl;
}

const char *tn_badge_name(int k) { return k >= 0 && k < T.nb ? T.b[k].name : ""; }

int tn_status(char *buf, int max)
{
    const char *org = T.b[0].name[0] ? T.b[0].name : "organizer";
    int k = 0, left = 0;
    switch (T.role == R_NONE ? -1 : T.st) {
    case -1: buf[0] = 0; return TN_IDLE;
    case S_FAIL: snprintf(buf, max, "tournament: %s %s", T.role == R_ORG ? "a badge" : org, T.why); return TN_FAILED;
    case 0: snprintf(buf, max, "asking %s to organize a tournament", org); return TN_BUSY;
    case S_COLLECT:
        for (int i = 1; i < T.nb; i++) k += !T.b[i].e && !T.b[i].gone;
        snprintf(buf, max, "collecting robots from %d badge%s", k, k == 1 ? "" : "s");
        return TN_BUSY;
    case S_FETCH: snprintf(buf, max, "fetching robots (%d left)", missing()); return TN_BUSY;
    case S_JOINED: snprintf(buf, max, "joined %s's tournament", org); return TN_BUSY;
    case S_GET: snprintf(buf, max, "getting robots from %s (%d left)", org, missing()); return TN_BUSY;
    case S_READY: snprintf(buf, max, "%s's tournament: %d robots, %d badges", org, T.n, T.nb); return TN_RUNNING;
    case S_RESULT: snprintf(buf, max, "waiting for %s's standings", org); return TN_WAITING;
    case S_PLAN:
        if (!T.mine_done) {
            snprintf(buf, max, "my tournament: %d robots, %d badges", T.n, T.nb);
            return TN_RUNNING;
        }
        for (int i = 1; i < T.nb; i++) left += !T.b[i].gone && !T.b[i].res;
        snprintf(buf, max, "waiting for %d badge%s' results", left, left == 1 ? "" : "s");
        return TN_WAITING;
    case S_DONE: {
        int nb = T.w[9], same = 0, none = 0, diff = -1;
        uint32_t official = get32(T.w + 5);
        for (int i = 0; i < nb; i++) {
            int a = T.w[10 + i];
            if (T.role == R_PART && i == T.me) a = T.mine_done && T.my_hash == official ? 1 : T.mine_done ? 0 : 2;
            if (a == 1) same++;
            else if (a == 2) none++;
            else if (diff < 0) diff = i;
        }
        if (diff >= 0) {
            snprintf(buf, max, "%s got a DIFFERENT result!", T.b[diff].name[0] ? T.b[diff].name : "a badge");
            return TN_DIFFERENT;
        }
        if (none) snprintf(buf, max, "%d badges got the same result, %d sent none", same, none);
        else snprintf(buf, max, "all %d badges got the same result", same);
        return TN_SAME;
    }
    }
    buf[0] = 0;
    return TN_IDLE;
}
